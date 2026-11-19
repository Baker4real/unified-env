"""Exercise the one-skill staging CLI using only disposable local Git repositories."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/daily-update/stage-skill-candidates.py'
EVIDENCE_ROOT = Path('D:/agents/run-evidence')
BASE_SKILL = b'# Sample\nupstream: old\none\ntwo\nthree\nfour\nlocal: old\n'
SOURCE = b'\xef\xbb\xbf# Source\r\n\r\nOriginal record.\r\n'


class SkillCandidateStagingTests(unittest.TestCase):
    def setUp(self):
        EVIDENCE_ROOT.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(dir=EVIDENCE_ROOT, prefix='skill-staging-fixture-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.run = self.root / '20261119-120000'
        self.run.mkdir()
        self.active = self.root / 'active'
        self.active.mkdir()
        self.repo = self.root / 'local upstream'
        self.repo.mkdir()
        self.git('init', '--quiet')
        self.upstream = self.repo / 'pack' / '中文 skill'
        self.old_path = 'pack/中文 skill'
        self.local = self.active / 'sample'

    def put(self, root, path, raw):
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(raw)

    def git(self, *args, input=None):
        return subprocess.run([
            'git', '-C', str(self.repo), '-c', 'core.longpaths=true', '-c', 'core.autocrlf=false',
            '-c', 'core.hooksPath=NUL', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
            *args,
        ], input=input, check=True, capture_output=True, timeout=30).stdout

    def commit(self):
        self.git('add', '--all')
        self.git('commit', '--quiet', '-m', 'Fixture')
        return self.git('rev-parse', 'HEAD').decode('ascii').strip()

    def config(self, old, new, *, name='sample', mode='update', **fields):
        value = dict(run_directory=str(self.run), repository=str(self.repo), active_root=str(self.active),
                     name=name, mode=mode, upstream_path=self.old_path, old_commit=old, new_commit=new)
        value.update(fields)
        path = self.run / f'config-{name}.json'
        path.write_text(json.dumps(value), encoding='utf-8')
        return path

    def invoke(self, config, action='stage'):
        return subprocess.run([sys.executable, '-B', str(SCRIPT), action, '--config', str(config)],
                              capture_output=True, timeout=40)

    def simple_update(self):
        self.put(self.upstream, 'SKILL.md', BASE_SKILL)
        old = self.commit()
        self.put(self.upstream, 'SKILL.md', BASE_SKILL.replace(b'upstream: old', b'upstream: new'))
        new = self.commit()
        self.put(self.local, 'SKILL.md', BASE_SKILL)
        self.put(self.local, 'SOURCE.md', SOURCE)
        return old, new

    def ready(self, config, status='staged', action='stage'):
        completed = self.invoke(config, action)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        result = json.loads(completed.stdout)
        self.assertTrue(result['ok'])
        self.assertEqual(result['status'], status)
        return result

    def blocked(self, config, status, action='stage'):
        completed = self.invoke(config, action)
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        result = json.loads(completed.stdout)
        self.assertFalse(result['ok'])
        self.assertEqual(result['status'], status)
        return result

    def test_update_merges_the_literal_subtree_and_preserves_active_overlay_bytes(self):
        self.put(self.upstream, 'SKILL.md', BASE_SKILL)
        self.put(self.upstream, 'resources/retired.txt', b'retired\n')
        self.put(self.repo, '.gitattributes', b'*.bin export-ignore\n')
        self.put(self.repo, 'unrelated.md', b'outside skill subtree')
        old = self.commit()
        self.put(self.upstream, 'SKILL.md', BASE_SKILL.replace(b'upstream: old', b'upstream: new'))
        (self.upstream / 'resources/retired.txt').unlink()
        self.put(self.upstream, 'resources/- 参考 notes.bin', b'\xff\x00\r\n\x01')
        self.put(self.upstream, 'SOURCE.md', b'The upstream provenance must not replace the local record.\n')
        new = self.commit()
        self.put(self.local, 'SKILL.md', BASE_SKILL.replace(b'local: old', b'local: kept'))
        self.put(self.local, 'resources/retired.txt', b'retired\n')
        self.put(self.local, 'resources/local notes.md', b'Local only.\r\nNo final newline')
        self.put(self.local, 'SOURCE.md', SOURCE)
        self.put(self.active, 'neighbor/SKILL.md', b'unrelated active')

        completed = self.invoke(self.config(old, new))
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result['status'], 'staged')
        self.assertTrue(result['ok'])
        candidate, receipt = Path(result['candidate_path']), Path(result['receipt_path'])
        self.assertEqual(receipt, self.run / 'skills/staging/sample/receipt.json')
        self.assertTrue(candidate.is_relative_to(self.run))
        self.assertEqual({p.relative_to(candidate).as_posix(): p.read_bytes()
                          for p in candidate.rglob('*') if p.is_file()}, {
            'SKILL.md': b'# Sample\nupstream: new\none\ntwo\nthree\nfour\nlocal: kept\n',
            'SOURCE.md': SOURCE,
            'resources/- 参考 notes.bin': b'\xff\x00\r\n\x01',
            'resources/local notes.md': b'Local only.\r\nNo final newline',
        })
        self.assertEqual((self.local / 'SKILL.md').read_bytes(), BASE_SKILL.replace(b'local: old', b'local: kept'))
        self.assertEqual((self.local / 'SOURCE.md').read_bytes(), SOURCE)
        self.assertEqual((self.active / 'neighbor/SKILL.md').read_bytes(), b'unrelated active')
        self.assertTrue(receipt.is_file())

    def test_one_success_survives_next_candidates_conflict_and_partial_attempt(self):
        old, new = self.simple_update()
        first_config = self.config(old, new)
        first = self.ready(first_config)
        first_receipt = Path(first['receipt_path'])
        original_bytes = first_receipt.read_bytes()

        other = self.active / 'second'
        self.put(other, 'SKILL.md', BASE_SKILL.replace(b'upstream: old', b'upstream: incompatible'))
        self.put(other, 'SOURCE.md', SOURCE)
        second_config = self.config(old, new, name='second')
        abandoned = self.run / 'skills/staging/second/attempt-01/candidate'
        self.put(abandoned, 'sentinel', b'untrusted interrupted attempt')
        second_receipt = self.run / 'skills/staging/second/receipt.json'

        failure = self.blocked(second_config, 'text-merge-conflict')
        self.assertEqual(failure['path'], 'SKILL.md')
        self.assertFalse(second_receipt.exists())
        self.assertEqual(first_receipt.read_bytes(), original_bytes)
        self.assertEqual(self.ready(first_config, status='reused')['candidate_path'], first['candidate_path'])

        self.put(other, 'SKILL.md', BASE_SKILL)
        second = self.ready(second_config)
        self.assertEqual(Path(second['receipt_path']), second_receipt)
        self.assertNotEqual(Path(second['candidate_path']), abandoned)
        self.assertEqual((abandoned / 'sentinel').read_bytes(), b'untrusted interrupted attempt')
        self.assertEqual(first_receipt.read_bytes(), original_bytes)

    def test_replay_refuses_config_active_and_candidate_drift_without_overwriting(self):
        old, new = self.simple_update()
        cfg = self.config(old, new)
        first = self.ready(cfg)
        receipt, candidate = Path(first['receipt_path']), Path(first['candidate_path'])
        receipt_bytes = receipt.read_bytes()
        record = json.loads(receipt_bytes)
        self.assertEqual(record['binding']['old_commit'], old)
        self.assertEqual(record['binding']['new_commit'], new)
        self.assertEqual(record['binding']['upstream_path'], self.old_path)
        self.assertEqual(record['candidate_payload']['tree_sha256'], first['candidate_tree_sha256'])
        self.assertEqual(self.ready(cfg, status='verified', action='verify')['candidate_path'], str(candidate))

        self.blocked(self.config(new, old), 'receipt-input-drift')
        self.config(old, new)
        self.put(self.local, 'resources/active drift.md', b'local drift')
        self.blocked(cfg, 'active-payload-drift')
        (self.local / 'resources/active drift.md').unlink()
        (self.local / 'resources').rmdir()
        (candidate / 'new-empty-dir').mkdir()
        self.blocked(cfg, 'candidate-payload-drift', action='verify')
        self.assertTrue((candidate / 'new-empty-dir').is_dir())
        (candidate / 'new-empty-dir').rmdir()
        self.put(candidate, 'SOURCE.md', b'modified after staging')
        self.blocked(cfg, 'candidate-payload-drift')
        self.assertEqual((candidate / 'SOURCE.md').read_bytes(), b'modified after staging')
        self.assertEqual(receipt.read_bytes(), receipt_bytes)

    def test_unknown_commit_and_mutable_ref_never_publish(self):
        old, new = self.simple_update()
        self.blocked(self.config('HEAD', new), 'full-commit-id-required')
        failure = self.blocked(self.config('1' * 40, new), 'git-failed')
        self.assertNotEqual(failure['git_exit_code'], 0)
        self.assertFalse((self.run / 'skills').exists())
        self.ready(self.config(old, new))

    def test_install_stages_a_root_subtree_with_long_names_and_bounds_the_listing(self):
        long_path = '/'.join(['references'] + [f'folder-{n}-' + 'a' * 64 for n in range(4)] + ['`usage`.md'])
        self.put(self.repo, 'SKILL.md', BASE_SKILL)
        self.put(Path('\\\\?\\' + str(self.repo)), long_path, b'Long resource with no final newline')
        for n in range(12):
            self.put(self.repo, f'references/short-{n}.txt', b'ordinary resource\r\n')
        new = self.commit()
        config = self.config(None, new, mode='install', upstream_path='.')
        completed = self.invoke(config)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        result = json.loads(completed.stdout)
        candidate = Path(result['candidate_path'])
        candidate_disk = Path('\\\\?\\' + str(candidate))
        self.assertGreater(len(str(candidate / long_path)), 260)
        self.assertEqual((candidate_disk / long_path).read_bytes(), b'Long resource with no final newline')
        self.assertEqual((candidate / 'references/short-11.txt').read_bytes(), b'ordinary resource\r\n')
        self.assertGreater(result['omitted_path_count'], 0)
        self.assertLessEqual(len(result['changed_paths']), 8)
        self.assertLessEqual(len(completed.stdout), 8192)
        self.assertFalse((candidate / 'SOURCE.md').exists())
        self.assertFalse(self.local.exists())
        self.put(self.local, 'SKILL.md', b'appeared after staging')
        self.blocked(config, 'active-payload-drift', action='verify')
        self.assertEqual((self.local / 'SKILL.md').read_bytes(), b'appeared after staging')

    def test_binary_two_sided_conflict_publishes_no_receipt(self):
        self.put(self.upstream, 'SKILL.md', BASE_SKILL)
        self.put(self.upstream, 'image.bin', b'\x00base')
        old = self.commit()
        self.put(self.upstream, 'image.bin', b'\x00upstream')
        new = self.commit()
        self.put(self.local, 'SKILL.md', BASE_SKILL)
        self.put(self.local, 'SOURCE.md', SOURCE)
        self.put(self.local, 'image.bin', b'\x00local')
        result = self.blocked(self.config(old, new), 'binary-merge-conflict')
        self.assertEqual(result['path'], 'image.bin')
        self.assertFalse((self.run / 'skills/staging/sample/receipt.json').exists())
        self.assertEqual((self.local / 'image.bin').read_bytes(), b'\x00local')

    def test_git_symlink_and_unsafe_windows_names_are_refused_before_an_attempt(self):
        blob = self.git('hash-object', '-w', '--stdin', input=BASE_SKILL).strip()
        base_entry = b'100644 blob ' + blob + b'\tSKILL.md\0'
        cases = {
            b'120000 blob ' + blob + b'\tlink\0': 'unsupported-git-tree-entry',
            b'100644 blob ' + blob + b'\tCON.txt\0': 'unsafe-path',
            b'100644 blob ' + blob + b'\tline\nbreak\0': 'unsafe-path',
            b'100644 blob ' + blob + b'\tcase\0' + b'100644 blob ' + blob + b'\tCASE\0': 'case-colliding-path',
        }
        for special_entry, status in cases.items():
            with self.subTest(status=status, entry=special_entry):
                tree = self.git('mktree', '-z', input=base_entry + special_entry).decode('ascii').strip()
                commit = self.git('commit-tree', tree, '-m', 'Synthetic staging fixture').decode('ascii').strip()
                self.blocked(self.config(None, commit, mode='install', upstream_path='.'), status)
                self.assertFalse((self.run / 'skills').exists())

    def test_reparse_in_active_or_staging_path_cannot_be_followed(self):
        old, new = self.simple_update()
        cfg = self.config(old, new)
        other = self.root / 'outside'
        other.mkdir()

        def junction(path):
            subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(path), str(other)],
                           check=True, capture_output=True, timeout=15)

        active_link = self.local / 'resources'
        junction(active_link)
        self.blocked(cfg, 'reparse-path')
        self.assertEqual(list(other.iterdir()), [])
        self.assertTrue(active_link.is_junction())
        active_link.rmdir()
        junction(self.run / 'skills')
        self.blocked(cfg, 'reparse-path')
        self.assertEqual(list(other.iterdir()), [])
        self.assertTrue((self.run / 'skills').is_junction())

    def test_large_unrelated_tree_does_not_expand_the_selected_subtree(self):
        blob = self.git('hash-object', '-w', '--stdin', input=BASE_SKILL).strip()
        entry = b'100644 blob ' + blob + b'\t'
        large_tree = self.git('mktree', '-z', input=b''.join(
            entry + f'outside-{n:05}\0'.encode('ascii') for n in range(10001))).strip()
        skill_tree = self.git('mktree', '-z', input=entry + b'SKILL.md\0').strip()
        root_tree = self.git('mktree', '-z', input=(
            b'040000 tree ' + large_tree + b'\tunrelated\0'
            b'040000 tree ' + skill_tree + b'\tselected\0')).decode('ascii').strip()
        commit = self.git('commit-tree', root_tree, '-m', 'Large Git object fixture').decode('ascii').strip()
        result = self.ready(self.config(None, commit, mode='install', upstream_path='selected'))
        candidate = Path(result['candidate_path'])
        self.assertEqual([p.name for p in candidate.iterdir()], ['SKILL.md'])
        self.blocked(self.config(None, commit, name='wide', mode='install', upstream_path='.'),
                     'git-tree-listing-limit')
        self.assertFalse((self.run / 'skills/staging/wide').exists())

    def test_concurrent_same_skill_staging_publishes_one_receipt(self):
        old, new = self.simple_update()
        cfg = self.config(old, new)
        with ThreadPoolExecutor(max_workers=2) as workers:
            children = list(workers.map(self.invoke, (cfg, cfg)))
        for child in children:
            self.assertEqual(child.returncode, 0, child.stdout + child.stderr)
        first, second = [json.loads(child.stdout) for child in children]
        self.assertEqual({first['status'], second['status']}, {'staged', 'reused'})
        self.assertEqual(first['receipt_path'], second['receipt_path'])
        self.assertEqual(first['candidate_path'], second['candidate_path'])
        self.assertEqual(self.ready(cfg, status='verified', action='verify')['candidate_path'], first['candidate_path'])

    def test_ambiguous_config_or_receipt_schema_blocks_replay(self):
        old, new = self.simple_update()
        cfg = self.config(old, new)
        original = cfg.read_text(encoding='utf-8')
        cfg.write_text(original[:-1] + ',"mode":"update"}', encoding='utf-8')
        self.blocked(cfg, 'invalid-or-missing-json')
        self.assertFalse((self.run / 'skills').exists())

        cfg.write_text(original, encoding='utf-8')
        receipt = Path(self.ready(cfg)['receipt_path'])
        record = json.loads(receipt.read_bytes())
        record['schema_version'] = True
        receipt.write_text(json.dumps(record), encoding='utf-8')
        self.blocked(cfg, 'invalid-receipt', action='verify')

    def test_existing_receipt_and_exhausted_attempts_are_left_untouched(self):
        old, new = self.simple_update()
        cfg = self.config(old, new)
        scope = self.run / 'skills/staging/sample'
        for n in range(1, 9):
            self.put(scope, f'attempt-{n:02}/abandoned', bytes([n]))
        self.blocked(cfg, 'attempt-limit-reached')
        self.assertEqual(sorted(p.name for p in scope.iterdir()), [f'attempt-{n:02}' for n in range(1, 9)])
        for n in range(1, 9):
            self.assertEqual((scope / f'attempt-{n:02}/abandoned').read_bytes(), bytes([n]))
        self.put(scope, 'receipt.json', b'{')
        self.blocked(cfg, 'invalid-or-missing-json')
        self.assertEqual((scope / 'receipt.json').read_bytes(), b'{')


if __name__ == '__main__':
    unittest.main()
