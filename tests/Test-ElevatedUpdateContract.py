"""Pre-UAC public entry must reject incomplete phases without starting any child update."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = ROOT / 'scripts/daily-update/daily-update-step.py'
LAUNCHER = ROOT / 'scripts/daily-update/Invoke-ElevatedUpdate.ps1'


class ElevatedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='D:/agents/run-evidence', prefix='elevation-contract-')
        self.addCleanup(self.temp.cleanup)
        self.run = pathlib.Path(self.temp.name) / '20261116-120000'
        self.run.mkdir()
        self.marker = self.run / 'unexpected.txt'
        self.script = self.run / 'update.ps1'
        self.script.write_text("param([string]$Mode='Prepare')\nSet-Content -LiteralPath '"+str(self.marker)+"' -Value unexpected", encoding='utf-8')
        self.spec = {'command_id': 'elevated-fixture', 'kind': 'powershell', 'script': str(self.script),
                     'parameters': {'Mode': 'Apply'}, 'phase': 'Apply', 'equals': {'ok': True, 'version': '1.2.3', 'status': 'activated'}}
        self.path = self.run / 'step.json'

    def invoke(self):
        self.path.write_text(json.dumps(self.spec), encoding='utf-8')
        return subprocess.run([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-File', str(LAUNCHER),
                               '-Mode', 'Validate', '-Spec', str(self.path), '-Receipt', str(self.run/'receipt.json'),
                               '-Python', sys.executable], capture_output=True, text=True, encoding='utf-8')

    def test_missing_phase_is_refused_before_uac_or_update(self):
        self.spec.pop('phase')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.run/'receipt.json').exists())
        self.assertIn('pre-elevation-contract-rejected', result.stdout)

    def test_elevation_requires_target_version_and_success_predicates(self):
        self.spec['equals'] = {'ok': True}
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_missing_script_argument_is_rejected_before_uac(self):
        self.script.write_text('param([Parameter(Mandatory)][string]$PackageName,[string]$Mode)', encoding='utf-8')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.run/'receipt.json.launch.json').exists())

    def test_unknown_or_invalid_script_parameter_is_rejected_before_uac(self):
        self.script.write_text("param([ValidateSet('Prepare')][string]$Mode)", encoding='utf-8')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.spec['parameters']['Unknown'] = 'x'
        self.script.write_text('param([string]$Mode)', encoding='utf-8')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)

    def test_named_parameter_set_cannot_be_skipped_via_all_sets(self):
        self.script.write_text("param([ValidateSet('Apply')][string]$Mode,[Parameter(Mandatory,ParameterSetName='Target')][string]$PackageName)", encoding='utf-8')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_existing_lifecycle_sidecar_is_rejected_during_validation(self):
        (self.run/'receipt.json.launched.json').write_text('{"old":true}', encoding='utf-8')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('launch-evidence-already-exists', result.stdout)
        self.assertFalse((self.run/'receipt.json.launch.json').exists())

    def test_duplicate_case_insensitive_mode_is_rejected(self):
        self.spec['parameters']['mode'] = 'Prepare'
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_relative_receipt_is_refused_consistently(self):
        self.path.write_text(json.dumps(self.spec), encoding='utf-8')
        result = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-File', str(LAUNCHER),
                                 '-Mode', 'Validate', '-Spec', str(self.path), '-Receipt', 'review-receipt.json',
                                 '-Python', sys.executable], capture_output=True, text=True, encoding='utf-8')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((ROOT/'review-receipt.json.launch.json').exists())

    def test_explicit_apply_can_be_validated_without_executing_it(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['phase'], 'Apply')
        self.assertEqual(value['status'], 'validated-not-elevated')
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.run/'receipt.json').exists())


if __name__ == '__main__':
    unittest.main()
