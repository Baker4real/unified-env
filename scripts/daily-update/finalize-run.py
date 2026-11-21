"""Publish the first verified daily-update RESULT.md for its Taipei completion day."""
import argparse
import datetime as dt
import importlib.util
import json
import msvcrt
import os
import pathlib
import re
import stat
import tempfile

from evidence_io import RUN_NAME, RunEvidence

BASE = pathlib.Path(__file__).resolve().parent
_loader = importlib.util.spec_from_file_location('daily_resume', BASE / 'daily-update-resume.py')
resume = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(resume)
step = resume.step

COLLECTION = 'daily-codex-ecosystem-update'
# Current workstation runs use Taipei civil time (UTC+08, no DST). Windows Python need not ship tzdata.
TAIPEI = dt.timezone(dt.timedelta(hours=8), 'Asia/Taipei')
COUNTS = ('processed', 'failed', 'pending', 'skipped', 'running')
NON_SUCCESS = {
    'blocked', 'deferred', 'error', 'failed', 'failure', 'in_progress', 'invalid-input',
    'launched-not-yet-verified', 'manual-review', 'pending', 'running', 'skipped', 'timeout',
    'unknown', 'validated-not-executed',
}
TRANSPORT_FIELDS = {
    'schema_version', 'exit_code', 'process_status', 'timeout', 'output_present', 'json_object',
    'required_fields_ok', 'predicates_ok', 'phase_ok', 'command_id', 'phase', 'spec_sha256',
    'started_at', 'finished_at', 'stdout_bytes', 'stdout_sha256', 'stderr_bytes', 'stderr_sha256',
}


class Refusal(ValueError):
    """A fixed, safe-to-project publication refusal."""


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def int_equals(value, expected):
    return type(value) is int and value == expected


def sha256(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def load_json(raw):
    def unique_fields(pairs):
        result = dict(pairs)
        require(len(result) == len(pairs), 'duplicate-json-field')
        return result

    def invalid_constant(_):
        raise Refusal('invalid-json-constant')

    return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique_fields, parse_constant=invalid_constant)


def instant(value):
    require(isinstance(value, str) and re.fullmatch(
        r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})', value),
        'timezone-aware-completion-required')
    return dt.datetime.fromisoformat(value)


def checked_path(value):
    path = step.evidence_path(value)
    for part in (path, *path.parents):
        try:
            attributes = part.lstat().st_file_attributes
        except FileNotFoundError:
            continue
        require(not attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT, 'reparse-evidence')
    return path


def evidence_ref(run, ref):
    require(isinstance(ref, str) and ref and not pathlib.PureWindowsPath(ref).anchor
            and re.search(r'[\x00-\x1f:@?]', ref) is None, 'invalid-evidence-reference')
    return checked_path(run.output_path(ref))


def business_predicates(equals):
    require(isinstance(equals, dict) and equals, 'business-predicates-required')
    for field, wanted in equals.items():
        require(re.fullmatch(r'[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*', field)
                and type(wanted) in (bool, int, float, str, type(None)), 'invalid-business-predicate')
        leaf = field.rsplit('.', 1)[-1].lower()
        if leaf == 'ok' or (leaf.endswith('_ok') and leaf not in TRANSPORT_FIELDS):
            require(wanted is True, 'non-success-business-predicate')
        if leaf == 'status':
            require(isinstance(wanted, str) and bool(wanted.strip()) and wanted.lower() not in NON_SUCCESS,
                    'non-success-business-predicate')
    require(any(field.rsplit('.', 1)[-1].lower() not in TRANSPORT_FIELDS and wanted not in (None, '')
                for field, wanted in equals.items()), 'business-predicates-required')
    return equals


def check_business_json(value, equals):
    require(isinstance(value, dict), 'invalid-business-evidence')
    require('ok' not in value or value['ok'] is True, 'business-evidence-failed')
    status = value.get('status', '')
    require(isinstance(status, str) and status.lower() not in NON_SUCCESS, 'business-evidence-failed')
    for field, wanted in business_predicates(equals).items():
        observed = step.json_field(value, field)
        require(type(observed) is type(wanted) and observed == wanted, 'business-predicate-mismatch')


