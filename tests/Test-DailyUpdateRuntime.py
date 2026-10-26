"""Behavior checks for the updater's pre-mutation runtime probes."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('update_runtime', ROOT / 'scripts/daily-update/runtime-health.py')
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class RuntimeHealthTests(unittest.TestCase):
    def test_windows_cmd_launch_preserves_native_path(self):
        argv = runtime.shell_command('cmd', 'C:/Windows/System32/cmd.exe', 'python')
        self.assertEqual(argv, ['C:\\Windows\\System32\\cmd.exe', '/d', '/c', 'python --version'])

    def test_command_name_cannot_inject_shell_operators(self):
        with self.assertRaises(ValueError):
            runtime.shell_command('cmd', 'C:/Windows/System32/cmd.exe', 'python & echo unsafe')

    def test_success_exit_without_matching_version_fails(self):
        self.assertFalse(runtime.version_matches('python', 'Python 3.15.0\n', '3.15.1'))
        self.assertFalse(runtime.version_matches('python', '', '3.15.1'))
        self.assertFalse(runtime.version_matches('python', 'Python 3.15.1\nPython 3.15.0\n', '3.15.1'))
        self.assertTrue(runtime.version_matches('python', 'Python 3.15.1\r\n', '3.15.1'))

    def test_mcp_requires_both_fresh_named_protocol_results(self):
        good = [
            {'name': name, 'initialize': {'ok': True, 'protocol': '2024-11-05',
             'serverInfo': {'name': name, 'version': '1.0.0'}}, 'toolsList': {'ok': True, 'count': 1}}
            for name in ('serena', 'codegraph')
        ]
        self.assertTrue(runtime.validate_mcp_rows(good)['ok'])
        self.assertFalse(runtime.validate_mcp_rows(good[:1])['ok'])
        self.assertFalse(runtime.validate_mcp_rows([good[0], good[0]])['ok'])
        good[1]['toolsList']['count'] = 0
        self.assertFalse(runtime.validate_mcp_rows(good)['ok'])
        good[1]['toolsList']['count'] = 1
        good[1]['initialize'] = {'ok': True}
        self.assertFalse(runtime.validate_mcp_rows(good)['ok'])

    def test_mixed_node_and_npm_targets_are_not_silently_dropped(self):
        with mock.patch.object(runtime, 'fresh_environment', return_value={}):
            with self.assertRaisesRegex(ValueError, 'separate-expected-versions'):
                runtime.check_shells('node', '24.22.1', ['node', 'npm'])

    def test_missing_or_stale_result_is_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = pathlib.Path(tmp) / 'result.json'
            self.assertFalse(runtime.read_mcp_result(file, 0)['ok'])
            file.write_text('{}\n', encoding='utf-8')
            self.assertFalse(runtime.read_mcp_result(file, file.stat().st_mtime_ns + 1)['ok'])

    def test_hidden_runner_retains_child_failure(self):
        result = runtime.run_hidden([sys.executable, '-I', '-c', 'raise SystemExit(7)'], timeout=10)
        self.assertEqual(result['exit_code'], 7)
        self.assertEqual(result['status'], 'exited')

    def test_hidden_runner_reports_timeout(self):
        result = runtime.run_hidden([sys.executable, '-I', '-c', 'import time; time.sleep(10)'], timeout=0.1)
        self.assertEqual(result['status'], 'timeout')


if __name__ == '__main__':
    unittest.main()
