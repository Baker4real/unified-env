import importlib.util
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('evidence_io', ROOT / 'scripts/daily-update/evidence_io.py')
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class RunEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix='evidence-writer-', dir='D:/Codex/tmp'))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / '20261110-120000'
        self.root.mkdir()

    def test_writes_only_new_files_inside_the_current_run(self):
        writer = evidence.RunEvidence(self.root)
        target = writer.write_json_new('steps/result.json', {'ok': True})
        self.assertEqual(target.read_text(encoding='utf-8'), '{\n  "ok": true\n}\n')
        with self.assertRaisesRegex(ValueError, 'evidence-already-exists'):
            writer.write_json_new('steps/result.json', {'ok': False})

    def test_rejects_another_run_before_creating_the_target(self):
        other = self.tmp / '20261109-213128'
        other.mkdir()
        writer = evidence.RunEvidence(self.root)
        with self.assertRaisesRegex(ValueError, 'outside-current-run'):
            writer.output_path(other / 'diff-check.json')
        self.assertFalse((other / 'diff-check.json').exists())

    def test_rejects_parent_and_leaf_reparse_points(self):
        outside = self.tmp / 'outside'
        outside.mkdir()
        link = self.root / 'linked'
        subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(outside)], check=True, capture_output=True)
        writer = evidence.RunEvidence(self.root)
        with self.assertRaisesRegex(ValueError, 'reparse-evidence'):
            writer.output_path('linked/result.json')


if __name__ == '__main__':
    unittest.main()