def is_step_receipt(value):
    return isinstance(value, dict) and (
        {'spec_sha256', 'command_id'} <= value.keys() or {'predicates_ok', 'process_status'} <= value.keys() or
        (value.get('status') == 'invalid-input' and {'started_at', 'finished_at'} <= value.keys()))


def check_step_receipt(receipt, spec_bytes, completed):
    spec = load_json(spec_bytes)
    require(isinstance(spec, dict), 'invalid-step-spec')
    equals = business_predicates(spec.get('equals'))
    # The receipt has no raw stdout. Bind an explicit successful business `ok`
    # predicate from the executed spec, as well as any command-specific equals.
    require(equals.get('ok') is True, 'step-business-ok-predicate-required')
    command_id = spec.get('command_id')
    phase = spec.get('phase')
    require(isinstance(command_id, str) and re.fullmatch(r'[A-Za-z0-9._-]{1,100}', command_id)
            and phase in (None, 'Prepare', 'Apply', 'Rollback'), 'invalid-step-spec')
    success = ('ok', 'phase_ok', 'output_present', 'json_object', 'required_fields_ok', 'predicates_ok')
    require(is_step_receipt(receipt) and int_equals(receipt.get('schema_version'), 1)
            and receipt.get('process_status') == 'exited' and int_equals(receipt.get('exit_code'), 0)
            and receipt.get('timeout') is False and all(receipt.get(field) is True for field in success)
            and 'status' not in receipt and 'phase' in receipt and receipt['phase'] == phase
            and type(receipt.get('stdout_bytes')) is int and receipt['stdout_bytes'] > 0
            and sha256(receipt.get('stdout_sha256')), 'step-receipt-not-successful')
    require(receipt.get('spec_sha256') == step.digest(spec_bytes) and receipt.get('command_id') == command_id,
            'step-spec-binding-mismatch')
    require(instant(receipt.get('started_at')) <= instant(receipt.get('finished_at')) <= completed,
            'step-receipt-clock-conflict')


def validate_shared_skill_delivery(json_evidence, checked_paths, processed):
    successful_status = {'register': 'dsh-verified', 'deliver': 'distributed', 'verify': 'verified'}
    identities = {}
    operations = {}
    completed = set()
    for path, value in json_evidence.items():
        if not isinstance(value, dict) or value.get('receipt_kind') != 'shared-skill-delivery':
            continue
        name = value.get('name')
        transaction = value.get('transaction_id')
        agents = value.get('intended_agents')
        require(isinstance(name, str) and len(name) <= 64 and re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', name)
                and isinstance(transaction, str) and re.fullmatch(r'[0-9a-f]{32}', transaction)
                and isinstance(agents, list) and all(isinstance(agent, str) and
                    re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', agent) for agent in agents)
                and 'dsh' in agents and len(agents) == len(set(agents)), 'invalid-shared-skill-delivery-identity')
        phase = value.get('phase')
        ok = value.get('ok')
        operation = value.get('guarded_operation', 'install')
        require(int_equals(value.get('schema_version'), 1) and isinstance(phase, str) and phase in successful_status
                and type(ok) is bool and value.get('status') == (successful_status[phase] if ok else 'pending')
                and (operation == 'install' or (operation == 'update' and phase == 'verify'
                     and sha256(value.get('transaction_manifest_sha256')))), 'invalid-shared-skill-delivery-stage')
        identity = (name, transaction)
        intended = frozenset(agents)
        require(identities.setdefault(identity, intended) == intended, 'shared-skill-delivery-target-conflict')
        require(operations.setdefault(identity, operation) == operation, 'shared-skill-operation-conflict')
        required_phase = 'verify' if operation == 'update' else 'deliver'
        if ok and phase == required_phase and path in checked_paths:
            completed.add(identity)
    if processed:
        require(identities.keys() == completed, 'shared-skill-delivery-incomplete')


def validate_codex_plugin_adoption(json_evidence, checked_paths):
    spec = importlib.util.spec_from_file_location('codex_store_plugins', BASE / 'codex-store-plugins.py')
    plugins = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugins)
    values = [json_evidence[path] for path in checked_paths if isinstance(json_evidence[path], dict)]
    closeout_checks = {'menu', 'closure', 'catalog', 'system_provenance'}
    closeout_ok = any(value.get('ok') is True and value.get('status') == 'healthy'
                      and value.get('phase') in ('Check', 'Apply') and isinstance(value.get('checks'), dict)
                      and all(value['checks'].get(key) is True for key in closeout_checks) for value in values)
    for value in values:
        if value.get('ok') is not True:
            continue
        expected_version = None
        if 'plugin_adoption' in value:
            if value.get('phase') not in ('Apply', 'Verify') or value.get('closeout_ok') is not True:
                continue
            expected_version = value.get('observed_version')
            if not isinstance(expected_version, str):
                continue
            value = value['plugin_adoption']
        elif not closeout_ok:
            continue
        try:
            receipt = plugins.validate_result(value, expected_appx_version=expected_version)
        except plugins.Rejected:
            continue
        if receipt['ok'] is True and receipt['status'] == 'verified':
            return
    raise Refusal('codex-plugin-adoption-unverified')


