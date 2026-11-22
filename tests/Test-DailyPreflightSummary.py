import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
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

    def test_matching_configured_proxy_wins_among_listener_ports(self):
        rows = [dict(state='Listen', address='127.0.0.1', port=27605, pid=1, process='mihomo'),
                dict(state='Listen', address='127.0.0.1', port=17897, pid=2, process='verge-mihomo')]
        proxy = 'http://127.0.0.1:17897'
        report = summary.proxy_summary(rows, proxy, proxy)
        self.assertTrue(report['three_faces_consistent'])
        self.assertEqual(report['proxy'], proxy)

    def test_ambiguous_live_ports_are_not_guessed(self):
        rows = [dict(state='Listen', address='127.0.0.1', port=port, pid=123, process='mihomo') for port in (17897,17898)]
        result = summary.proxy_summary(rows, 'http://127.0.0.1:17897', 'http://127.0.0.1:17898')
        self.assertFalse(result['ok'])
        self.assertIsNone(result['proxy'])

    def test_worktree_preserves_full_git_evidence_and_projects_renames_and_dirt_age(self):
        temp_root = 'D:/Codex/temp' if os.name == 'nt' else None
        with tempfile.TemporaryDirectory(dir=temp_root) as scratch:
            repo = pathlib.Path(scratch) / 'repo'
            run = pathlib.Path(scratch) / '20261119-020132'
            repo.mkdir()
            run.mkdir()
            env = dict(os.environ, GIT_AUTHOR_DATE='2026-11-17T15:00:00+08:00',
                       GIT_COMMITTER_DATE='2026-11-17T15:00:00+08:00')

            def git(*args):
                return subprocess.check_output(['git', '-C', str(repo), *args], env=env)

            git('init', '-q')
            (repo / 'before space.txt').write_text('keep\n', encoding='utf-8')
            git('add', '.')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
                '-c', 'core.hooksPath=.git/hooks', 'commit', '-qm', 'baseline')
            git('mv', 'before space.txt', 'after space.txt')
            for index in range(34):
                (repo / f'草稿-{index:02d}.md').touch()
            command = [sys.executable, '-B', str(ROOT / 'scripts/daily-update/preflight-summary.py'),
                       '--max-bytes', '768', 'worktree', '--repo', str(repo), '--run-directory', str(run),
                       '--started-at', '2026-11-19T02:00:00+08:00']
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertLessEqual(len(result.stdout), 768)
            report = json.loads(result.stdout)
            self.assertEqual(report['counts'], {'R ': 1, '??': 34})
            self.assertTrue(report['dirty_age_gate_failed'])
            self.assertEqual(report['sample'][0], {'status': 'R ', 'path': 'after space.txt', 'from': 'before space.txt'})
            self.assertEqual(report['omitted_count'], 35 - len(report['sample']))
            full = (run / report['status_evidence']).read_bytes()
            self.assertEqual(full, git('status', '--porcelain=v1', '-z', '--untracked-files=all'))
            self.assertEqual(report['status_sha256'], hashlib.sha256(full).hexdigest())
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual((run / report['status_evidence']).read_bytes(), full)

    def test_final_cli_stdout_uses_budgeted_utf8_with_lf(self):
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/daily-update/preflight-summary.py'),
                                 '--max-bytes', '512', 'module', '--id', 'host-safety'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLessEqual(len(result.stdout), 512)
        self.assertTrue(result.stdout.endswith(b'\n'))
        self.assertNotIn(b'\r\n', result.stdout)


if __name__ == '__main__':
    unittest.main()
