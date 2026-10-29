"""The fixtures matrix in ci.yml runs every PowerShell suite of each module profile it covers in exactly one job."""
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/ci.yml'
RUNNER = ROOT / 'scripts/Run-PowerShellTests.cjs'


def list_suites(module, profile, only=None, skip=None):
    args = ['node', str(RUNNER), '--list', '--module', module, '--profile', profile]
    if only:
        args += ['--only', only]
    if skip:
        args += ['--skip', skip]
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
    return result.returncode, result.stdout.splitlines(), result.stderr.strip()


class FixtureShardTests(unittest.TestCase):
    # A failure lists every misplaced suite.
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        job = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))['jobs']['fixtures']
        cls.entries = job['strategy']['matrix']['include']
        cls.step = next(step for step in job['steps'] if step.get('name') == 'Run module fixture tests')

    def test_step_passes_entry_filters_to_runner(self):
        self.assertEqual(self.step['env'], {'FIXTURE_ONLY': '${{ matrix.only }}', 'FIXTURE_SKIP': '${{ matrix.skip }}'})
        self.assertIn("'--only', $env:FIXTURE_ONLY", self.step['run'])
        self.assertIn("'--skip', $env:FIXTURE_SKIP", self.step['run'])

    def test_each_suite_runs_in_exactly_one_job(self):
        groups = {}
        for entry in self.entries:
            groups.setdefault((entry['module'], entry['profile']), []).append(entry)
        for (module, profile), entries in groups.items():
            with self.subTest(module=module, profile=profile):
                code, suites, error = list_suites(module, profile)
                self.assertEqual(code, 0, error)
                jobs = {suite: [] for suite in suites}
                for entry in entries:
                    name = entry.get('name') or f'{module} fixtures'
                    code, selected, error = list_suites(module, profile, entry.get('only'), entry.get('skip'))
                    self.assertEqual(code, 0, f'{name}: {error}')
                    for suite in selected:
                        jobs[suite].append(name)
                # [] means no job runs the suite; two names mean two jobs run it.
                self.assertEqual({suite: names for suite, names in jobs.items() if len(names) != 1}, {})


if __name__ == '__main__':
    unittest.main()
