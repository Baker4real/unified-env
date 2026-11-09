"""Bind a run index, then reuse Read-DailyUpdateEvidence for bounded recovery."""
import argparse
import importlib.util
import json
import pathlib
import shutil
import sys

BASE = pathlib.Path(__file__).resolve().parent
_loader = importlib.util.spec_from_file_location('daily_step', BASE / 'daily-update-step.py')
step = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(step)
READER = BASE / 'Read-DailyUpdateEvidence.ps1'


def read_receipts(current, previous, budget=6000):
    env = step.runtime.fresh_environment()
    argv = [shutil.which('pwsh', path=env['PATH']), '-NoProfile', '-NonInteractive', '-File', str(READER),
            '-RunDirectory', str(current), '-MaxTotalBytes', str(budget)]
    if previous:
        argv += ['-PreviousRunDirectory', str(previous)]
    result = step.runtime.run_hidden(argv, timeout=40, env=env)
    if result['exit_code'] != 0:
        raise ValueError('receipt-validation-failed')
    value = json.loads(result['stdout'].lstrip('\ufeff'))
    if value.get('ok') is not True:
        raise ValueError('invalid-receipt-result')
    return value


def bound_files(run):
    run = step.evidence_path(run)
    manifest = run / 'scope-manifest.json'
    if not manifest.exists():
        manifest = run / 'scope.json'
    checkpoint = run / 'scope-checkpoint.json'
    files = [manifest, checkpoint]
    if (run / 'RESULT.md').exists():
        files.append(run / 'RESULT.md')
    units = json.loads(manifest.read_text(encoding='utf-8-sig')).get('units')
    if units is None:
        units = json.loads(checkpoint.read_text(encoding='utf-8-sig'))['contracts']
    if not isinstance(units, list) or any(not isinstance(unit, dict) for unit in units):
        raise ValueError('invalid-units')
    for unit in units:
        refs = unit.get('evidence', [])
        for ref in [refs] if isinstance(refs, str) else (refs or []):
            path = step.evidence_path(run / ref)
            if not path.is_relative_to(run):
                raise ValueError('evidence-outside-run')
            files.append(path)
    bindings = {str(p): step.digest(p.read_bytes()) for p in sorted(set(files))}
    unfinished = [u['id'] for u in units if u['status'] in ('pending', 'running', 'in_progress')]
    return bindings, unfinished


def verify_bindings(bindings):
    if not isinstance(bindings, dict) or not bindings:
        raise ValueError('missing-bindings')
    for name, expected in bindings.items():
        path = step.evidence_path(name)
        if step.digest(path.read_bytes()) != expected:
            raise ValueError('index-content-drift')


def create_index(args):
    target = step.evidence_path(args.index_path)
    current = step.evidence_path(args.run_directory)
    previous = step.evidence_path(args.previous_run_directory) if args.previous_run_directory else None
    if target.suffix.lower() != '.json':
        raise ValueError('json-index-required')
    # Hash before and after the existing validator, so the index cannot bless a concurrent change.
    bindings, unfinished = bound_files(current)
    if previous:
        bindings.update(bound_files(previous)[0])
    state = None
    if args.document_state:
        state = step.evidence_path(args.document_state)
        bindings[str(state)] = step.digest(state.read_bytes())
    value = read_receipts(current, previous)
    verify_bindings(bindings)
    index = {'schema_version': 1, 'run_directory': str(current),
             'previous_run_directory': str(previous) if previous else None,
             'scope_sha256': value['manifest_sha256'], 'unfinished_units': unfinished,
             'document_state': str(state) if state else None, 'bindings': bindings}
    encoded = json.dumps(index, ensure_ascii=False, indent=2) + '\n'
    if len(encoded.encode('utf-8')) > 262144:
        raise ValueError('index-too-large')
    if target.exists() and not args.replace:
        raise ValueError('index-exists-use-replace')
    if str(target) in bindings:
        raise ValueError('index-overlaps-bound-file')
    temp = target.with_suffix('.json.new')
    with temp.open('x', encoding='utf-8') as handle:
        handle.write(encoded)
    temp.replace(target)
    return {'ok': True, 'index_path': str(target), 'unfinished_count': len(unfinished), 'scope_sha256': value['manifest_sha256']}


def resume(args):
    path = step.evidence_path(args.index_path)
    raw = path.read_bytes()
    if len(raw) > 262144:
        raise ValueError('index-too-large')
    index = json.loads(raw.decode('utf-8-sig'))
    expected = {'schema_version','run_directory','previous_run_directory','scope_sha256','unfinished_units','document_state','bindings'}
    if not isinstance(index, dict) or set(index) != expected or index['schema_version'] != 1:
        raise ValueError('unknown-index-schema')
    current = step.evidence_path(index['run_directory'])
    previous = step.evidence_path(index['previous_run_directory']) if index['previous_run_directory'] else None
    # Bindings must cover exactly the actual receipt graph, not an unrelated valid file.
    bindings, unfinished = bound_files(current)
    if previous:
        bindings.update(bound_files(previous)[0])
    state = step.evidence_path(index['document_state']) if index['document_state'] else None
    if state:
        bindings[str(state)] = step.digest(state.read_bytes())
    if bindings != index['bindings'] or unfinished != index['unfinished_units']:
        raise ValueError('index-content-drift')
    value = read_receipts(current, previous, max(512, args.max_total_bytes - 1400))
    verify_bindings(bindings)
    if path.read_bytes() != raw or value['manifest_sha256'] != index['scope_sha256']:
        raise ValueError('index-scope-drift')
    value['resume'] = {'index_path': str(path), 'unfinished_units': unfinished,
                       'unfinished_count': len(unfinished), 'unfinished_omitted': 0,
                       'document_state': str(state) if state else None,
                       'document_action': 'reuse-Read-SessionDocument-state' if state else 'no-recorded-document-state'}
    # Reader owns decisions and counts. Trim item lists before those higher-priority fields.
    def size():
        return len(json.dumps(value, ensure_ascii=False).encode('utf-8')) + 2
    while size() > args.max_total_bytes and value['changes']:
        value['changes'].pop()
        value['emitted_count'] -= 1
        value['omitted_count'] += 1
    while size() > args.max_total_bytes and value['resume']['unfinished_units']:
        value['resume']['unfinished_units'].pop()
        value['resume']['unfinished_omitted'] += 1
    if size() > args.max_total_bytes:
        raise ValueError('budget-too-small-for-decisions-and-counts')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    create = commands.add_parser('index')
    create.add_argument('--index-path', required=True)
    create.add_argument('--run-directory', required=True)
    create.add_argument('--previous-run-directory')
    create.add_argument('--document-state')
    create.add_argument('--replace', action='store_true')
    read = commands.add_parser('resume')
    read.add_argument('--index-path', required=True)
    read.add_argument('--max-total-bytes', type=int, default=6000)
    args = parser.parse_args()
    try:
        if args.mode == 'resume' and not 512 <= args.max_total_bytes <= 6000:
            raise ValueError('invalid-budget')
        result = create_index(args) if args.mode == 'index' else resume(args)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(json.dumps({'ok': False, 'status': 'invalid-index-or-receipt', 'error_type': type(error).__name__}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
