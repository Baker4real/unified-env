"""Exercise the Store plugin entry point with fixture files and real bounded child IO."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ENTRY = Path(__file__).resolve().parents[1] / 'scripts/daily-update/codex-store-plugins.py'
FAMILY = 'OpenAI.Codex_2p2nqsd0c76g0'
APPX = '45.67.89.0'
FULL_NAME = f'OpenAI.Codex_{APPX}_x64__2p2nqsd0c76g0'
BUNDLED = 'openai-bundled'
PRIMARY = 'openai-primary-runtime'
REAL_POPEN = subprocess.Popen


class StorePluginsTests(unittest.TestCase):
    def setUp(self):
        d_temp = Path('D:/agents/run-evidence')
        temp = tempfile.TemporaryDirectory(dir=d_temp if d_temp.is_dir() else None)
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.profile = self.root / 'profile'
        self.home = self.root / 'codex-home'
        self.bundled = self.home / '.tmp/bundled-marketplaces' / BUNDLED
        self.primary = self.profile / '.cache/codex-runtimes/codex-primary-runtime/plugins' / PRIMARY
        self.install = self.root / 'WindowsApps' / FULL_NAME
        self.executable = self.install / 'app/resources/codex.exe'
        self.executable.parent.mkdir(parents=True)
        self.executable.touch()
        self.package_market = self.executable.parent / 'plugins' / BUNDLED
        self.pwsh = shutil.which('pwsh') or str(self.root / 'pwsh.exe')
        self.package = {'name': 'OpenAI.Codex', 'family': FAMILY, 'full_name': FULL_NAME,
                        'version': APPX, 'architecture': 'X64', 'status': 'Ok',
                        'signature_kind': 'Store', 'development_mode': False,
                        'install_location': str(self.install)}
        self.installed = {BUNDLED: self.listing(BUNDLED, self.bundled, 'fixture-view', '3.14.15'),
                          PRIMARY: self.listing(PRIMARY, self.primary, 'fixture-notes', '4.2.1')}
        self.marketplace(self.package_market, BUNDLED, {'fixture-view': '3.14.15', 'new-unused': '9.0.0'})
        self.marketplace(self.bundled, BUNDLED, {'fixture-view': '3.14.15', 'disabled': '8.0.0'})
        self.marketplace(self.primary, PRIMARY, {'fixture-notes': '4.2.1'})
        self.manifest(self.home / 'plugins/cache' / BUNDLED / 'fixture-view' / '3.14.15', 'fixture-view', '3.14.15')
        self.manifest(self.home / 'plugins/cache' / PRIMARY / 'fixture-notes' / '4.2.1', 'fixture-notes', '4.2.1')
        self.config()
        self.commands = []
        self.child_programs = {}
        self.registration_outputs = []
        self.spec = importlib.util.spec_from_file_location('codex_store_plugins', ENTRY)
        self.module = importlib.util.module_from_spec(self.spec)
        self.spec.loader.exec_module(self.module)

    def write_json(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding='utf-8')

    def config(self, include_primary=True):
        parts = [f'[plugins."fixture-view@{BUNDLED}"]\nenabled = true',
                 f'[plugins."disabled@{BUNDLED}"]\nenabled = false',
                 '[plugins."other@unrelated"]\nenabled = true',
                 f'[marketplaces.{BUNDLED}]\nsource_type = "local"\nsource = \'{self.path(self.bundled)}\'']
        if include_primary:
            parts.extend([f'[plugins."fixture-notes@{PRIMARY}"]\nenabled = true',
                          f'[marketplaces.{PRIMARY}]\nsource_type = "local"\nsource = \'{self.path(self.primary)}\''])
        (self.home / 'config.toml').write_text('\n\n'.join(parts), encoding='utf-8')

    @staticmethod
    def path(path):
        return ('\\\\?\\' if os.name == 'nt' else '') + str(path)

    def manifest(self, root, name, version):
        self.write_json(root / '.codex-plugin/plugin.json', {'name': name, 'version': version})

    def marketplace(self, root, name, versions):
        rows = []
        for plugin, version in versions.items():
            self.manifest(root / 'plugins' / plugin, plugin, version)
            rows.append({'name': plugin, 'source': {'source': 'local', 'path': f'./plugins/{plugin}'}})
        self.write_json(root / '.agents/plugins/marketplace.json', {'name': name, 'plugins': rows})

    def listing(self, market, root, name, version):
        return {'installed': [{'pluginId': f'{name}@{market}', 'name': name, 'marketplaceName': market,
                               'version': version, 'installed': True, 'enabled': True,
                               'source': {'source': 'local', 'path': str(root / 'plugins' / name)},
                               'marketplaceSource': {'sourceType': 'local', 'source': self.path(root)}}],
                'available': []}

    def child(self, argv, **kwargs):
        self.commands.append(list(argv))
        if argv[0] == self.pwsh:
            self.assertIn('-NonInteractive', argv)
            self.assertIn('Get-AppxPackage -Name OpenAI.Codex -PackageTypeFilter Main', argv[-1])
            scope = 'package'
            data = self.registration_outputs.pop(0) if self.registration_outputs else {'packages': [self.package]}
        else:
            self.assertEqual(Path(argv[0]), self.executable)
            self.assertEqual(argv[1:7], ['--no-daemon', '-c', 'cli_auth_credentials_store=ephemeral',
                                         '--disable', 'remote_plugin', 'plugin'])
            self.assertEqual(argv[7:9], ['list', '--marketplace'])
            self.assertEqual(argv[10:], ['--json'])
            self.assertEqual(kwargs['env']['CODEX_HOME'], str(self.home))
            self.assertNotIn('OPENAI_API_KEY', kwargs['env'])
            scope = argv[9]
            data = self.installed[scope]
        source = self.child_programs.get(scope) or ('import os; os.write(1, ' + repr(json.dumps(data).encode()) + ')')
        return REAL_POPEN([sys.executable, '-B', '-I', '-c', source], **kwargs)

    def cli(self, *args, expected=0):
        stdout = io.StringIO()
        with (patch.dict(os.environ, {'CODEX_HOME': str(self.home), 'USERPROFILE': str(self.profile),
                                     'HOME': str(self.profile), 'OPENAI_API_KEY': 'fixture-secret'}),
              patch('shutil.which', return_value=self.pwsh),
              patch('subprocess.Popen', side_effect=self.child), contextlib.redirect_stdout(stdout)):
            code = self.module.main(list(args))
        self.assertEqual(code, expected, stdout.getvalue())
        self.assertNotIn('fixture-secret', stdout.getvalue())
        self.assertLessEqual(len(stdout.getvalue().encode()), 16 * 1024)
        return json.loads(stdout.getvalue())

    def test_default_uses_registered_package_and_live_configured_scope(self):
        result = self.cli()
        self.assertEqual((result['status'], result['appx_version'], result['registered_package']),
                         ('verified', APPX, FULL_NAME))
        self.assertEqual((result['enabled_count'], result['adopted_count'], result['pending_count']), (2, 2, 0))
        self.assertTrue(result['primary_runtime_checked'])
        self.assertEqual(result['bundled'], [{'plugin_id': 'fixture-view@openai-bundled',
                                             'source_version': '3.14.15', 'marketplace_version': '3.14.15',
                                             'enabled_version': '3.14.15', 'cache_version': '3.14.15'}])
        self.assertEqual([row['plugin_id'] for row in result['primary_runtime']], ['fixture-notes@openai-primary-runtime'])

    def test_version_pending_preserves_matching_primary_runtime_and_read_only_inputs(self):
        self.manifest(self.package_market / 'plugins/fixture-view', 'fixture-view', '3.14.16')
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.rglob('*') if p.is_file()}
        result = self.cli('--expected-appx-version', APPX, expected=2)
        self.assertEqual(result['status'], 'official-client-refresh-pending')
        self.assertEqual((result['adopted_count'], result['pending_count']), (1, 1))
        self.assertEqual(result['bundled'][0]['source_version'], '3.14.16')
        after = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_no_configured_primary_market_still_checks_bundled(self):
        self.config(include_primary=False)
        result = self.cli()
        self.assertFalse(result['primary_runtime_checked'])
        self.assertEqual(result['primary_runtime'], [])
        self.assertEqual(result['enabled_count'], 1)
        self.assertFalse(any(PRIMARY in argv for argv in self.commands))

    def test_expected_version_mismatch_precedes_plugin_probe(self):
        result = self.cli('--expected-appx-version', '45.67.90.0', expected=1)
        self.assertEqual(result, {'schema_version': 1, 'ok': False, 'status': 'rejected',
                                  'error_code': 'appx-version-mismatch'})
        self.assertEqual([argv[0] for argv in self.commands], [self.pwsh])

    def test_invalid_registrations_fail_before_plugin_probe(self):
        for rows, code in (([], 'registered-package-not-unique'),
                           ([self.package, self.package], 'registered-package-not-unique'),
                           ([dict(self.package, status='Modified')], 'registered-package-unhealthy'),
                           ([dict(self.package, signature_kind='Developer')], 'registered-package-unhealthy'),
                           ([dict(self.package, family='Other.App_2p2nqsd0c76g0')], 'registered-package-unhealthy')):
            with self.subTest(code=code, count=len(rows)):
                self.registration_outputs = [{'packages': rows}]
                self.assertEqual(self.cli(expected=1)['error_code'], code)
        self.assertTrue(all(argv[0] == self.pwsh for argv in self.commands))

    def test_registration_that_changes_during_probe_is_rejected(self):
        other = self.install.parent / 'elsewhere' / FULL_NAME
        other.mkdir(parents=True)
        self.registration_outputs = [{'packages': [self.package]},
                                     {'packages': [dict(self.package, install_location=str(other))]}]
        self.assertEqual(self.cli('--expected-appx-version', APPX, expected=1)['error_code'],
                         'registered-package-changed')

    def test_cli_enabled_ids_must_agree_with_config(self):
        listing = self.installed[BUNDLED]
        disabled = dict(self.listing(BUNDLED, self.bundled, 'disabled', '8.0.0')['installed'][0], enabled=False)
        listing['installed'].append(disabled)
        self.assertEqual(self.cli()['enabled_count'], 2)
        disabled['enabled'] = True
        self.assertEqual(self.cli(expected=1)['error_code'], 'enabled-plugin-set-mismatch')
        disabled['enabled'] = False
        listing['installed'][0]['enabled'] = False
        self.assertEqual(self.cli(expected=1)['error_code'], 'enabled-plugin-set-mismatch')

    def test_corrupt_cache_is_rejected_even_if_registration_and_cli_agree(self):
        self.manifest(self.home / 'plugins/cache' / PRIMARY / 'fixture-notes' / '4.2.1', 'fixture-notes', '4.2.0')
        self.assertEqual(self.cli(expected=1)['error_code'], 'cache-version-mismatch')

    def test_cli_rejects_invalid_payloads_without_emitting_upstream_text(self):
        self.child_programs[BUNDLED] = "import os; os.write(2, b'fixture-secret'); os.write(1, b'{not-json-fixture-secret')"
        self.assertEqual(self.cli(expected=1)['error_code'], 'unexpected-child-output')
        self.child_programs[BUNDLED] = "import os; os.write(1, b'{\"installed\":[],\"installed\":[],\"available\":[]}')"
        self.assertEqual(self.cli(expected=1)['error_code'], 'unexpected-child-output')
        del self.child_programs[BUNDLED]
        row = self.installed[BUNDLED]['installed'][0]
        row['marketplaceName'] = PRIMARY
        self.assertEqual(self.cli(expected=1)['error_code'], 'invalid-cli-plugin-list')

    def test_cli_rejects_non_json_constants_in_additive_metadata(self):
        native = self.installed[BUNDLED]
        native['installed'][0]['unknown'] = float('nan')
        self.assertEqual(self.cli(expected=1)['error_code'], 'unexpected-child-output')

    def test_no_cli_output_survives_oversize_or_timeout(self):
        self.child_programs[BUNDLED] = "import os; os.write(1, b'x' * (256 * 1024 + 1))"
        self.assertEqual(self.cli(expected=1)['error_code'], 'input-too-large')
        self.child_programs[BUNDLED] = "import time; time.sleep(100)"
        start = time.monotonic()
        with patch.object(self.module, 'PLUGIN_TIMEOUT', 0.25):
            self.assertEqual(self.cli(expected=1)['error_code'], 'child-timed-out')
        self.assertLess(time.monotonic() - start, 5)

    def test_gate_validator_rejects_inconsistent_or_unexpected_receipt_fields(self):
        result = self.cli()
        self.assertEqual(self.module.validate_result(result, expected_appx_version=APPX), result)
        for changed in (dict(result, pending_count=1), dict(result, enabled_count=True),
                        dict(result, raw_stdout='fixture-secret'), dict(result, appx_version='45.67.90.0')):
            with self.subTest(keys=tuple(changed)):
                with self.assertRaisesRegex(ValueError, '^invalid-result$'):
                    self.module.validate_result(changed, expected_appx_version=APPX)

    def test_gate_validator_rejects_oversized_serialization(self):
        result = self.cli()
        result['primary_runtime_checked'] = False
        result['primary_runtime'] = []
        version = '1.2.3-' + 'a' * 58
        result['bundled'] = [dict(plugin_id=f'fixture-{index}@{BUNDLED}', source_version=version,
                                  marketplace_version=version, enabled_version=version, cache_version=version)
                             for index in range(64)]
        result['enabled_count'] = result['adopted_count'] = 64
        with self.assertRaisesRegex(ValueError, '^result-too-large$'):
            self.module.validate_result(result, expected_appx_version=APPX)


if __name__ == '__main__':
    unittest.main()
