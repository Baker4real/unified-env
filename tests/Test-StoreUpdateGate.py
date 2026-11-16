"""Official Store plan/apply public seam, without installing on the host."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('store_gate', ROOT / 'scripts/daily-update/store-update-gate.py')


class StoreGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='D:/agents/run-evidence', prefix='store-gate-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.run = pathlib.Path(self.temp.name) / '20261116-120000'
        self.run.mkdir()
        self.config = {'run_directory': str(self.run), 'product_id': '9PLM9XGG6VKS', 'source': 'msstore',
                       'package_family': 'OpenAI.Codex_2p2nqsd0c76g0', 'operation': 'upgrade'}
        self.gate = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(self.gate)
        self.calls = []
        self.packages = [{'family': self.config['package_family'], 'version': '26.1106.6628.0', 'status': 'Ok'}]

    def metadata(self):
        return {'Data': {'PackageIdentifier': '9PLM9XGG6VKS', 'Versions': [{'Installers': [{
            'MSStoreProductIdentifier': '9PLM9XGG6VKS', 'Architecture': 'x64', 'InstallerType': 'msstore',
            'PackageFamilyName': 'OpenAI.Codex_2p2nqsd0c76g0', 'Scope': 'user'}]}]}}

    def observe(self, family):
        return self.packages

    def runner(self, argv, **kwargs):
        self.calls.append(argv)
        self.packages = [{'family': self.config['package_family'], 'version': '26.1111.2228.0', 'status': 'Ok'}]
        return {'status': 'exited', 'exit_code': 0, 'stdout': 'fixture', 'stderr': ''}

    def prepare(self):
        return self.gate.prepare(self.config, fetcher=lambda _: self.metadata(), observer=self.observe)

    def apply(self):
        return self.gate.apply(self.config, fetcher=lambda _: self.metadata(), observer=self.observe,
                               runner=self.runner, winget='winget.exe', closer=lambda *a, **kw: {'ok': True})

    def test_wrong_source_rejected_before_any_command_or_uninstall(self):
        self.config['source'] = 'winget'
        with self.assertRaisesRegex(ValueError, 'store-source-required'):
            self.prepare()
        self.assertEqual(self.calls, [])
        self.assertFalse((self.run / 'store-update/plan.json').exists())

    def test_wrong_package_identity_is_not_an_install_target(self):
        data = self.metadata()
        data['Data']['Versions'][0]['Installers'][0]['PackageFamilyName'] = 'Unrelated.App_123456789abcd'
        with self.assertRaisesRegex(ValueError, 'store-package-identity-mismatch'):
            self.gate.prepare(self.config, fetcher=lambda _: data, observer=self.observe)
        self.assertEqual(self.calls, [])

    def test_upgrade_uses_exact_product_and_source_without_uninstall(self):
        plan = self.prepare()
        self.assertFalse(plan['uninstall_permitted'])
        self.assertEqual(self.calls, [])
        result = self.apply()
        self.assertTrue(result['ok'])
        self.assertEqual(result['phase'], 'Apply')
        self.assertEqual(len(self.calls), 1)
        argv = self.calls[0]
        self.assertEqual(argv[1:6], ['upgrade', '--id', '9PLM9XGG6VKS', '--exact', '--source'])
        self.assertIn('msstore', argv)
        self.assertNotIn('uninstall', argv)
        self.assertEqual(result['observed_version'], '26.1111.2228.0')

    def test_source_drift_after_prepare_blocks_apply_before_execution(self):
        self.prepare()
        self.config['package_family'] = 'Other.Package_123456789abcd'
        with self.assertRaisesRegex(ValueError, 'plan-config-drift'):
            self.apply()
        self.assertEqual(self.calls, [])

    def test_official_metadata_drift_blocks_apply_before_execution(self):
        self.prepare()
        data = self.metadata()
        data['Data']['Versions'][0]['Installers'][0]['Scope'] = 'machine'
        with self.assertRaises(ValueError):
            self.gate.apply(self.config, fetcher=lambda _: data, observer=self.observe, runner=self.runner, winget='winget.exe', closer=lambda *a, **kw: {'ok': True})
        self.assertEqual(self.calls, [])

    def test_new_wrong_family_cannot_hide_behind_old_matching_version(self):
        self.prepare()
        data = self.metadata()
        newer = json.loads(json.dumps(data['Data']['Versions'][0]))
        newer['Installers'][0]['PackageFamilyName'] = 'Wrong.Package_123456789abcd'
        data['Data']['Versions'].insert(0, newer)
        with self.assertRaisesRegex(ValueError, 'store-package-identity-mismatch'):
            self.gate.apply(self.config, fetcher=lambda _: data, observer=self.observe,
                            runner=self.runner, winget='winget.exe', closer=lambda *a, **kw: {'ok': True})
        self.assertEqual(self.calls, [])

    def test_install_is_only_for_absent_main_package(self):
        self.config['operation'] = 'install'
        with self.assertRaisesRegex(ValueError, 'install-requires-absent-package'):
            self.prepare()
        self.packages = []
        self.prepare()
        result = self.apply()
        self.assertTrue(result['ok'])
        self.assertEqual(self.calls[0][1], 'install')

    def test_successful_codex_install_still_requires_post_refresh_closeout(self):
        self.prepare()
        calls = []
        def closer(run, repair):
            calls.append((run, repair))
            return {'ok': False, 'status': 'manual-review'}
        result = self.gate.apply(self.config, fetcher=lambda _: self.metadata(), observer=self.observe,
                                 runner=self.runner, winget='winget.exe', closer=closer)
        self.assertTrue(result['installation_ok'])
        self.assertFalse(result['closeout_ok'])
        self.assertFalse(result['ok'])
        self.assertEqual(calls, [(self.run.resolve(), True)])

    def test_failed_post_observation_never_claims_original_package_retained(self):
        self.prepare()
        observations = 0
        def observer(family):
            nonlocal observations
            observations += 1
            if observations > 1:
                raise OSError('query unavailable')
            return self.packages
        result = self.gate.apply(self.config, fetcher=lambda _: self.metadata(), observer=observer,
                                 runner=self.runner, winget='winget.exe', closer=lambda *a, **kw: {'ok': True})
        self.assertFalse(result['ok'])
        self.assertFalse(result['observation_ok'])
        self.assertIsNone(result['previous_package_retained'])
        self.assertFalse(result['uninstall_executed'])

    def test_closeout_exception_keeps_install_outcome_and_failure_receipt(self):
        self.prepare()
        def closer(*args, **kwargs):
            raise ValueError('private-fixture')
        result = self.gate.apply(self.config, fetcher=lambda _: self.metadata(), observer=self.observe,
                                 runner=self.runner, winget='winget.exe', closer=closer)
        self.assertTrue(result['installation_ok'])
        self.assertFalse(result['ok'])
        self.assertEqual(result['closeout_error'], 'ValueError')
        self.assertNotIn('private-fixture', json.dumps(result))
        self.assertTrue((self.run/'store-update/apply-result.json').is_file())

    def test_failed_store_operation_keeps_original_install_and_failure_receipt(self):
        self.prepare()
        def failed(argv, **kwargs):
            self.calls.append(argv)
            return {'status': 'exited', 'exit_code': -2147009287, 'stdout': '', 'stderr': ''}
        result = self.gate.apply(self.config, fetcher=lambda _: self.metadata(), observer=self.observe,
                                 runner=failed, winget='winget.exe', closer=lambda *a, **kw: {'ok': True})
        self.assertFalse(result['ok'])
        self.assertEqual(result['observed_version'], '26.1106.6628.0')
        self.assertNotIn('uninstall', self.calls[0])
        with self.assertRaisesRegex(ValueError, 'attempt-already-exists'):
            self.apply()


if __name__ == '__main__':
    pathlib.Path('D:/agents/run-evidence').mkdir(parents=True, exist_ok=True)
    unittest.main()
