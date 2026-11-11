import hashlib
import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest
import zipfile
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('python_runtime_transaction', ROOT / 'scripts/daily-update/python-runtime-transaction.py')
transaction = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transaction)


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


class FakeRunner:
    def __init__(self, config, gate_plan):
        self.config = config
        self.gate_plan = gate_plan
        self.events = []
        self.fail_health = False
        self.fail_restore = False

    def result(self, stdout='', exit_code=0):
        return {'status': 'exited', 'exit_code': exit_code, 'stdout': stdout, 'stderr': ''}

    def __call__(self, args, **kwargs):
        args = [str(item) for item in args]
        self.events.append(args)
        if args == ['stop']:
            return self.result()
        if args == ['restore']:
            return self.result(exit_code=1 if self.fail_restore else 0)
        if 'verify' in args:
            return self.result(json.dumps({'ok': True, 'status': 'selection-verified',
                'version': self.config['target_version'], 'install_argv': self.gate_plan['install_argv']}))
        if args == self.gate_plan['install_argv']:
            (pathlib.Path(self.config['manager_runtime']) / 'VERSION').write_text(self.config['target_version'], encoding='utf-8')
            return self.result('manager updated')
        if 'shells' in args:
            output = pathlib.Path(args[args.index('--output') + 1])
            payload = {'ok': not self.fail_health}
            if not self.fail_health:
                output.write_text(json.dumps(payload), encoding='utf-8')
            return self.result(json.dumps(payload), 0 if not self.fail_health else 1)
        if args[0].endswith('python.exe') and 'sys.version_info' in args[-1]:
            version = (pathlib.Path(args[0]).parent / 'VERSION').read_text(encoding='utf-8')
            return self.result(version + '\n')
        if 'import_candidates' in args[-1]:
            return self.result('["PIL", "yaml"]')
        if 'ssl,sqlite3,ctypes,venv' in args[-1]:
            return self.result('stdlib-ok')
        if 'existing third-party imports ok' in args[-1]:
            return self.result('existing third-party imports ok')
        if '-m' in args and 'pip' in args:
            return self.result('No broken requirements found.')
        raise AssertionError(args)


class PythonRuntimeTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix='python-transaction-', dir='D:/Codex/tmp'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.run = self.tmp / '20261110-120000'
        self.run.mkdir()
        self.default = self.tmp / 'default'
        self.manager = self.tmp / 'manager'
        self.stage = self.tmp / 'stage'
        for root in (self.default, self.manager):
            (root / 'DLLs').mkdir(parents=True)
            (root / 'Lib/site-packages/demo').mkdir(parents=True)
            (root / 'python.exe').write_bytes(b'old-python')
            (root / 'VERSION').write_text('3.15.1', encoding='utf-8')
            (root / 'DLLs/_asyncio.pyd').write_bytes(b'old-asyncio')
            (root / 'Lib/site-packages/demo/__init__.py').write_text('VALUE = 1\n', encoding='utf-8')
        (self.stage / 'DLLs').mkdir(parents=True)
        (self.stage / 'Doc/html/c-api').mkdir(parents=True)
        (self.stage / 'include/internal/mimalloc').mkdir(parents=True)
        (self.stage / 'Lib/site-packages').mkdir(parents=True)
        files = {
            'python.exe': b'new-python', 'VERSION': b'3.15.2',
            'DLLs/_asyncio.pyd': b'new-asyncio',
            'Doc/html/c-api/pyexpat.html': b'new-doc',
            'include/internal/mimalloc/mimalloc-stats.h': b'new-header',
        }
        for name, data in files.items():
            (self.stage / name).write_bytes(data)
        self.archive = self.tmp / 'python.zip'
        with zipfile.ZipFile(self.archive, 'w') as bundle:
            bundle.writestr('__install__.json', '{}')
            for name, data in files.items():
                bundle.writestr(name, data)
        self.selected = self.run / 'python-selected-index.json'
        self.selected.write_text('{"versions":[],"next":null}\n', encoding='utf-8')
        self.gate_plan = self.run / 'python-update-plan.json'
        self.gate_document = {
            'status': 'selection-verified', 'version': '3.15.2',
            'selected_index': str(self.selected), 'selected_index_sha256': sha(self.selected),
            'source_index_sha256': 'different-full-online-index-hash',
            'archive_sha256': sha(self.archive),
            'install_argv': ['manager-install', '--update', '3.15.2', '--yes'],
        }
        self.gate_plan.write_text(json.dumps(self.gate_document), encoding='utf-8')
        self.config = {
            'run_directory': str(self.run), 'attempt_id': 'attempt1',
            'current_version': '3.15.1', 'target_version': '3.15.2',
            'default_runtime': str(self.default), 'manager_runtime': str(self.manager),
            'staged_runtime': str(self.stage), 'archive': str(self.archive),
            'backup': str(self.tmp / 'backup'), 'gate_plan': str(self.gate_plan),
            'gate_script': 'gate.py', 'safe_python': 'safe-python',
            'runtime_health_script': 'runtime-health.py',
            'stop_command': ['stop'], 'restore_command': ['restore'],
            'health_imports': ['PIL', 'yaml', 'pandas'],
        }
        self.runner = FakeRunner(self.config, self.gate_document)

    def plan(self):
        return transaction.plan(self.config, self.runner)

    def test_new_official_files_and_verify_schema_succeed(self):
        self.plan()
        result = transaction.apply(self.config, self.runner)
        self.assertEqual(result['status'], 'updated-verified')
        self.assertEqual((self.default / 'VERSION').read_text(encoding='utf-8'), '3.15.2')
        self.assertEqual((self.default / 'Doc/html/c-api/pyexpat.html').read_bytes(), b'new-doc')
        self.assertEqual((self.default / 'include/internal/mimalloc/mimalloc-stats.h').read_bytes(), b'new-header')
        self.assertEqual((self.default / 'Lib/site-packages/demo/__init__.py').read_text(encoding='utf-8'), 'VALUE = 1\n')
        self.assertEqual(result['baseline_imports'], ['PIL', 'yaml'])
        self.assertNotIn('pandas', result['baseline_imports'])
        self.assertLess(self.runner.events.index(['stop']), self.runner.events.index(self.gate_document['install_argv']))
        self.assertEqual(self.runner.events[-1], ['restore'])

    def test_failed_health_rolls_back_new_files_and_restores(self):
        self.plan()
        self.runner.fail_health = True
        with self.assertRaisesRegex(RuntimeError, 'runtime-health'):
            transaction.apply(self.config, self.runner)
        self.assertEqual((self.default / 'VERSION').read_text(encoding='utf-8'), '3.15.1')
        self.assertEqual((self.manager / 'VERSION').read_text(encoding='utf-8'), '3.15.1')
        self.assertFalse((self.default / 'Doc/html/c-api/pyexpat.html').exists())
        self.assertFalse((self.default / 'include/internal/mimalloc/mimalloc-stats.h').exists())
        self.assertEqual(self.runner.events[-1], ['restore'])
        error = self.run / 'python-transaction/apply-attempt1-error.json'
        self.assertTrue(error.is_file())

    def test_locked_stage_copy_is_rolled_back(self):
        self.plan()
        original = shutil.copy2
        def locked(source, target):
            if pathlib.Path(source).is_relative_to(self.stage) and pathlib.Path(source).name == '_asyncio.pyd':
                raise PermissionError(32, 'locked')
            return original(source, target)
        with mock.patch.object(transaction.shutil, 'copy2', side_effect=locked):
            with self.assertRaises(PermissionError):
                transaction.apply(self.config, self.runner)
        self.assertEqual((self.default / 'VERSION').read_text(encoding='utf-8'), '3.15.1')
        self.assertEqual((self.manager / 'VERSION').read_text(encoding='utf-8'), '3.15.1')
        self.assertEqual((self.default / 'DLLs/_asyncio.pyd').read_bytes(), b'old-asyncio')
        self.assertEqual(self.runner.events[-1], ['restore'])

    def test_config_drift_fails_before_stopping_occupants(self):
        self.plan()
        self.config['default_runtime'] = str(self.tmp / 'other-runtime')
        count = len(self.runner.events)
        with self.assertRaisesRegex(ValueError, 'config-drift'):
            transaction.apply(self.config, self.runner)
        self.assertEqual(len(self.runner.events), count)
        self.assertFalse(self.runner.events[count:])

    def test_restore_failure_never_leaves_a_success_receipt(self):
        self.plan()
        self.runner.fail_restore = True
        with self.assertRaisesRegex(RuntimeError, 'process-failed'):
            transaction.apply(self.config, self.runner)
        self.assertFalse((self.run / 'python-transaction/apply-attempt1.json').exists())
        self.assertTrue((self.run / 'python-transaction/apply-attempt1-error.json').is_file())
        self.assertEqual(self.runner.events[-1], ['restore'])

    def test_rollback_restore_failure_never_leaves_a_success_receipt(self):
        self.plan()
        self.runner.fail_restore = True
        with self.assertRaisesRegex(RuntimeError, 'process-failed'):
            transaction.rollback(self.config, self.runner)
        self.assertFalse((self.run / 'python-transaction/rollback-attempt1.json').exists())
        self.assertTrue((self.run / 'python-transaction/rollback-attempt1-error.json').is_file())
        self.assertEqual(self.runner.events[-1], ['restore'])

    def test_attempt_cannot_be_replayed(self):
        self.plan()
        transaction.apply(self.config, self.runner)
        count = len(self.runner.events)
        with self.assertRaisesRegex(ValueError, 'attempt-already-evidenced'):
            transaction.apply(self.config, self.runner)
        self.assertEqual(len(self.runner.events), count)


if __name__ == '__main__':
    unittest.main()
