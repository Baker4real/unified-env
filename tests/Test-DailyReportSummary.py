"""Bounded public summary entry keeps full audit evidence out of stdout."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/daily-update/report-summary.py'


class SummaryTests(unittest.TestCase):
    def setUp(self):
        pathlib.Path('D:/agents/run-evidence').mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir='D:/agents/run-evidence', prefix='summary-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.run = pathlib.Path(self.tmp.name) / '20261116-120000'
        self.run.mkdir()

    def test_large_menu_report_is_bounded_without_descriptions(self):
        report = {'findingCount': 500, 'identityFindingCount': 0, 'warningCount': 0,
                  'findings': [{'file': f'D:/plugins/插件-{n}/SKILL.md', 'field': 'skill.description',
                                'value': 'private-fixture-' + '中文' * 2000} for n in range(500)]}
        p = self.run / 'menu.json'
        raw = json.dumps(report, ensure_ascii=False).encode()
        p.write_bytes(raw)
        child = subprocess.run([sys.executable, '-B', str(SCRIPT), 'read', '--kind', 'menu', '--input', str(p),
                                '--max-bytes', '1600'], capture_output=True)
        self.assertEqual(child.returncode, 1)
        out = json.loads(child.stdout)
        self.assertEqual(out['finding_count'], 500)
        self.assertGreater(out['omitted_count'], 0)
        self.assertEqual(len(out['paths']) + out['omitted_count'], 500)
        self.assertLessEqual(len(child.stdout), 1600)
        self.assertNotIn(b'private-fixture', child.stdout)
        self.assertEqual(p.read_bytes(), raw)

    def test_unknown_catalog_status_is_rejected_without_echo(self):
        report = {'artifact_count': 1, 'checks': {'scan_complete': True,
                  'ledger': {'status': 'synthetic-private-sentinel'}, 'resource_closure': {'status': 'pass'}}}
        p = self.run / 'catalog.json'
        p.write_text(json.dumps(report), encoding='utf-8')
        child = subprocess.run([sys.executable, '-B', str(SCRIPT), 'read', '--kind', 'catalog', '--input', str(p)], capture_output=True)
        self.assertNotEqual(child.returncode, 0)
        self.assertNotIn(b'synthetic-private-sentinel', child.stdout+child.stderr)

    def test_collection_keeps_full_report_and_returns_only_summary(self):
        spec = importlib.util.spec_from_file_location('summary', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        raw = json.dumps({'findingCount': 1, 'identityFindingCount': 0, 'warningCount': 0,
                          'findings': [{'file': 'D:/fixture/SKILL.md', 'field': 'skill.description', 'value': 'secret-fixture'}]})
        calls = []
        def runner(argv, **kwargs):
            calls.append(argv)
            return {'status': 'exited', 'exit_code': 1, 'stdout': raw, 'stderr': ''}
        value = module.collect('menu', self.run, 'full-menu.json', runner=runner)
        self.assertEqual(len(calls), 1)
        self.assertEqual(json.loads((self.run / 'full-menu.json').read_text())['findings'][0]['value'], 'secret-fixture')
        self.assertNotIn('secret-fixture', json.dumps(value))
        self.assertFalse(value['ok'])
        with self.assertRaises(ValueError):
            module.collect('menu', self.run, 'full-menu.json', runner=runner)
        self.assertEqual(len(calls), 1)


if __name__ == '__main__':
    unittest.main()
