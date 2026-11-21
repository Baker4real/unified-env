"""Official Store plan/apply public seam, without installing on the host."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

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
        self.stage = []
        self.archive = self.run / 'old.msix'
        self.archive.write_bytes(b'exact signed Store rollback fixture')
        self.config['rollback_archive'] = self.archive.name
        self.probe_calls = []
        self.pending = False
        def plugins(_version):
            return {'ok': not self.pending, 'status': 'official-client-refresh-pending' if self.pending else 'verified'}
        for target, name, replacement in ((self.gate.runtime, 'run_hidden', self.observe_worker),
                                          (self.gate, 'verify_plugins', plugins)):
            stub = patch.object(target, name, replacement)
            stub.start()
            self.addCleanup(stub.stop)

    def observe_worker(self, argv, **kwargs):
        self.probe_calls.append(argv)
        if '-CurrentVersion' in argv and '-Mode' not in argv:
            result = {'ok': True, 'offers': self.stage}
        else:
            mode, version = (argv[argv.index(flag) + 1] for flag in ('-Mode', '-Version'))
            name = f'OpenAI.Codex_{version}_x64__2p2nqsd0c76g0'
            result = dict(ok=True, phase=mode, version=version, full_name=name)
            if mode == 'Proof':
                result['archive'] = dict(signature='Valid', full_name=name, bytes=7, sha256='a' * 64)
            elif mode == 'Verify':
                result['signature_verified'] = True
            else:
                raise AssertionError(argv)
        return {'status': 'exited', 'exit_code': 0, 'stdout': json.dumps(result), 'stderr': ''}

    def staged_offer(self):
        self.stage = [{'version': '26.1111.2228.0', 'full_name': 'OpenAI.Codex_26.1111.2228.0_x64__2p2nqsd0c76g0',
                       'store_record': 201, 'stage_record': 400, 'occupied_record': 404}]
        return self.stage[0]

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

    def test_staged_exact_update_refuses_apply_without_verified_rollback(self):
        observation = self.staged_offer()
        self.config.pop('rollback_archive')
        plan = self.prepare()
        self.assertEqual(plan.get('staged'), observation)
        with self.assertRaisesRegex(ValueError, 'store-rollback-unverified'):
            self.apply()
        self.assertFalse((self.run / 'store-update/apply-intent.json').exists())
        self.assertEqual(self.calls, [])

    def test_staged_occupied_offer_routes_to_exact_registration_and_pending_plugins(self):
        observation = self.staged_offer()
        self.pending = True
        self.prepare()
        result = self.apply()
        self.assertTrue(result['installation_ok'])
        self.assertEqual(result['mechanism'], 'register-staged')
        self.assertEqual(result['registration']['full_name'], observation['full_name'])
        self.assertEqual(self.calls[0][-6:], ['-Mode', 'Register', '-Version', observation['version'],
                                            '-CurrentVersion', '26.1106.6628.0'])
        self.assertIn('-ArchiveSha256', self.probe_calls[-2])
        self.assertFalse(result['ok'])
        self.assertIsNone(result['closeout_ok'])
        self.assertEqual(result['status'], 'official-client-refresh-pending')

        receipt = 'store-update/verify-after-client.json'
        recheck = self.gate.verify(self.config, receipt, observer=self.observe)
        self.assertEqual(recheck['status'], 'official-client-refresh-pending')
        self.assertFalse(recheck['ok'])
        self.assertTrue((self.run / receipt).exists())
        self.assertEqual(len(self.calls), 1)

    def test_winget_no_upgrade_does_not_clear_a_known_offer_without_registration(self):
        self.staged_offer()['stage_record'] = None
        self.stage[0]['occupied_record'] = None
        self.prepare()
        def no_offer(argv, **kwargs):
            self.calls.append(argv)
            return {'status': 'exited', 'exit_code': 0x8A15002B, 'stdout': '', 'stderr': ''}
        result = self.gate.apply(self.config, fetcher=lambda _: self.metadata(), observer=self.observe,
                                 runner=no_offer, winget='winget.exe')
        self.assertEqual(result['mechanism'], 'winget')
        self.assertEqual(result['status'], 'manual-review')
        self.assertFalse(result['ok'])
        self.assertTrue(result['previous_package_retained'])

    def test_staged_plan_cannot_register_a_different_offer(self):
        self.staged_offer()
        self.prepare()
        self.stage[0]['stage_record'] += 1
        with self.assertRaisesRegex(ValueError, 'store-stage-drift'):
            self.apply()
        self.assertEqual(self.calls, [])

    def test_independent_rollback_binds_target_current_version_and_archive_sha(self):
        self.staged_offer()
        self.prepare()
        self.apply()
        def restore(argv, **kwargs):
            self.calls.append(argv)
            self.packages[0]['version'] = '26.1106.6628.0'
            return {'status': 'exited', 'exit_code': 0,
                    'stdout': '{"ok":true,"signature_verified":true}', 'stderr': ''}
        result = self.gate.rollback(self.config, observer=self.observe, runner=restore)
        self.assertTrue(result['ok'])
        self.assertEqual(self.calls[-1][-10:], ['-Mode', 'Rollback', '-Version', '26.1106.6628.0',
            '-CurrentVersion', '26.1111.2228.0', '-Archive', str(self.archive), '-ArchiveSha256', 'a' * 64])
        self.assertEqual(result['status'], 'restored')

    def test_source_drift_after_prepare_blocks_apply_before_execution(self):
        self.prepare()
        self.config['operation'] = 'install'
        self.config.pop('rollback_archive')
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
        self.config.pop('rollback_archive')
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
