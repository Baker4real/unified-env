import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = pathlib.Path(__file__).resolve().parents[1] / 'scripts/daily-update'
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location('shared_delivery', SCRIPTS / 'shared-skill-delivery.py')
delivery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(delivery)


class MagpieFixture:
    def __init__(self, events):
        self.events = events
        self.selection = None

    def selected(self, skill):
        return self.selection

    def install(self, skill):
        self.events.append(('install', ('dsh',)))
        self.selection = ('dsh',)

    def distribute(self, skill, agents):
        self.events.append(('distribute', agents))
        self.selection = agents

    def verify_delivery(self, skill, agents):
        self.events.append(('readback', agents))
        return {name: 1 for name in agents}


class SharedSkillDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.skill = SimpleNamespace(name='fixture-skill', source=pathlib.Path('fixture-skill'),
                                     sha256='a' * 64, preset='cordis', cwd=pathlib.Path.cwd(),
                                     model_invocable=False, user_invocable=True, verify=lambda: None)
        self.events = []
        self.magpie = MagpieFixture(self.events)
        self.agents = ('claude', 'dsh')

    def probe(self, skill):
        self.events.append(('load', skill.preset))
        return dict(ok=True, source='user-dsh', path=str(skill.source.resolve() / 'SKILL.md'),
                    preset=skill.preset, sha256=skill.sha256, modelInvocable=False,
                    userInvocable=True, bodyLoaded=True)

    def test_register_checks_dsh_before_other_agents_can_receive_skill(self):
        result = delivery.advance('register', self.skill, self.agents, self.magpie, self.probe)
        self.assertEqual(result['status'], 'dsh-verified')
        self.assertEqual(self.events, [('install', ('dsh',)), ('readback', ('dsh',)), ('load', 'cordis')])
        self.events.clear()
        result = delivery.advance('deliver', self.skill, self.agents, self.magpie, self.probe)
        self.assertEqual(result['status'], 'distributed')
        self.assertEqual(self.events, [('readback', ('dsh',)), ('load', 'cordis'),
                                       ('distribute', self.agents), ('readback', self.agents)])
        self.events.clear()
        delivery.advance('deliver', self.skill, self.agents, self.magpie, self.probe)
        self.assertNotIn(('distribute', self.agents), self.events)

    def test_wrong_policy_stops_distribution_and_keeps_first_stage(self):
        def wrong_policy(skill):
            return dict(self.probe(skill), modelInvocable=True)

        self.magpie.selection = ('dsh',)
        with self.assertRaisesRegex(delivery.DeliveryError, 'dsh-acceptance-mismatch'):
            delivery.advance('deliver', self.skill, self.agents, self.magpie, wrong_policy)
        self.assertEqual(self.magpie.selection, ('dsh',))
        self.assertNotIn(('distribute', self.agents), self.events)

    def test_deliver_does_not_enroll_an_unregistered_skill(self):
        with self.assertRaisesRegex(delivery.DeliveryError, 'dsh-registration-required'):
            delivery.advance('deliver', self.skill, self.agents, self.magpie, self.probe)
        self.assertFalse(self.events)


class AntigravityTargetTests(unittest.TestCase):
    def test_reuse_antigravity_distribution_and_resolve_config_path(self):
        state = {'skills': [{'name': 'sibling', 'agents': ['claude', 'antigravity']}]}
        magpie = SimpleNamespace(read=lambda: state, entry=delivery.Magpie().entry)
        args = SimpleNamespace(agents=None, like='sibling')
        self.assertEqual(delivery.enabled_agents(args, magpie), ('antigravity', 'claude', 'dsh'))
        home = pathlib.Path('fixture-home').absolute()
        with patch.dict(os.environ, USERPROFILE=str(home), DSH_HOME=str(home / '.dsh')):
            expected = home / '.gemini/config/skills/fixture-skill'
            self.assertEqual(delivery.consumer_paths('antigravity', 'fixture-skill'), [expected])


