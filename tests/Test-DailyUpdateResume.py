"""Resume uses the existing reader and binds its scope, never guesses the newest directory."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / 'scripts/daily-update/daily-update-resume.py'
WRAPPER = ROOT / 'scripts/daily-update/Resume-DailyUpdate.ps1'


class ResumeTests(unittest.TestCase):
    def setUp(self):
        pathlib.Path('D:/agents/run-evidence').mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir='D:/agents/run-evidence', prefix='resume-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.index = self.root / 'resume-index.json'
        for name in ('current', 'previous'):
            run = self.root / name
            run.mkdir()
            raw = json.dumps({'units': [{'id': 'check', 'status': 'pending', 'evidence': []}]}).encode()
            (run / 'scope-manifest.json').write_bytes(raw)
            (run / 'scope-checkpoint.json').write_text(json.dumps({'scope_manifest': 'scope-manifest.json',
                'scope_manifest_sha256': hashlib.sha256(raw).hexdigest()}), encoding='utf-8')
            (run / 'RESULT.md').write_text('# 需要用户裁决\n\n需核对兼容映射。\n\n# 结果\n', encoding='utf-8')

    def create(self):
        return subprocess.run([sys.executable, '-B', str(CLI), 'index', '--run-directory', str(self.root / 'current'),
            '--previous-run-directory', str(self.root / 'previous'), '--index-path', str(self.index)],
            capture_output=True, text=True, encoding='utf-8')

    def resume(self, budget=6000):
        return subprocess.run([shutil.which('pwsh'), '-NoProfile', '-File', str(WRAPPER),
            '-IndexPath', str(self.index), '-MaxTotalBytes', str(budget)], capture_output=True, text=True,
            encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)

    def test_correct_run_and_decisions_within_budget(self):
        created = self.create()
        self.assertEqual(created.returncode, 0, created.stdout + created.stderr)
        result = self.resume()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(result.stdout)
        self.assertTrue(value['ok'])
        self.assertEqual(pathlib.Path(value['run_directory']), self.root / 'current')
        self.assertEqual(value['resume']['unfinished_units'], ['check'])
        self.assertIn('兼容映射', result.stdout)
        self.assertLessEqual(len(result.stdout.encode()), 6000)

    def test_scope_hash_drift_is_not_silent_empty_success(self):
        self.assertEqual(self.create().returncode, 0)
        with (self.root / 'current/scope-manifest.json').open('a') as handle:
            handle.write(' ')
        result = self.resume()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['ok'])

    def test_many_pending_units_preserve_decisions_and_report_omission(self):
        run = self.root / 'current'
        raw = json.dumps({'units': [{'id': 'component-' + str(i) + '-pending-' + 'x' * 60,
                                    'status': 'pending', 'evidence': []} for i in range(90)]}).encode()
        (run / 'scope-manifest.json').write_bytes(raw)
        (run / 'scope-checkpoint.json').write_text(json.dumps({'scope_manifest': 'scope-manifest.json',
            'scope_manifest_sha256': hashlib.sha256(raw).hexdigest()}), encoding='utf-8')
        self.assertEqual(self.create().returncode, 0)
        result = self.resume()
        value = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, value)
        self.assertLessEqual(len(result.stdout.encode()), 6000)
        self.assertGreater(value['resume']['unfinished_omitted'], 0)
        self.assertEqual(value['resume']['unfinished_count'], 90)
        self.assertIn('兼容映射', result.stdout)

    def test_previous_drift_outside_path_and_unknown_schema_rejected(self):
        self.assertEqual(self.create().returncode, 0)
        original = self.index.read_bytes()
        for change in ({'run_directory': 'C:/Windows'}, {'schema_version': 99}, {'unexpected': 'private-fixture'}):
            value = json.loads(original)
            value.update(change)
            self.index.write_text(json.dumps(value), encoding='utf-8')
            result = self.resume()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('private-fixture', result.stdout + result.stderr)
        self.index.write_bytes(original)
        (self.root / 'previous/RESULT.md').write_text('changed', encoding='utf-8')
        self.assertNotEqual(self.resume().returncode, 0)

    def test_non_object_unit_is_a_json_refusal(self):
        for units in (['check'], {'check': {'status': 'pending'}}):
            with self.subTest(units=units):
                (self.root / 'current/scope-manifest.json').write_text(json.dumps({'units': units}), encoding='utf-8')
                result = self.create()
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse(json.loads(result.stdout)['ok'])

    def test_index_symlink_is_rejected(self):
        self.assertEqual(self.create().returncode, 0)
        real = self.root / 'real-index.json'
        self.index.rename(real)
        try:
            self.index.symlink_to(real)
        except OSError:
            self.skipTest('symlink privilege unavailable')
        self.assertNotEqual(self.resume().returncode, 0)

    def test_document_state_only_returns_reusable_pointer(self):
        state = self.root / 'document-state.json'
        state.write_text('{"schemaVersion":1,"documents":[]}', encoding='utf-8')
        result = subprocess.run([sys.executable, '-B', str(CLI), 'index', '--run-directory', str(self.root / 'current'),
            '--index-path', str(self.index), '--document-state', str(state)], capture_output=True)
        self.assertEqual(result.returncode, 0)
        result = self.resume()
        value = json.loads(result.stdout)
        self.assertEqual(value['resume']['document_state'], str(state))
        self.assertNotIn('documents', result.stdout)


if __name__ == '__main__':
    unittest.main()
