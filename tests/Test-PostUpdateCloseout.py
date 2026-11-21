"""Post-refresh public coordinator uses the existing guard and never rewrites skills itself."""
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/daily-update/post-update-closeout.py'


class CloseoutTests(unittest.TestCase):
    def setUp(self):
        pathlib.Path('D:/agents/run-evidence').mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir='D:/agents/run-evidence', prefix='closeout-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.run = pathlib.Path(self.tmp.name) / '20261116-120000'
        self.run.mkdir()
        spec = importlib.util.spec_from_file_location('closeout', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.calls = []
        self.state = 'healthy'
        self.menu_count = 0

    def runner(self, argv, **kwargs):
        self.calls.append(argv)
        text = ' '.join(argv)
        code = 0
        if ' status' in text:
            result = {'state': self.state, 'reasons': [], 'display': {n: 'official' for n in ['imagegen','openai-docs','review-agent','skill-creator','skill-installer']}}
            code = 0 if self.state == 'healthy' else 1
        elif 'preserve-official' in text:
            result = {'preserved': {}}
        elif 'skill-creator-overlay' in text and 'prepare_system_provenance_repair.py' in text:
            candidate = self.run/'post-refresh/creator/skill-creator-overlay/skill-creator'
            manifest = candidate.parent/'decision-manifest.json'
            result = {'candidate': str(candidate), 'decision_manifest': str(manifest)}
        elif ' plan ' in text:
            result = {'plan': str(self.run/'post-refresh/system/plan.json'), 'mode': 'atomic-six-skill-bootstrap'}
        elif 'install-skill-guarded.ps1' in text:
            self.assertEqual(pathlib.Path(argv[0]).stem.lower(), 'pwsh', argv)
            self.assertEqual(
                argv[1:6],
                ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', 'D:/Codex/.codex/scripts/install-skill-guarded.ps1'],
            )
            result = {'status': 'validated' if '--dry-run' in argv else 'succeeded'}
            if '--dry-run' not in argv:
                self.state = 'needs-skill-creator-overlay' if '--system-provenance-repair-plan' in argv else 'healthy'
        elif 'audit-skill-menu-i18n.cjs' in text:
            result = {'findingCount': self.menu_count, 'identityFindingCount': 0, 'warningCount': 0,
                      'findings': [{'file': 'D:/fixture/SKILL.md', 'value': 'private-fixture'}]*self.menu_count}
            code = int(bool(self.menu_count))
        elif 'apply-skill-menu-i18n-overlay.cjs' in text:
            result = {'changedFiles': []}
            if '--apply' in argv:
                self.menu_count = 0
        elif 'generate_skill_catalog.py' in text:
            result = {'artifact_count': 112, 'checks': {'scan_complete': True, 'ledger': {'status': 'pass'}, 'resource_closure': {'status': 'pass'}}}
        elif 'skill_resource_closure.py' in text:
            result = {'summary': {'finding_count': 0, 'active_skill_count': 112}, 'findings': []}
        else:
            raise AssertionError('unexpected public command '+text)
        return {'status': 'exited', 'exit_code': code, 'stdout': json.dumps(result), 'stderr': ''}

    def test_healthy_closeout_performs_no_active_write(self):
        result = self.module.closeout(self.run, repair=True, runner=self.runner)
        self.assertTrue(result['ok'])
        self.assertFalse(result['active_changes'])
        self.assertFalse(any('install-skill-guarded.ps1' in ' '.join(c) or 'install-skill-guarded.cmd' in ' '.join(c) or '--apply' in c for c in self.calls))

    def test_detected_refresh_runs_preserve_menu_guarded_repair_then_final_checks(self):
        self.state = 'needs-bootstrap'
        result = self.module.closeout(self.run, repair=True, runner=self.runner)
        self.assertTrue(result['ok'])
        commands = [' '.join(c) for c in self.calls]
        preserve = next(i for i,c in enumerate(commands) if 'preserve-official' in c)
        menu = next(i for i,c in enumerate(commands) if 'apply-skill-menu-i18n-overlay' in c and '--apply' in c)
        guard = next(i for i,c in enumerate(commands) if 'install-skill-guarded.ps1' in c and '--dry-run' not in c)
        self.assertLess(preserve, menu)
        self.assertLess(menu, guard)
        self.assertEqual(self.state, 'healthy')
        self.assertEqual(sum('install-skill-guarded.ps1' in c for c in commands), 4)
        self.assertFalse(any('install-skill-guarded.cmd' in c or 'cmd.exe' in c.lower() for c in commands))

    def test_closeout_recovers_current_official_system_inventory(self):
        self.state = 'needs-bootstrap'

        def current_release(argv, **kwargs):
            result = self.runner(argv, **kwargs)
            if 'status' in argv:
                status = json.loads(result['stdout'])
                status['display']['create-statusline'] = 'official'
                result['stdout'] = json.dumps(status)
            return result

        result = self.module.closeout(self.run, repair=True, runner=current_release)
        self.assertTrue(result['ok'], result)
        self.assertEqual(self.state, 'healthy')

    def test_check_only_does_not_repair_provenance(self):
        self.state = 'needs-bootstrap'
        result = self.module.closeout(self.run, repair=False, runner=self.runner)
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'repair-required')
        self.assertFalse(any('--apply' in c or 'install-skill-guarded.ps1' in ' '.join(c) or 'install-skill-guarded.cmd' in ' '.join(c) for c in self.calls))

    def test_missing_pwsh_fails_closed_without_running_guard(self):
        self.state = 'needs-bootstrap'
        with mock.patch('shutil.which', return_value=None):
            result = self.module.closeout(self.run, repair=True, runner=self.runner)
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'manual-review')
        self.assertEqual(result['failed_step'], 'system-guard-pwsh-unavailable')
        self.assertFalse(any('install-skill-guarded' in ' '.join(c) for c in self.calls))

    def test_unknown_or_partial_system_state_stops_without_mutation(self):
        self.state = 'needs-review'
        result = self.module.closeout(self.run, repair=True, runner=self.runner)
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'manual-review')
        self.assertEqual(len(self.calls), 1)

    def test_nonzero_audit_cannot_pass_even_with_healthy_json(self):
        def contradictory(argv, **kwargs):
            child = self.runner(argv, **kwargs)
            if 'skill_resource_closure.py' in ' '.join(argv):
                child['exit_code'] = 1
            return child
        result = self.module.closeout(self.run, repair=True, runner=contradictory)
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'manual-review')

    def test_nonzero_status_cannot_be_treated_as_healthy(self):
        def contradictory(argv, **kwargs):
            child = self.runner(argv, **kwargs)
            if 'status' in argv:
                child['exit_code'] = 1
            return child
        result = self.module.closeout(self.run, repair=True, runner=contradictory)
        self.assertFalse(result['ok'])
        self.assertFalse(any('--apply' in c for c in self.calls))

    def test_failure_does_not_run_following_mutations_or_claim_success(self):
        self.state = 'needs-bootstrap'
        def failing(argv, **kwargs):
            if 'preserve-official' in argv:
                return {'status':'exited','exit_code':1,'stdout':'{}','stderr':'secret-fixture'}
            return self.runner(argv, **kwargs)
        result = self.module.closeout(self.run, repair=True, runner=failing)
        self.assertFalse(result['ok'])
        self.assertNotIn('secret-fixture', json.dumps(result))
        self.assertFalse(any('--apply' in c for c in self.calls))


if __name__ == '__main__':
    unittest.main()
