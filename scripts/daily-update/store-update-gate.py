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

def sibling(name, filename):
    spec = importlib.util.spec_from_file_location(name, BASE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

runtime = sibling('store_runtime', 'runtime-health.py')
evidence = sibling('store_evidence', 'evidence_io.py')


def binding(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def context(config):
    if set(config) != {'run_directory', 'product_id', 'source', 'package_family', 'operation'}:
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
    plan = dict(schema_version=1, phase='Prepare', ok=True, config_sha256=binding(config),
                target=identity, target_sha256=binding(identity), before=before,
                operation=config['operation'], uninstall_permitted=False,
                source='msstore', product_id=config['product_id'],
                observed_at=datetime.datetime.now().astimezone().isoformat())
    writer.write_json_new('store-update/plan.json', plan)
    return plan


def apply(config, fetcher=official_metadata, observer=observed_packages, runner=runtime.run_hidden, winget=None, closer=None):
    writer = context(config)
    if writer.output_path('store-update/apply-intent.json').exists():
        raise ValueError('attempt-already-exists')
    plan = json.loads(writer.output_path('store-update/plan.json').read_text(encoding='utf-8'))
    if plan.get('schema_version') != 1 or plan.get('config_sha256') != binding(config):
        raise ValueError('plan-config-drift')
    identity = target_identity(config, fetcher(config['product_id']))
    if binding(identity) != plan.get('target_sha256') or identity != plan.get('target'):
        raise ValueError('official-target-drift')
    if checked_observation(config, observer) != plan.get('before'):
        raise ValueError('installed-state-drift')
    exe = winget or shutil.which('winget.exe')
    if not exe:
        raise ValueError('winget-unavailable')
    argv = [exe, config['operation'], '--id', config['product_id'], '--exact', '--source', 'msstore',
            '--silent', '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity', '--authentication-mode', 'silent']
    writer.write_json_new('store-update/apply-intent.json', dict(phase='Apply', argv=argv,
                          plan_sha256=binding(plan), no_uninstall=True))
    child = runner(argv, timeout=600, env=runtime.fresh_environment())
    observation_ok = True
    try:
        after = checked_observation(config, observer)
    except (ValueError, OSError, KeyError):
        after = []
        observation_ok = False
    # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE has explicit native semantics;
    # treat it as current only if the registered healthy identity still exists.
    native = child['exit_code']
    no_upgrade = config['operation'] == 'upgrade' and isinstance(native, int) and (native & 0xffffffff) == 0x8A15002B
    ok = child['status'] == 'exited' and (native == 0 or no_upgrade) and len(after) == 1
    installation_ok = ok
    closeout_ok = None
    closeout_error = None
    if ok and config['package_family'] == 'OpenAI.Codex_2p2nqsd0c76g0':
        try:
            if closer is None:
                closer = sibling('store_closeout', 'post-update-closeout.py').closeout
            closeout_ok = closer(writer.root, repair=True).get('ok') is True
        except (ValueError, OSError, RuntimeError, KeyError, TypeError) as error:
            closeout_ok = False
            closeout_error = type(error).__name__
        ok = ok and closeout_ok
    result = dict(schema_version=1, phase='Apply', ok=ok,
                  installation_ok=installation_ok, closeout_ok=closeout_ok, closeout_error=closeout_error,
                  status='updated-or-current' if ok else 'manual-review', exit_code=native,
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('prepare', 'apply'))
    parser.add_argument('--config', required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding='utf-8-sig'))
        result = (prepare if args.mode == 'prepare' else apply)(config)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result['ok'] else 1
    except (ValueError, KeyError, TypeError, OSError) as error:
        # Fixed codes only: never echo upstream JSON or config values.
        code = str(error) if isinstance(error, ValueError) and re.fullmatch('[a-z][a-z-]+', str(error)) else type(error).__name__
        print(json.dumps(dict(ok=False, status='rejected', error_code=code)))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
