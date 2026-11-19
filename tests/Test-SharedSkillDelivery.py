import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest

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


class MagpieReadbackTests(unittest.TestCase):
    def scratch(self):
        return tempfile.TemporaryDirectory(dir='D:/Codex/temp' if os.name == 'nt' else None)

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

    def test_recover_only_same_source_orphan_library_link(self):
        with self.scratch() as scratch:
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
                    if operation == 'probe':
                        return {'kind': 'folder', 'candidates': [{'name': skill.name, 'path': ''}]}
                    self.assertEqual(payload['agents'], ['dsh'])
                    entry = {'name': skill.name, 'source': {'kind': 'folder', 'dir': str(source)}, 'agents': ['dsh']}
                    state.write_text(json.dumps({'skills': [entry]}), encoding='utf-8')
                    return {'result': {'installed': [skill.name]}}
                yield post

            magpie.endpoint = endpoint
            magpie.install(skill)
            self.assertEqual(calls, ['probe', 'install'])
            state.write_text('{"skills":[]}', encoding='utf-8')
            conflict = SimpleNamespace(source=root / 'another', name=source.name, verify=lambda: None)
            with self.assertRaisesRegex(delivery.DeliveryError, 'magpie-initial-registration-conflict'):
                magpie.install(conflict)
            self.assertEqual(calls, ['probe', 'install'])


if __name__ == '__main__':
    unittest.main()
