import importlib.util
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('daily_summary', ROOT / 'scripts/daily-update/preflight-summary.py')
summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(summary)


class PreflightSummaryTests(unittest.TestCase):
    def test_only_loopback_listeners_enter_decision_and_sensitive_proxy_is_not_echoed(self):
        rows = [dict(state='Listen', address='127.0.0.1', port=17897, pid=123, process='verge-mihomo'),
                dict(state='Established', address='127.0.0.1', port=5000, pid=123, process='verge-mihomo'),
                dict(state='Listen', address='192.0.2.2', port=9000, pid=123, process='verge-mihomo')]
        report = summary.proxy_summary(rows, 'http://127.0.0.1:17897', 'http://127.0.0.1:17897')
        self.assertTrue(report['three_faces_consistent'])
        self.assertEqual(report['proxy'], 'http://127.0.0.1:17897')
        self.assertEqual(len(report['listeners']), 1)
        secret = summary.proxy_summary(rows, 'http://private:secret@host.example:123', None)
        self.assertNotIn('secret', str(secret))
        self.assertEqual(secret['git']['status'], 'invalid')

    def test_runtime_recipe_routes_npm_to_node_aliases(self):
        argv = summary.runtime_recipe('npm', '12.2.2')
        self.assertEqual(argv[argv.index('--runtime')+1], 'node')
        self.assertEqual(argv[argv.index('--aliases')+1:], ['npm','npx'])

    def test_budget_is_real_utf8_bytes_and_reports_omissions(self):
        result = dict(ok=True, interfaces=['很长的路径/'*50 for _ in range(100)], omitted_count=0)
        output = summary.bounded_json(result, 600)
        self.assertLessEqual(len(output.encode('utf-8'))+1, 600)
        self.assertGreater(result['omitted_count'], 0)

    def test_ambiguous_live_ports_are_not_guessed(self):
        rows = [dict(state='Listen', address='127.0.0.1', port=port, pid=123, process='mihomo') for port in (17897,17898)]
        result = summary.proxy_summary(rows, 'http://127.0.0.1:17897', 'http://127.0.0.1:17898')
        self.assertFalse(result['ok'])
        self.assertIsNone(result['proxy'])

    def test_final_cli_stdout_uses_budgeted_utf8_with_lf(self):
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/daily-update/preflight-summary.py'),
                                 '--max-bytes', '512', 'module', '--id', 'host-safety'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLessEqual(len(result.stdout), 512)
        self.assertTrue(result.stdout.endswith(b'\n'))
        self.assertNotIn(b'\r\n', result.stdout)


if __name__ == '__main__':
    unittest.main()
