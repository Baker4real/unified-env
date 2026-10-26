"""CLI contract tests; fixtures contain synthetic values only."""
import hashlib
from contextlib import contextmanager
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/daily-update/compare-cc-switch-migration.py'


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


@contextmanager
def database(path):
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.before, self.after = self.root / 'before.db', self.root / 'after.db'
        self.native = self.root / 'native.toml'
        self.native.write_text('[providers.existing]\ntype="kimi"\napi_key=""\n[models.test]\nprovider="existing"\n', encoding='utf-8')
        for path, version in ((self.before, 21), (self.after, 23)):
            with database(path) as db:
                db.execute('CREATE TABLE providers(id TEXT NOT NULL, app_type TEXT NOT NULL, name TEXT, settings_config TEXT, meta TEXT, is_current INTEGER, PRIMARY KEY(id,app_type))')
                db.execute('CREATE TABLE mcp_servers(id TEXT PRIMARY KEY, server_config TEXT, enabled_codex INTEGER)')
                db.execute('INSERT INTO providers VALUES(?,?,?,?,?,?)', ('original', 'codex', 'private-name-canary', '{"token":"SECRET-CANARY"}', '{}', 1))
                db.execute('INSERT INTO mcp_servers VALUES(?,?,?)', ('server', '{"env":{"key":"SECRET-CANARY"}}', 1))
                db.execute(f'PRAGMA user_version={version}')
        self.row = {'id': 'existing', 'app_type': 'kimi', 'name': 'native-name', 'settings_config': {'provider': {'type': 'kimi', 'api_key': ''}, 'models': {'test': {'provider': 'existing'}}}, 'meta': {}, 'is_current': 0}
        with database(self.after) as db:
            db.execute('ALTER TABLE mcp_servers ADD COLUMN enabled_kimi BOOLEAN NOT NULL DEFAULT 0')
            db.execute('ALTER TABLE mcp_servers ADD COLUMN enabled_omp BOOLEAN NOT NULL DEFAULT 0')
            db.execute('INSERT INTO providers VALUES(?,?,?,?,?,?)', tuple(json.dumps(v) if isinstance(v, dict) else v for v in self.row.values()))
        self.policy = {
            'schema_version': 1, 'before_user_version': 21, 'after_user_version': 23,
            'added_columns': {'providers': {}, 'mcp_servers': {
                key: {'type': 'BOOLEAN', 'notnull': 1, 'default': '0', 'pk': 0, 'value': 0}
                for key in ('enabled_kimi', 'enabled_omp')}},
            'new_kimi_rows': [{'selector_sha256': digest(['existing', 'kimi']),
                               'metadata_sha256': digest({k: v for k, v in self.row.items() if k != 'settings_config'})}],
            'native_snapshot_sha256': hashlib.sha256(self.native.read_bytes()).hexdigest(),
        }
        self.policy_path = self.root / 'policy.json'

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self):
        self.policy_path.write_text(json.dumps(self.policy), encoding='utf-8')
        original = {p: p.read_bytes() for p in (self.before, self.after, self.native)}
        p = subprocess.run([sys.executable, '-B', str(SCRIPT), '--before', str(self.before), '--after', str(self.after), '--policy', str(self.policy_path), '--native-snapshot', str(self.native)], capture_output=True, text=True,
                           creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        self.assertNotIn('SECRET-CANARY', p.stdout + p.stderr)
        self.assertNotIn('private-name-canary', p.stdout + p.stderr)
        self.assertTrue(all(path.read_bytes() == value for path, value in original.items()))
        self.assertFalse(list(self.root.glob('*-shm')))
        self.assertFalse(list(self.root.glob('*-wal')))
        return p.returncode, json.loads(p.stdout)

    def change(self, sql):
        with database(self.after) as db:
            db.execute(sql)

    def test_known_native_import_passes_and_preserves_all_originals(self):
        code, result = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['providers']['unchanged'], 1)
        self.assertEqual(result['providers']['accepted_additions'], 1)
        self.assertEqual(result['mcp_servers']['unchanged'], 1)

    def test_old_template_change_rejected(self):
        self.change("UPDATE providers SET settings_config='{}' WHERE id='original'")
        self.assertEqual(self.run_cli()[0], 1)

    def test_old_template_removed_rejected(self):
        self.change("DELETE FROM providers WHERE id='original'")
        self.assertEqual(self.run_cli()[0], 1)

    def test_unapproved_addition_rejected(self):
        self.change("INSERT INTO providers VALUES('extra','kimi','x','{}','{}',0)")
        self.assertEqual(self.run_cli()[0], 1)

    def test_unknown_schema_rejected(self):
        self.change('PRAGMA user_version=24')
        self.assertEqual(self.run_cli()[0], 1)

    def test_old_mcp_flag_change_rejected(self):
        self.change('UPDATE mcp_servers SET enabled_codex=0')
        self.assertEqual(self.run_cli()[0], 1)

    def test_new_mcp_flag_enabled_rejected(self):
        self.change('UPDATE mcp_servers SET enabled_kimi=1')
        self.assertEqual(self.run_cli()[0], 1)

    def test_native_projection_and_snapshot_binding_required(self):
        self.change("UPDATE providers SET settings_config='{}' WHERE id='existing'")
        self.assertEqual(self.run_cli()[0], 1)
        self.policy['native_snapshot_sha256'] = '0' * 64
        self.assertEqual(self.run_cli()[0], 2)

    def test_active_or_changed_new_metadata_rejected(self):
        self.change("UPDATE providers SET is_current=1 WHERE id='existing'")
        self.assertEqual(self.run_cli()[0], 1)

    def test_unknown_column_and_definition_drift_rejected(self):
        self.change('ALTER TABLE providers ADD COLUMN unknown_field TEXT')
        self.assertEqual(self.run_cli()[0], 1)

    def test_original_column_definition_drift_rejected(self):
        with database(self.after) as db:
            db.execute('ALTER TABLE mcp_servers RENAME TO previous_mcp')
            db.execute('CREATE TABLE mcp_servers(id TEXT PRIMARY KEY, server_config TEXT, enabled_codex TEXT, enabled_kimi BOOLEAN NOT NULL DEFAULT 0, enabled_omp BOOLEAN NOT NULL DEFAULT 0)')
            db.execute('INSERT INTO mcp_servers SELECT * FROM previous_mcp')
            db.execute('DROP TABLE previous_mcp')
        code, result = self.run_cli()
        self.assertEqual(code, 1)
        self.assertIn('original-column-definition-changed', {x['reason'] for x in result['findings']})

    def test_mcp_addition_rejected(self):
        self.change("INSERT INTO mcp_servers VALUES('extra','{}',0,0,0)")
        self.assertEqual(self.run_cli()[0], 1)

    def test_json_format_only_change_is_allowed(self):
        self.change("UPDATE providers SET settings_config=' { \"token\" : \"SECRET-CANARY\" } ' WHERE id='original'")
        self.assertEqual(self.run_cli()[0], 0)

    def test_declared_addition_must_be_present(self):
        self.change("DELETE FROM providers WHERE id='existing'")
        self.assertEqual(self.run_cli()[0], 1)

    def test_nonobject_policy_is_redacted_invalid_input(self):
        self.policy['added_columns'] = ['providers', 'mcp_servers']
        self.assertEqual(self.run_cli()[0], 2)

    def test_boolean_schema_is_not_integer_schema(self):
        self.policy['schema_version'] = True
        self.assertEqual(self.run_cli()[0], 2)

    def test_invalid_json_column_returns_only_redacted_reason(self):
        self.change("UPDATE providers SET settings_config='SECRET-CANARY' WHERE id='original'")
        code, result = self.run_cli()
        self.assertEqual(code, 2)
        self.assertEqual(result['reason'], 'unreadable-or-invalid-input')

    def test_duplicate_json_keys_rejected(self):
        self.change("UPDATE providers SET settings_config='{\"token\":\"SECRET-CANARY\",\"token\":\"SECRET-CANARY\"}' WHERE id='original'")
        code, result = self.run_cli()
        self.assertEqual(code, 2)
        self.assertEqual(result['reason'], 'duplicate-json-key')

    def test_sidecar_snapshot_rejected_without_mutation(self):
        Path(str(self.after) + '-wal').write_bytes(b'synthetic-not-a-real-wal')
        self.policy_path.write_text(json.dumps(self.policy), encoding='utf-8')
        p = subprocess.run([sys.executable, '-B', str(SCRIPT), '--before', str(self.before), '--after', str(self.after), '--policy', str(self.policy_path)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)
        self.assertIn('sidecar-present', p.stdout)


if __name__ == '__main__':
    unittest.main()
