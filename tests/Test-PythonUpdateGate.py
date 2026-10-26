"""Regression cases for the managed Python update selection gate."""
import contextlib
import hashlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import unittest
import tempfile
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('python_update_gate', ROOT / 'scripts/daily-update/python-update-gate.py')
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def index():
    return {'versions': [{'schema': 1, 'id': 'pythoncore-3.15-64', 'company': 'PythonCore',
        'tag': '3.15-64', 'sort-version': '3.15.1', 'display-name': 'Python 3.15.1',
        'install-for': ['3.15.1-64', '3.15-64'], 'executable': '.\\python.exe',
        'url': 'https://www.python.org/ftp/python/3.15.1/python-3.15.1-amd64.zip',
        'hash': {'sha256': 'a' * 64}}], 'next': None}


class PythonUpdateGateTests(unittest.TestCase):
    def test_malformed_index_is_a_controlled_error(self):
        for data in ([], {}, {'versions': 'bad'}):
            with self.assertRaises(ValueError):
                gate.select_candidate(data, '3.15.1')
        data = index()
        data['versions'][0]['hash'] = []
        with self.assertRaises(ValueError):
            gate.select_candidate(data, '3.15.1')

    def test_dry_run_rejects_input_changed_during_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            manager, selected = pathlib.Path(tmp) / 'py.exe', pathlib.Path(tmp) / 'index.json'
            manager.write_bytes(b'manager')
            selected.write_bytes(b'index')
            def drift(*args, **kwargs):
                selected.write_bytes(b'changed')
                return {'exit_code': 0, 'status': 'exited', 'stdout':
                    'Installing Python 3.15.1.\nSkipping rest of install due to --dry-run', 'stderr': ''}
            with mock.patch.object(gate.runtime, 'run_hidden', side_effect=drift):
                self.assertFalse(gate.dry_run(manager, selected, '3.15.1')['ok'])

    def test_old_index_fails_before_any_installer_call(self):
        stale = index()
        stale['versions'][0]['sort-version'] = '3.15.0'
        with self.assertRaisesRegex(ValueError, 'exact-stable-candidate'):
            gate.select_candidate(stale, '3.15.1')

    def test_one_exact_stable_official_candidate(self):
        candidate = gate.select_candidate(index(), '3.15.1')
        self.assertEqual(candidate['sort-version'], '3.15.1')
        with self.assertRaises(ValueError):
            gate.select_candidate(index(), '3.15.1rc1')
        duplicate = index()
        duplicate['versions'] *= 2
        with self.assertRaises(ValueError):
            gate.select_candidate(duplicate, '3.15.1')

    def test_unknown_or_authenticated_archive_origin_rejected(self):
        for url in ('https://evil.invalid/python.zip', 'https://<userinfo>@www.python.org/python.zip',
                    'https://www.python.org/ftp/python/3.15.0/python-3.15.0-amd64.zip'):
            data = index()
            data['versions'][0]['url'] = url
            with self.assertRaises(ValueError):
                gate.select_candidate(data, '3.15.1')

    def test_zero_exit_fallback_and_wrong_target_are_rejected(self):
        for output in ('[ERROR] Unable to access runtimes index\nPython 3.15.0 is already up to date.',
                       'Installing Python 3.15.0.\nSkipping rest of install due to --dry-run',
                       'fallback-index.json\nInstalling Python 3.15.1.', ''):
            self.assertFalse(gate.manager_selected(0, output, '3.15.1'))
        self.assertFalse(gate.manager_selected(1, 'Installing Python 3.15.1.', '3.15.1'))

    def test_exact_dry_run_or_already_installed_is_recognized(self):
        self.assertTrue(gate.manager_selected(0, 'Installing Python 3.15.1.\nSkipping rest of install due to --dry-run', '3.15.1'))
        self.assertTrue(gate.manager_selected(0, 'Python 3.15.1 is already installed.\nSkipping shortcut refresh due to --dry-run', '3.15.1'))


class PythonUpdateLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='python-update-gate-')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name).resolve()
        self.manager = self.root / 'py.exe'
        self.manager.write_bytes(b'synthetic-manager-never-executed')
        self.source = self.root / 'official-index.json'
        self.source.write_text(json.dumps(index()), encoding='utf-8')
        self.out = self.root / 'plan'
        self.plan_path = self.out / 'python-update-plan.json'
        self.selected_path = self.out / 'python-selected-index.json'
        self.calls = []
        self.output = 'Installing Python 3.15.1.\nSkipping rest of install due to --dry-run'
        self.process = mock.patch.object(gate.runtime.subprocess, 'run', side_effect=self.run_manager)
        self.process.start()
        self.addCleanup(self.process.stop)

    def run_manager(self, argv, **kwargs):
        # The only executable boundary is simulated. An apply command is a failure.
        self.assertEqual(argv, [str(self.manager), 'install', '--source',
                               str(self.selected_path), '--dry-run', '3.15.1'])
        self.calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, self.output, '')

    def cli(self, *argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, 'argv', ['python-update-gate.py', *map(str, argv)]), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = gate.main()
        self.assertEqual(stderr.getvalue(), '')
        self.assertNotIn('SECRET-CANARY', stdout.getvalue())
        return code, json.loads(stdout.getvalue())

    def prepare(self):
        source_hash = hashlib.sha256(self.source.read_bytes()).hexdigest()
        return self.cli('prepare', '--version', '3.15.1', '--out-dir', self.out,
                        '--manager', self.manager, '--index', self.source,
                        '--index-sha256', source_hash)

    def verify(self):
        return self.cli('verify', '--plan', self.plan_path)

    def test_prepare_verify_round_trip_is_dry_run_only_and_preserves_inputs(self):
        originals = {path: path.read_bytes() for path in (self.manager, self.source)}
        code, prepared = self.prepare()
        self.assertEqual((code, prepared['status']), (0, 'selection-verified'))
        self.assertEqual(prepared['plan'], str(self.plan_path))
        plan = json.loads(self.plan_path.read_text(encoding='utf-8'))
        self.assertEqual(plan['source_method'], 'caller-verified-official-index')
        self.assertEqual(plan['source_url'], 'https://www.python.org/ftp/python/index-windows.json')
        self.assertEqual(plan['authorization'], 'separate-authorized-transaction-with-verified-rollback-required')
        selected = json.loads(self.selected_path.read_text(encoding='utf-8'))
        self.assertEqual(selected, index())
        snapshots = {path: path.read_bytes() for path in self.out.iterdir()}
        code, verified = self.verify()
        self.assertEqual((code, verified['status']), (0, 'selection-verified'))
        self.assertEqual(verified['install_argv'], [str(self.manager), 'install', '--source',
                         str(self.selected_path), '--update', '3.15.1', '--yes'])
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(set(path.name for path in self.out.iterdir()),
                         {'python-selected-index.json', 'python-update-plan.json'})
        self.assertTrue(all(path.read_bytes() == data for path, data in {**originals, **snapshots}.items()))

    def test_fallback_creates_blocked_plan_which_cannot_be_verified(self):
        self.output = '[ERROR] fallback SECRET-CANARY\n' + self.output
        code, result = self.prepare()
        self.assertEqual((code, result['status']), (1, 'blocked'))
        self.assertNotIn('SECRET-CANARY', self.plan_path.read_text(encoding='utf-8'))
        code, result = self.verify()
        self.assertEqual((code, result['status']), (2, 'blocked'))
        self.assertEqual(len(self.calls), 1)

    def test_manager_drift_during_prepare_creates_only_blocked_plan(self):
        original_hash = hashlib.sha256(self.manager.read_bytes()).hexdigest()
        def drift(argv, **kwargs):
            self.manager.write_bytes(b'changed-manager')
            return self.run_manager(argv, **kwargs)
        with mock.patch.object(gate.runtime.subprocess, 'run', side_effect=drift):
            code, result = self.prepare()
        self.assertEqual((code, result['status']), (1, 'blocked'))
        plan = json.loads(self.plan_path.read_text(encoding='utf-8'))
        self.assertEqual(plan['manager_sha256'], original_hash)
        self.assertEqual(self.verify()[0], 2)
        self.assertEqual(len(self.calls), 1)

    def test_selected_index_drift_is_rejected_before_another_process(self):
        self.assertEqual(self.prepare()[0], 0)
        self.selected_path.write_text('[]', encoding='utf-8')
        self.assertEqual(self.verify()[0], 2)
        self.assertEqual(len(self.calls), 1)

    def test_manager_drift_is_rejected_before_another_process(self):
        self.assertEqual(self.prepare()[0], 0)
        self.manager.write_bytes(b'changed-manager')
        self.assertEqual(self.verify()[0], 2)
        self.assertEqual(len(self.calls), 1)

    def test_modified_install_command_is_rejected_before_another_process(self):
        self.assertEqual(self.prepare()[0], 0)
        plan = json.loads(self.plan_path.read_text(encoding='utf-8'))
        plan['install_argv'][-2] = '3.15.0'
        self.plan_path.write_text(json.dumps(plan), encoding='utf-8')
        self.assertEqual(self.verify()[0], 2)
        self.assertEqual(len(self.calls), 1)

    def test_drift_during_verify_never_returns_apply_command(self):
        self.assertEqual(self.prepare()[0], 0)
        def drift(argv, **kwargs):
            self.selected_path.write_text('[]', encoding='utf-8')
            return self.run_manager(argv, **kwargs)
        with mock.patch.object(gate.runtime.subprocess, 'run', side_effect=drift):
            code, result = self.verify()
        self.assertEqual((code, result['status']), (2, 'blocked'))
        self.assertNotIn('install_argv', result)

    def test_unreadable_app_alias_fails_before_writing_or_spawning(self):
        original_read = pathlib.Path.read_bytes
        def read_bytes(path):
            if path == self.manager:
                raise OSError('unreadable app alias SECRET-CANARY')
            return original_read(path)
        with mock.patch.object(pathlib.Path, 'read_bytes', read_bytes):
            code, result = self.prepare()
        self.assertEqual((code, result['status'], result['error_type']), (2, 'blocked', 'ValueError'))
        self.assertFalse(self.out.exists())
        self.assertEqual(self.calls, [])

    def test_invalid_source_json_has_sanitized_cli_contract_and_no_outputs(self):
        malformed_hash = index()
        malformed_hash['versions'][0]['hash'] = []
        for data in ('{SECRET-CANARY', '[]', json.dumps(malformed_hash)):
            with self.subTest(data=data):
                self.source.write_text(data, encoding='utf-8')
                code, result = self.prepare()
                self.assertEqual((code, result['status']), (2, 'blocked'))
                self.assertFalse(self.out.exists())
                self.assertEqual(self.calls, [])

    def test_invalid_plan_json_has_sanitized_cli_contract(self):
        self.out.mkdir()
        for data in ('{SECRET-CANARY', '[]', 'null', '{}'):
            with self.subTest(data=data):
                self.plan_path.write_text(data, encoding='utf-8')
                code, result = self.verify()
                self.assertEqual((code, result['status']), (2, 'blocked'))
                self.assertEqual(self.calls, [])

    def test_existing_plan_is_never_overwritten(self):
        self.assertEqual(self.prepare()[0], 0)
        originals = {path: path.read_bytes() for path in self.out.iterdir()}
        self.assertEqual(self.prepare()[0], 2)
        self.assertTrue(all(path.read_bytes() == data for path, data in originals.items()))
        self.assertEqual(len(self.calls), 1)

    def test_wrong_source_hash_fails_before_writing_or_spawning(self):
        code, result = self.cli('prepare', '--version', '3.15.1', '--out-dir', self.out,
                               '--manager', self.manager, '--index', self.source,
                               '--index-sha256', '0' * 64)
        self.assertEqual((code, result['status']), (2, 'blocked'))
        self.assertFalse(self.out.exists())
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
