import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
CLI = ROOT / 'patch_wsl.py'


def pack_fixture(*members):
    entries = {}
    body = b''
    for name, data in members:
        digest = hashlib.sha256(data).hexdigest()
        entries[name] = {'size': len(data), 'offset': str(len(body)), 'integrity': {
            'algorithm': 'SHA256', 'hash': digest, 'blockSize': 4194304, 'blocks': [digest],
        }}
        body += data
    text = json.dumps({'files': {'dist': {'files': entries}}}, separators=(',', ':')).encode()
    size = (len(text) + 3) & ~3
    return struct.pack('<IIII', 4, 8 + size, 4 + size, len(text)) + text.ljust(size, b'\0') + body


class PatchTest(unittest.TestCase):
    def setUp(self):
        base = Path('D:/agents/tmp' if os.name == 'nt' else tempfile.gettempdir())
        base.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix='agy-wsl-fixture-', dir=base)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def cli(self, *args):
        return subprocess.run([sys.executable, '-B', '-I', str(CLI), *map(str, args)],
                              capture_output=True, text=True, timeout=15)

    def test_unknown_archive_is_observable_and_never_staged(self):
        old = self.root / 'official-new-build.asar'
        old.write_bytes(pack_fixture(('wsl.js', b'unknown build')))
        output = self.root / 'candidate.asar'
        status = self.cli('status', old)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)['state'], 'unrecognized')
        attempt = self.cli('stage', old, output)
        self.assertEqual(attempt.returncode, 2, attempt.stderr)
        self.assertIn('unrecognized', attempt.stderr)
        self.assertFalse(output.exists())
        self.assertEqual(old.read_bytes(), pack_fixture(('wsl.js', b'unknown build')))

    def test_patch_preserves_members_and_wsl_behavior(self):
        module = importlib.util.spec_from_file_location('antigravity_patch_wsl', CLI)
        patch = importlib.util.module_from_spec(module)
        module.loader.exec_module(patch)
        upstream = (ROOT / 'wsl-fixture.cjs').read_bytes()
        original = pack_fixture(('before.txt', b'before'), ('wsl.js', upstream), ('after.txt', b'after'))
        candidate, unchanged = patch.build_candidate(original)
        self.assertEqual(unchanged, 2)
        header, body = patch.unpack_asar(candidate)
        files = header['files']['dist']['files']
        self.assertEqual(patch.get_member(body, files['before.txt']), b'before')
        self.assertEqual(patch.get_member(body, files['after.txt']), b'after')
        patched = patch.get_member(body, files['wsl.js'])
        self.assertEqual(files['wsl.js']['integrity']['blocks'], [hashlib.sha256(patched).hexdigest()])
        generated = self.root / 'patched.cjs'
        generated.write_bytes(patched)
        result = subprocess.run(['node', str(ROOT / 'test-wsl-behavior.cjs'), str(ROOT / 'wsl-fixture.cjs'), str(generated)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
