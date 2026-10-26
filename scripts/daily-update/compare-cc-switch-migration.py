"""Read-only, fail-closed CC Switch provider/MCP migration comparison.

Inputs must be sealed, standalone SQLite snapshots, not the running database.
The explicit policy records a reviewed migration; it is not inferred from after.
"""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys
import tomllib

TABLES = {'providers': ('id', 'app_type'), 'mcp_servers': ('id',)}
JSON_COLUMNS = {'providers': ('settings_config', 'meta'), 'mcp_servers': ('server_config', 'tags')}
HEX = re.compile(r'^[0-9a-f]{64}$')


class InvalidInput(Exception):
    """Only constant, non-sensitive reason codes may be passed here."""


def canonical(value):
    def encode_blob(item):
        if isinstance(item, bytes):
            return {'blob_sha256': hashlib.sha256(item).hexdigest()}
        raise InvalidInput('unsupported-value-type')
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False,
                      default=encode_blob).encode('utf-8')


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def file_hash(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def checked_file(path):
    # Resolve neither aliases nor reparse points into a different trusted source.
    path = Path(path).absolute()
    if any(p.is_symlink() or (hasattr(p, 'is_junction') and p.is_junction()) for p in (path, *path.parents)):
        raise InvalidInput('reparse-input')
    if not path.is_file():
        raise InvalidInput('missing-input')
    return path


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise InvalidInput('duplicate-json-key')
            result[key] = value
        return result
    return json.loads(text, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(InvalidInput('non-finite-json')))


def policy_document(path):
    policy = strict_json(path.read_text(encoding='utf-8-sig'))
    keys = {'schema_version', 'before_user_version', 'after_user_version', 'added_columns', 'new_kimi_rows', 'native_snapshot_sha256'}
    if not isinstance(policy, dict) or set(policy) != keys or type(policy['schema_version']) is not int or policy['schema_version'] != 1:
        raise InvalidInput('policy-schema')
    if any(type(policy[k]) is not int or policy[k] < 0 for k in ('before_user_version', 'after_user_version')):
        raise InvalidInput('policy-version')
    if not isinstance(policy['added_columns'], dict) or set(policy['added_columns']) != set(TABLES):
        raise InvalidInput('policy-tables')
    for table, columns in policy['added_columns'].items():
        if not isinstance(columns, dict):
            raise InvalidInput('policy-columns')
        for name, rule in columns.items():
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', name) or not isinstance(rule, dict) or set(rule) != {'type', 'notnull', 'default', 'pk', 'value'}:
                raise InvalidInput('policy-column-rule')
            if type(rule['notnull']) is not int or type(rule['pk']) is not int or rule['notnull'] not in (0, 1) or rule['pk'] != 0 or not isinstance(rule['type'], str) or (rule['default'] is not None and not isinstance(rule['default'], str)):
                raise InvalidInput('policy-column-definition')
    if not isinstance(policy['new_kimi_rows'], list):
        raise InvalidInput('policy-additions')
    seen = set()
    for row in policy['new_kimi_rows']:
        if not isinstance(row, dict) or set(row) != {'selector_sha256', 'metadata_sha256'} or any(not isinstance(v, str) or not HEX.fullmatch(v) for v in row.values()):
            raise InvalidInput('policy-addition-rule')
        if row['selector_sha256'] in seen:
            raise InvalidInput('duplicate-policy-addition')
        seen.add(row['selector_sha256'])
    native_hash = policy['native_snapshot_sha256']
    if native_hash is not None and (not isinstance(native_hash, str) or not HEX.fullmatch(native_hash)):
        raise InvalidInput('policy-native-hash')
    if policy['new_kimi_rows'] and native_hash is None:
        raise InvalidInput('native-binding-required')
    return policy


def read_snapshot(path):
    if any(Path(str(path) + suffix).exists() for suffix in ('-wal', '-shm', '-journal')):
        raise InvalidInput('sidecar-present')
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro&immutable=1', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        db.execute('PRAGMA trusted_schema=OFF')
        db.execute('BEGIN')
        if db.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
            raise InvalidInput('database-integrity')
        result = {'version': db.execute('PRAGMA user_version').fetchone()[0], 'tables': {}}
        for table, identity in TABLES.items():
            kind = db.execute('SELECT type FROM sqlite_master WHERE name=?', (table,)).fetchone()
            if kind != ('table',):
                raise InvalidInput('required-table-missing')
            columns = {row[1]: {'type': row[2], 'notnull': row[3], 'default': row[4], 'pk': row[5]}
                       for row in db.execute(f'PRAGMA table_info({table})')}
            required = set(identity) | ({'settings_config', 'is_current'} if table == 'providers' else {'server_config'})
            if not required <= columns.keys():
                raise InvalidInput('required-column-missing')
            rows = {}
            cursor = db.execute(f'SELECT * FROM {table}')
            fields = [item[0] for item in cursor.description]
            if set(fields) != set(columns):
                raise InvalidInput('unsupported-hidden-column')
            for values in cursor:
                row = dict(zip(fields, values))
                selector = tuple(row[key] for key in identity)
                if any(not isinstance(key, str) or not key for key in selector) or selector in rows:
                    raise InvalidInput('invalid-row-identity')
                for column in JSON_COLUMNS[table]:
                    if column in row and row[column] is not None:
                        if not isinstance(row[column], str):
                            raise InvalidInput('invalid-json-column')
                        row[column] = strict_json(row[column])
                rows[selector] = row
            result['tables'][table] = {'columns': columns, 'rows': rows}
        db.rollback()
        return result


def native_projection(path, expected_hash):
    if path is None:
        if expected_hash is not None:
            raise InvalidInput('native-snapshot-required')
        return {}
    if expected_hash is None or file_hash(path) != expected_hash:
        raise InvalidInput('native-snapshot-hash-mismatch')
    document = tomllib.loads(path.read_text(encoding='utf-8-sig'))
    providers, models = document.get('providers', {}), document.get('models', {})
    if not isinstance(providers, dict) or not isinstance(models, dict) or any(not isinstance(v, dict) for v in [*providers.values(), *models.values()]):
        raise InvalidInput('native-snapshot-schema')
    return {key: {'provider': provider, 'models': {name: model for name, model in models.items() if model.get('provider') == key}}
            for key, provider in providers.items()}


def compare(before, after, policy, native):
    findings = []
    if before['version'] != policy['before_user_version'] or after['version'] != policy['after_user_version']:
        findings.append({'reason': 'unapproved-schema-version'})
    result = {'schema_version': 1, 'scope': ['providers', 'mcp_servers'], 'other_tables_checked': False,
              'database_versions': {'before': before['version'], 'after': after['version']}, 'findings': findings}
    allowed = {row['selector_sha256']: row for row in policy['new_kimi_rows']}
    observed_additions = set()
    for table in TABLES:
        old, new = before['tables'][table], after['tables'][table]
        columns_before, columns_after = old['columns'], new['columns']
        declared = policy['added_columns'][table]
        actual = set(columns_after) - set(columns_before)
        if set(columns_before) - set(columns_after) or any(columns_before[k] != columns_after.get(k) for k in columns_before):
            findings.append({'table': table, 'reason': 'original-column-definition-changed'})
        if actual != set(declared):
            findings.append({'table': table, 'reason': 'unapproved-added-columns'})
        for column in actual & set(declared):
            if columns_after[column] != {k: v for k, v in declared[column].items() if k != 'value'}:
                findings.append({'table': table, 'reason': 'added-column-definition-mismatch'})
            if any(digest(row[column]) != digest(declared[column]['value']) for row in new['rows'].values()):
                findings.append({'table': table, 'reason': 'added-column-value-mismatch'})
        summary = {'before': len(old['rows']), 'after': len(new['rows']), 'unchanged': 0, 'changed': 0, 'missing': 0, 'added': 0, 'accepted_additions': 0, 'records': []}
        for selector, row in old['rows'].items():
            candidate = new['rows'].get(selector)
            before_hash = digest(row)
            after_hash = digest({k: candidate.get(k) for k in row}) if candidate else None
            status = 'missing' if candidate is None else ('unchanged' if before_hash == after_hash and set(row) <= candidate.keys() else 'changed')
            summary[status] += 1
            summary['records'].append({'identity_sha256': digest(selector), 'status': status, 'before_sha256': before_hash, 'after_original_fields_sha256': after_hash})
            if status != 'unchanged':
                findings.append({'table': table, 'identity_sha256': digest(selector), 'reason': 'original-row-' + status})
        for selector in sorted(set(new['rows']) - set(old['rows'])):
            row = new['rows'][selector]
            selector_hash = digest(selector)
            summary['added'] += 1
            rule = allowed.get(selector_hash) if table == 'providers' else None
            metadata = {k: v for k, v in row.items() if k != 'settings_config'}
            accepted = (rule is not None and row.get('app_type') == 'kimi' and type(row.get('is_current')) is int and row['is_current'] == 0
                        and selector[0] in native and digest(row['settings_config']) == digest(native[selector[0]])
                        and digest(metadata) == rule['metadata_sha256'])
            if accepted:
                observed_additions.add(selector_hash)
                summary['accepted_additions'] += 1
            else:
                findings.append({'table': table, 'identity_sha256': selector_hash, 'reason': 'unapproved-new-row'})
            summary['records'].append({'identity_sha256': selector_hash, 'status': 'accepted-native-import' if accepted else 'rejected-addition', 'row_sha256': digest(row)})
        result[table] = summary
    if set(allowed) != observed_additions:
        findings.append({'reason': 'approved-native-import-set-mismatch'})
    result['status'] = 'pass' if not findings else 'rejected'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', required=True, type=Path)
    parser.add_argument('--after', required=True, type=Path)
    parser.add_argument('--policy', required=True, type=Path)
    parser.add_argument('--native-snapshot', type=Path)
    args = parser.parse_args()
    try:
        paths = {name: checked_file(value) for name, value in vars(args).items() if value is not None}
        hashes = {name: file_hash(path) for name, path in paths.items()}
        policy = policy_document(paths['policy'])
        # Check DB boundaries first; no native config or OAuth reference is followed.
        before, after = read_snapshot(paths['before']), read_snapshot(paths['after'])
        native = native_projection(paths.get('native_snapshot'), policy['native_snapshot_sha256'])
        result = compare(before, after, policy, native)
        if hashes != {name: file_hash(path) for name, path in paths.items()}:
            raise InvalidInput('input-changed-during-read')
        if any(Path(str(paths[name]) + suffix).exists() for name in ('before', 'after') for suffix in ('-wal', '-shm', '-journal')):
            raise InvalidInput('sidecar-appeared-during-read')
        result['input_sha256'] = hashes
        result['read_only'] = True
        result['inputs_unchanged'] = True
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0 if result['status'] == 'pass' else 1
    except InvalidInput as error:
        print(json.dumps({'status': 'invalid-input', 'reason': str(error)}))
    except (OSError, ValueError, TypeError, KeyError, sqlite3.Error):
        # Parsers and SQLite errors may contain config values or raw SQL. Redact.
        print(json.dumps({'status': 'invalid-input', 'reason': 'unreadable-or-invalid-input'}))
    return 2


if __name__ == '__main__':
    sys.exit(main())
