"""Exercise the read-only daily receipt reader through its PowerShell CLI."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/daily-update/Read-DailyUpdateEvidence.ps1'


class EvidenceReaderTests(unittest.TestCase):
    def setUp(self):
        parent = pathlib.Path('D:/agents/run-evidence')
        parent.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix='daily-evidence-fixture-', dir=parent)
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)

    def receipt(self, name, units, canonical=False, absolute=False):
        path = self.root / name
        path.mkdir()
        manifest = path / 'scope-manifest.json'
        value = {'units': units}
        manifest.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
        digest = hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
            separators=(',', ':')).encode('utf-8') if canonical else manifest.read_bytes()).hexdigest()
        hash_field = 'scope_manifest_canonical_sha256' if canonical else 'scope_manifest_sha256'
        (path / 'scope-checkpoint.json').write_text(json.dumps({'status': 'complete',
            'scope_manifest': str(manifest) if absolute else 'scope-manifest.json', hash_field: digest}), encoding='utf-8')
        for unit in units:
            refs = unit.get('evidence', [])
            for ref in [refs] if isinstance(refs, str) else refs:
                evidence = path / ref
                evidence.parent.mkdir(parents=True, exist_ok=True)
                evidence.write_text('{}', encoding='utf-8')
        (path / 'RESULT.md').write_text('# 需要用户裁决\n\n本次无新增裁决。\n\n# 结果\n\n通过\n'.replace('\\n', '\n'), encoding='utf-8')
        return path

    def invoke(self, path, previous=None, budget=6000):
        args = [shutil.which('pwsh'), '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                str(SCRIPT), '-RunDirectory', str(path), '-MaxTotalBytes', str(budget)]
        if previous:
            args.extend(['-PreviousRunDirectory', str(previous)])
        return subprocess.run(args, cwd=ROOT, capture_output=True, encoding='utf-8',
                              creationflags=subprocess.CREATE_NO_WINDOW)

    def test_only_changed_rows_and_fixed_budget(self):
        units = [{'id': 'item-' + str(i), 'status': 'complete', 'evidence': 'result.json'} for i in range(120)]
        before = self.receipt('before', units)
        units[-1] = {'id': 'item-119', 'status': 'blocked', 'evidence': 'blocked.json'}
        after = self.receipt('after', units)
        hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        result = self.invoke(after, before)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLessEqual(len(result.stdout.encode('utf-8')), 6000)
        value = json.loads(result.stdout)
        self.assertEqual(value['unchanged_count'], 119)
        self.assertEqual([r['id'] for r in value['changes']], ['item-119'])
        self.assertEqual(value['changes'][0]['status'], 'blocked')
        self.assertEqual(hashes, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in hashes})

    def test_hash_drift_is_rejected(self):
        path = self.receipt('drift', [])
        (path / 'scope-manifest.json').write_text('{"units":[] }', encoding='utf-8')
        result = self.invoke(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['ok'])

    def test_canonical_python_contract_and_absolute_manifest_reference(self):
        unit = {'id': '中文组件', 'status': 'manual-review', 'evidence': 'nested/finding.json',
                'last_observed_at': '2026-10-26T10:46:31.101961+08:00',
                'details': {'z': '安全审核', 'a': ['🙂', True, 1.5, None]}}
        path = self.receipt('canonical', [unit], canonical=True, absolute=True)
        result = self.invoke(path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['receipt_contract'], 'canonical')
        self.assertEqual(value['changes'][0]['status'], 'manual-review')
        self.assertNotIn('安全审核', result.stdout)
        manifest = path / 'scope-manifest.json'
        data = json.loads(manifest.read_text(encoding='utf-8'))
        data['units'][0]['details']['a'][2] = 2.5
        manifest.write_text(json.dumps(data), encoding='utf-8')
        self.assertNotEqual(self.invoke(path).returncode, 0)

    def test_recorded_legacy_canonical_subset_contract(self):
        path = self.root / 'legacy'
        path.mkdir()
        binding = {'scope_id': 'legacy-test', 'required': ['closure'], 'owners': {'root': ['closure']}}
        scope = dict(binding, started_at='2026-10-21T02:02:44+08:00')
        (path / 'scope.json').write_text(json.dumps(scope), encoding='utf-8')
        digest = hashlib.sha256(json.dumps(binding, ensure_ascii=False, sort_keys=True,
            separators=(',', ':')).encode('utf-8')).hexdigest()
        checkpoint = {'scope_id': 'legacy-test', 'required_count': 1, 'scope_manifest_sha256': digest,
            'status': 'running', 'contracts': [{'id': 'closure', 'status': 'pending', 'evidence': []}]}
        (path / 'scope-checkpoint.json').write_text(json.dumps(checkpoint), encoding='utf-8')
        result = self.invoke(path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['receipt_contract'], 'legacy-canonical-subset')
        scope['owners']['root'] = []
        (path / 'scope.json').write_text(json.dumps(scope), encoding='utf-8')
        self.assertNotEqual(self.invoke(path).returncode, 0)

    def test_referenced_findings_change_without_status_change(self):
        units = [{'id': 'closure', 'status': 'blocked', 'evidence': 'closure.json'}]
        before = self.receipt('before', units)
        after = self.receipt('after', units)
        marker = 'fixture-sensitive-finding-detail'
        (after / 'closure.json').write_text(json.dumps({'findings': [marker]}), encoding='utf-8')
        result = self.invoke(after, before)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['changed_count'], 1)
        self.assertEqual(value['unchanged_count'], 0)
        self.assertNotIn(marker, result.stdout + result.stderr)
        (after / 'closure.json').unlink()
        self.assertNotEqual(self.invoke(after).returncode, 0)

    def test_clock_only_changes_are_ignored_but_versions_are_not(self):
        unit = {'id': 'runtime', 'status': 'complete', 'version': '1.0.0',
                'evidence': 'runtime.json', 'observed_at': '2026-10-21T01:00:00+08:00'}
        before = self.receipt('before', [unit])
        after = self.receipt('after', [dict(unit, observed_at='2026-10-26T01:00:00+08:00')])
        value = json.loads(self.invoke(after, before).stdout)
        self.assertEqual(value['unchanged_count'], 1)
        upgraded = self.receipt('upgraded', [dict(unit, version='1.0.1')])
        value = json.loads(self.invoke(upgraded, before).stdout)
        self.assertEqual(value['changed_count'], 1)

    def test_valid_unknown_fields_are_hashed_without_being_echoed(self):
        marker = 'fixture-private-config-value'
        path = self.receipt('projection', [{'id': 'runtime', 'status': 'complete',
            'evidence': 'runtime.json', 'private_config': marker}])
        result = self.invoke(path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(marker, result.stdout + result.stderr)
        self.assertEqual(set(json.loads(result.stdout)['changes'][0]), {'id', 'status', 'evidence'})

    def test_decisions_are_prioritized_and_budget_omissions_are_explicit(self):
        units = [{'id': '组件-' + str(i), 'status': 'blocked', 'evidence': 'finding.json'} for i in range(80)]
        path = self.receipt('decisions', units)
        (path / 'RESULT.md').write_text('# 需要用户裁决\n\n请选择修复方案：' + '人工处理事项。' * 70 + '\n', encoding='utf-8')
        full = self.invoke(path)
        self.assertEqual(full.returncode, 0, full.stdout + full.stderr)
        value = json.loads(full.stdout)
        self.assertIsNotNone(value['decisions'])
        self.assertIn(value['decisions_status'], ['included', 'truncated'])
        self.assertGreater(value['omitted_count'], 0)
        self.assertLessEqual(len(full.stdout.encode('utf-8')), 6000)
        tight = self.invoke(path, budget=1200)
        self.assertEqual(tight.returncode, 0, tight.stdout + tight.stderr)
        value = json.loads(tight.stdout)
        self.assertLessEqual(len(tight.stdout.encode('utf-8')), 1200)
        self.assertEqual(value['decisions_status'], 'omitted-budget')
        self.assertGreater(value['decisions_omitted_rows'], 0)

    def test_manifest_and_evidence_references_cannot_escape_run(self):
        path = self.receipt('boundaries', [{'id': 'x', 'status': 'complete', 'evidence': 'safe.json'}])
        checkpoint_path = path / 'scope-checkpoint.json'
        checkpoint = json.loads(checkpoint_path.read_text(encoding='utf-8'))
        checkpoint['scope_manifest'] = '../scope-manifest.json'
        checkpoint_path.write_text(json.dumps(checkpoint), encoding='utf-8')
        self.assertNotEqual(self.invoke(path).returncode, 0)
        checkpoint['scope_manifest'] = 'scope-manifest.json'
        manifest = path / 'scope-manifest.json'
        manifest.write_text(json.dumps({'units': [{'id': 'x', 'status': 'complete', 'evidence': '../outside.json'}]}), encoding='utf-8')
        checkpoint['scope_manifest_sha256'] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        checkpoint_path.write_text(json.dumps(checkpoint), encoding='utf-8')
        self.assertNotEqual(self.invoke(path).returncode, 0)

    def test_reparse_evidence_is_rejected(self):
        path = self.receipt('reparse', [{'id': 'x', 'status': 'complete', 'evidence': 'link/finding.json'}])
        target = path / 'target'
        (path / 'link').rename(target)
        try:
            (path / 'link').symlink_to(target, target_is_directory=True)
        except OSError as exc:
            self.skipTest(str(exc))
        self.assertNotEqual(self.invoke(path).returncode, 0)

    def test_missing_checkpoint_is_not_empty_success(self):
        result = self.invoke(self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['ok'])

    def test_invalid_status_and_unknown_fields_are_not_echoed(self):
        secret = 'fixture-sensitive-marker'
        path = self.receipt('invalid', [{'id': 'item', 'status': secret, 'token': secret}])
        result = self.invoke(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
