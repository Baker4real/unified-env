"""Kimi official upgrades with an independent pre-install binary recovery point."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import urllib.request

BASE = pathlib.Path(__file__).resolve().parent

def sibling(name, file):
    spec = importlib.util.spec_from_file_location(name, BASE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

runtime = sibling('kimi_runtime_health', 'runtime-health.py')
evidence = sibling('kimi_evidence', 'evidence_io.py')
OFFICIAL_INSTALLER = 'https://code.kimi.com/kimi-code/install.ps1'


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def physical(path):
    path = pathlib.Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('absolute-physical-path-required')
    for item in (path, *path.parents):
        if item.is_symlink() or (item.exists() and item.is_junction()):
            raise ValueError('reparse-path')
    return path


def config_context(config):
    exe = physical(config['executable'])
    if exe.name.lower() != 'kimi.exe' or exe.parent.name.lower() != 'bin':
        raise ValueError('kimi-executable-required')
    writer = evidence.RunEvidence(config['run_directory'])
    if writer.root.drive.lower() != 'd:' or exe.is_relative_to(writer.root):
        raise ValueError('independent-d-drive-evidence-required')
    versions = [config[key] for key in ('current_version', 'target_version')]
    if any(not re.fullmatch(r'\d+\.\d+\.\d+', value) for value in versions):
        raise ValueError('stable-version-required')
    if tuple(map(int, versions[0].split('.'))) >= tuple(map(int, versions[1].split('.'))):
        raise ValueError('newer-stable-required')
    return exe, writer


def version(exe, runner):
    result = runner([str(exe), '--version'], timeout=30)
    if result['status'] != 'exited' or result['exit_code'] != 0:
        raise RuntimeError('version-probe-failed')
    return result['stdout'].strip()


def fetch_installer():
    # Kimi's recorded official installer uses the existing direct route.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(OFFICIAL_INSTALLER, timeout=60) as response:
        if response.url not in {OFFICIAL_INSTALLER, 'https://cdn.kimi.com/kimi-code/install.ps1'}:
            raise ValueError('unexpected-installer-redirect')
        data = response.read(4 * 1024 * 1024 + 1)
    if not data or len(data) > 4 * 1024 * 1024:
        raise ValueError('invalid-installer-size')
    return data


def binding(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def plan(config, runner=runtime.run_hidden, fetcher=fetch_installer):
    exe, writer = config_context(config)
    target = writer.output_path('kimi-transaction/plan.json')
    if target.exists():
        raise ValueError('plan-already-exists')
    if version(exe, runner) != config['current_version']:
        raise ValueError('current-version-mismatch')
    old_hash = sha(exe)
    backup = writer.output_path('kimi-transaction/old-kimi.exe')
    backup.parent.mkdir(parents=True, exist_ok=True)
    if not backup.exists():
        with backup.open('xb') as stream:
            stream.write(exe.read_bytes())
    if sha(backup) != old_hash or sha(exe) != old_hash:
        raise ValueError('backup-hash-mismatch')
    # Fetch before create: a transient download failure leaves a reusable verified
    # old binary, not an empty installer or an unrecoverable partially prepared run.
    installer_bytes = fetcher()
    installer = writer.output_path('kimi-transaction/official-install.ps1')
    if installer.exists():
        if installer.read_bytes() != installer_bytes:
            raise ValueError('unbound-installer-drift')
    else:
        with installer.open('xb') as stream:
            stream.write(installer_bytes)
    result = dict(schema_version=1, status='prepared', config_sha256=binding(config),
                  executable=str(exe), backup=str(backup), old_sha256=old_hash,
                  installer=str(installer), installer_sha256=sha(installer), installer_url=OFFICIAL_INSTALLER,
                  current_version=config['current_version'], target_version=config['target_version'])
    writer.write_json_new('kimi-transaction/plan.json', result)
    return result


def load_plan(config):
    exe, writer = config_context(config)
    data = json.loads(writer.output_path('kimi-transaction/plan.json').read_text(encoding='utf-8'))
    if data.get('schema_version') != 1 or data['config_sha256'] != binding(config):
        raise ValueError('plan-config-drift')
    for key, name, expected in [('backup', 'old-kimi.exe', data['old_sha256']),
                                 ('installer', 'official-install.ps1', data['installer_sha256'])]:
        path = writer.output_path('kimi-transaction/' + name)
        if str(path) != data[key] or sha(path) != expected:
            raise ValueError(key + '-hash-mismatch')
    return exe, writer, data


def restore_binary(exe, writer, data, runner):
    temporary = exe.with_name('.kimi-restore-' + data['old_sha256'][:16] + '.tmp')
    physical(temporary)
    with temporary.open('xb') as stream:
        stream.write(pathlib.Path(data['backup']).read_bytes())
    if sha(temporary) != data['old_sha256']:
        raise ValueError('rollback-copy-mismatch')
    physical(exe)
    os.replace(temporary, exe)
    return sha(exe) == data['old_sha256'] and version(exe, runner) == data['current_version']


def apply(config, runner=runtime.run_hidden):
    exe, writer, data = load_plan(config)
    if sha(exe) != data['old_sha256'] or version(exe, runner) != data['current_version']:
        raise ValueError('active-binary-drift')
    # Create-only intent prevents overlapping/repeated installers and survives a lost job ID.
    writer.write_json_new('kimi-transaction/apply-intent.json', dict(plan_sha256=sha(writer.output_path('kimi-transaction/plan.json'))))
    env = runtime.fresh_environment()
    for key in list(env):
        if key.upper() in {'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY'}:
            del env[key]
    env['KIMI_NO_MODIFY_PATH'] = '1'
    # Pin both official installer inputs; inherited values must not select a
    # different runtime or race the planned stable version with latest.
    env['KIMI_VERSION'] = data['target_version']
    env['KIMI_INSTALL_DIR'] = str(exe.parent.parent)
    pwsh = shutil.which('pwsh', path=env['PATH'])
    if not pwsh:
        raise ValueError('powershell-unavailable')
    result = dict(status='failed', installation_ok=False, health_ok=False,
                  rollback_available=True, rollback_triggered=False, rollback_ok=None)
    try:
        child = runner([pwsh, '-NoProfile', '-NonInteractive', '-File', data['installer']], timeout=600, env=env)
        result['installer_process_status'] = child['status']
        result['installer_exit_code'] = child['exit_code']
        if child['status'] != 'exited':
            # No terminal process evidence: never race a still-running installer with restore.
            result['status'] = 'manual-review-installer-state'
            raise RuntimeError('installer-not-terminal')
        result['installation_ok'] = child['exit_code'] == 0
        result['health_ok'] = result['installation_ok'] and version(exe, runner) == data['target_version']
        result['rollback_available'] = sha(physical(data['backup'])) == data['old_sha256']
        if not all(result[key] for key in ('installation_ok', 'health_ok', 'rollback_available')):
            raise RuntimeError('upgrade-verification-failed')
        result['status'] = 'updated-verified'
        result['after_sha256'] = sha(exe)
    except Exception:
        if result.get('installer_process_status') == 'exited' and result['rollback_available']:
            result['rollback_triggered'] = True
            try:
                # Check backup again immediately before using it.
                if sha(physical(data['backup'])) != data['old_sha256']:
                    raise ValueError('rollback-backup-drift')
                result['rollback_ok'] = restore_binary(exe, writer, data, runner)
            except Exception:
                result['rollback_ok'] = False
            result['status'] = 'rolled-back' if result['rollback_ok'] else 'manual-review-rollback-failed'
        writer.write_json_new('kimi-transaction/apply-error.json', result)
        raise
    writer.write_json_new('kimi-transaction/apply-result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('plan', 'apply'))
    parser.add_argument('--config', type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding='utf-8-sig'))
        result = plan(config) if args.mode == 'plan' else apply(config)
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError):
        print(json.dumps(dict(status='failed', ok=False, reason='see-bound-transaction-receipt')))
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