def validate_units(run, manifest, read_bound, completed):
    require(isinstance(manifest, dict), 'invalid-manifest')
    required = manifest.get('required_units')
    optional = manifest.get('optional_units')
    units = manifest.get('units')
    require(isinstance(required, list) and required and isinstance(optional, list) and isinstance(units, list),
            'invalid-unit-scope')
    names = required + optional
    require(all(isinstance(name, str) and name for name in names) and len(set(names)) == len(names),
            'invalid-unit-scope')
    seen = set()
    counts = dict.fromkeys(COUNTS, 0)
    for unit in units:
        require(isinstance(unit, dict) and isinstance(unit.get('id'), str), 'invalid-unit')
        name, outcome = unit['id'], unit.get('status')
        require(name in names and name not in seen, 'invalid-unit-scope')
        seen.add(name)
        require(outcome == 'processed' or (outcome == 'skipped' and name in optional), 'unsuccessful-unit')
        refs = unit.get('evidence')
        checks = unit.get('checks', [])
        require(isinstance(refs, list) and isinstance(checks, list), 'invalid-unit-evidence')
        paths = {evidence_ref(run, ref) for ref in refs}
        require(len(paths) == len(refs), 'duplicate-evidence-reference')
        require(bool(checks) == (outcome == 'processed'), 'invalid-unit-checks')
        json_evidence = {path: load_json(read_bound(path)) for path in paths if path.suffix.lower() == '.json'}
        unchecked_steps = {path for path, value in json_evidence.items() if is_step_receipt(value)}
        checked_paths = set()
        for check in checks:
            require(isinstance(check, dict) and set(check) in ({'path', 'equals'}, {'path', 'spec'}),
                    'invalid-unit-check')
            path = evidence_ref(run, check['path'])
            require(path in paths and path in json_evidence, 'check-json-evidence-not-bound')
            value = json_evidence[path]
            if 'spec' in check:
                spec_path = evidence_ref(run, check['spec'])
                require(spec_path in paths, 'step-spec-not-bound')
                check_step_receipt(value, read_bound(spec_path), completed)
                unchecked_steps.discard(path)
            else:
                require(not is_step_receipt(value), 'step-receipt-requires-spec')
                check_business_json(value, check['equals'])
            checked_paths.add(path)
        require(not unchecked_steps, 'unchecked-step-receipt')
        validate_shared_skill_delivery(json_evidence, checked_paths, outcome == 'processed')
        if name == 'codex-plugins' and outcome == 'processed':
            validate_codex_plugin_adoption(json_evidence, checked_paths)
        counts[outcome] += 1
    require(seen == set(names), 'invalid-unit-scope')
    return counts


