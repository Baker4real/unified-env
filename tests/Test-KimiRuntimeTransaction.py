"""Normal CLI upgrades preserve an independent, verified recovery point."""
import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('kimi_transaction', ROOT / 'scripts/daily-update/kimi-runtime-transaction.py')
transaction = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transaction)


class KimiTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir='D:/Codex/tmp', prefix='kimi-transaction-')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.run = self.root / '20261111-120000'
        self.run.mkdir()
        self.exe = self.root / 'bin/kimi.exe'
        self.exe.parent.mkdir()
        self.exe.write_bytes(b'2.5.2')
        self.config = dict(run_directory=str(self.run), executable=str(self.exe), current_version='2.5.2', target_version='2.5.3')
        self.installs = 0
        self.bad_version = False

    def runner(self, argv, **kwargs):
        if str(argv[-1]) == '--version':
            return dict(status='exited', exit_code=0, stdout=self.exe.read_text(), stderr='')
        self.installs += 1
        self.assertEqual(kwargs['env']['KIMI_VERSION'], '2.5.3')
        self.assertEqual(pathlib.Path(kwargs['env']['KIMI_INSTALL_DIR']), self.root)
        # The official installer need not leave any .bak file.
        self.exe.write_bytes(b'wrong' if self.bad_version else b'2.5.3')
        return dict(status='exited', exit_code=0, stdout='installed', stderr='')

    def plan(self):
        return transaction.plan(self.config, self.runner, lambda: b'# official installer fixture')

    def test_installer_without_backup_still_has_independent_recovery(self):
        self.plan()
        result = transaction.apply(self.config, self.runner)
        self.assertTrue(result['installation_ok'])
        self.assertTrue(result['rollback_available'])
        self.assertTrue(result['health_ok'])
        self.assertEqual((self.run / 'kimi-transaction/old-kimi.exe').read_bytes(), b'2.5.2')
        self.assertFalse(self.exe.with_suffix('.exe.bak').exists())

    def test_failed_health_restores_original_hash_and_version(self):
        self.plan()
        self.bad_version = True
        with self.assertRaisesRegex(RuntimeError, 'upgrade-verification-failed'):
            transaction.apply(self.config, self.runner)
        self.assertEqual(self.exe.read_bytes(), b'2.5.2')
        receipt = json.loads((self.run / 'kimi-transaction/apply-error.json').read_text())
        self.assertTrue(receipt['rollback_ok'])
        self.assertEqual(receipt['status'], 'rolled-back')

    def test_backup_drift_prevents_installer(self):
        self.plan()
        (self.run / 'kimi-transaction/old-kimi.exe').write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'backup-hash-mismatch'):
            transaction.apply(self.config, self.runner)
        self.assertEqual(self.installs, 0)
        self.assertEqual(self.exe.read_bytes(), b'2.5.2')

    def test_successful_apply_cannot_replay(self):
        self.plan()
        transaction.apply(self.config, self.runner)
        with self.assertRaises(ValueError):
            transaction.apply(self.config, self.runner)
        self.assertEqual(self.installs, 1)

    def test_timeout_is_not_safe_rollback_evidence(self):
        self.plan()
        def timed_out(argv, **kwargs):
            if str(argv[-1]) == '--version':
                return self.runner(argv, **kwargs)
            return dict(status='timeout', exit_code=None, stdout='', stderr='')
        with self.assertRaisesRegex(RuntimeError, 'installer-not-terminal'):
            transaction.apply(self.config, timed_out)
        receipt = json.loads((self.run / 'kimi-transaction/apply-error.json').read_text())
        self.assertFalse(receipt['rollback_triggered'])
        self.assertEqual(receipt['status'], 'manual-review-installer-state')

    def test_official_cdn_redirect_is_accepted_and_other_hosts_are_refused(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.url = 'https://cdn.kimi.com/kimi-code/install.ps1'
        response.read.return_value = b'# installer'
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch.object(transaction.urllib.request, 'build_opener', return_value=opener):
            self.assertEqual(transaction.fetch_installer(), b'# installer')
            response.url = 'https://unrelated.example/install.ps1'
            with self.assertRaisesRegex(ValueError, 'unexpected-installer-redirect'):
                transaction.fetch_installer()

    def test_download_failure_leaves_reusable_verified_binary_without_empty_installer(self):
        def failing_fetch():
            raise OSError('fixture-download-failed')
        with self.assertRaises(OSError):
            transaction.plan(self.config, self.runner, failing_fetch)
        self.assertFalse((self.run / 'kimi-transaction/official-install.ps1').exists())
        self.plan()
        self.assertEqual((self.run / 'kimi-transaction/old-kimi.exe').read_bytes(), b'2.5.2')


if __name__ == '__main__':
    unittest.main()