class MagpieReadbackTests(unittest.TestCase):
    def scratch(self):
        return tempfile.TemporaryDirectory(dir='D:/Codex/temp' if os.name == 'nt' else None)

    def test_idempotent_delivery_receipt_does_not_reclassify_prior_writes(self):
        with self.scratch() as scratch:
            root = pathlib.Path(scratch)
            run = root / '20261121-000000-fixture'
            run.mkdir()
            skill = SimpleNamespace(name='fixture-skill', source=root / 'skill', preset='cordis', cwd=root,
                                    sha256='a' * 64, transaction='fixture', manifest=root / 'manifest.json',
                                    manifest_sha256='b' * 64, model_invocable=True, user_invocable=True,
                                    new_install=True, operation='install', verify=lambda: None)
            magpie = MagpieFixture([])
            magpie.selection = ('antigravity', 'dsh')
            magpie.write_audits = []
            observed = dict(ok=True, preset='cordis', source='user-dsh', path=str(skill.source / 'SKILL.md'),
                            sha256=skill.sha256, modelInvocable=True, userInvocable=True, bodyLoaded=True)
            argv = ['shared-skill-delivery.py', 'deliver', '--run-directory', str(run), '--receipt', 'receipt.json',
                    '--transaction-manifest', str(skill.manifest), '--name', skill.name, '--preset', skill.preset,
                    '--cwd', str(root), '--model-invocable', 'yes', '--user-invocable', 'yes', '--agents', 'dsh,antigravity']
            with patch.object(delivery, 'EVIDENCE', root), patch.object(delivery, 'Magpie', return_value=magpie), \
                    patch.object(delivery, 'GuardedSkill', return_value=skill), \
                    patch.object(delivery, 'probe_dsh', return_value=observed), patch.object(sys, 'argv', argv), \
                    patch.object(sys, 'stdout', SimpleNamespace(buffer=io.BytesIO())):
                self.assertEqual(delivery.main(), 0)
            receipt = json.loads((run / 'receipt.json').read_text(encoding='utf-8'))
            self.assertEqual(receipt['magpie_write_audit_status'], 'not-observed')
            self.assertEqual(receipt['magpie_write_audits'], [])
            self.assertTrue(receipt['ok'])  # Only current delivery readback passed.

    def profile_environment(self, root):
        return patch.dict(os.environ, USERPROFILE=str(root), APPDATA=str(root / 'roaming'),
                          LOCALAPPDATA=str(root / 'local'), DSH_HOME=str(root / 'dsh'),
                          CODEX_HOME=str(root / 'codex'), CLAUDE_CONFIG_DIR='', KIMI_CODE_HOME='',
                          KIMI_SHARE_DIR='')

    def test_official_binary_is_rejected_before_starting_library_writer(self):
        with self.scratch() as scratch:
            root = pathlib.Path(scratch)
            executable = root / delivery.MAGPIE_SCOPE_EXE.name
            executable.touch()
            magpie = delivery.Magpie(state=root / 'magpie/library.json', executable=executable)
            official = SimpleNamespace(returncode=0, stdout=b'magpie v0.1.4652\n')
            with patch.dict(os.environ, XDG_CONFIG_HOME=str(root)), \
                    patch.object(delivery.subprocess, 'run', return_value=official) as version, \
                    patch.object(delivery.subprocess, 'Popen') as writer:
                with self.assertRaisesRegex(delivery.DeliveryError, 'magpie-scoped-writer-unavailable'):
                    with magpie.endpoint():
                        self.fail('an official binary offered an unscoped write')
            self.assertEqual(version.call_args.args[0], [str(executable.resolve()), '--version'])
            writer.assert_not_called()

    @unittest.skipUnless(os.name == 'nt', 'Windows cross-process file locking')
    def test_scoped_mcp_refuses_to_start_a_second_writer_for_the_same_state(self):
        import msvcrt

        with self.scratch() as scratch:
            root = pathlib.Path(scratch)
            state = root / 'library.json'
            state.write_text('{}', encoding='utf-8')
            script = SCRIPTS / 'shared-skill-delivery.py'
            program = '''
import pathlib, runpy, sys
script, state = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(script.parent))
m = runpy.run_path(str(script))
magpie = m['Magpie'](state=state)
def unexpected():
    raise RuntimeError('writer started while the Library lock was held')
magpie.endpoint = unexpected
try:
    magpie.set_mcp_agents(['fixture-server'], ['antigravity'], True)
except m['DeliveryError'] as err:
    assert str(err) == 'magpie-scoped-write-busy', str(err)
else:
    raise AssertionError('second writer did not report contention')
'''
            with (root / 'library.scoped.lock').open('a+b') as lock:
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                result = subprocess.run([sys.executable, '-B', '-c', program, str(script), str(state)],
                                        capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))

    def test_scoped_mcp_cli_records_missing_writer_receipt_without_retry(self):
        with self.scratch() as scratch, self.profile_environment(pathlib.Path(scratch)):
            root = pathlib.Path(scratch)
            run = root / '20261121-000000-fixture'
            run.mkdir()
            state = root / 'library.json'
            state.write_text('{}', encoding='utf-8')
            magpie = delivery.Magpie(state=state)
            events = []

            @delivery.contextlib.contextmanager
            def endpoint():
                def post(route, payload):
                    events.append((route, payload))
                    raise delivery.DeliveryError('magpie-scoped-library-request-failed')
                yield post

            magpie.endpoint = endpoint
            argv = ['shared-skill-delivery.py', 'scoped-mcp', '--run-directory', str(run), '--receipt', 'mcp.json',
                    '--agents', 'antigravity', '--servers', 'fixture-server', '--enable']
            with patch.object(delivery, 'EVIDENCE', root), patch.object(delivery, 'Magpie', return_value=magpie), \
                    patch.object(sys, 'argv', argv), patch.object(sys, 'stdout', SimpleNamespace(buffer=io.BytesIO())):
                self.assertEqual(delivery.main(), 1)
            self.assertEqual(events, [('servers/agents-some', {'names': ['fixture-server'],
                                                               'agents': ['antigravity'], 'on': True})])
            receipt = json.loads((run / 'mcp.json').read_bytes())
            self.assertEqual(receipt['intended_agents'], ['antigravity'])
            self.assertEqual(receipt['magpie_write_audit_status'], 'review-required')
            audit, = receipt['magpie_write_audits']
            self.assertEqual((audit['kind'], audit['result_complete']), ('mcp', False))

    def test_distribution_records_unplanned_host_and_refuses_success(self):
        with self.scratch() as scratch, self.profile_environment(pathlib.Path(scratch)):
            root = pathlib.Path(scratch)
            state = root / 'library.json'
            skill = SimpleNamespace(name='fixture-skill', source=root / 'source', verify=lambda: None)
            entry = {'name': skill.name, 'source': {'kind': 'folder', 'dir': str(skill.source)}, 'agents': ['dsh']}
            state.write_text(json.dumps({'skills': [entry]}), encoding='utf-8')
            desktop_mcp = root / 'local/Claude-3p/claude_desktop_config.json'
            desktop_mcp.parent.mkdir(parents=True)
            desktop_mcp.write_text('{}', encoding='utf-8')
            magpie = delivery.Magpie(state=state)

            @delivery.contextlib.contextmanager
            def endpoint():
                def post(operation, payload):
                    self.assertEqual((operation, payload['agents']), ('skills/agents', ['antigravity', 'dsh']))
                    entry['agents'] = payload['agents']
                    state.write_text(json.dumps({'skills': [entry]}), encoding='utf-8')
                    target = root / '.gemini/config/skills/fixture-skill'
                    target.mkdir(parents=True)
                    (target / 'SKILL.md').write_text('fixture', encoding='utf-8')
                    desktop_mcp.write_text('{"fixture": "private-canary"}', encoding='utf-8')
                    return {'result': {'changed': ['antigravity', 'claude-desktop'], 'problems': []}}
                yield post

            magpie.endpoint = endpoint
            with self.assertRaisesRegex(delivery.DeliveryError, 'magpie-write-audit-needs-review'):
                magpie.distribute(skill, ('antigravity', 'dsh'))
            audit, = magpie.write_audits
            self.assertEqual(audit['reported_changed_hosts'], ['antigravity', 'claude-desktop'])
            self.assertEqual(audit['unexpected_changed_hosts'], ['claude-desktop'])
            self.assertIn('claude-desktop.mcp', audit['changed_artifacts'])
            self.assertNotIn('private-canary', json.dumps(audit))

    def audit_cli(self, state, *argv, stdin=None):
        stdout = io.BytesIO()
        request = io.BytesIO(json.dumps(stdin).encode('utf-8'))
        with patch.object(delivery, 'MAGPIE_STATE', state), patch.object(sys, 'argv', ['shared-skill-delivery.py', *argv]), \
                patch.object(sys, 'stdin', SimpleNamespace(buffer=request)), \
                patch.object(sys, 'stdout', SimpleNamespace(buffer=stdout)):
            code = delivery.main()
        return code, json.loads(stdout.getvalue())

    def test_gui_mcp_audit_reconciles_report_and_fingerprints(self):
        with self.scratch() as scratch, self.profile_environment(pathlib.Path(scratch)):
            root = pathlib.Path(scratch)
            state = root / 'library.json'
            state.write_text('{"mcp":[{"url":"private-url-canary"}]}', encoding='utf-8')
            antigravity = root / '.gemini/config/mcp_config.json'
            antigravity.parent.mkdir(parents=True)
            antigravity.write_text('{}', encoding='utf-8')
            manifest = root / 'local/Claude-3p/local-agent-mode-sessions/skills-plugin/org/account/manifest.json'
            manifest.parent.mkdir(parents=True)
            manifest.write_text('{"skills":[]}', encoding='utf-8')

            code, before = self.audit_cli(state, 'audit-before', '--kind', 'mcp', '--agents', 'antigravity')
            self.assertEqual((code, before['status']), (0, 'preflight-ready'))
            self.assertIn('antigravity-mcp-and-skill-files-shared-with-agy-if-installed', before['limitations'])
            self.assertNotIn('private-url-canary', json.dumps(before))
            antigravity.write_text('{"mcpServers":{}}', encoding='utf-8')
            result = {'changed': ['antigravity'], 'problems': []}
            code, after = self.audit_cli(state, 'audit-after', stdin={'before': before, 'result': result})
            self.assertEqual((code, after['status']), (0, 'observed-within-scope'))
            self.assertEqual(after['changed_artifacts'], ['antigravity.mcp'])

            manifest.write_text('{"skills":[{"name":"unrelated-fixture-skill"}]}', encoding='utf-8')
            result['changed'].append('claude-desktop')
            code, after = self.audit_cli(state, 'audit-after', stdin={'before': before, 'result': result})
            self.assertEqual((code, after['status']), (1, 'review-required'))
            self.assertEqual(after['unexpected_changed_hosts'], ['claude-desktop'])
            self.assertEqual(after['unexpected_artifacts'], ['claude-desktop.manifest'])
            self.assertNotIn('unrelated-fixture-skill', json.dumps(after))

    def test_gui_audit_keeps_other_host_changes_when_profile_inventory_fails(self):
        with self.scratch() as scratch, self.profile_environment(pathlib.Path(scratch)):
            root = pathlib.Path(scratch)
            state = root / 'library.json'
            state.write_text('{}', encoding='utf-8')
            profiles = root / 'dsh/profiles'
            profiles.mkdir(parents=True)
            code, before = self.audit_cli(state, 'audit-before', '--kind', 'mcp', '--agents', 'antigravity')
            self.assertEqual(code, 0)
            target = root / '.gemini/config/mcp_config.json'
            target.parent.mkdir(parents=True)
            target.write_text('{}', encoding='utf-8')
            original = pathlib.Path.iterdir

            def iterdir(path):
                if path == profiles:
                    raise PermissionError('fixture-denied')
                return original(path)

            with patch.object(pathlib.Path, 'iterdir', iterdir):
                code, after = self.audit_cli(state, 'audit-after', stdin={
                    'before': before, 'result': {'changed': ['antigravity'], 'problems': []},
                })
            self.assertEqual((code, after['status']), (1, 'review-required'))
            self.assertEqual(after['unavailable_artifacts'], ['dsh.mcp'])
            self.assertEqual(after['changed_artifacts'], ['antigravity.mcp'])

    def test_gui_skill_audit_keeps_unknown_and_unreported_writes_pending(self):
        with self.scratch() as scratch, self.profile_environment(pathlib.Path(scratch)):
            root = pathlib.Path(scratch)
            state = root / 'library.json'
            state.write_text('{}', encoding='utf-8')
            code, before = self.audit_cli(state, 'audit-before', '--kind', 'skill', '--name', 'fixture-skill', '--agents', 'dsh')
            self.assertEqual(code, 0)
            target = root / 'dsh/skills/fixture-skill'
            target.mkdir(parents=True)
            (target / 'SKILL.md').write_text('fixture payload', encoding='utf-8')
            (target / 'helper.cmd').write_text('@echo off\n', encoding='utf-8')
            for result, code_expected, unreported, unknown in (
                (None, 1, ['dsh'], 0),
                ({'changed': [], 'problems': []}, 1, ['dsh'], 0),
                ({'changed': ['antigravity', 'dsh', None], 'problems': []}, 1, [], 1),
                ({'changed': ['dsh'], 'problems': []}, 0, [], 0),
            ):
                with self.subTest(result=result):
                    code, after = self.audit_cli(state, 'audit-after', stdin={'before': before, 'result': result})
                    self.assertEqual((code, after['result_complete']), (code_expected, result is not None))
                    self.assertEqual(after['changed_artifacts'], ['dsh.skill'])
                    self.assertEqual(after['unreported_observed_hosts'], unreported)
                    self.assertEqual(after['unknown_reported_host_count'], unknown)
                    self.assertEqual(after['unverified_reported_hosts'],
                                     ['antigravity'] if unknown else [])
            result = {'changed': ['dsh'], 'problems': [{'agent': 'dsh', 'error': 'private-canary'}]}
            code, after = self.audit_cli(state, 'audit-after', stdin={'before': before, 'result': result})
            self.assertEqual((code, after['status'], after['reason']),
                             (1, 'input-invalid', 'invalid-magpie-audit-projection'))
            self.assertFalse(after['result_complete'])
            self.assertEqual(after['changed_artifacts'], ['dsh.skill'])
            self.assertNotIn('private-canary', json.dumps(after))

    def test_desktop_copied_payload_requires_enabled_manifest_entry(self):
        with self.scratch() as scratch:
            root = pathlib.Path(scratch)
            source = root / 'active/fixture-skill'
            source.mkdir(parents=True)
            (source / 'SKILL.md').write_text('expected fixture', encoding='utf-8')
            account = root / 'desktop-account'
            target = account / 'skills/fixture-skill'
            shutil.copytree(source, target)
            (target / '.magpie-library').touch()
            skill = SimpleNamespace(source=source, name='fixture-skill')
            manifest = account / 'manifest.json'
            manifest.write_text('{"skills":[]}', encoding='utf-8')
            with self.assertRaisesRegex(delivery.DeliveryError, 'desktop-skill-not-enabled'):
                delivery.verify_target(target, skill, source, agent='claude-desktop')
            manifest.write_text('{"skills":[{"name":"fixture-skill","enabled":true}]}', encoding='utf-8')
            delivery.verify_target(target, skill, source, agent='claude-desktop')

    def test_install_audits_before_receipt_acknowledgement(self):
        with self.scratch() as scratch, self.profile_environment(pathlib.Path(scratch)):
            root = pathlib.Path(scratch)
            state = root / 'library.json'
            state.write_text('{"skills":[]}', encoding='utf-8')
            skill = SimpleNamespace(name='fixture-skill', source=root / 'source', verify=lambda: None)
            magpie = delivery.Magpie(state=state)

            @delivery.contextlib.contextmanager
            def endpoint():
                def post(operation, payload):
                    if operation == 'skills/probe':
                        return {'kind': 'folder', 'candidates': [{'name': skill.name, 'path': ''}]}
                    self.assertEqual((operation, payload['agents']), ('skills/install', ['dsh']))
                    target = root / 'dsh/skills/fixture-skill'
                    target.mkdir(parents=True)
                    (target / 'SKILL.md').write_text('fixture', encoding='utf-8')
                    return {'mcp': [{'url': 'private-url-canary'}], 'result': {
                        'changed': ['dsh'], 'installed': [], 'backup': 'private-backup-canary',
                        'problems': [{'agent': 'dsh', 'error': 'private-command-canary'}],
                    }}
                yield post

            magpie.endpoint = endpoint
            with self.assertRaisesRegex(delivery.DeliveryError, 'magpie-install-not-acknowledged'):
                magpie.install(skill)
            audit, = magpie.write_audits
            self.assertFalse(audit['ok'])
            self.assertEqual(audit['problem_hosts'], ['dsh'])
            self.assertTrue(audit['backup_reported'])
            self.assertEqual(audit['changed_artifacts'], ['dsh.skill'])
            self.assertNotIn('canary', json.dumps(audit))

    def test_recover_only_same_source_orphan_library_link(self):
        with self.scratch() as scratch, self.profile_environment(pathlib.Path(scratch)):
            root = pathlib.Path(scratch)
            state = root / 'library.json'
            state.write_text('{"skills":[]}', encoding='utf-8')
            source = root / 'active/fixture-skill'
            source.mkdir(parents=True)
            skill = SimpleNamespace(source=source, name=source.name, verify=lambda: None)
            magpie = delivery.Magpie(state=state)
            link = magpie.library_root / skill.name
            link.parent.mkdir(parents=True)
            try:
                link.symlink_to(source, target_is_directory=True)
            except OSError as error:
                if os.name == 'nt' and error.winerror == 1314:
                    self.skipTest('fixture cannot create Windows symlinks')
                raise
            calls = []

            @delivery.contextlib.contextmanager
            def endpoint():
                def post(operation, payload):
                    calls.append(operation)
                    if operation == 'skills/probe':
                        return {'kind': 'folder', 'candidates': [{'name': skill.name, 'path': ''}]}
                    self.assertEqual(payload['agents'], ['dsh'])
                    entry = {'name': skill.name, 'source': {'kind': 'folder', 'dir': str(source)}, 'agents': ['dsh']}
                    state.write_text(json.dumps({'skills': [entry]}), encoding='utf-8')
                    return {'result': {'installed': [skill.name], 'changed': [], 'problems': []}}
                yield post

            magpie.endpoint = endpoint
            magpie.install(skill)
            self.assertEqual(calls, ['skills/probe', 'skills/install'])
            state.write_text('{"skills":[]}', encoding='utf-8')
            conflict = SimpleNamespace(source=root / 'another', name=source.name, verify=lambda: None)
            with self.assertRaisesRegex(delivery.DeliveryError, 'magpie-initial-registration-conflict'):
                magpie.install(conflict)
            self.assertEqual(calls, ['skills/probe', 'skills/install'])


if __name__ == '__main__':
    unittest.main()
