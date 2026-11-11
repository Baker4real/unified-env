"""Execute one check and persist a fresh receipt; never echo command output or configuration."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import pathlib
import re
import shutil
import sys

BASE = pathlib.Path(__file__).resolve().parent
_loader = importlib.util.spec_from_file_location('daily_runtime', BASE / 'runtime-health.py')
runtime = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(runtime)
_evidence_loader = importlib.util.spec_from_file_location('daily_evidence_io', BASE / 'evidence_io.py')
evidence_io = importlib.util.module_from_spec(_evidence_loader)
_evidence_loader.loader.exec_module(evidence_io)
EVIDENCE = pathlib.Path('D:/agents/run-evidence')
CHECKED = 'D:/Codex/.codex/scripts/Invoke-CheckedPowerShell.ps1'
MISSING = object()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def evidence_path(value):
    path = pathlib.Path(value)
    if not path.is_absolute() or not path.is_relative_to(EVIDENCE) or '..' in path.parts:
        raise ValueError('invalid-evidence-path')
    for item in (path, *path.parents):
        if item.is_symlink() or (item.exists() and item.is_junction()):
            raise ValueError('reparse-evidence')
    return path


def json_field(value, field):
    for part in field.split('.'):
        if not isinstance(value, dict) or part not in value:
            return MISSING
        value = value[part]
    return value


def argv_for(spec, env):
    if spec['kind'] == 'native':
        if 'script' in spec or 'parameters' in spec:
            raise ValueError('mixed-execution-kinds')
        argv = spec['argv']
        if not isinstance(argv, list) or not argv or any(not isinstance(x, str) or '\x00' in x for x in argv):
            raise ValueError('invalid-argv')
        # Shell commands belong in the checked single-invocation branch.
        if pathlib.Path(argv[0]).stem.lower() in {'pwsh', 'powershell', 'cmd', 'bash', 'sh', 'agent'}:
            raise ValueError('shell-or-agent-not-supported')
        return argv
    if spec['kind'] != 'powershell':
        raise ValueError('unknown-kind')
    if 'argv' in spec:
        raise ValueError('mixed-execution-kinds')
    script = pathlib.Path(spec['script'])
    if not script.is_absolute() or script.suffix.lower() != '.ps1' or not script.is_file():
        raise ValueError('invalid-script')
    parameters = spec.get('parameters', {})
    if not isinstance(parameters, dict):
        raise ValueError('invalid-parameters')
    def quote(value):
        if isinstance(value, bool):
            return '$true' if value else '$false'
        if type(value) in (int, float):
            return str(value)
        if not isinstance(value, str) or '\x00' in value:
            raise ValueError('invalid-parameter-value')
        # PowerShell ends a single-quoted string at any of ' ‘ ’ ‚ ‛; doubling each keeps it literal.
        return "'" + re.sub('[\'‘’‚‛]', lambda match: match.group(0) * 2, value) + "'"
    command = '& ' + quote(str(script))
    for key, value in parameters.items():
        if not re.fullmatch('[A-Za-z][A-Za-z0-9]*', key):
            raise ValueError('invalid-parameter-name')
        command += ' -' + key + ':' + quote(value)
    # The receipt parses and hashes the whole stdout, so the entry's display cap (-MaxOutputChars) is turned off.
    return [shutil.which('pwsh', path=env['PATH']), '-NoProfile', '-NonInteractive', '-File',
            CHECKED, '-CommandText', command, '-TimeoutSeconds', str(spec.get('timeout_seconds', 60)),
            '-MaxOutputChars', '0']


def execute(spec):
    allowed = {'command_id', 'kind', 'argv', 'script', 'parameters', 'required_fields', 'equals', 'timeout_seconds'}
    if not isinstance(spec, dict) or set(spec) - allowed:
        raise ValueError('unknown-spec-fields')
    if not re.fullmatch('[a-zA-Z0-9._-]{1,100}', spec.get('command_id', '')):
        raise ValueError('invalid-command-id')
    required, equals = spec.get('required_fields', []), spec.get('equals', {})
    if (not isinstance(required, list) or not isinstance(equals, dict) or not (required or equals)
            or any(not isinstance(x, str) or not re.fullmatch(r'[A-Za-z0-9_.]+', x) for x in [*required, *equals])):
        raise ValueError('explicit-json-contract-required')
    timeout = spec.get('timeout_seconds', 60)
    if type(timeout) is not int or not 1 <= timeout <= 1800:
        raise ValueError('invalid-timeout')
    env = runtime.fresh_environment()
    child = runtime.run_hidden(argv_for(spec, env), timeout=timeout + (7 if spec['kind'] == 'powershell' else 0), env=env)
    output = child['stdout']
    parsed = False
    value = None
    try:
        value = json.loads(output.lstrip('\ufeff'))
        parsed = isinstance(value, dict)
    except ValueError:
        pass
    fields_ok = parsed and all(json_field(value, key) is not None and json_field(value, key) is not MISSING for key in required)
    predicates_ok = parsed and all(type(json_field(value, key)) is type(wanted) and
                                   json_field(value, key) == wanted for key, wanted in equals.items())
    return {'schema_version': 1, 'command_id': spec['command_id'],
            'ok': child['exit_code'] == 0 and bool(output.strip()) and fields_ok and predicates_ok,
            'process_status': child['status'], 'exit_code': child['exit_code'],
            'timeout': child['status'] == 'timeout' or child['exit_code'] == 124,
            'output_present': bool(output.strip()), 'json_object': parsed,
            'required_fields_ok': fields_ok, 'predicates_ok': predicates_ok,
            'stdout_bytes': len(output.encode('utf-8')), 'stdout_sha256': digest(output.encode('utf-8')),
            'stderr_bytes': len(child['stderr'].encode('utf-8')),
            'stderr_sha256': digest(child['stderr'].encode('utf-8'))}


def receipt_run(spec, explicit):
    if explicit is not None:
        root = pathlib.Path(explicit)
    else:
        resolved = spec.resolve()
        root = next((parent for parent in resolved.parents if evidence_io.RUN_NAME.fullmatch(parent.name)), None)
        if root is None:
            raise ValueError('invalid-run-directory')
    if not root.is_absolute() or not root.is_relative_to(EVIDENCE):
        raise ValueError('invalid-run-directory')
    return evidence_io.RunEvidence(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['run'])
    parser.add_argument('--spec', required=True, type=pathlib.Path)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--run-directory', type=pathlib.Path,
                        help='Current run root; normally inferred from the spec path')
    args = parser.parse_args()
    try:
        writer = receipt_run(args.spec, args.run_directory)
        receipt = writer.output_path(args.receipt)
        # Reserve before execution: a retry cannot overwrite a failed receipt or run twice accidentally.
        with receipt.open('x', encoding='utf-8') as handle:
            started = datetime.datetime.now().astimezone().isoformat()
            try:
                raw = args.spec.read_bytes()
                if len(raw) > 65536:
                    raise ValueError('spec-too-large')
                result = execute(json.loads(raw.decode('utf-8-sig')))
                result['spec_sha256'] = digest(raw)
            except (ValueError, OSError, KeyError, TypeError) as error:
                result = {'schema_version': 1, 'ok': False, 'status': 'invalid-input', 'error_type': type(error).__name__}
            result['started_at'] = started
            result['finished_at'] = datetime.datetime.now().astimezone().isoformat()
            handle.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result['ok'] else 1
    except (OSError, ValueError) as error:
        print(json.dumps({'ok': False, 'status': 'receipt-not-created', 'error_type': type(error).__name__}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
