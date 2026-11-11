"""Public read-only retirement verification with explicit observations."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('retirement', ROOT / 'scripts/verify-component-retirement.py')
retirement = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(retirement)


class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir='D:/Codex/tmp', prefix='retirement-check-')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.active = self.root / 'skills'
        self.active.mkdir()
        self.consumer = self.root / 'consumer'
        self.consumer.mkdir()
        self.archive = self.root / 'archives'
        self.archive.mkdir()
        self.ledger = self.active / '.downloaded-skills-source-state.json'
        self.ledger.write_text(json.dumps({'sources':[{'id':'source-demo','status':'deleted-by-user','skills':[], 'backup_status':'no-local-backup-by-user-rule'}]}))
        self.magpie = self.root / 'library.json'
        self.magpie.write_text('{"skills":[]}')
        self.policy = self.root / 'policy.json'
        self.policy.write_text('{"entries":[]}')
        self.spec = dict(schema_version=1, skills=[dict(name='demo-skill',source_id='source-demo')],
                         active_root=str(self.active), ledger=str(self.ledger), magpie_library=str(self.magpie),
                         consumer_roots=[str(self.consumer)], scan_roots=[str(self.archive)],
                         policy=str(self.policy), temporary_policy_ids=['temporary-demo'],
                         absent_paths=[str(self.root / 'program')], tasks=['Demo Elevated'], products=['{DEMO}'],
                         process_names=['demo'], manual_pending=[])
        self.observed = dict(tasks={'Demo Elevated':'absent'}, products={'{DEMO}':'absent'}, processes={'demo':'absent'})

    def verify(self):
        return retirement.verify(self.spec, lambda spec: self.observed)

    def test_complete_predicate_rejects_an_active_payload(self):
        self.assertEqual(self.verify()['status'], 'retired')
        (self.active / 'demo-skill').mkdir()
        result = self.verify()
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'residual')

    def test_every_observed_surface_is_required(self):
        for section, identity in [('tasks','Demo Elevated'), ('products','{DEMO}'), ('processes','demo')]:
            with self.subTest(section=section):
                self.observed[section][identity] = 'present'
                self.assertFalse(self.verify()['ok'])
                self.observed[section][identity] = 'unknown'
                self.assertEqual(self.verify()['status'], 'unknown')
                self.observed[section][identity] = 'absent'

    def test_policy_ledger_library_links_and_program_each_block_success(self):
        cases = [
            (self.policy, {'entries':[{'id':'temporary-demo'}]}),
            (self.ledger, {'sources':[{'id':'source-demo','status':'deleted-by-user','skills':[], 'backup_status':'purge-pending-elevated-acl'}]}),
            (self.magpie, {'skills':[{'name':'demo-skill'}]}),
        ]
        for file, bad in cases:
            original = file.read_bytes()
            file.write_text(json.dumps(bad))
            self.assertFalse(self.verify()['ok'], file)
            file.write_bytes(original)
        link = self.consumer / 'demo-skill'
        link.mkdir()
        self.assertFalse(self.verify()['ok'])
        link.rmdir()
        program = self.root / 'program'
        program.mkdir()
        self.assertFalse(self.verify()['ok'])

    def test_content_identity_finds_renamed_payload_without_author_false_positive(self):
        renamed = self.archive / 'arbitrary-name'
        renamed.mkdir()
        (renamed / 'SKILL.md').write_text('---\nname: demo-skill\n---\nPayload\n')
        unrelated = self.archive / 'other-skill'
        unrelated.mkdir()
        (unrelated / 'SKILL.md').write_text('---\nname: other\nauthor: demo-skill\ndescription: [deprecated] legacy unrelated metadata\n---\n```yaml\nname: demo-skill\n```\n')
        (unrelated / 'SOURCE.md').write_text('Skill: `demo-skill`\n---\nSkill: `other`\n')
        result = self.verify()
        self.assertFalse(result['ok'])
        self.assertEqual([row['path'] for row in result['payloads']], [str(renamed)])
        self.assertEqual(result['unknown'], [], 'Unrelated metadata syntax is outside the identity seam')

    def test_manual_recycle_action_cannot_be_hidden_by_machine_success(self):
        self.spec['manual_pending'] = ['empty-recycle-bin']
        result = self.verify()
        self.assertTrue(result['machine_retired'])
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], 'manual-pending')

    def test_unreadable_or_missing_input_stays_unknown(self):
        self.ledger.unlink()
        result = self.verify()
        self.assertEqual(result['status'], 'unknown')
        self.assertFalse(result['ok'])


if __name__ == '__main__':
    unittest.main()
