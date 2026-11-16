"""Collect known read-only audits, keep full evidence, print bounded counts and paths only."""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import sys

BASE = pathlib.Path(__file__).resolve().parent
ROOT = BASE.parents[1]

def sibling(name, filename):
    spec = importlib.util.spec_from_file_location(name, BASE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

runtime = sibling('summary_runtime', 'runtime-health.py')
evidence = sibling('summary_evidence', 'evidence_io.py')
KINDS = ('menu', 'closure', 'catalog')


def command(kind):
    if kind == 'menu':
        return ['D:/Codex/tools/bin/node.exe', 'D:/Codex/.codex/scripts/audit-skill-menu-i18n.cjs', '--json']
    if kind == 'closure':
        return [sys.executable, '-B', 'D:/agents/skills-manager/skills/skill-install-guard/scripts/skill_resource_closure.py',
                '--root', 'D:/agents/skills-manager/skills', '--strict', '--format', 'json']
    if kind == 'catalog':
        return [sys.executable, '-B', str(ROOT / 'scripts/generate_skill_catalog.py'), '--dry-run']
    raise ValueError('unknown-report-kind')


def count(value, key):
    number = value[key]
    if type(number) is not int or number < 0:
        raise ValueError('invalid-report-count')
    return number


def summarize(kind, value, source, raw):
    paths = []
    if kind == 'menu':
        n = count(value, 'findingCount')
        identity = count(value, 'identityFindingCount')
        warnings = count(value, 'warningCount')
        rows = value.get('findings', [])
        if not isinstance(rows, list) or len(rows) != n:
            raise ValueError('incomplete-menu-report')
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get('file'), str):
                raise ValueError('invalid-finding-path')
            paths.append(row['file'])
        result = dict(ok=n == identity == warnings == 0, finding_count=n, identity_finding_count=identity, warning_count=warnings)
    elif kind == 'closure':
        summary = value['summary']
        n = count(summary, 'finding_count')
        rows = value.get('findings', [])
        if not isinstance(rows, list) or len(rows) != n:
            raise ValueError('incomplete-closure-report')
        paths = [row['resolved'] for row in rows]
        if any(not isinstance(path, str) for path in paths):
            raise ValueError('invalid-finding-path')
        result = dict(ok=n == 0, finding_count=n, active_skill_count=count(summary, 'active_skill_count'))
    elif kind == 'catalog':
        checks = value['checks']
        if (checks['ledger'].get('status') not in ('pass', 'partial', 'conflict')
                or checks['resource_closure'].get('status') not in ('pass', 'preexisting-findings', 'not-run', 'fail')):
            raise ValueError('unknown-catalog-status')
        result = dict(ok=checks.get('scan_complete') is True and checks['ledger'].get('status') == 'pass'
                      and checks['resource_closure'].get('status') == 'pass',
                      artifact_count=count(value, 'artifact_count'), ledger_status=checks['ledger']['status'],
                      closure_status=checks['resource_closure']['status'])
    else:
        raise ValueError('unknown-report-kind')
    unique = sorted(set(paths))
    result.update(kind=kind, evidence=str(source), evidence_sha256=hashlib.sha256(raw).hexdigest(),
                  evidence_bytes=len(raw), changed_path_count=len(unique), paths=unique[:8],
                  omitted_count=max(0, len(unique)-8))
    return result


def bounded(value, budget=6000):
    if type(budget) is not int or not 512 <= budget <= 6000:
        raise ValueError('budget-outside-512-6000')
    result = dict(value, paths=list(value.get('paths', [])))
    while True:
        text = json.dumps(result, ensure_ascii=False, separators=(',', ':'))
        if len(text.encode('utf-8')) + 1 <= budget:
            return text
        if result['paths']:
            result['paths'].pop()
            result['omitted_count'] += 1
        else:
            raise ValueError('metadata-exceeds-budget')


def read_report(kind, source):
    source = pathlib.Path(source)
    if not source.is_absolute() or not source.is_file() or source.is_symlink() or source.is_junction():
        raise ValueError('regular-report-file-required')
    raw = source.read_bytes()
    return summarize(kind, json.loads(raw.decode('utf-8-sig')), source, raw)


def collect(kind, run_directory, output, runner=runtime.run_hidden):
    writer = evidence.RunEvidence(run_directory)
    if writer.root.drive.lower() != 'd:':
        raise ValueError('d-drive-evidence-required')
    path = writer.output_path(output)
    if path.exists():
        raise ValueError('evidence-already-exists')
    child = runner(command(kind), timeout=120, env=runtime.fresh_environment())
    if child['status'] != 'exited' or child['exit_code'] not in (0, 1):
        raise ValueError('audit-process-unavailable')
    raw = child['stdout'].encode('utf-8')
    result = summarize(kind, json.loads(child['stdout'].lstrip('\ufeff')), path, raw)
    # JSON schema is validated before publication. Full report never goes to stdout.
    writer.write_text_new(output, child['stdout'])
    result['process_exit_code'] = child['exit_code']
    result['ok'] = result['ok'] and child['exit_code'] == 0
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    for name in ('read', 'collect'):
        p = sub.add_parser(name)
        p.add_argument('--kind', choices=KINDS, required=True)
        p.add_argument('--max-bytes', type=int, default=6000)
        if name == 'read':
            p.add_argument('--input', required=True, type=pathlib.Path)
        else:
            p.add_argument('--run-directory', required=True, type=pathlib.Path)
            p.add_argument('--output', required=True)
    args = parser.parse_args()
    try:
        if not 512 <= args.max_bytes <= 6000:
            raise ValueError('budget-outside-512-6000')
        value = read_report(args.kind, args.input) if args.mode == 'read' else collect(args.kind, args.run_directory, args.output)
        sys.stdout.buffer.write(bounded(value, args.max_bytes).encode('utf-8') + b'\n')
        return 0 if value['ok'] else 1
    except (OSError, ValueError, KeyError, TypeError):
        print('{"ok":false,"status":"invalid-or-unavailable-report"}')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
