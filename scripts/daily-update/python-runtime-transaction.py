"""Authorized Python runtime plan/apply/rollback with verified official payload."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import zipfile

BASE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('daily_evidence_io', BASE / 'evidence_io.py')
evidence_io = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(evidence_io)
ATTEMPT = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
VERSION = re.compile(r'^\d+\.\d+\.\d+$')


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def checked(args, runner, timeout=600):
    result = runner([str(item) for item in args], timeout=timeout)
    if result.get('exit_code') != 0:
        raise RuntimeError('process-failed')
    return result


def runtime_version(root, runner):
    code = 'import sys;print(".".join(map(str,sys.version_info[:3])))'
    result = checked([root / 'python.exe', '-I', '-c', code], runner, 60)
    return result['stdout'].strip()


def fingerprint(root):
    root = pathlib.Path(root)
    if not root.exists():
        return {}
    return {path.relative_to(root).as_posix(): {'sha256': sha(path), 'bytes': path.stat().st_size}
            for path in sorted(root.rglob('*')) if path.is_file()
            and path.suffix != '.pyc' and '__pycache__' not in path.parts}


def validate_config(config):
    required = ['run_directory', 'attempt_id', 'current_version', 'target_version',
                'default_runtime', 'manager_runtime', 'staged_runtime', 'archive',
                'backup', 'gate_plan', 'safe_python']
    missing = [key for key in required if key not in config]
    if missing:
        raise ValueError('missing-config')
    if not ATTEMPT.fullmatch(config['attempt_id']):
        raise ValueError('invalid-attempt-id')
    if not VERSION.fullmatch(config['current_version']) or not VERSION.fullmatch(config['target_version']):
        raise ValueError('invalid-version')
    for key in ('default_runtime', 'manager_runtime', 'staged_runtime', 'archive', 'backup', 'gate_plan', 'safe_python'):
        path = pathlib.Path(config[key])
        if not path.is_absolute() and key != 'safe_python':
            raise ValueError('invalid-config-path')
    config.setdefault('gate_script', str(BASE / 'python-update-gate.py'))
    config.setdefault('runtime_health_script', str(BASE / 'runtime-health.py'))
    config.setdefault('health_imports', ['PIL', 'yaml', 'requests', 'pptx', 'lxml', 'numpy', 'pandas'])
    if not isinstance(config['health_imports'], list) or not all(isinstance(item, str) and item.isidentifier() for item in config['health_imports']):
        raise ValueError('invalid-health-imports')
    for key in ('stop_command', 'restore_command'):
        if key in config and (not isinstance(config[key], list) or not config[key] or not all(isinstance(item, str) and item for item in config[key])):
            raise ValueError('invalid-occupant-command')
    return config


def config_sha256(config):
    binding = {key: value for key, value in config.items() if key != 'attempt_id'}
    encoded = json.dumps(binding, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return hashlib.sha256(encoded).hexdigest()


def payload_entries(archive):
    entries = {}
    with zipfile.ZipFile(archive) as bundle:
        for info in bundle.infolist():
            relative = pathlib.PurePosixPath(info.filename)
            if info.is_dir():
                continue
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('unsafe-payload')
            name = relative.as_posix()
            if name == '__install__.json' or name.lower().startswith(('scripts/', 'lib/site-packages/')):
                continue
            entries[name] = (info, hashlib.sha256(bundle.read(info)).hexdigest())
    return entries


def plan(config, runner):
    config = validate_config(dict(config))
    writer = evidence_io.RunEvidence(config['run_directory'])
    plan_path = writer.output_path('python-transaction/plan.json')
    if plan_path.exists():
        raise ValueError('plan-already-evidenced')
    default = pathlib.Path(config['default_runtime'])
    manager = pathlib.Path(config['manager_runtime'])
    stage = pathlib.Path(config['staged_runtime'])
    if runtime_version(default, runner) != config['current_version'] or runtime_version(manager, runner) != config['current_version']:
        raise ValueError('current-version-mismatch')
    if runtime_version(stage, runner) != config['target_version']:
        raise ValueError('stage-version-mismatch')
    backup = pathlib.Path(config['backup'])
    if backup.exists():
        raise ValueError('backup-already-exists')
    records = {}
    for label, root in (('runtime', default), ('manager', manager)):
        shutil.copytree(root, backup / label, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        records[label] = fingerprint(root)
        if records[label] != fingerprint(backup / label):
            raise RuntimeError('backup-hash-mismatch')
    candidates = json.dumps(config['health_imports'])
    code = ('import importlib.util,json;names=json.loads(' + repr(candidates) + ');'
            'print(json.dumps([name for name in names if importlib.util.find_spec(name) is not None]))# import_candidates')
    baseline = json.loads(checked([default / 'python.exe', '-I', '-c', code], runner, 60)['stdout'])
    manager_config = config.get('manager_config')
    document = {
        'schema_version': 1, 'status': 'plan-ready', 'attempt_id': config['attempt_id'],
        'old': config['current_version'], 'new': config['target_version'],
        'created_at': datetime.datetime.now().astimezone().isoformat(),
        'backup': str(backup), 'archive_sha256': sha(config['archive']),
        'gate_plan_sha256': sha(config['gate_plan']), 'config_sha256': config_sha256(config), 'records': records,
        'site_packages_before': fingerprint(default / 'Lib/site-packages'),
        'baseline_imports': baseline,
        'manager_config_sha256': sha(manager_config) if manager_config else None,
    }
    writer.write_json_new('python-transaction/plan.json', document)
    return document


def read_plan(config):
    return json.loads((pathlib.Path(config['run_directory']) / 'python-transaction/plan.json').read_text(encoding='utf-8'))


def attempt_available(writer, attempt, mode):
    for suffix in ('', '-error'):
        path = writer.output_path(f'python-transaction/{mode}-{attempt}{suffix}.json')
        if path.exists():
            raise ValueError('attempt-already-evidenced')


def verify_gate(config, plan_document, runner):
    gate_path = pathlib.Path(config['gate_plan'])
    if sha(gate_path) != plan_document['gate_plan_sha256']:
        raise ValueError('gate-plan-drift')
    result = checked([config['safe_python'], '-X', 'utf8', config['gate_script'], 'verify', '--plan', gate_path], runner, 90)
    gate = json.loads(result['stdout'])
    metadata = json.loads(gate_path.read_text(encoding='utf-8'))
    if not gate.get('ok') or gate.get('status') != 'selection-verified' or gate.get('version') != config['target_version']:
        raise ValueError('gate-not-verified')
    if gate.get('install_argv') != metadata.get('install_argv'):
        raise ValueError('gate-command-drift')
    if metadata['archive_sha256'] != sha(config['archive']) or plan_document['archive_sha256'] != sha(config['archive']):
        raise ValueError('archive-drift')
    if metadata['selected_index_sha256'] != sha(metadata['selected_index']):
        raise ValueError('selected-index-drift')
    return gate


def restore_tree(root, backup, entries):
    backup_names = {path.relative_to(backup).as_posix().casefold() for path in backup.rglob('*') if path.is_file()}
    for name in entries:
        target = root / name
        if name.casefold() not in backup_names and target.is_file():
            target.unlink()
    for source in backup.rglob('*'):
        if not source.is_file():
            continue
        target = root / source.relative_to(backup)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def rollback(config, runner, manage_occupants=True):
    config = validate_config(dict(config))
    writer = evidence_io.RunEvidence(config['run_directory'])
    attempt_available(writer, config['attempt_id'], 'rollback')
    plan_document = read_plan(config)
    if plan_document.get('config_sha256') != config_sha256(config):
        raise ValueError('config-drift')
    stop_attempted = False
    try:
        if manage_occupants and config.get('stop_command'):
            stop_attempted = True
            checked(config['stop_command'], runner, 90)
        entries = payload_entries(config['archive'])
        default = pathlib.Path(config['default_runtime'])
        manager = pathlib.Path(config['manager_runtime'])
        backup = pathlib.Path(plan_document['backup'])
        restore_tree(manager, backup / 'manager', entries)
        restore_tree(default, backup / 'runtime', entries)
        if runtime_version(default, runner) != config['current_version'] or runtime_version(manager, runner) != config['current_version']:
            raise RuntimeError('rollback-version-mismatch')
        if fingerprint(default) != plan_document['records']['runtime'] or fingerprint(manager) != plan_document['records']['manager']:
            raise RuntimeError('rollback-file-set-mismatch')
        result = {'status': 'rolled-back-verified', 'attempt_id': config['attempt_id'],
                  'default': config['current_version'], 'manager': config['current_version']}
    finally:
        if stop_attempted and config.get('restore_command'):
            try:
                checked(config['restore_command'], runner, 90)
            except Exception as restore_error:
                error_path = writer.output_path(f"python-transaction/rollback-{config['attempt_id']}-error.json")
                if not error_path.exists():
                    writer.write_json_new(error_path, {'type': type(restore_error).__name__,
                        'message': str(restore_error), 'phase': 'restore'})
                raise
    writer.write_json_new(f"python-transaction/rollback-{config['attempt_id']}.json", result)
    return result


def health(config, plan_document, writer, runner):
    default = pathlib.Path(config['default_runtime'])
    manager = pathlib.Path(config['manager_runtime'])
    if runtime_version(default, runner) != config['target_version'] or runtime_version(manager, runner) != config['target_version']:
        raise RuntimeError('post-update-version-mismatch')
    output = writer.output_path(f"python-transaction/shells-{config['attempt_id']}.json")
    result = runner([config['safe_python'], '-X', 'utf8', config['runtime_health_script'], 'shells',
                     '--runtime', 'python', '--expected-version', config['target_version'], '--output', output], timeout=300)
    healthy = False
    try:
        healthy = result.get('exit_code') == 0 and json.loads(result['stdout']).get('ok') is True and output.is_file() and json.loads(output.read_text(encoding='utf-8-sig')).get('ok') is True
    except (ValueError, OSError):
        healthy = False
    if not healthy:
        raise RuntimeError('runtime-health')
    stdlib = checked([default / 'python.exe', '-c', 'import ssl,sqlite3,ctypes,venv;print("stdlib-ok")'], runner, 60)
    imports = 'no-baseline-imports'
    if plan_document['baseline_imports']:
        code = 'import ' + ','.join(plan_document['baseline_imports']) + ';print("existing third-party imports ok")'
        imports = checked([default / 'python.exe', '-c', code], runner, 90)['stdout'].strip()
    pip = checked([default / 'python.exe', '-m', 'pip', 'check'], runner, 120)['stdout'].strip()
    return {'default': config['target_version'], 'manager': config['target_version'],
            'shells': str(output), 'stdlib': stdlib['stdout'].strip(), 'imports': imports, 'pip_check': pip}


def apply(config, runner):
    config = validate_config(dict(config))
    writer = evidence_io.RunEvidence(config['run_directory'])
    attempt_available(writer, config['attempt_id'], 'apply')
    plan_document = read_plan(config)
    if plan_document.get('config_sha256') != config_sha256(config):
        raise ValueError('config-drift')
    touched = False
    stop_attempted = False
    try:
        if config.get('stop_command'):
            stop_attempted = True
            checked(config['stop_command'], runner, 90)
        gate = verify_gate(config, plan_document, runner)
        touched = True
        checked(gate['install_argv'], runner)
        default = pathlib.Path(config['default_runtime'])
        manager = pathlib.Path(config['manager_runtime'])
        if runtime_version(manager, runner) != config['target_version']:
            raise RuntimeError('manager-version-mismatch')
        entries = payload_entries(config['archive'])
        stage = pathlib.Path(config['staged_runtime'])
        for name, (_, expected_hash) in sorted(entries.items()):
            source = stage / name
            if not source.is_file() or sha(source) != expected_hash:
                raise ValueError('staged-payload-drift')
            target = default / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        if runtime_version(default, runner) != config['target_version']:
            raise RuntimeError('default-version-mismatch')
        if fingerprint(default / 'Lib/site-packages') != plan_document['site_packages_before']:
            raise RuntimeError('third-party-files-changed')
        result = health(config, plan_document, writer, runner)
        manager_config = config.get('manager_config')
        if manager_config and sha(manager_config) != plan_document['manager_config_sha256']:
            raise RuntimeError('manager-config-drift')
        result.update({'status': 'updated-verified', 'attempt_id': config['attempt_id'],
                       'baseline_imports': plan_document['baseline_imports'], 'rollback_triggered': False})
    except Exception as error:
        writer.write_json_new(f"python-transaction/apply-{config['attempt_id']}-error.json",
                              {'type': type(error).__name__, 'message': str(error), 'touched': touched})
        if touched:
            rollback(config, runner, manage_occupants=False)
        raise
    finally:
        if stop_attempted and config.get('restore_command'):
            try:
                checked(config['restore_command'], runner, 90)
            except Exception as restore_error:
                error_path = writer.output_path(f"python-transaction/apply-{config['attempt_id']}-error.json")
                if not error_path.exists():
                    writer.write_json_new(error_path, {'type': type(restore_error).__name__,
                        'message': str(restore_error), 'phase': 'restore', 'touched': touched})
                raise
    writer.write_json_new(f"python-transaction/apply-{config['attempt_id']}.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['plan', 'apply', 'rollback'])
    parser.add_argument('--config', type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding='utf-8-sig'))
        _runtime_spec = importlib.util.spec_from_file_location('daily_runtime_health', BASE / 'runtime-health.py')
        runtime = importlib.util.module_from_spec(_runtime_spec)
        _runtime_spec.loader.exec_module(runtime)
        result = globals()[args.mode](config, runtime.run_hidden)
        print(json.dumps({'ok': True, 'mode': args.mode, 'status': result['status']}, ensure_ascii=False))
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(json.dumps({'ok': False, 'mode': args.mode, 'error_type': type(error).__name__, 'message': str(error)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