def verified_candidate(run, index_path):
    index, raw_index, projection = resume.verify_index(index_path, 6000)
    load_json(raw_index)
    require(pathlib.Path(index['run_directory']) == run.root, 'index-run-mismatch')
    if index['previous_run_directory'] is not None:
        previous = pathlib.Path(index['previous_run_directory'])
        require(previous.parent == run.root.parent and previous != run.root, 'invalid-previous-run')
    require(projection['run_status'] == 'completed' and projection['checkpoint_conflict'] is False
            and not index['unfinished_units'], 'unsuccessful-or-conflicting-receipt')
    bindings = {pathlib.Path(path): digest for path, digest in index['bindings'].items()}

    def read_bound(path):
        data = checked_path(path).read_bytes()
        require(step.digest(data) == bindings.get(path), 'index-content-drift')
        return data

    checkpoint = load_json(read_bound(run.output_path('scope-checkpoint.json')))
    manifest_path = run.output_path('scope-manifest.json')
    manifest = load_json(read_bound(manifest_path))
    require(isinstance(checkpoint, dict) and int_equals(checkpoint.get('finalize_schema_version'), 1)
            and checkpoint.get('scope_manifest_sha256') == bindings[manifest_path]
            and checkpoint.get('status') == 'completed', 'invalid-finalize-checkpoint')
    completed = instant(checkpoint.get('completed_at'))
    counts = validate_units(run, manifest, read_bound, completed)
    if 'scope_id' in manifest or 'scope_id' in checkpoint:
        scope_id = manifest.get('scope_id')
        require(isinstance(scope_id, str) and bool(scope_id.strip()) and scope_id == checkpoint.get('scope_id'),
                'checkpoint-scope-id-mismatch')
    checkpoint_refs = checkpoint.get('evidence_refs', [])
    require(isinstance(checkpoint_refs, list), 'invalid-checkpoint-evidence')
    for reference in checkpoint_refs:
        read_bound(evidence_ref(run, reference))
    claimed = checkpoint.get('counts')
    require(isinstance(claimed, dict) and set(claimed) == set(counts)
            and all(int_equals(claimed[key], count) for key, count in counts.items())
            and int_equals(checkpoint.get('scope_total'), sum(counts.values())), 'checkpoint-count-conflict')
    report = read_bound(run.output_path('RESULT.md'))
    require(bool(report.decode('utf-8-sig').strip()), 'empty-result')
    return completed, counts, report, raw_index, index['bindings']


def write_atomic(target, data):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.latest-', suffix='.tmp', delete=False) as stream:
            temporary = pathlib.Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(checked_path(target))
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_publication(path):
    try:
        with checked_path(path).open('rb') as stream:
            raw = stream.read(4097)
    except FileNotFoundError:
        return None
    require(len(raw) <= 4096, 'invalid-publication-record')
    value = load_json(raw)
    require(isinstance(value, dict) and set(value) == {'schema_version', 'local_date', 'run_id', 'index_sha256',
                'result_sha256', 'prior_latest_sha256'} and int_equals(value['schema_version'], 1)
            and isinstance(value['run_id'], str) and RUN_NAME.fullmatch(value['run_id'])
            and sha256(value['index_sha256']) and sha256(value['result_sha256'])
            and (value['prior_latest_sha256'] is None or sha256(value['prior_latest_sha256'])),
            'invalid-publication-record')
    dt.date.fromisoformat(value['local_date'])
    return value


def latest_hash(path):
    try:
        return step.digest(checked_path(path).read_bytes())
    except FileNotFoundError:
        return None


