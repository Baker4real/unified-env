"""The fixture matrices in ci.yml run every PowerShell suite of each module profile they cover in exactly one job,
and the job a docs-only change skips holds no suite that reads docs/."""
from pathlib import Path
import re
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/ci.yml'
RUNNER = ROOT / 'scripts/Run-PowerShellTests.cjs'
FIXTURE_JOBS = ('fixtures', 'safe-delete-fixtures')
DOCS_SKIPPABLE_JOB = 'safe-delete-fixtures'
# A suite reads docs/ when it names a path under it: 'docs/...', "docs\...", or Join-Path $root 'docs'.
DOCS_READ = re.compile(r"""['"/\\]docs[/\\]|['"]docs['"]""")


def list_suites(module, profile, only=None, skip=None):
    args = ['node', str(RUNNER), '--list', '--module', module, '--profile', profile]
    if only:
        args += ['--only', only]
    if skip:
        args += ['--skip', skip]
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
    return result.returncode, result.stdout.splitlines(), result.stderr.strip()


def suite_file(label):
    """The tests/ file behind a label the runner lists (a file name, possibly followed by a case)."""
    return ROOT / 'tests' / re.match(r'\S+?\.ps1', label).group(0)


class FixtureShardTests(unittest.TestCase):
    # A failure lists every misplaced suite.
    maxDiff = None

    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))['jobs']
        cls.entries = [entry for job in FIXTURE_JOBS for entry in cls.jobs[job]['strategy']['matrix']['include']]
        cls.steps = {job: next(step for step in cls.jobs[job]['steps'] if step.get('name') == 'Run module fixture tests')
                     for job in FIXTURE_JOBS}

    def test_step_passes_entry_filters_to_runner(self):
        for job, step in self.steps.items():
            with self.subTest(job=job):
                self.assertEqual(step['env'], {'FIXTURE_ONLY': '${{ matrix.only }}', 'FIXTURE_SKIP': '${{ matrix.skip }}'})
                self.assertIn("'--only', $env:FIXTURE_ONLY", step['run'])
                self.assertIn("'--skip', $env:FIXTURE_SKIP", step['run'])

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

    def test_docs_only_change_skips_only_suites_that_read_no_docs(self):
        job = self.jobs[DOCS_SKIPPABLE_JOB]
        self.assertEqual(job['needs'], 'changes')
        self.assertEqual(job['if'], "needs.changes.outputs.docs_only != 'true'")
        readers = {}
        for entry in job['strategy']['matrix']['include']:
            code, suites, error = list_suites(entry['module'], entry['profile'], entry.get('only'), entry.get('skip'))
            self.assertEqual(code, 0, f"{entry['name']}: {error}")
            self.assertTrue(suites, f"{entry['name']} selects no suite")
            for suite in suites:
                if DOCS_READ.search(suite_file(suite).read_text(encoding='utf-8')):
                    readers.setdefault(entry['name'], []).append(suite)
        # A suite listed here reads docs/: move it into a shard of the fixtures job, which every change runs.
        self.assertEqual(readers, {})


if __name__ == '__main__':
    unittest.main()
