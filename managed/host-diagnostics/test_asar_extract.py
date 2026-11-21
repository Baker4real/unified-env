import contextlib
import io
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import asar_extract as tool
from types import SimpleNamespace


class BoundedList(unittest.TestCase):
    def test_list_cli_caps_paths_and_reports_omissions(self):
        with tempfile.TemporaryDirectory() as root:
            target = pathlib.Path(root) / 'app.asar'
            files = {f'{n:03}-asset.js': {'size': 42, 'offset': '0'} for n in range(250)}
            files['not-a-script.txt'] = {'size': 10, 'offset': '0'}
            raw = json.dumps({'files': files}).encode()
            string = struct.pack('<I', len(raw)) + raw
            string += b'\0' * (-len(string) % 4)
            pickle = struct.pack('<I', len(string)) + string
            target.write_bytes(struct.pack('<II', 4, len(pickle)) + pickle)
            command = [sys.executable, '-B', '-I', str(pathlib.Path(tool.__file__).resolve()), 'list', str(target)]
            report = subprocess.run(command + ['--grep', r'\.js$', '--json', '--max-files', '3',
                                               '--max-output-bytes', '800'], capture_output=True, check=True)
            data = json.loads(report.stdout)
            self.assertEqual(data['totalFiles'], 250)
            self.assertEqual(data['omittedFiles'], 247)
            self.assertEqual(data['files'][0], {'path': '000-asset.js', 'size': 42, 'unpacked': False})
            self.assertEqual(len(data['files']), 3)
            self.assertLessEqual(len(report.stdout), 800)

            for options in ([], ['--json']):
                report = subprocess.run(command + ['--max-output-bytes', '800'] + options,
                                        capture_output=True, check=True)
                self.assertLessEqual(len(report.stdout), 800)
                self.assertNotIn(b'249-asset.js', report.stdout)
                self.assertIn(b'omitted', report.stdout)


class BoundedGrep(unittest.TestCase):
    def test_budget_counts_all_matches_without_dumping_minified_code(self):
        with tempfile.TemporaryDirectory() as root:
            target = pathlib.Path(root) / 'app.asar'
            payload = b'needle' * 2000
            header = {'files': {'one.js': {'size': len(payload), 'offset': '0'}, 'two.js': {'size': len(payload), 'offset': str(len(payload))}}}
            raw = json.dumps(header).encode()
            string = struct.pack('<I', len(raw)) + raw
            string += b'\0' * (-len(string) % 4)
            pickle = struct.pack('<I', len(string)) + string
            target.write_bytes(struct.pack('<II', 4, len(pickle)) + pickle + payload + payload)
            args = SimpleNamespace(asar=str(target), regex='needle', paths='^one', context=100, max_per_file=2, max_files=1, max_output_chars=800, json=True)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(tool.cmd_grep(args), 0)
            result = json.loads(output.getvalue())
            self.assertEqual(result['totalMatches'], 2000)
            self.assertEqual(result['filesMatched'], 1)
            self.assertLessEqual(len(result['matches']), 2)
            self.assertEqual(result['omittedMatches'], 2000-len(result['matches']))
            self.assertLessEqual(len(output.getvalue().encode('utf8')), 800)
            args.regex = 'absent'
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tool.cmd_grep(args), 1)


if __name__ == '__main__':
    unittest.main()