def legacy_day(path, collection, current, observed):
    require(path is not None, 'explicit-legacy-publication-required')
    legacy = RunEvidence(checked_path(path))
    require(legacy.root.parent == collection and legacy.root != current, 'invalid-legacy-publication-run')
    checkpoint_path = checked_path(legacy.output_path('scope-checkpoint.json'))
    raw = checkpoint_path.read_bytes()
    projection = resume.read_receipts(legacy.root, None)
    require(projection['run_status'] == 'completed' and projection['checkpoint_conflict'] is False
            and checkpoint_path.read_bytes() == raw and latest_hash(legacy.output_path('RESULT.md')) == observed,
            'unverified-legacy-publication')
    value = load_json(raw)
    return instant(value.get('completed_at', value.get('last_observed_at'))).astimezone(TAIPEI).date()


def current_day(completed):
    now = dt.datetime.now(TAIPEI)
    require(completed <= now and completed.astimezone(TAIPEI).date() == now.date(), 'completion-outside-current-day')
    return now.date()


def publish(args):
    run = RunEvidence(checked_path(args.run_directory))
    collection = run.root.parent
    require(collection.name == COLLECTION, 'invalid-daily-update-collection')
    index_path = checked_path(run.output_path(args.index_path))
    require(pathlib.Path(args.index_path).is_absolute() and index_path.suffix.lower() == '.json'
            and ':' not in index_path.name, 'invalid-index-path')
    completed, counts, report, raw_index, bindings = verified_candidate(run, index_path)
    day = current_day(completed)
    latest = collection / 'LATEST.md'
    journal = collection / 'latest-publication.json'
    candidate = {'schema_version': 1, 'local_date': day.isoformat(), 'run_id': run.root.name,
                 'index_sha256': step.digest(raw_index), 'result_sha256': step.digest(report)}
    with checked_path(collection / '.latest-publication.lock').open('a+b') as lock:
        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
        # Closing the handle releases a process-owned lock, including after an abrupt exit.
        record = read_publication(journal)
        observed = latest_hash(latest)
        result = {'ok': True, 'run_status': 'completed', 'local_date': day.isoformat(), 'counts': counts}
        if record is not None:
            previous_day = dt.date.fromisoformat(record['local_date'])
            require(previous_day <= day, 'publication-date-regression')
            published = observed == record['result_sha256']
            require(published or observed == record['prior_latest_sha256'], 'latest-content-drift')
            if previous_day == day:
                if published:
                    return dict(result, status='already-published', published_run_id=record['run_id'])
                require(candidate['run_id'] == record['run_id'] and candidate['result_sha256'] == record['result_sha256'],
                        'same-day-publication-pending')
        elif observed is not None:
            day_of_legacy = legacy_day(args.legacy_latest_run_directory, collection, run.root, observed)
            require(day_of_legacy <= day, 'publication-date-regression')
            if day_of_legacy == day:
                return dict(result, status='already-published', published_run_id=pathlib.Path(args.legacy_latest_run_directory).name)
        resume.verify_bindings(bindings)
        require(checked_path(index_path).read_bytes() == raw_index and latest_hash(latest) == observed,
                'publication-input-drift')
        current_day(completed)
        candidate['prior_latest_sha256'] = observed
        if candidate != record:
            write_atomic(journal, (json.dumps(candidate, indent=2) + '\n').encode('utf-8'))
        write_atomic(latest, report)
        return dict(result, status='published', published_run_id=run.root.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'Use a finalized checkpoint with finalize_schema_version=1 and an actual timezone-aware completed_at '
        'on the current Asia/Taipei day. Use the existing resume index with its explicitly recorded previous run.'))
    parser.add_argument('--run-directory', required=True, help=f'Current {COLLECTION} run directory')
    parser.add_argument('--index-path', required=True, help='Absolute path to the verified resume index in this run')
    parser.add_argument('--legacy-latest-run-directory', help='Explicit existing publishing run for an unmanaged LATEST')
    args = parser.parse_args()
    try:
        print(json.dumps(publish(args), ensure_ascii=False))
        return 0
    except Refusal as error:
        print(json.dumps({'ok': False, 'status': 'publication-refused', 'reason': str(error)}))
    except (ValueError, OSError, KeyError, TypeError, RecursionError) as error:
        print(json.dumps({'ok': False, 'status': 'publication-refused', 'error_type': type(error).__name__}))
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
