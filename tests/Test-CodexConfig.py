"""Read-only config checker contract; protocol peers are isolated local fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'modules/codex-host/Check-CodexConfig.py'


class ConfigCheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('config_checker', SOURCE)
        cls.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.checker)
        evidence = Path('D:/agents/run-evidence/codex-config-checker') if os.name == 'nt' else ROOT / '.scratch/config-checker'
        evidence.mkdir(parents=True, exist_ok=True)
        cls.root = Path(tempfile.mkdtemp(prefix='fixture-', dir=evidence))
        cls.peer = cls.root / 'peer.py'
        cls.peer.write_text('''import json, sys, time
mode = sys.argv[1]
if 'mcp' in sys.argv:
    if mode == 'profile-timeout': time.sleep(10)
    if mode == 'profile-error': sys.exit(9)
    if mode == 'profile-warning':
        print('Codex is ignoring 1 unrecognized configuration setting. secret-fixture-value', file=sys.stderr)
    if mode == 'profile-malformed':
        print('{}')
        sys.exit(0)
    print('[]')
    sys.exit(0)
if mode == 'timeout': time.sleep(10)
if mode == 'early-eof': sys.exit(0)
for line in sys.stdin:
    req = json.loads(line)
    if req.get('method') == 'initialize':
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
        if mode == 'init-only': sys.exit(0)
    elif req.get('method') == 'config/read':
        if mode == 'error':
            print(json.dumps({'id': 2, 'error': {'message': 'secret-fixture-value'}}), flush=True)
        elif mode == 'wrong-id':
            print(json.dumps({'id': 3, 'result': {'config': {}}}), flush=True)
            sys.exit(0)
        elif mode == 'malformed':
            print(json.dumps({'id': 2, 'result': {}}), flush=True)
        else:
            if mode == 'warning':
                print('Codex is ignoring 1 unrecognized configuration setting. secret-fixture-value', file=sys.stderr, flush=True)
            config = {'sensitive': 'secret-fixture-value'}
            if mode == 'warning-in-value': config['developer_instructions'] = 'Explain unrecognized configuration messages'
            if mode == 'warning-notification':
                print(json.dumps({'method': 'configWarning', 'params': {'message': 'secret-fixture-value'}}), flush=True)
            print(json.dumps({'id': 2, 'result': {'config': config, 'origins': {}}}), flush=True)
        if mode == 'shutdown-hang': time.sleep(10)
        if mode == 'stderr-overflow':
            sys.stderr.write('x' * (1024 * 1024 + 2))
            sys.stderr.flush()
        if mode == 'nonzero': sys.exit(7)
''', encoding='utf-8')

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix='home-', dir=self.root))
        (self.home / 'config.toml').write_text('model = "fixture"\n', encoding='utf-8')

    def check(self, mode='success', timeout=3):
        return self.checker.check(self.home, [sys.executable, str(self.peer), mode], timeout=timeout, cwd=ROOT)

    def test_success_requires_both_responses_and_preserves_files(self):
        path = self.home / 'config.toml'
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        result = self.check()
        self.assertTrue(result['ok'])
        self.assertEqual(result['acceptance'], {'files': 'passed', 'runtime': 'passed', 'desktopSession': 'unverified'})
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)
        self.assertNotIn('secret-fixture-value', json.dumps(result))

    def test_protocol_failures_never_pass(self):
        for mode in ('early-eof', 'init-only', 'error', 'wrong-id', 'malformed', 'nonzero', 'warning', 'warning-notification'):
            with self.subTest(mode=mode):
                result = self.check(mode)
                self.assertFalse(result['ok'])
                self.assertEqual(result['acceptance']['runtime'], 'failed')
                self.assertNotIn('secret-fixture-value', json.dumps(result))

    def test_warning_text_and_retired_names_in_user_values_are_not_settings(self):
        self.assertTrue(self.check('warning-in-value')['ok'])
        (self.home / 'config.toml').write_text('[mcp_servers.demo.env]\nthread_context="fixture"\ndisable_response_storage="fixture"\n', encoding='utf-8')
        result = self.check('warning-in-value')
        self.assertTrue(result['ok'])
        self.assertEqual(result['files'][0]['retiredKeys'], [])
        self.assertEqual(result['runtime'][0]['warningCount'], 0)

    def test_timeouts_include_hanging_shutdown(self):
        for mode in ('timeout', 'shutdown-hang'):
            with self.subTest(mode=mode):
                result = self.check(mode, timeout=0.4)
                self.assertFalse(result['ok'])
                self.assertEqual(result['runtime'][0]['failure'], 'timeout')
                self.assertIsNotNone(result['runtime'][0]['exitCode'])

    def test_output_limit_even_after_config_response(self):
        result = self.check('stderr-overflow')
        self.assertFalse(result['ok'])
        self.assertEqual(result['runtime'][0]['failure'], 'output-limit')

    def test_all_profile_files_are_checked_without_matching_comments(self):
        (self.home / 'config.toml').write_text('# disable_response_storage\nmodel="fixture"\n', encoding='utf-8')
        (self.home / 'astra.config.toml').write_text('model="fixture-profile"\n', encoding='utf-8')
        result = self.check()
        self.assertTrue(result['ok'])
        self.assertEqual([x['profile'] for x in result['runtime']], [None, 'astra'])
        (self.home / 'astra.config.toml').write_text('[features.guardianv2]\nthread_context=true\n', encoding='utf-8')
        result = self.check()
        self.assertFalse(result['ok'])
        self.assertEqual(result['runtime'], [])
        self.assertEqual(result['files'][1]['retiredKeys'], ['features.guardianv2.thread_context'])

    def test_invalid_toml_and_missing_file_fail_without_content_leak(self):
        path = self.home / 'config.toml'
        path.write_text('secret-fixture-value = [\n', encoding='utf-8')
        self.assertFalse(self.check()['ok'])
        self.assertNotIn('secret-fixture-value', json.dumps(self.check()))
        path.unlink()
        self.assertFalse(self.check()['ok'])

    def test_profile_load_failure_is_not_hidden_by_successful_base(self):
        (self.home / 'astra.config.toml').write_text('model="fixture"\n', encoding='utf-8')
        for mode in ('profile-error', 'profile-warning', 'profile-malformed', 'profile-timeout'):
            with self.subTest(mode=mode):
                result = self.check(mode, timeout=0.5)
                self.assertTrue(result['runtime'][0]['ok'])
                self.assertFalse(result['runtime'][1]['ok'])
                self.assertFalse(result['ok'])
                self.assertNotIn('secret-fixture-value', json.dumps(result))

    def test_cli_failure_is_nonzero_json(self):
        result = subprocess.run([sys.executable, '-B', str(SOURCE), '--home', str(self.home),
                                 '--codex-exe', str(self.root / 'missing.exe')],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)['ok'])
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
