"""Behavior checks for the updater's pre-mutation runtime probes."""
import importlib.util
import json
import pathlib
import shutil
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


class DailyUpdateLedgerExportTests(unittest.TestCase):
    def test_sweep_input_only_lists_adopted_source_refs(self):
        def entry(repo, skills, status='updated-with-local-overlay'):
            return {'repo': f'https://github.com/example/{repo}.git', 'ref': 'main',
                    'last_checked_commit': 'a' * 40, 'status': status, 'skills': skills}

        ledger = {'sources': [entry('shared', ['active']),
                              entry('retired-group', ['historical'], 'deleted-by-user'),
                              entry('empty-group', [])],
                  'deleted': [entry('shared', ['old'], 'deleted-by-user'),
                              entry('retired-entry', ['renamed'], 'moved')]}
        with tempfile.TemporaryDirectory(dir='D:/Codex/temp' if sys.platform == 'win32' else None) as tmp:
            directory = pathlib.Path(tmp)
            source = directory / 'ledger.json'
            source.write_text(json.dumps(ledger), encoding='utf-8')
            result = subprocess.run(['node', str(ROOT / 'scripts/daily-update/gen-ledger-tsv.cjs'),
                                     tmp, str(source)], timeout=15, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = (directory / 'ledger-github-sources.tsv').read_text(encoding='utf-8').splitlines()
        self.assertEqual(rows, [f'example/shared\tmain\t{"a" * 40}\tupdated-with-local-overlay\tactive'])

    def test_old_sweep_input_with_retired_rows_makes_no_git_request(self):
        if sys.platform == 'win32':
            bash = pathlib.Path('C:/Program Files/Git/bin/bash.exe')
            if not bash.is_file():
                self.skipTest('the scheduled Git Bash runtime is unavailable')
        else:
            bash = shutil.which('bash')
            if not bash:
                self.skipTest('bash is unavailable')
        with tempfile.TemporaryDirectory(dir='D:/Codex/temp' if sys.platform == 'win32' else None) as tmp:
            directory = pathlib.Path(tmp)
            (directory / 'ledger-github-sources.tsv').write_text(
                'example/active\tmain\taaaa\tupdated\tactive\n'
                'example/old\tmain\t\tmoved\told\n', encoding='utf-8')
            # Any Git invocation is observable without using the network.
            wrapper = 'git() { echo unexpected-query >> "$probe"; return 1; }; export -f git; export probe="$1"; shift; exec bash "$@"'
            probe = directory / 'git-invoked.txt'
            result = subprocess.run([str(bash), '-c', wrapper, '_', probe.as_posix(),
                                     (ROOT / 'scripts/daily-update/sweep-lsremote.sh').as_posix(),
                                     directory.as_posix()], timeout=15, capture_output=True, text=True)
            self.assertFalse(probe.exists())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('regenerate ledger-github-sources.tsv', result.stderr)

    def test_sweep_preserves_status_when_last_checked_commit_is_empty(self):
        bash = pathlib.Path('C:/Program Files/Git/bin/bash.exe') if sys.platform == 'win32' else shutil.which('bash')
        if not bash or not pathlib.Path(bash).is_file():
            self.skipTest('bash runtime is unavailable')
        with tempfile.TemporaryDirectory(dir='D:/Codex/temp' if sys.platform == 'win32' else None) as tmp:
            directory = pathlib.Path(tmp)
            (directory / 'ledger-github-sources.tsv').write_bytes(b'example/active\tmain\t\tupdated\tactive\r\n')
            sha = 'a' * 40
            wrapper = (
                f'''git() {{ test "$*" = 'ls-remote https://github.com/example/active refs/heads/main' || return 1; '''
                f'''printf '%s\\trefs/heads/main\\n' '{sha}'; }}; export -f git; exec bash "$@"'''
            )
            result = subprocess.run([str(bash), '-c', wrapper, '_',
                                     (ROOT / 'scripts/daily-update/sweep-lsremote.sh').as_posix(),
                                     directory.as_posix()], timeout=15, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((directory / 'lsremote-results.tsv').read_text(encoding='utf-8').splitlines(),
                             [f'example/active\tCHANGED\t{sha}\tmain\tupdated'])


if __name__ == '__main__':
    unittest.main()
