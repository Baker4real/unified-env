"""Public CLI regression for immutable, single-process daily receipts."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/daily-update/daily-update-step.py'
HOST_CHECKED = pathlib.Path('D:/Codex/.codex/scripts/Invoke-CheckedPowerShell.ps1')


class StepTests(unittest.TestCase):
    def setUp(self):
        pathlib.Path('D:/agents/run-evidence').mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir='D:/agents/run-evidence', prefix='step-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)

    def invoke(self, source, **contract):
        spec = dict(command_id='fixture', kind='native', argv=[sys.executable, '-c', source],
                    required_fields=['ok'], equals={'ok': True})
        spec.update(contract)
        if spec['kind'] == 'powershell':
            spec.pop('argv', None)
        path = self.root / ('spec-' + str(len(list(self.root.glob('spec-*')))) + '.json')
        path.write_text(json.dumps(spec), encoding='utf-8')
        receipt = path.with_suffix('.receipt.json')
        run = subprocess.run([sys.executable, '-B', str(SCRIPT), 'run', '--spec', str(path),
                              '--receipt', str(receipt)], capture_output=True, text=True, encoding='utf-8')
        return run, json.loads(receipt.read_text(encoding='utf-8'))

    def test_failure_cannot_be_replaced_by_later_success(self):
        failed, first = self.invoke('raise SystemExit(7)')
        passed, second = self.invoke('print(\'{"ok":true}\')')
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(first['exit_code'], 7)
        self.assertFalse(first['ok'])
        self.assertEqual(passed.returncode, 0)
        self.assertTrue(second['ok'])

    def test_empty_and_business_false_are_failures(self):
        for source in ('pass', 'print(\'{"ok":false}\')'):
            with self.subTest(source=source):
                process, value = self.invoke(source)
                self.assertNotEqual(process.returncode, 0)
                self.assertFalse(value['ok'])

    def test_presence_accepts_false_and_zero_but_not_null(self):
        process, value = self.invoke('print(\'{"flag":false,"count":0}\')',
                                     required_fields=['flag', 'count'], equals={})
        self.assertEqual(process.returncode, 0, value)
        process, value = self.invoke('print(\'{"flag":null}\')', required_fields=['flag'], equals={})
        self.assertNotEqual(process.returncode, 0)

    @unittest.skipUnless(HOST_CHECKED.is_file(), 'host-installed Invoke-CheckedPowerShell is unavailable on CI')
    def test_checked_parameter_error(self):
        process, value = self.invoke('', kind='powershell', argv=[],
            script=str(ROOT / 'scripts/daily-update/Read-DailyUpdateEvidence.ps1'),
            parameters={'RunDirectory': str(self.root), 'MaxTotalBytes': 8000})
        self.assertNotEqual(process.returncode, 0)
        self.assertNotEqual(value['exit_code'], 0)

    def test_output_redaction(self):
        process, value = self.invoke('import sys; print(\'{"ok":true,"secret":"private-fixture"}\'); print("private-fixture", file=sys.stderr)')
        self.assertEqual(process.returncode, 0)
        self.assertNotIn('private-fixture', json.dumps(value) + process.stdout + process.stderr)

    def test_same_receipt_cannot_be_overwritten(self):
        self.invoke('raise SystemExit(8)')
        path = self.root / 'spec-0.receipt.json'
        before = path.read_bytes()
        result = subprocess.run([sys.executable, '-B', str(SCRIPT), 'run', '--spec', str(self.root / 'spec-0.json'),
                                 '--receipt', str(path)], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(before, path.read_bytes())

    def test_timeout_and_type_mismatch_fail_closed(self):
        process, value = self.invoke('import time; time.sleep(3); print(\'{"ok":true}\')', timeout_seconds=1)
        self.assertNotEqual(process.returncode, 0)
        self.assertTrue(value['timeout'])
        process, value = self.invoke('print(\'{"ok":1}\')')
        self.assertNotEqual(process.returncode, 0)

    def test_null_predicate_requires_field_to_exist(self):
        process, value = self.invoke('print("{}")', required_fields=[], equals={'status': None})
        self.assertNotEqual(process.returncode, 0, value)
        process, value = self.invoke('print(\'{"status":null}\')', required_fields=[], equals={'status': None})
        self.assertEqual(process.returncode, 0, value)
        process, value = self.invoke('print(\'{"outer":{}}\')', required_fields=[], equals={'outer.status': None})
        self.assertNotEqual(process.returncode, 0, value)

    @unittest.skipUnless(HOST_CHECKED.is_file(), 'host-installed Invoke-CheckedPowerShell is unavailable on CI')
    def test_parameter_quotes_cannot_end_the_string(self):
        # PowerShell ends a single-quoted string at any of ' ‘ ’ ‚ ‛, so each must be doubled.
        marker = self.root / 'injected.txt'
        script = self.root / 'echo.ps1'
        script.write_text('param([string]$Value)\n$bytes = [Text.Encoding]::UTF8.GetBytes($Value)\n'
                          '[ordered]@{ ok = $true; sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }'
                          ' | ConvertTo-Json -Compress\n', encoding='utf-8')
        for value in ('a’; Set-Content -LiteralPath ' + str(marker) + ' -Value x; ’',
                      "it's ‘a‚‛’ and ''"):
            with self.subTest(value=value):
                process, receipt = self.invoke('', kind='powershell', argv=[], script=str(script),
                    parameters={'Value': value}, required_fields=['ok'],
                    equals={'ok': True, 'sha256': hashlib.sha256(value.encode('utf-8')).hexdigest()})
                self.assertFalse(marker.exists(), 'parameter text ran as a command')
                self.assertEqual(process.returncode, 0, receipt)

    @unittest.skipUnless(HOST_CHECKED.is_file(), 'host-installed Invoke-CheckedPowerShell is unavailable on CI')
    def test_sm_text_lock_missing_and_partial(self):
        script = ROOT / 'scripts/daily-update/Get-SkillsManagerState.ps1'
        lock = self.root / 'sm.lock'
        for text, status in [(None, 'missing'), ('operation=auto backup\n', 'missing-fields'),
                             ('operation=auto backup\nstart_time=2026-11-02T12:51:44.817681400+00:00\n', 'ok')]:
            if text is not None:
                lock.write_text(text, encoding='utf-8')
            process, value = self.invoke('', kind='powershell', argv=[], script=str(script),
                parameters={'LockPath': str(lock)}, required_fields=['process_query_ok', 'lock.status'],
                equals={'process_query_ok': True, 'lock.status': status,
                        **({'lock.operation': 'auto backup'} if text is not None else {})})
            self.assertEqual(process.returncode, 0, value)


if __name__ == '__main__':
    unittest.main()
