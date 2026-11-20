"""Check official-refresh drift and coordinate only the existing approved repair/overlay tools."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import sys

BASE = pathlib.Path(__file__).resolve().parent
ROOT = BASE.parents[1]

def sibling(name, filename):
    spec = importlib.util.spec_from_file_location(name, BASE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

runtime = sibling('closeout_runtime', 'runtime-health.py')
evidence = sibling('closeout_evidence', 'evidence_io.py')
reports = sibling('closeout_reports', 'report-summary.py')
PREPARE = str(ROOT / 'modules/skill-supply-chain/implementation/prepare_system_provenance_repair.py')
MENU = 'D:/Codex/.codex/scripts/apply-skill-menu-i18n-overlay.cjs'
GUARD = 'D:/Codex/.codex/scripts/install-skill-guarded.cmd'
NODE = 'D:/Codex/tools/bin/node.exe'


class StepFailure(Exception):
    pass


def closeout(run_directory, repair=False, runner=runtime.run_hidden):
    writer = evidence.RunEvidence(run_directory)
    if writer.root.drive.lower() != 'd:' or any(c in str(writer.root) for c in '%!&|<>^"'):
        raise ValueError('physical-d-drive-shell-safe-evidence-required')
    attempt = writer.output_path('post-refresh/result.json')
    if attempt.exists():
        raise ValueError('closeout-attempt-exists')
    steps = []
    changed = False

    def call(label, argv, allowed=(0,), timeout=180):
        child = runner(argv, timeout=timeout, env=runtime.fresh_environment())
        row = dict(step=label, process_status=child['status'], exit_code=child['exit_code'],
                   stdout_sha256=hashlib.sha256(child['stdout'].encode()).hexdigest(),
                   stderr_sha256=hashlib.sha256(child['stderr'].encode()).hexdigest())
        steps.append(row)
        writer.write_json_new('post-refresh/'+label+'-receipt.json', row)
        process_ok = child['status'] == 'exited' and child['exit_code'] in allowed
        try:
            value = json.loads(child['stdout'].lstrip('\ufeff'))
        except ValueError:
            raise StepFailure(label) from None
        if not isinstance(value, dict):
            raise StepFailure(label)
        # These tools output audited machine data, not account configuration.
        writer.write_json_new('post-refresh/'+label+'.json', value)
        if not process_ok:
            raise StepFailure(label)
        return value

    def status(label):
        value = call(label, [sys.executable, '-B', PREPARE, 'status'], allowed=(0, 1, 3))
        expected_exit = {'healthy': 0, 'needs-bootstrap': 1, 'needs-skill-creator-overlay': 1, 'needs-review': 3}
        if value.get('state') not in expected_exit or steps[-1]['exit_code'] != expected_exit[value['state']]:
            raise StepFailure(label)
        return value

    def overlay(label, system_only):
        argv = [NODE, MENU] + (['--system-only'] if system_only else [])
        call(label+'-dry', argv+['--dry-run'])
        call(label+'-apply', argv+['--apply'])

    def guard(label, arguments):
        # Wrapper remains the sole active skill/ledger/catalog writer. Do not execute
        # human-readable `next` strings or infer commands from returned prose.
        cmd = [os.environ.get('COMSPEC', r'C:\Windows\System32\cmd.exe'), '/d', '/c', GUARD, *arguments]
        call(label+'-dry', cmd+['--dry-run'])
        value = call(label+'-apply', cmd)
        if value.get('status') != 'succeeded':
            raise StepFailure(label+'-apply')

    def finish(ok, state, **extra):
        result = dict(schema_version=1, ok=ok, phase='Apply' if repair else 'Check', status=state,
                      active_changes=changed, step_count=len(steps), steps=steps, **extra)
        writer.write_json_new('post-refresh/result.json', result)
        return result

    try:
        current = status('system-before')
        if current['state'] != 'healthy' and not repair:
            return finish(False, 'repair-required', system_state=current['state'])
        if current['state'] == 'needs-bootstrap':
            display = current.get('display', {})
            # The prepare tool validates the supported inventory before returning needs-bootstrap.
            if not isinstance(display, dict) or not display or any(v != 'official' for v in display.values()):
                return finish(False, 'manual-review', reason='official-display-baseline-required')
            system = str(writer.output_path('post-refresh/system'))
            call('preserve-official', [sys.executable, '-B', PREPARE, 'preserve-official', '--evidence', system])
            changed = True
            overlay('system-menu', True)
            plan = str(writer.output_path('post-refresh/system/plan.json'))
            value = call('system-plan', [sys.executable, '-B', PREPARE, 'plan', '--evidence', system, '--out', plan])
            if value.get('plan') != plan or value.get('mode') != 'atomic-six-skill-bootstrap':
                raise StepFailure('system-plan')
            guard('system-guard', ['--system-provenance-repair-plan', plan])
            current = status('system-after-bootstrap')
        if current['state'] == 'needs-skill-creator-overlay':
            changed = True
            creator = str(writer.output_path('post-refresh/creator'))
            value = call('creator-candidate', [sys.executable, '-B', PREPARE, 'skill-creator-overlay', '--evidence', creator])
            candidate = str(writer.output_path('post-refresh/creator/skill-creator-overlay/skill-creator'))
            manifest = str(writer.output_path('post-refresh/creator/skill-creator-overlay/decision-manifest.json'))
            # Paths come from the fixed recipe, never arbitrary tool output.
            if value.get('candidate') != candidate or value.get('decision_manifest') != manifest:
                raise StepFailure('creator-candidate')
            guard('creator-guard', ['--candidate', candidate, '--name', 'skill-creator',
                                    '--decision-manifest', manifest, '--update'])
            current = status('system-after-creator')
        if current['state'] != 'healthy':
            return finish(False, 'manual-review', system_state=current['state'])
        menu = call('menu-before', reports.command('menu'), allowed=(0, 1))
        summary = reports.summarize('menu', menu, writer.output_path('post-refresh/menu-before.json'),
                                    json.dumps(menu, ensure_ascii=False).encode())
        if not summary['ok']:
            if not repair:
                return finish(False, 'repair-required', reason='menu-overlay-required')
            if summary['identity_finding_count'] or summary['warning_count']:
                return finish(False, 'manual-review', reason='menu-identity-or-warning')
            changed = True
            overlay('all-menu', False)
        menu = call('menu-final', reports.command('menu'))
        closure = call('closure-final', reports.command('closure'))
        catalog = call('catalog-final', reports.command('catalog'))
        checks = {kind: reports.summarize(kind, data, writer.output_path('post-refresh/'+kind+'-final.json'), b'')['ok']
                  for kind, data in [('menu', menu), ('closure', closure), ('catalog', catalog)]}
        # Menu localization may change effective fingerprints; no old healthy snapshot
        # can substitute for the binding check after the final write.
        checks['system_provenance'] = status('system-final')['state'] == 'healthy'
        return finish(all(checks.values()), 'healthy' if all(checks.values()) else 'manual-review', checks=checks)
    except (StepFailure, ValueError, OSError, KeyError, TypeError) as error:
        code = str(error) if isinstance(error, StepFailure) else type(error).__name__
        return finish(False, 'manual-review', failed_step=code)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('check', 'repair'))
    parser.add_argument('--run-directory', type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        value = closeout(args.run_directory, repair=args.mode == 'repair')
        print(json.dumps({key: value[key] for key in ('ok', 'phase', 'status', 'active_changes', 'step_count')}, ensure_ascii=False))
        return 0 if value['ok'] else 1
    except (ValueError, OSError):
        print('{"ok":false,"status":"invalid-closeout-context"}')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
