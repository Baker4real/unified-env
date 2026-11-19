"""Exercise the managed publisher against isolated workstation evidence."""
import datetime as dt
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts/daily-update'
EVIDENCE = pathlib.Path('D:/agents/run-evidence')
TAIPEI = dt.timezone(dt.timedelta(hours=8))


def put(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_script(name, *args):
    result = subprocess.run([sys.executable, '-B', str(SCRIPTS / name), *map(str, args)],
                            capture_output=True, text=True, encoding='utf-8', timeout=60)
    return result, json.loads(result.stdout) if result.stdout else None


class FinalizeTests(unittest.TestCase):
    def setUp(self):
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        fixture = tempfile.TemporaryDirectory(prefix='finalize-fixture-', dir=EVIDENCE)
        self.addCleanup(fixture.cleanup)
        self.collection = pathlib.Path(fixture.name) / 'daily-codex-ecosystem-update'
        self.collection.mkdir()
        self.latest = self.collection / 'LATEST.md'
        self.now = dt.datetime.now(dt.UTC)

    def receipt(self, label, *, units=None, counts=None, completed_at=None, started_at=None, status='completed'):
        start = (started_at or self.now).astimezone(TAIPEI)
        run = self.collection / (start.strftime('%Y%m%d-%H%M%S') + '-' + label)
        run.mkdir()
        (run / 'RESULT.md').write_bytes(f'# 需要用户裁决\r\n\r\n无\r\n\r\n# {label}\r\n'.encode())
        put(run / 'health.json', {'ok': True, 'status': 'verified'})
        if units is None:
            units = [{'id': 'health', 'status': 'processed', 'evidence': ['health.json'],
                      'checks': [{'path': 'health.json', 'equals': {'ok': True, 'status': 'verified'}}]},
                     {'id': 'optional', 'status': 'skipped', 'evidence': []}]
        manifest = {'required_units': ['health'], 'optional_units': ['optional'], 'units': units}
        digest = put(run / 'scope-manifest.json', manifest)
        self.checkpoint(run, digest, counts, completed_at, status)
        return run

    def checkpoint(self, run, digest, counts=None, completed_at=None, status='completed'):
        put(run / 'scope-checkpoint.json', {'finalize_schema_version': 1,
            'scope_manifest': 'scope-manifest.json', 'scope_manifest_sha256': digest, 'status': status,
            'counts': counts or {'processed': 1, 'failed': 0, 'pending': 0, 'skipped': 1, 'running': 0},
            'scope_total': 2, 'completed_at': (completed_at or self.now).isoformat()})

    def index(self, run, previous=None, replace=False, document_state=None):
        args = ['--previous-run-directory', previous] if previous else []
        if document_state:
            args.extend(['--document-state', document_state])
        if replace:
            args.append('--replace')
        result, value = run_script('daily-update-resume.py', 'index', '--run-directory', run,
                                   '--index-path', run / 'resume-index.json', *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return value

    def finalize(self, run, *flags):
        return run_script('finalize-run.py', *self.finalize_args(run, *flags))

    @staticmethod
    def finalize_args(run, *flags):
        return ['--run-directory', str(run), '--index-path', str(run / 'resume-index.json'), *map(str, flags)]

    def assert_refused(self, run, *flags):
        result, value = self.finalize(run, *flags)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(value['ok'])
        return value

    def legacy_latest(self, completed):
        run = self.receipt('legacy-latest', completed_at=completed)
        path = run / 'scope-checkpoint.json'
        checkpoint = json.loads(path.read_bytes())
        checkpoint['last_observed_at'] = checkpoint.pop('completed_at')
        checkpoint.pop('finalize_schema_version')
        put(path, checkpoint)
        self.latest.write_bytes((run / 'RESULT.md').read_bytes())
        return run

    def step_receipt(self, label, output, equals=None, *, receipt_as_json=False):
        check = {'path': 'step-receipt.json', 'spec': 'step-spec.json'}
        if receipt_as_json:
            check = {'path': 'step-receipt.json', 'equals': {'ok': True}}
        run = self.receipt(label, units=[
            {'id': 'health', 'status': 'processed', 'evidence': ['step-spec.json', 'step-receipt.json'], 'checks': [check]},
            {'id': 'optional', 'status': 'skipped', 'evidence': []},
        ])
        spec = run / 'step-spec.json'
        put(spec, {'command_id': 'fixture-health', 'kind': 'native', 'required_fields': ['ok'],
                   'equals': equals or {}, 'argv': [sys.executable, '-B', '-c', f'print({json.dumps(output)!r})']})
        result, receipt = run_script('daily-update-step.py', 'run', '--spec', spec, '--receipt', run / 'step-receipt.json')
        self.assertEqual(receipt['ok'], result.returncode == 0, result.stderr)
        manifest_sha = hashlib.sha256((run / 'scope-manifest.json').read_bytes()).hexdigest()
        self.checkpoint(run, manifest_sha, completed_at=dt.datetime.now(dt.UTC))
        self.index(run)
        return run, receipt

    def test_real_step_receipt_with_bound_positive_business_predicate_is_accepted(self):
        run, receipt = self.step_receipt('step-verified', {'ok': True}, {'ok': True})
        self.assertTrue(receipt['ok'])
        result, value = self.finalize(run)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(value['status'], 'published')
        self.assertEqual(self.latest.read_bytes(), (run / 'RESULT.md').read_bytes())

    def test_shape_only_step_receipt_cannot_masquerade_as_business_evidence(self):
        run, receipt = self.step_receipt('shape-only-json', {'ok': False}, receipt_as_json=True)
        self.assertTrue(receipt['ok'], 'the step wrapper can pass a required-fields-only contract')
        self.assertEqual(receipt['exit_code'], 0)
        result, value = self.finalize(run)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(value['ok'])
        self.assertFalse(self.latest.exists())

    def test_publishes_exact_report_once_and_keeps_same_day_winner(self):
        first = self.receipt('first')
        self.index(first)
        result, value = self.finalize(first)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(value['status'], 'published')
        self.assertEqual(value['local_date'], self.now.astimezone(TAIPEI).date().isoformat())
        self.assertEqual(value['counts'], {'processed': 1, 'failed': 0, 'pending': 0, 'skipped': 1, 'running': 0})
        expected = (first / 'RESULT.md').read_bytes()
        self.assertEqual(self.latest.read_bytes(), expected)
        original_mtime = self.latest.stat().st_mtime_ns
        second = self.receipt('second')
        self.index(second)
        for run in (first, second):
            result, value = self.finalize(run)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(value['status'], 'already-published')
            self.assertEqual(self.latest.read_bytes(), expected)
            self.assertEqual(self.latest.stat().st_mtime_ns, original_mtime)

    def test_unsuccessful_or_contradictory_receipts_cannot_replace_previous_latest(self):
        legacy = self.legacy_latest(self.now - dt.timedelta(days=1))
        before = self.latest.read_bytes()
        default_unit = {'id': 'health', 'status': 'processed', 'evidence': ['health.json'],
                        'checks': [{'path': 'health.json', 'equals': {'ok': True}}]}
        optional = {'id': 'optional', 'status': 'skipped', 'evidence': []}
        for label, spec in (
            ('failed-checkpoint', {'status': 'failed'}),
            ('missing-success', {'units': [dict(default_unit, status='pending'), optional]}),
            ('failed-count', {'counts': {'processed': 0, 'failed': 1, 'pending': 0, 'skipped': 1, 'running': 0}}),
        ):
            with self.subTest(label=label):
                run = self.receipt(label, **spec)
                self.index(run, legacy)
                value = self.assert_refused(run, '--legacy-latest-run-directory', legacy)
                self.assertEqual(value['reason'], 'unsuccessful-or-conflicting-receipt')
                self.assertEqual(self.latest.read_bytes(), before)

    def test_failed_machine_json_cannot_satisfy_unrelated_positive_predicate(self):
        run = self.receipt('failed-business')
        put(run / 'health.json', {'ok': False, 'status': 'verified'})
        self.index(run)
        self.assertEqual(self.assert_refused(run)['reason'], 'business-evidence-failed')
        self.assertFalse(self.latest.exists())

    def test_checkpoint_evidence_has_to_be_covered_by_the_index(self):
        run = self.receipt('unbound-checkpoint-evidence')
        put(run / 'other.json', {'ok': True})
        path = run / 'scope-checkpoint.json'
        checkpoint = json.loads(path.read_bytes())
        checkpoint['evidence_refs'] = ['RESULT.md', 'other.json']
        put(path, checkpoint)
        self.index(run)
        self.assertEqual(self.assert_refused(run)['reason'], 'index-content-drift')
        self.assertFalse(self.latest.exists())

    def test_mutated_evidence_after_index_is_refused(self):
        run = self.receipt('index-drift')
        self.index(run)
        put(run / 'health.json', {'ok': True, 'status': 'verified', 'new': 'drift'})
        self.assert_refused(run)
        self.assertFalse(self.latest.exists())

    def test_shape_only_and_business_failed_step_receipts_are_refused(self):
        for label, equals, reason in (('shape-only', {}, 'business-predicates-required'),
                                      ('business-failed', {'ok': True}, 'step-receipt-not-successful')):
            with self.subTest(label=label):
                run, receipt = self.step_receipt(label, {'ok': False}, equals)
                self.assertEqual(receipt['ok'], not equals)
                self.assertEqual(self.assert_refused(run)['reason'], reason)
                self.assertFalse(self.latest.exists())

    def test_reindexed_spec_cannot_be_substituted_for_the_executed_spec(self):
        run, receipt = self.step_receipt('substituted-spec', {'ok': True}, {'ok': True})
        self.assertTrue(receipt['ok'])
        spec_path = run / 'step-spec.json'
        spec = json.loads(spec_path.read_bytes())
        spec['timeout_seconds'] = 5
        put(spec_path, spec)
        self.index(run, replace=True)
        self.assertEqual(self.assert_refused(run)['reason'], 'step-spec-binding-mismatch')
        self.assertFalse(self.latest.exists())

    def test_completion_day_uses_the_clock_with_offset_across_midnight(self):
        midnight = self.now.astimezone(TAIPEI).replace(hour=0, minute=0, second=0, microsecond=0)
        if midnight == self.now:
            self.skipTest('exact midnight clock tick')
        previous = midnight - dt.timedelta(seconds=1)
        older = self.receipt('older', completed_at=previous.astimezone(dt.UTC))
        self.index(older)
        self.assertEqual(self.assert_refused(older)['reason'], 'completion-outside-current-day')
        run = self.receipt('started-before-midnight', completed_at=midnight.astimezone(dt.UTC), started_at=previous)
        self.index(run)
        result, value = self.finalize(run)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(value['local_date'], midnight.date().isoformat())
        self.assertFalse(run.name.startswith(midnight.strftime('%Y%m%d')))

    def test_bootstrap_requires_explicit_matching_legacy_winner_and_preserves_its_day(self):
        legacy = self.legacy_latest(self.now)
        run = self.receipt('same-day-legacy')
        self.index(run, legacy)
        before = self.latest.read_bytes()
        self.assertEqual(self.assert_refused(run)['reason'], 'explicit-legacy-publication-required')
        result, value = self.finalize(run, '--legacy-latest-run-directory', legacy)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(value['status'], 'already-published')
        self.assertEqual(value['published_run_id'], legacy.name)
        self.assertEqual(self.latest.read_bytes(), before)

    def test_locked_latest_preserves_old_bytes_until_same_run_retries_with_refreshed_index(self):
        legacy = self.legacy_latest(self.now - dt.timedelta(days=1))
        run = self.receipt('retry-publisher')
        competing = self.receipt('competing-publisher')
        self.index(run, legacy)
        self.index(competing, legacy)
        with self.latest.open('rb') as old_latest:
            old_bytes = old_latest.read()
            self.assertEqual(self.assert_refused(run, '--legacy-latest-run-directory', legacy)['error_type'],
                             'PermissionError')
            self.assertEqual(self.latest.read_bytes(), old_bytes)
        self.assertEqual(self.assert_refused(competing)['reason'], 'same-day-publication-pending')
        state = run / 'document-reads.json'
        put(state, {'schemaVersion': 1, 'documents': []})
        self.index(run, legacy, replace=True, document_state=state)
        result, value = self.finalize(run)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(value['status'], 'published')
        self.assertEqual(self.latest.read_bytes(), (run / 'RESULT.md').read_bytes())

    def shared_delivery(self, label, receipts, checked):
        stages = {'register': 'dsh-verified', 'deliver': 'distributed', 'verify': 'verified'}
        paths = [f'delivery-{i}.json' for i in range(len(receipts))]
        checks = [{'path': paths[i], 'equals': {'ok': True, 'status': stages[receipts[i]['phase']]}} for i in checked]
        run = self.receipt(label, units=[
            {'id': 'health', 'status': 'processed', 'evidence': paths, 'checks': checks},
            {'id': 'optional', 'status': 'skipped', 'evidence': []},
        ])
        for path, receipt in zip(paths, receipts):
            defaults = {'schema_version': 1, 'receipt_kind': 'shared-skill-delivery', 'name': 'fixture-skill',
                        'transaction_id': 'a' * 32, 'intended_agents': ['dsh'], 'ok': True,
                        'status': stages[receipt['phase']]}
            put(run / path, dict(defaults, **receipt))
        self.index(run)
        return run

    def test_checked_register_and_pending_delivery_do_not_close_a_processed_unit(self):
        pending = {'phase': 'deliver', 'ok': False, 'status': 'pending'}
        run = self.shared_delivery('delivery-pending', [{'phase': 'register'}, pending], checked=[0])
        self.assertEqual(self.assert_refused(run)['reason'], 'shared-skill-delivery-incomplete')
        self.assertFalse(self.latest.exists())

    def test_checked_dsh_only_deliver_retry_closes_the_same_transaction(self):
        pending = {'phase': 'deliver', 'ok': False, 'status': 'pending'}
        run = self.shared_delivery('delivery-retried', [{'phase': 'register'}, pending, {'phase': 'deliver'}], checked=[2])
        result, value = self.finalize(run)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(value['status'], 'published')
        self.assertEqual(self.latest.read_bytes(), (run / 'RESULT.md').read_bytes())

    def test_delivery_checks_bind_each_transaction_and_target_set(self):
        for label, retry, checked, reason in (
            ('different-transaction', {'transaction_id': 'b' * 32}, [1], 'shared-skill-delivery-incomplete'),
            ('different-agents', {'intended_agents': ['codex', 'dsh']}, [1], 'shared-skill-delivery-target-conflict'),
            ('unchecked-success', {}, [0], 'shared-skill-delivery-incomplete'),
        ):
            with self.subTest(label=label):
                run = self.shared_delivery(label, [{'phase': 'register'}, dict(retry, phase='deliver')], checked)
                self.assertEqual(self.assert_refused(run)['reason'], reason)
                self.assertFalse(self.latest.exists())

    def test_unidentified_pending_receipt_is_refused_even_with_a_successful_retry(self):
        pending = {'phase': 'deliver', 'ok': False, 'status': 'pending', 'transaction_id': None}
        run = self.shared_delivery('unidentified-delivery', [pending, {'phase': 'deliver'}], checked=[1])
        self.assertEqual(self.assert_refused(run)['reason'], 'invalid-shared-skill-delivery-identity')
        self.assertFalse(self.latest.exists())

    def test_concurrent_successes_consume_only_one_day_slot(self):
        first = self.receipt('parallel-one')
        second = self.receipt('parallel-two')
        self.index(first)
        self.index(second)
        commands = [[sys.executable, '-B', str(SCRIPTS / 'finalize-run.py'), *self.finalize_args(run)]
                    for run in (first, second)]
        with subprocess.Popen(commands[0], stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8') as one:
            with subprocess.Popen(commands[1], stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8') as two:
                outcomes = []
                for process in (one, two):
                    stdout, stderr = process.communicate(timeout=60)
                    self.assertEqual(process.returncode, 0, stdout + stderr)
                    outcomes.append(json.loads(stdout))
        self.assertCountEqual([value['status'] for value in outcomes], ['published', 'already-published'])
        winner = outcomes[0]['published_run_id']
        self.assertEqual(outcomes[1]['published_run_id'], winner)
        self.assertEqual(self.latest.read_bytes(), (self.collection / winner / 'RESULT.md').read_bytes())


if __name__ == '__main__':
    unittest.main()
