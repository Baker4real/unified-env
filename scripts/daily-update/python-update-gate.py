"""Pin an official Python Manager candidate before an authorized update transaction.

prepare snapshots the index and proves exact selection with the official manager's
--dry-run. verify checks the snapshot and manager again immediately before apply.
Neither command installs or replaces a runtime, nor grants update authorization.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import sys
import urllib.parse
import urllib.request

SPEC = importlib.util.spec_from_file_location('daily_runtime_health', pathlib.Path(__file__).with_name('runtime-health.py'))
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)
OFFICIAL_INDEX = 'https://www.python.org/ftp/python/index-windows.json'


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def select_candidate(index, version):
    if not isinstance(index, dict) or not isinstance(index.get('versions'), list):
        raise ValueError('invalid-index-shape')
    if not re.fullmatch(r'3\.\d+\.\d+', version):
        raise ValueError('exact-stable-candidate-required')
    line = '.'.join(version.split('.')[:2])
    matches = [r for r in index.get('versions', []) if isinstance(r, dict)
               and r.get('sort-version') == version and r.get('id') == f'pythoncore-{line}-64']
    if len(matches) != 1:
        raise ValueError('exact-stable-candidate-not-unique')
    candidate = matches[0]
    if not isinstance(candidate.get('hash'), dict):
        raise ValueError('invalid-candidate-hash-shape')
    expected_url = f'https://www.python.org/ftp/python/{version}/python-{version}-amd64.zip'
    if (candidate.get('schema') != 1 or candidate.get('company') != 'PythonCore'
            or candidate.get('url') != expected_url or candidate.get('tag') != f'{line}-64'
            or not re.fullmatch(r'[a-fA-F0-9]{64}', str(candidate.get('hash', {}).get('sha256', '')))):
        raise ValueError('invalid-official-candidate')
    return candidate


def manager_selected(exit_code, text, version):
    if exit_code != 0 or re.search(r'\[ERROR\]|fallback|unable to access', text, re.I):
        return False
    selected = re.findall(r'(?m)^(?:Installing Python (\d+\.\d+\.\d+)\.|Python (\d+\.\d+\.\d+) is already installed\.)\s*$', text)
    versions = [left or right for left, right in selected]
    return versions == [version] and bool(re.search(r'(?m)^Skipping (?:rest of install|shortcut refresh) due to --dry-run\s*$', text))


def dry_run(manager, index, version):
    before = (sha(manager), sha(index))
    child = runtime.run_hidden([str(manager), 'install', '--source', str(index), '--dry-run', version], timeout=60)
    ok = before == (sha(manager), sha(index)) and manager_selected(
        child['exit_code'], child['stdout'] + '\n' + child['stderr'], version)
    return {'ok': ok, 'exit_code': child['exit_code'], 'process_status': child['status'],
            'target': version if ok else None, 'reason': None if ok else 'exact-manager-selection-unproven'}


def prepare(args):
    manager = pathlib.Path(args.manager or shutil.which('py') or '').resolve()
    if not manager.is_file():
        raise ValueError('python-manager-unavailable')
    try:
        manager_hash = sha(manager)
    except OSError as error:
        raise ValueError('python-manager-unhashable-use-verified-package-executable') from error
    if args.index:
        if not args.index_sha256 or sha(args.index) != args.index_sha256.lower():
            raise ValueError('official-index-hash-mismatch')
        data = args.index.read_bytes()
        source = 'caller-verified-official-index'
    else:
        if not args.proxy:
            raise ValueError('resolved-proxy-required')
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({'https': args.proxy}))
        with opener.open(OFFICIAL_INDEX, timeout=45) as response:
            if response.url != OFFICIAL_INDEX:
                raise ValueError('unexpected-index-redirect')
            data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise ValueError('index-too-large')
        source = 'official-https-fetch'
    candidate = select_candidate(json.loads(data.decode('utf-8-sig')), args.version)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    index_path = args.out_dir.resolve() / 'python-selected-index.json'
    plan_path = args.out_dir.resolve() / 'python-update-plan.json'
    if index_path.exists() or plan_path.exists():
        raise ValueError('use-new-python-plan-directory')
    # A single record and null next prevent a later fallback/pagination selection.
    with index_path.open('x', encoding='utf-8') as stream:
        json.dump({'versions': [candidate], 'next': None}, stream, indent=2)
        stream.write('\n')
    selected = dry_run(manager, index_path, args.version)
    if sha(manager) != manager_hash:
        selected = {'ok': False, 'reason': 'manager-drift-during-prepare'}
    plan = {'schema_version': 1, 'status': 'selection-verified' if selected['ok'] else 'blocked',
            'created_at': datetime.datetime.now().astimezone().isoformat(),
            'version': args.version, 'source_url': OFFICIAL_INDEX, 'source_method': source,
            'source_index_sha256': hashlib.sha256(data).hexdigest(),
            'selected_index': str(index_path), 'selected_index_sha256': sha(index_path),
            'archive_sha256': candidate['hash']['sha256'].lower(),
            'manager': str(manager), 'manager_sha256': manager_hash, 'dry_run': selected,
            'install_argv': [str(manager), 'install', '--source', str(index_path), '--update', args.version, '--yes'],
            'authorization': 'separate-authorized-transaction-with-verified-rollback-required'}
    with plan_path.open('x', encoding='utf-8') as stream:
        json.dump(plan, stream, indent=2)
        stream.write('\n')
    return {'ok': selected['ok'], 'status': plan['status'], 'version': args.version, 'plan': str(plan_path)}


def verify(plan_path):
    plan = json.loads(plan_path.read_text(encoding='utf-8-sig'))
    if not isinstance(plan, dict):
        raise ValueError('invalid-plan')
    if plan.get('schema_version') != 1 or plan.get('status') != 'selection-verified' or plan.get('source_url') != OFFICIAL_INDEX:
        raise ValueError('invalid-plan')
    index = pathlib.Path(plan['selected_index'])
    manager = pathlib.Path(plan['manager'])
    if sha(index) != plan['selected_index_sha256'] or sha(manager) != plan['manager_sha256']:
        raise ValueError('selection-or-manager-drift')
    document = json.loads(index.read_text(encoding='utf-8-sig'))
    candidate = select_candidate(document, plan['version'])
    if len(document['versions']) != 1 or document.get('next') is not None or candidate['hash']['sha256'].lower() != plan['archive_sha256']:
        raise ValueError('selected-index-drift')
    argv = [str(manager), 'install', '--source', str(index), '--update', plan['version'], '--yes']
    if argv != plan.get('install_argv'):
        raise ValueError('install-command-drift')
    selection = dry_run(manager, index, plan['version'])
    if sha(index) != plan['selected_index_sha256'] or sha(manager) != plan['manager_sha256']:
        raise ValueError('selection-or-manager-drift-during-verification')
    return {'ok': selection['ok'], 'status': 'selection-verified' if selection['ok'] else 'blocked',
            'version': plan['version'], 'dry_run': selection,
            'install_argv': argv if selection['ok'] else None,
            'next_action': 'Use only inside the authorized transaction after backup and current-version checks.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest='mode', required=True)
    command = modes.add_parser('prepare')
    command.add_argument('--version', required=True)
    command.add_argument('--out-dir', type=pathlib.Path, required=True)
    command.add_argument('--index', type=pathlib.Path, help='Already verified official index; requires --index-sha256')
    command.add_argument('--index-sha256')
    command.add_argument('--proxy', help='Dynamically resolved PROXY, required for official HTTPS fetch')
    command.add_argument('--manager', help='Explicit official py.exe; otherwise resolve current PATH')
    command = modes.add_parser('verify')
    command.add_argument('--plan', type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args) if args.mode == 'prepare' else verify(args.plan)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result['ok'] else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        # Never echo index contents, arbitrary URLs, configuration, or raw manager output.
        print(json.dumps({'ok': False, 'status': 'blocked', 'error_type': type(error).__name__}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
