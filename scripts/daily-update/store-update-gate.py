"""Preflight a Microsoft Store identity before an explicit install/upgrade; never uninstall."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import sys
import urllib.request

BASE = pathlib.Path(__file__).resolve().parent
CODEX_FAMILY = 'OpenAI.Codex_2p2nqsd0c76g0'
CODEX_PRODUCT = '9PLM9XGG6VKS'
VERSION = re.compile(r'\d{1,5}(?:\.\d{1,5}){3}')
VERIFY_RECEIPT = re.compile(r'store-update/verify-[a-z0-9][a-z0-9-]{0,55}\.json')

def sibling(name, filename):
    spec = importlib.util.spec_from_file_location(name, BASE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

runtime = sibling('store_runtime', 'runtime-health.py')
evidence = sibling('store_evidence', 'evidence_io.py')


def binding(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def is_codex(config):
    return config['package_family'] == CODEX_FAMILY and config['product_id'] == CODEX_PRODUCT


def context(config):
    fields = {'run_directory', 'product_id', 'source', 'package_family', 'operation'}
    if not isinstance(config, dict) or set(config) not in (fields, fields | {'rollback_archive'}):
        raise ValueError('invalid-store-config')
    if config['source'] != 'msstore':
        raise ValueError('store-source-required')
    if not isinstance(config['product_id'], str) or not re.fullmatch('[A-Z0-9]{12}', config['product_id']):
        raise ValueError('invalid-store-product-id')
    if not isinstance(config['package_family'], str) or not re.fullmatch(r'[A-Za-z0-9.-]+_[a-z0-9]{13}', config['package_family']):
        raise ValueError('invalid-package-family')
    if config['operation'] not in ('upgrade', 'install'):
        raise ValueError('only-store-install-or-upgrade-supported')
    writer = evidence.RunEvidence(config['run_directory'])
    if writer.root.drive.lower() != 'd:':
        raise ValueError('d-drive-evidence-required')
    if (config['package_family'] == CODEX_FAMILY or config['product_id'] == CODEX_PRODUCT) and not is_codex(config):
        raise ValueError('codex-store-identity-mismatch')
    if 'rollback_archive' in config:
        if not is_codex(config) or config['operation'] != 'upgrade' or not isinstance(config['rollback_archive'], str):
            raise ValueError('invalid-rollback-archive')
        archive = writer.output_path(config['rollback_archive'])
        if archive.suffix.lower() != '.msix' or not archive.is_file():
            raise ValueError('invalid-rollback-archive')
    return writer


def official_metadata(product_id):
    url = f'https://storeedgefd.dsx.mp.microsoft.com/v9.0/packageManifests/{product_id}?Market=CN'
    with urllib.request.urlopen(url, timeout=30) as response:
        if response.geturl() != url:
            raise ValueError('unexpected-store-redirect')
        data = response.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024:
        raise ValueError('store-metadata-too-large')
    return json.loads(data)


def target_identity(config, metadata):
    data = metadata.get('Data', {})
    if data.get('PackageIdentifier') != config['product_id'] or not isinstance(data.get('Versions'), list):
        raise ValueError('store-product-identity-mismatch')
    matches = []
    for version in data['Versions']:
        for installer in version.get('Installers', []):
            if installer.get('Architecture') != 'x64':
                continue
            # WinGet chooses the current candidate. An older correct installer
            # must never hide a newer x64 candidate with a different identity.
            if (installer.get('InstallerType') != 'msstore' or installer.get('Scope') != 'user'
                    or installer.get('MSStoreProductIdentifier') != config['product_id']
                    or installer.get('PackageFamilyName') != config['package_family']):
                raise ValueError('store-package-identity-mismatch')
            matches.append({key: installer[key] for key in ('Architecture', 'InstallerType', 'MSStoreProductIdentifier', 'PackageFamilyName', 'Scope')})
    if not matches or any(item != matches[0] for item in matches):
        raise ValueError('store-package-identity-mismatch')
    return matches[0]


def observed_packages(family):
    # Family is validated before interpolation; no command, credential or user-data query.
    command = "$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);" + (
        "@{packages=@(Get-AppxPackage|Where-Object PackageFamilyName -eq '" + family + "'|ForEach-Object{"
        "@{family=$_.PackageFamilyName;version=$_.Version;status=$_.Status.ToString()}})}|ConvertTo-Json -Depth 4 -Compress")
    child = runtime.run_hidden([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-Command', command])
    if child['status'] != 'exited' or child['exit_code'] != 0:
        raise ValueError('store-installed-query-unavailable')
    return json.loads(child['stdout'])['packages']


def checked_observation(config, observer):
    rows = observer(config['package_family'])
    if not isinstance(rows, list) or len(rows) > 1:
        raise ValueError('ambiguous-installed-package')
    for row in rows:
        if (not isinstance(row, dict) or row.get('family') != config['package_family']
                or not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', str(row.get('version', '')))
                or row.get('status') != 'Ok'):
            raise ValueError('installed-package-unhealthy')
    return rows


def package_full_name(version):
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError('invalid-codex-package-version')
    return f'OpenAI.Codex_{version}_x64__2p2nqsd0c76g0'


def powershell_script(script, *args):
    exe = shutil.which('pwsh')
    if exe is None:
        raise ValueError('pwsh-unavailable')
    return [exe, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(BASE / script), *args]


def worker_value(child):
    if child['status'] != 'exited' or child['exit_code'] != 0 or len(child['stdout']) > 16384:
        raise ValueError('store-worker-failed')
    value = json.loads(child['stdout'])
    if not isinstance(value, dict) or value.get('ok') is not True:
        raise ValueError('store-worker-failed')
    return value


def discover_staged_codex(current):
    child = runtime.run_hidden(powershell_script('Read-CodexStoreDeployment.ps1', '-CurrentVersion', current), timeout=40)
    offers = worker_value(child)['offers']
    if not isinstance(offers, list) or len(offers) > 8:
        raise ValueError('invalid-store-deployment-observation')
    for row in offers:
        if (row.get('full_name') != package_full_name(row.get('version'))
                or any(type(row[key]) is not int or row[key] <= 0 for key in ('store_record',))
                or any(row[key] is not None and (type(row[key]) is not int or row[key] <= 0)
                       for key in ('stage_record', 'occupied_record'))):
            raise ValueError('invalid-store-deployment-observation')
    version_key = lambda version: tuple(map(int, version.split('.')))
    if not offers:
        return None
    exact = max(offers, key=lambda row: version_key(row['version']))
    if version_key(exact['version']) <= version_key(current):
        raise ValueError('unexpected-store-offer-version')
    return exact


def package_command(mode, version, *args):
    package_full_name(version)
    return powershell_script('Invoke-CodexStorePackage.ps1', '-Mode', mode, '-Version', version, *args)


def prove_rollback(config, writer, version, expected=None):
    archive = config.get('rollback_archive')
    if archive is None:
        return None
    argv = package_command('Proof', version, '-Archive', str(writer.output_path(archive)))
    if expected:
        argv += ['-ArchiveSha256', expected['sha256']]
    result = worker_value(runtime.run_hidden(argv, timeout=120))
    proof = result.get('archive')
    if (result.get('phase') != 'Proof' or not isinstance(proof, dict)
            or proof.get('signature') != 'Valid' or proof.get('full_name') != package_full_name(version)
            or type(proof.get('bytes')) is not int or not 0 < proof['bytes'] <= 4 * 1024**3
            or not re.fullmatch(r'[a-f0-9]{64}', str(proof.get('sha256', '')))
            or (expected is not None and proof != expected)):
        raise ValueError('store-rollback-unverified')
    return proof


def verify_registered(version):
    receipt = worker_value(runtime.run_hidden(package_command('Verify', version), timeout=40))
    if receipt != dict(ok=True, phase='Verify', full_name=package_full_name(version), version=version, signature_verified=True):
        raise ValueError('store-registration-unverified')
    return receipt


def verify_plugins(version):
    plugins = sibling('store_codex_plugins', 'codex-store-plugins.py')
    return plugins.validate_result(plugins.verify(expected_appx_version=version), expected_appx_version=version)


def prepare(config, fetcher=official_metadata, observer=observed_packages):
    writer = context(config)
    if writer.output_path('store-update/plan.json').exists():
        raise ValueError('plan-already-exists')
    identity = target_identity(config, fetcher(config['product_id']))
    before = checked_observation(config, observer)
    if config['operation'] == 'install' and before:
        raise ValueError('install-requires-absent-package')
    if config['operation'] == 'upgrade' and not before:
        raise ValueError('upgrade-requires-installed-package')
    plan = dict(schema_version=2, phase='Prepare', ok=True, config_sha256=binding(config),
                target=identity, target_sha256=binding(identity), before=before,
                operation=config['operation'], uninstall_permitted=False,
                source='msstore', product_id=config['product_id'],
                observed_at=datetime.datetime.now().astimezone().isoformat())
    if is_codex(config) and before:
        current = before[0]['version']
        plan['staged'] = discover_staged_codex(current)
        plan['rollback'] = prove_rollback(config, writer, current)
        plan['apply_ready'] = plan['rollback'] is not None
    writer.write_json_new('store-update/plan.json', plan)
    return plan


def load_plan(config, writer):
    plan = json.loads(writer.output_path('store-update/plan.json').read_text(encoding='utf-8'))
    schemas = (2,) if is_codex(config) and config['operation'] == 'upgrade' else (1, 2)
    if plan.get('schema_version') not in schemas or plan.get('config_sha256') != binding(config):
        raise ValueError('plan-config-drift')
    return plan


def codex_acceptance(version, run_directory, closer=None):
    acceptance = dict(registration=None, plugin_adoption=None, closeout_ok=None, closeout_error=None)
    try:
        acceptance['registration'] = verify_registered(version)
        plugins = verify_plugins(version)
        acceptance['plugin_adoption'] = plugins
        if plugins.get('ok') is not True:
            return acceptance
        if closer is None:
            closer = sibling('store_closeout', 'post-update-closeout.py').closeout
        acceptance['closeout_ok'] = closer(run_directory, repair=True).get('ok') is True
    except (ValueError, OSError, RuntimeError, KeyError, TypeError) as error:
        acceptance['closeout_ok'] = False
        acceptance['closeout_error'] = type(error).__name__
    return acceptance


def deployment_argv(config, plan, writer, winget):
    if is_codex(config) and config['operation'] == 'upgrade':
        current = plan['before'][0]['version']
        staged = discover_staged_codex(current)
        if staged != plan['staged']:
            raise ValueError('store-stage-drift')
        proof = plan['rollback']
        if proof is None or prove_rollback(config, writer, current, proof) != proof:
            raise ValueError('store-rollback-unverified')
        if staged and staged['stage_record']:
            return 'register-staged', package_command('Register', staged['version'], '-CurrentVersion', current)
    exe = winget or shutil.which('winget.exe')
    if not exe:
        raise ValueError('winget-unavailable')
    return 'winget', [exe, config['operation'], '--id', config['product_id'], '--exact', '--source', 'msstore',
                      '--silent', '--accept-package-agreements', '--accept-source-agreements',
                      '--disable-interactivity', '--authentication-mode', 'silent']


def apply(config, fetcher=official_metadata, observer=observed_packages, runner=runtime.run_hidden, winget=None, closer=None):
    writer = context(config)
    if writer.output_path('store-update/apply-intent.json').exists():
        raise ValueError('attempt-already-exists')
    plan = load_plan(config, writer)
    identity = target_identity(config, fetcher(config['product_id']))
    if binding(identity) != plan.get('target_sha256') or identity != plan.get('target'):
        raise ValueError('official-target-drift')
    if checked_observation(config, observer) != plan.get('before'):
        raise ValueError('installed-state-drift')
    mechanism, argv = deployment_argv(config, plan, writer, winget)
    writer.write_json_new('store-update/apply-intent.json', dict(phase='Apply', argv=argv,
                          plan_sha256=binding(plan), mechanism=mechanism, no_uninstall=True))
    child = runner(argv, timeout=600, env=runtime.fresh_environment())
    observation_ok = True
    try:
        after = checked_observation(config, observer)
    except (ValueError, OSError, KeyError):
        after = []
        observation_ok = False
    # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE is scoped to WinGet.
    native = child['exit_code']
    no_upgrade = (mechanism == 'winget' and config['operation'] == 'upgrade' and isinstance(native, int)
                  and (native & 0xffffffff) == 0x8A15002B)
    version = after[0]['version'] if after else None
    installation_ok = child['status'] == 'exited' and (native == 0 or no_upgrade) and version is not None
    if mechanism == 'register-staged':
        installation_ok = installation_ok and version == plan['staged']['version']
    if is_codex(config) and installation_ok and after == plan['before']:
        # An update staged by the operation itself is still outstanding.
        try:
            installation_ok = discover_staged_codex(version) is None
        except (ValueError, OSError, KeyError, TypeError):
            installation_ok = False
    acceptance = dict(registration=None, plugin_adoption=None, closeout_ok=None, closeout_error=None)
    if is_codex(config) and installation_ok:
        acceptance = codex_acceptance(version, writer.root, closer)
    ok = installation_ok and (not is_codex(config) or acceptance['closeout_ok'] is True)
    status = 'updated-or-current' if ok else 'manual-review'
    if (acceptance['plugin_adoption'] or {}).get('status') == 'official-client-refresh-pending':
        status = 'official-client-refresh-pending'
    result = dict(schema_version=2, phase='Apply', ok=ok, plan_sha256=binding(plan),
                  installation_ok=installation_ok, **acceptance, mechanism=mechanism,
                  status=status, exit_code=native,
                  process_status=child['status'], product_id=config['product_id'], source='msstore',
                  package_family=config['package_family'], observed_version=after[0]['version'] if after else None,
                  previous_version=plan['before'][0]['version'] if plan['before'] else None,
                  uninstall_executed=False, observation_ok=observation_ok,
                  previous_package_retained=(after == plan['before']) if observation_ok and plan['before'] else None,
                  rollback='No uninstall was issued by this gate; retention is reported only from the post-operation observation.',
                  stdout_sha256=hashlib.sha256(child['stdout'].encode()).hexdigest(),
                  stderr_sha256=hashlib.sha256(child['stderr'].encode()).hexdigest())
    writer.write_json_new('store-update/apply-result.json', result)
    return result


def read_apply(config, writer):
    if not is_codex(config):
        raise ValueError('codex-store-identity-required')
    plan = load_plan(config, writer)
    intent = json.loads(writer.output_path('store-update/apply-intent.json').read_text(encoding='utf-8'))
    applied = json.loads(writer.output_path('store-update/apply-result.json').read_text(encoding='utf-8'))
    if (applied.get('phase') != 'Apply' or applied.get('observation_ok') is not True
            or intent.get('phase') != 'Apply' or intent.get('plan_sha256') != binding(plan)
            or applied.get('plan_sha256') != binding(plan)
            or applied.get('mechanism') != intent.get('mechanism')):
        raise ValueError('unbound-store-apply-result')
    package_full_name(applied.get('observed_version'))
    return plan, applied


def verify(config, receipt, observer=observed_packages):
    writer = context(config)
    if not isinstance(receipt, str) or not VERIFY_RECEIPT.fullmatch(receipt):
        raise ValueError('invalid-store-verify-receipt')
    _, applied = read_apply(config, writer)
    version = applied['observed_version']
    current = checked_observation(config, observer)
    if not current or current[0]['version'] != version or not applied['installation_ok']:
        raise ValueError('installed-state-drift')
    closeout_run = writer.output_path(f'store-update/{writer.root.name}-{pathlib.Path(receipt).stem}')
    closeout_run.mkdir(exist_ok=False)
    acceptance = codex_acceptance(version, closeout_run)
    ok = acceptance['closeout_ok'] is True
    state = (acceptance['plugin_adoption'] or {}).get('status')
    result = dict(schema_version=2, phase='Verify', ok=ok, apply_sha256=binding(applied),
                  observed_version=version, status='verified' if ok else (
                      'official-client-refresh-pending' if state == 'official-client-refresh-pending' else 'manual-review'),
                  **acceptance)
    writer.write_json_new(receipt, result)
    return result


def rollback(config, observer=observed_packages, runner=runtime.run_hidden):
    writer = context(config)
    plan, applied = read_apply(config, writer)
    old, new = applied['previous_version'], applied['observed_version']
    proof = plan.get('rollback')
    if (not proof or config['operation'] != 'upgrade' or old != plan['before'][0]['version']
            or old == new or proof.get('full_name') != package_full_name(old)):
        raise ValueError('store-rollback-unverified')
    current = checked_observation(config, observer)
    if not current or current[0]['version'] != new:
        raise ValueError('installed-state-drift')
    archive = writer.output_path(config['rollback_archive'])
    argv = package_command('Rollback', old, '-CurrentVersion', new,
                           '-Archive', str(archive), '-ArchiveSha256', proof['sha256'])
    writer.write_json_new('store-update/rollback-intent.json', dict(phase='Rollback', argv=argv,
                          plan_sha256=binding(plan), apply_sha256=binding(applied)))
    child = runner(argv, timeout=600, env=runtime.fresh_environment())
    try:
        installed = checked_observation(config, observer)
        ok = (worker_value(child).get('signature_verified') is True and installed == plan['before'])
    except (ValueError, OSError, KeyError, TypeError):
        ok = False
    result = dict(schema_version=2, phase='Rollback', status='restored' if ok else 'manual-review',
                  ok=ok, target_version=old, exit_code=child['exit_code'])
    writer.write_json_new('store-update/rollback-result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('mode', choices=('prepare', 'apply', 'verify', 'rollback'))
    parser.add_argument('--config', required=True, type=pathlib.Path)
    parser.add_argument('--receipt', help='New store-update/verify-<attempt>.json, required for verify')
    args = parser.parse_args()
    try:
        if (args.mode == 'verify') != (args.receipt is not None):
            raise ValueError('invalid-store-verify-receipt')
        with args.config.open('rb') as stream:
            raw = stream.read(8193)
        if len(raw) > 8192:
            raise ValueError('store-config-too-large')
        config = json.loads(raw.decode('utf-8-sig'))
        handlers = {'prepare': prepare, 'apply': apply, 'verify': verify, 'rollback': rollback}
        result = handlers[args.mode](config, args.receipt) if args.mode == 'verify' else handlers[args.mode](config)
        print(json.dumps(result, ensure_ascii=False))
        if result.get('status') == 'official-client-refresh-pending':
            return 2
        return 0 if result['ok'] else 1
    except (ValueError, KeyError, TypeError, OSError) as error:
        # Fixed codes only: never echo upstream JSON or config values.
        code = str(error) if isinstance(error, ValueError) and re.fullmatch('[a-z][a-z-]+', str(error)) else type(error).__name__
        print(json.dumps(dict(ok=False, status='rejected', error_code=code)))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
