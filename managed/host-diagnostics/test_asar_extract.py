import contextlib
import io
import json
import pathlib
import struct
import tempfile
import unittest
import asar_extract as tool
from types import SimpleNamespace


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
