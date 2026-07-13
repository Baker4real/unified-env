from __future__ import annotations

import hashlib
import base64
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
FIXTURE_ROOT = PROJECT_ROOT / "reports" / "codex-state-policy-test"
MODULE_PATH = PROJECT_ROOT / "managed" / "codex-hooks" / "hooks" / "codex-state-policy-guard.py"

os.environ["TMP"] = str(FIXTURE_ROOT / "tmp")
os.environ["TEMP"] = str(FIXTURE_ROOT / "tmp")
tempfile.tempdir = str(FIXTURE_ROOT / "tmp")


def load_module():
    spec = importlib.util.spec_from_file_location("codex_state_policy_guard", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("state policy module loader unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


class CodexStatePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(FIXTURE_ROOT, ignore_errors=True)
        (FIXTURE_ROOT / "tmp").mkdir(parents=True)
        cls.module = load_module()

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(FIXTURE_ROOT, ignore_errors=True)

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(dir=FIXTURE_ROOT))
        self.codex_home = self.root / "codex-home"
        self.codex_home.mkdir()
        self.global_path = self.codex_home / ".codex-global-state.json"
        self.db_path = self.codex_home / "state_5.sqlite"
        self.backup_root = self.root / "backups"
        self.sqlite_snapshot_root = self.root / "sqlite-snapshots"
        self.write_permission_config()

    def write_permission_config(
        self,
        *,
        approval_policy: str = "never",
        sandbox_mode: str = "danger-full-access",
    ) -> None:
        target = self.codex_home / "config.toml"
        temporary = self.codex_home / ".config.toml.test.tmp"
        temporary.write_text(
            f'approval_policy = "{approval_policy}"\n'
            f'sandbox_mode = "{sandbox_mode}"\n',
            encoding="utf-8",
        )
        try:
            os.replace(temporary, target)
        except PermissionError as exc:
            raise self.module.StatePolicyError(
                "permission policy source changed concurrently: writer blocked by lease"
            ) from exc
        sandbox_json = {
            "read-only": "readOnly",
            "workspace-write": "workspaceWrite",
            "danger-full-access": "dangerFullAccess",
        }[sandbox_mode]
        policy_json = json.dumps(
            {
                "approvalPolicy": approval_policy,
                "sandboxPolicy": {"type": sandbox_json},
            },
            separators=(",", ":"),
        )
        for supplemental in ("policy.json", "state-policy.json"):
            (self.codex_home / supplemental).write_text(policy_json, encoding="utf-8")

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def write_global(self, state: object) -> bytes:
        data = json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode()
        self.global_path.write_bytes(data)
        return data

    @staticmethod
    def permission_drift() -> dict[str, object]:
        return {
            "electron-persisted-atom-state": {
                "heartbeat-thread-permissions-by-id": {
                    "target": {
                        "approvalPolicy": "on-request",
                        "sandboxPolicy": {"type": "workspaceWrite"},
                    }
                }
            }
        }

    def create_db(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "create table threads (id text primary key, source text, thread_source text, "
            "approval_mode text, sandbox_policy text, sentinel text)"
        )
        conn.executemany(
            "insert into threads values (?,?,?,?,?,?)",
            [
                ("target-a", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep-a"),
                ("target-b", "vscode", None, "never", "danger-full-access", "keep-b"),
                ("unknown", "cli", "user", "on-request", '{"type":"workspace-write"}', "keep-unknown"),
                ("target-null", "vscode", "user", None, None, "keep-null"),
            ],
        )
        conn.commit()
        return conn

    def create_wal_db(self) -> sqlite3.Connection:
        conn = self.create_db()
        self.assertEqual(conn.execute("pragma journal_mode=wal").fetchone()[0], "wal")
        conn.execute("pragma wal_autocheckpoint=0")
        conn.commit()
        return conn

    def test_rewrite_projectless_path_is_boundary_safe_and_case_insensitive(self) -> None:
        rewrite = self.module.rewrite_projectless_path
        self.assertEqual(
            rewrite(r"c:/Users/WINDOWS/Documents/Codex/output"),
            r"D:\Users\WINDOWS\Documents\Codex\output",
        )
        self.assertEqual(
            rewrite(r"C:\Users\WINDOWS\Documents\Codex"),
            r"D:\Users\WINDOWS\Documents\Codex",
        )
        self.assertEqual(
            rewrite(r"C:\Users\WINDOWS\Documents\CodexBackup"),
            r"C:\Users\WINDOWS\Documents\CodexBackup",
        )
        unsafe = (
            r"C:\Users\WINDOWS\Documents\Codex\..\CodexBackup",
            r"C:\Users\WINDOWS\Documents\Codex\.\output",
            r"\\server\share\Users\WINDOWS\Documents\Codex\output",
            r"\\?\C:\Users\WINDOWS\Documents\Codex\output",
            r"\\.\C:\Users\WINDOWS\Documents\Codex\output",
            r"C:Users\WINDOWS\Documents\Codex\output",
            r"Users\WINDOWS\Documents\Codex\output",
        )
        for value in unsafe:
            with self.subTest(value=value):
                self.assertEqual(rewrite(value), value)
        self.assertEqual(
            rewrite(r"c:/Users\WINDOWS/Documents\Codex/mixed"),
            r"D:\Users\WINDOWS\Documents\Codex\mixed",
        )
        sentinel = {"not": "a path"}
        self.assertIs(rewrite(sentinel), sentinel)

    def test_normalize_global_state_combines_both_maps_and_heartbeat(self) -> None:
        policy = self.module.resolve_permission_policy(self.codex_home)
        state = {
            "thread-workspace-root-hints": {"redacted-a": r"C:\Users\WINDOWS\Documents\Codex\a"},
            "thread-projectless-output-directories": {"redacted-b": r"c:/users/windows/documents/codex/b"},
            "electron-persisted-atom-state": {
                "heartbeat-thread-permissions-by-id": {
                    "redacted-c": {"approvalPolicy": "on-request", "sandboxPolicy": {"type": "workspaceWrite"}},
                    "redacted-d": "unknown-shape",
                },
                "sentinel": {"keep": True},
            },
            "unknown": "keep",
        }
        normalized, summary = self.module.normalize_global_state(
            state,
            permission_policy=policy,
            path_mode="inventory",
        )
        self.assertEqual(normalized["thread-workspace-root-hints"]["redacted-a"], r"C:\Users\WINDOWS\Documents\Codex\a")
        self.assertEqual(normalized["thread-projectless-output-directories"]["redacted-b"], r"c:/users/windows/documents/codex/b")
        heartbeat = normalized["electron-persisted-atom-state"]["heartbeat-thread-permissions-by-id"]
        self.assertEqual(heartbeat["redacted-c"]["approvalPolicy"], "never")
        self.assertEqual(heartbeat["redacted-c"]["sandboxPolicy"], {"type": "dangerFullAccess"})
        self.assertEqual(heartbeat["redacted-d"], "unknown-shape")
        self.assertEqual(normalized["unknown"], "keep")
        self.assertEqual(summary["pathChangedCount"], 0)
        self.assertEqual(summary["pathDriftCount"], 2)
        self.assertEqual(summary["heartbeatChangedCount"], 1)
        self.assertNotIn("redacted-a", json.dumps(summary))

    def test_permission_policy_resolves_from_controlled_config(self) -> None:
        self.write_permission_config(approval_policy="on-request", sandbox_mode="workspace-write")

        policy = self.module.resolve_permission_policy(self.codex_home)

        self.assertEqual(policy.approval_policy, "on-request")
        self.assertEqual(policy.sandbox_mode, "workspace-write")
        self.assertEqual(policy.heartbeat_sandbox_type, "workspaceWrite")
        self.assertEqual(policy.sqlite_sandbox_policy, '{"type":"workspace-write"}')

    @unittest.skipUnless(os.name == "nt", "requires Windows source lease semantics")
    def test_permission_policy_source_lease_denies_in_place_writer(self) -> None:
        policy = self.module.resolve_permission_policy(self.codex_home)
        with self.module.PermissionPolicySourceLease(policy):
            with self.assertRaises(PermissionError):
                (self.codex_home / "config.toml").write_text(
                    'approval_policy = "on-request"\n'
                    'sandbox_mode = "danger-full-access"\n',
                    encoding="utf-8",
                )

    @unittest.skipUnless(os.name == "nt", "requires Windows source lease semantics")
    def test_permission_policy_source_lease_denies_delete(self) -> None:
        policy = self.module.resolve_permission_policy(self.codex_home)
        with self.module.PermissionPolicySourceLease(policy):
            with self.assertRaises(PermissionError):
                (self.codex_home / "config.toml").unlink()

    def test_permission_policy_object_shape_fails_closed(self) -> None:
        digest = "0" * 64
        invalid = [
            ([], "danger-full-access", r"D:\Codex\config.toml", ((r"D:\Codex\config.toml", digest),)),
            ("never", {}, r"D:\Codex\config.toml", ((r"D:\Codex\config.toml", digest),)),
            ("never", "danger-full-access", r"D:\Codex\config.toml", ((r"D:\Codex\config.toml",),)),
            ("never", "danger-full-access", r"D:\Codex\config.toml", ((r"C:\Codex\config.toml", digest),)),
        ]
        for approval, sandbox, source, source_hashes in invalid:
            with self.subTest(approval=approval, sandbox=sandbox, source_hashes=source_hashes):
                with self.assertRaises(self.module.StatePolicyError):
                    self.module.PermissionPolicy(approval, sandbox, source, source_hashes)

    def test_permission_policy_missing_fails_closed(self) -> None:
        (self.codex_home / "config.toml").unlink()
        (self.codex_home / "policy.json").unlink()
        (self.codex_home / "state-policy.json").unlink()
        with self.assertRaisesRegex(self.module.StatePolicyError, "permission policy"):
            self.module.resolve_permission_policy(self.codex_home)

    def test_permission_policy_conflict_fails_closed(self) -> None:
        self.write_permission_config()
        (self.codex_home / "policy.json").write_text(
            json.dumps(
                {
                    "approvalPolicy": "on-request",
                    "sandboxPolicy": {"type": "workspaceWrite"},
                }
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(self.module.StatePolicyError, "conflict"):
            self.module.resolve_permission_policy(self.codex_home)

    def test_run_policy_missing_permission_source_fails_closed(self) -> None:
        (self.codex_home / "config.toml").unlink()
        (self.codex_home / "policy.json").unlink()
        (self.codex_home / "state-policy.json").unlink()
        self.write_global(self.permission_drift())
        output = io.StringIO()

        payload = self.module.run_policy(
            self.codex_home,
            check_only=True,
            health_root=self.root / "health",
            output=output,
        )

        self.assertFalse(payload["ok"])
        self.assertFalse(payload["converged"])
        self.assertTrue(payload["errors"])
        self.assertEqual(payload["globalState"]["status"], "not-run")

    def test_heartbeat_and_sqlite_use_resolved_permission_policy(self) -> None:
        self.write_permission_config(approval_policy="on-request", sandbox_mode="workspace-write")
        policy = self.module.resolve_permission_policy(self.codex_home)
        state = {
            "electron-persisted-atom-state": {
                "heartbeat-thread-permissions-by-id": {
                    "target": {
                        "approvalPolicy": "never",
                        "sandboxPolicy": {"type": "dangerFullAccess"},
                    }
                }
            }
        }

        normalized, summary = self.module.normalize_global_state(
            state,
            permission_policy=policy,
            path_mode="inventory",
        )

        heartbeat = normalized["electron-persisted-atom-state"][
            "heartbeat-thread-permissions-by-id"
        ]["target"]
        self.assertEqual(heartbeat["approvalPolicy"], "on-request")
        self.assertEqual(heartbeat["sandboxPolicy"], {"type": "workspaceWrite"})
        self.assertEqual(summary["heartbeatChangedCount"], 1)

        connection = self.create_db()
        connection.close()
        result = self.module.update_thread_state(
            self.db_path,
            permission_policy=policy,
        )
        self.assertEqual(result["changedCount"], 2)
        verify = sqlite3.connect(self.db_path)
        row = verify.execute(
            "select approval_mode,sandbox_policy from threads where id='target-a'"
        ).fetchone()
        verify.close()
        self.assertEqual(row, ("on-request", '{"type":"workspace-write"}'))

    def test_unresolved_path_preserves_bytes_and_remains_drift(self) -> None:
        self.write_permission_config()
        original = self.write_global(
            {
                "thread-workspace-root-hints": {
                    "missing": r"C:\Users\WINDOWS\Documents\Codex\missing"
                }
            }
        )
        policy = self.module.resolve_permission_policy(self.codex_home)

        result = self.module.update_global_state(
            self.global_path,
            self.backup_root,
            permission_policy=policy,
            path_mode="repair-safe-only",
        )

        self.assertFalse(result["changed"])
        self.assertGreater(result["driftCount"], 0)
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_safe_path_requires_explicit_approved_map(self) -> None:
        self.write_permission_config()
        candidate_root = self.root / "canonical"
        candidate = candidate_root / "safe"
        candidate.mkdir(parents=True)
        state = {
            "thread-workspace-root-hints": {
                "safe": r"C:\Users\WINDOWS\Documents\Codex\safe"
            }
        }
        policy = self.module.resolve_permission_policy(self.codex_home)
        with mock.patch.object(self.module, "CANONICAL_CANDIDATE_ROOT", self.module.PureWindowsPath(str(candidate_root))):
            self.write_global(state)
            no_approval = self.module.update_global_state(
                self.global_path,
                self.backup_root,
                permission_policy=policy,
                path_mode="repair-safe-only",
            )
            self.assertFalse(no_approval["changed"])
            self.assertGreater(no_approval["driftCount"], 0)
            inventory = self.module.build_path_inventory(
                state,
                self.module.PROJECTLESS_SOURCE_ROOT,
                self.module.CANONICAL_CANDIDATE_ROOT,
            )
            approved = self.module.update_global_state(
                self.global_path,
                self.backup_root,
                permission_policy=policy,
                path_mode="repair-safe-only",
                approved_map={
                    "inventoryGeneration": inventory["inventoryGeneration"],
                    "stateSha256": inventory["stateSha256"],
                    "mappingSha256": inventory["mappingSha256"],
                    "mappings": {
                        "thread-workspace-root-hints": {"safe": str(candidate)}
                    },
                },
            )
        self.assertTrue(approved["changed"])
        self.assertEqual(
            json.loads(self.global_path.read_text(encoding="utf-8"))["thread-workspace-root-hints"]["safe"],
            str(candidate),
        )

    def test_approved_map_requires_inventory_generation_and_mapping_hash(self) -> None:
        candidate_root = self.root / "generation-canonical"
        candidate = candidate_root / "safe"
        candidate.mkdir(parents=True)
        state = {
            "thread-workspace-root-hints": {
                "safe": r"C:\Users\WINDOWS\Documents\Codex\safe"
            }
        }
        policy = self.module.resolve_permission_policy(self.codex_home)
        original = self.write_global(state)
        with mock.patch.object(
            self.module,
            "CANONICAL_CANDIDATE_ROOT",
            self.module.PureWindowsPath(str(candidate_root)),
        ):
            with self.assertRaisesRegex(self.module.StatePolicyError, "generation"):
                self.module.update_global_state(
                    self.global_path,
                    self.backup_root,
                    permission_policy=policy,
                    path_mode="repair-safe-only",
                    approved_map={
                        "thread-workspace-root-hints": {"safe": str(candidate)}
                    },
                )

    def test_approved_map_rejects_unknown_contract_fields(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "safe": r"C:\Users\WINDOWS\Documents\Codex\safe"
            }
        }
        policy = self.module.resolve_permission_policy(self.codex_home)
        self.write_global(state)
        inventory = self.module.build_path_inventory(
            state,
            self.module.PROJECTLESS_SOURCE_ROOT,
            self.module.CANONICAL_CANDIDATE_ROOT,
        )
        approved = {
            "inventoryGeneration": inventory["inventoryGeneration"],
            "stateSha256": inventory["stateSha256"],
            "mappingSha256": inventory["mappingSha256"],
            "mappings": {},
            "unexpected": True,
        }
        with self.assertRaisesRegex(self.module.StatePolicyError, "unknown"):
            self.module.update_global_state(
                self.global_path,
                self.backup_root,
                permission_policy=policy,
                path_mode="repair-safe-only",
                approved_map=approved,
            )

    def test_permission_policy_source_change_before_publish_fails_closed(self) -> None:
        state = self.permission_drift()
        original = self.write_global(state)
        policy = self.module.resolve_permission_policy(self.codex_home)

        def change_policy(_attempt: int) -> None:
            self.write_permission_config(approval_policy="on-request")

        with self.assertRaisesRegex(self.module.StatePolicyError, "concurrently"):
            self.module.update_global_state(
                self.global_path,
                self.backup_root,
                permission_policy=policy,
                before_prewrite_check=change_policy,
            )
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_permission_policy_rejects_new_supplemental_source_after_resolution(self) -> None:
        (self.codex_home / "policy.json").unlink()
        (self.codex_home / "state-policy.json").unlink()
        policy = self.module.resolve_permission_policy(self.codex_home)
        (self.codex_home / "policy.json").write_text(
            json.dumps(
                {
                    "approvalPolicy": "never",
                    "sandboxPolicy": {"type": "dangerFullAccess"},
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(self.module.StatePolicyError, "changed|source"):
            self.module._assert_permission_policy_unchanged(policy)

    @unittest.skipUnless(os.name == "nt", "requires Windows reparse-point semantics")
    def test_permission_policy_rejects_dangling_supplemental_reparse_source(self) -> None:
        policy_path = self.codex_home / "policy.json"
        policy_path.unlink(missing_ok=True)
        junction_target = self.root / "policy-target"
        junction_target.mkdir()
        command = (
            "$ErrorActionPreference='Stop';"
            f"New-Item -ItemType Junction -Path '{policy_path}' -Target '{junction_target}' | Out-Null;"
            f"Remove-Item -LiteralPath '{junction_target}' -Force"
        )
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        created = subprocess.run(
            [
                r"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe",
                "-NoProfile",
                "-EncodedCommand",
                encoded,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if created.returncode != 0:
            self.skipTest(created.stderr or created.stdout)
        try:
            with self.assertRaisesRegex(self.module.StatePolicyError, "reparse|policy"):
                self.module.resolve_permission_policy(self.codex_home)
        finally:
            junction_target.mkdir(exist_ok=True)
            if policy_path.exists() or policy_path.is_symlink():
                policy_path.rmdir()
            junction_target.rmdir()

    def test_permission_policy_rejects_forged_values_even_with_source_hashes(self) -> None:
        policy = self.module.resolve_permission_policy(self.codex_home)
        with self.assertRaises(self.module.StatePolicyError):
            self.module.PermissionPolicy(
                "on-request",
                policy.sandbox_mode,
                policy.source,
                policy.source_hashes,
                policy.codex_home,
                policy.source_identities,
                policy.source_values,
            )

    def test_repair_modes_distinguish_safe_only_from_all_approved(self) -> None:
        candidate_root = self.root / "mode-canonical"
        safe_candidate = candidate_root / "safe"
        safe_candidate.mkdir(parents=True)
        state = {
            "thread-workspace-root-hints": {
                "safe": r"C:\Users\WINDOWS\Documents\Codex\safe",
                "missing": r"C:\Users\WINDOWS\Documents\Codex\missing",
            }
        }
        policy = self.module.resolve_permission_policy(self.codex_home)
        original = self.write_global(state)
        with mock.patch.object(
            self.module,
            "CANONICAL_CANDIDATE_ROOT",
            self.module.PureWindowsPath(str(candidate_root)),
        ):
            inventory = self.module.build_path_inventory(
                state,
                self.module.PROJECTLESS_SOURCE_ROOT,
                self.module.CANONICAL_CANDIDATE_ROOT,
            )
            approved = {
                "inventoryGeneration": inventory["inventoryGeneration"],
                "stateSha256": inventory["stateSha256"],
                "mappingSha256": inventory["mappingSha256"],
                "mappings": {
                    "thread-workspace-root-hints": {
                        "safe": str(safe_candidate),
                        "missing": str(candidate_root / "missing"),
                    }
                },
            }
            with self.assertRaisesRegex(self.module.StatePolicyError, "approved"):
                self.module.update_global_state(
                    self.global_path,
                    self.backup_root,
                    permission_policy=policy,
                    path_mode="repair-all-approved",
                    approved_map=approved,
                )
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_all_unresolved_path_kinds_remain_drift(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "alternate": r"\\?\C:\Users\WINDOWS\Documents\Codex\alternate",
                "invalid": r"C:\Users\WINDOWS\Documents\Codex\bad\x00".replace(
                    "\\x00", "\x00"
                ),
                "legacy": r"D:\Users\WINDOWS\Documents\Codex\legacy",
            }
        }
        self.write_global(state)
        result = self.module.update_global_state(
            self.global_path,
            self.backup_root,
            check_only=True,
        )
        self.assertGreaterEqual(result["driftCount"], 3)
        self.assertEqual(self.global_path.read_bytes(), json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode())

    def test_legacy_destination_stays_drift_when_candidate_root_is_unavailable(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "legacy": r"D:\Users\WINDOWS\Documents\Codex\legacy",
                "legacy-alternate": r"\\?\D:\Users\WINDOWS\Documents\Codex\legacy-alternate",
            }
        }
        self.write_global(state)
        result = self.module.update_global_state(
            self.global_path,
            self.backup_root,
            check_only=True,
            candidate_root=r"D:\Documents\Codex\uncontrolled",
        )
        self.assertGreaterEqual(result["driftCount"], 2)

    def test_path_inventory_keeps_lone_surrogate_as_unresolved_evidence(self) -> None:
        value = r"C:\Users\WINDOWS\Documents\Codex\bad" + "\ud800"
        inventory = self.module.build_path_inventory(
            {"thread-workspace-root-hints": {"surrogate": value}},
            self.module.PROJECTLESS_SOURCE_ROOT,
            self.module.CANONICAL_CANDIDATE_ROOT,
        )
        entry = inventory["maps"]["thread-workspace-root-hints"]["surrogate"]
        self.assertFalse(entry["safe"])
        self.assertTrue(str(entry["reason"]).startswith("unresolved-"))
        self.assertRegex(inventory["inventoryGeneration"], r"^inventory-v1-[0-9a-f]{64}$")

    def test_run_policy_rolls_back_json_when_sqlite_domain_fails(self) -> None:
        original = self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        output = io.StringIO()
        with mock.patch.object(
            self.module,
            "update_thread_state",
            side_effect=self.module.StatePolicyError("fixture sqlite failure"),
        ):
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
        self.assertFalse(result["ok"])
        self.assertTrue(
            any(
                marker in result["errors"]
                for marker in ("state policy rollback completed", "unsafe-partial")
            )
        )
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_run_policy_marks_unsafe_partial_when_sqlite_snapshot_changes(self) -> None:
        original = self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()

        def fail_after_sqlite_change(*_args: object, **_kwargs: object) -> None:
            changed = sqlite3.connect(self.db_path)
            changed.execute("update threads set sentinel='competitor' where id='target-a'")
            changed.commit()
            changed.close()
            raise self.module.StatePolicyError("fixture sqlite failure after commit")

        with mock.patch.object(self.module, "update_thread_state", side_effect=fail_after_sqlite_change):
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=io.StringIO(),
            )
        self.assertFalse(result["ok"])
        self.assertIn("unsafe-partial", result["errors"])
        self.assertFalse(result["changed"])
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_run_policy_marks_unknown_wal_snapshot_unsafe_partial(self) -> None:
        original = self.write_global(self.permission_drift())
        keeper = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("wal-unknown", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep"),
            )
            keeper.commit()
            real_capture = self.module._capture_sqlite_source

            def unknown_capture(path: Path):
                snapshot = real_capture(path)
                known = list(snapshot.content_known)
                payload = list(snapshot.payload)
                for index in range(1, 4):
                    if snapshot.identities[index] is not None:
                        known[index] = False
                        payload[index] = None
                return self.module.SqliteSourceSnapshot(
                    payload=tuple(payload),
                    identities=snapshot.identities,
                    metadata=snapshot.metadata,
                    content_known=tuple(known),
                )

            with mock.patch.object(self.module, "_capture_sqlite_source", side_effect=unknown_capture):
                with mock.patch.object(
                    self.module,
                    "update_thread_state",
                    side_effect=self.module.StatePolicyError("fixture sqlite failure with unknown WAL"),
                ):
                    result = self.module.run_policy(
                        self.codex_home,
                        check_only=False,
                        health_root=self.root / "health",
                        output=io.StringIO(),
                    )
            self.assertFalse(result["ok"])
            self.assertFalse(result["changed"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(result["globalState"]["status"], "not-run")
            self.assertEqual(self.global_path.read_bytes(), original)
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_reports_global_publish_claim_when_postcheck_fails(self) -> None:
        original = self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        real_inventory = self.module.build_path_inventory
        calls = 0

        def fail_after_publish(*args: object, **kwargs: object) -> dict[str, object]:
            nonlocal calls
            calls += 1
            if calls >= 2:
                raise RuntimeError("fixture post-publish inventory failure")
            return real_inventory(*args, **kwargs)

        with mock.patch.object(self.module, "build_path_inventory", side_effect=fail_after_publish):
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=io.StringIO(),
            )

        self.assertFalse(result["ok"])
        self.assertFalse(result["changed"])
        self.assertEqual(result["globalState"]["status"], "not-run")
        self.assertIn("unsafe-partial", result["errors"])
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_run_policy_missing_state_domain_fails_closed(self) -> None:
        output = io.StringIO()
        result = self.module.run_policy(
            self.codex_home,
            check_only=True,
            health_root=self.root / "health",
            output=output,
        )
        self.assertFalse(result["ok"])
        self.assertFalse(result["converged"])
        self.assertEqual(result["globalState"]["status"], "not-run")

    def test_stdout_redaction_drops_map_and_unknown_keys(self) -> None:
        self.write_global(
            {
                "thread-workspace-root-hints": {
                    "secret-thread-id": r"C:\Users\WINDOWS\Documents\Codex\missing"
                },
                "secret-unknown-map": {"private": "value"},
            }
        )
        output = io.StringIO()
        self.module.run_policy(
            self.codex_home,
            check_only=True,
            health_root=self.root / "health",
            output=output,
        )
        text = output.getvalue()
        self.assertNotIn("thread-workspace-root-hints", text)
        self.assertNotIn("secret-thread-id", text)
        self.assertNotIn("secret-unknown-map", text)

    def test_nested_permission_policy_shape_is_malformed(self) -> None:
        (self.codex_home / "policy.json").write_text(
            json.dumps({"permissionPolicy": "not-an-object"}),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(self.module.StatePolicyError, "malformed"):
            self.module.resolve_permission_policy(self.codex_home)

    def test_empty_supplemental_permission_source_fails_closed(self) -> None:
        (self.codex_home / "policy.json").write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(self.module.StatePolicyError, "policy"):
            self.module.resolve_permission_policy(self.codex_home)

    def test_explicit_permission_policy_cannot_cross_codex_home(self) -> None:
        policy = self.module.resolve_permission_policy(self.codex_home)
        other_home = self.root / "other-codex-home"
        other_home.mkdir()
        other_db = other_home / "state_5.sqlite"
        other_db.write_bytes(b"not-a-database")
        with self.assertRaisesRegex(self.module.StatePolicyError, "home|source"):
            self.module._resolve_policy_for_path(other_db, policy)

    def test_select_thread_updates_preserves_unknown_rows(self) -> None:
        conn = self.create_db()
        try:
            policy = self.module.resolve_permission_policy(self.codex_home)
            self.assertEqual(self.module.select_thread_updates(conn, policy), ["target-a", "target-null"])
        finally:
            conn.close()

    def test_global_writer_replays_latest_competitor_state(self) -> None:
        original_state = self.permission_drift()
        original_state["thread-workspace-root-hints"] = {
            "x": r"C:\Users\WINDOWS\Documents\Codex\a"
        }
        original = self.write_global(original_state)
        competitor = {
            "thread-workspace-root-hints": {"x": r"C:\Users\WINDOWS\Documents\Codex\a"},
            "competitorSentinel": "keep",
        }
        competitor.update(self.permission_drift())
        calls = 0

        def race(_attempt: int) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                self.global_path.write_text(json.dumps(competitor), encoding="utf-8")

        result = self.module.update_global_state(
            self.global_path, self.backup_root, before_prewrite_check=race
        )
        self.assertTrue(result["changed"])
        self.assertGreaterEqual(result["attempts"], 2)
        after = json.loads(self.global_path.read_text(encoding="utf-8"))
        self.assertEqual(after["competitorSentinel"], "keep")
        self.assertTrue(after["thread-workspace-root-hints"]["x"].startswith("C:"))
        self.assertNotEqual(hashlib.sha256(original).hexdigest(), result["afterSha256"])

    def test_global_writer_never_overwrites_unstable_competitor(self) -> None:
        state = self.permission_drift()
        state["thread-workspace-root-hints"] = {
            "x": r"C:\Users\WINDOWS\Documents\Codex\a"
        }
        self.write_global(state)
        latest = b""

        def race(attempt: int) -> None:
            nonlocal latest
            latest_state = self.permission_drift()
            latest_state.update(
                {
                    "competitor": attempt,
                    "thread-workspace-root-hints": {
                        "x": r"C:\Users\WINDOWS\Documents\Codex\a"
                    },
                }
            )
            latest = json.dumps(latest_state).encode()
            self.global_path.write_bytes(latest)

        with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent"):
            self.module.update_global_state(
                self.global_path, self.backup_root, before_prewrite_check=race
            )
        self.assertEqual(self.global_path.read_bytes(), latest)

    def test_global_writer_rejects_same_bytes_competitor_by_handle_identity(self) -> None:
        state = self.permission_drift()
        state["thread-workspace-root-hints"] = {
            "x": r"C:\Users\WINDOWS\Documents\Codex\a"
        }
        original = self.write_global(state)

        def replace_with_same_bytes(_attempt: int) -> None:
            competitor_path = self.root / "same-bytes-competitor.json"
            competitor_path.write_bytes(original)
            os.replace(competitor_path, self.global_path)

        with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent"):
            self.module.update_global_state(
                self.global_path,
                self.backup_root,
                before_prewrite_check=replace_with_same_bytes,
            )
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_global_publish_rechecks_bytes_on_same_target_handle(self) -> None:
        original = self.write_global(self.permission_drift())
        target_identity = self.module._file_handle_identity(self.global_path)
        self.assertIsNotNone(target_identity)
        temporary = self.module._write_same_directory_temp(self.global_path, b"replacement")
        try:
            with mock.patch.object(
                self.module,
                "_read_publish_handle_bytes",
                side_effect=[original, b"changed-by-existing-writer"],
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent"):
                    self.module._publish_temp_file(
                        self.global_path,
                        temporary,
                        expected_hash=hashlib.sha256(original).hexdigest(),
                        expected_identity=target_identity,
                    )
        finally:
            temporary.unlink(missing_ok=True)
        self.assertEqual(self.global_path.read_bytes(), original)

    @unittest.skipUnless(os.name == "nt", "requires Windows handle-bound publish")
    def test_global_publish_rejects_competitor_rename_after_final_handle_read(self) -> None:
        original = self.write_global(self.permission_drift())
        target_identity = self.module._file_handle_identity(self.global_path)
        self.assertIsNotNone(target_identity)
        temporary = self.module._write_same_directory_temp(self.global_path, b"replacement")
        original_info = self.module._publish_handle_info
        target_info_calls = 0

        def competitor_rename(kernel32: object, handle: object, target: Path) -> tuple[int, int]:
            nonlocal target_info_calls
            if target == self.global_path:
                target_info_calls += 1
                if target_info_calls >= 2:
                    raise self.module.StatePolicyError("state publish target changed concurrently")
            return original_info(kernel32, handle, target)

        try:
            with mock.patch.object(self.module, "_publish_handle_info", side_effect=competitor_rename):
                with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent"):
                    self.module._publish_temp_file(
                        self.global_path,
                        temporary,
                        expected_hash=hashlib.sha256(original).hexdigest(),
                        expected_identity=target_identity,
                    )
        finally:
            temporary.unlink(missing_ok=True)
        self.assertEqual(self.global_path.read_bytes(), original)

    @unittest.skipUnless(os.name == "nt", "requires Windows handle-bound publish")
    def test_global_publish_preserves_delete_recreate_competitor_after_final_read(self) -> None:
        original = self.write_global(self.permission_drift())
        target_identity = self.module._file_handle_identity(self.global_path)
        self.assertIsNotNone(target_identity)
        temporary = self.module._write_same_directory_temp(self.global_path, b"replacement")
        original_read = self.module._read_publish_handle_bytes
        calls = 0

        def delete_and_recreate(kernel32: object, handle: object) -> bytes:
            nonlocal calls
            calls += 1
            data = original_read(kernel32, handle)
            if calls == 3:
                self.global_path.unlink()
                self.global_path.write_bytes(b"competitor")
            return data

        try:
            with mock.patch.object(self.module, "_read_publish_handle_bytes", side_effect=delete_and_recreate):
                with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent"):
                    self.module._publish_temp_file(
                        self.global_path,
                        temporary,
                        expected_hash=hashlib.sha256(original).hexdigest(),
                        expected_identity=target_identity,
                    )
        finally:
            temporary.unlink(missing_ok=True)
        self.assertEqual(self.global_path.read_bytes(), b"competitor")

    @unittest.skipUnless(os.name == "nt", "requires Windows handle-bound publish")
    def test_global_publish_restores_original_when_hostile_deletes_lease_backup(self) -> None:
        original = self.write_global(self.permission_drift())
        target_identity = self.module._file_handle_identity(self.global_path)
        self.assertIsNotNone(target_identity)
        temporary = self.module._write_same_directory_temp(self.global_path, b"replacement")
        original_move = self.module._move_path_by_name

        def delete_lease_after_move(source: Path, target: Path, *, replace_if_exists: bool) -> None:
            original_move(source, target, replace_if_exists=replace_if_exists)
            if target.name.endswith(".lease"):
                target.unlink(missing_ok=True)

        try:
            with mock.patch.object(self.module, "_move_path_by_name", side_effect=delete_lease_after_move):
                with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent|lease"):
                    self.module._publish_temp_file(
                        self.global_path,
                        temporary,
                        expected_hash=hashlib.sha256(original).hexdigest(),
                        expected_identity=target_identity,
                    )
        finally:
            temporary.unlink(missing_ok=True)
        self.assertEqual(self.global_path.read_bytes(), original)

    @unittest.skipUnless(os.name == "nt", "requires Windows handle-bound publish")
    def test_global_publish_keeps_snapshot_when_competitor_replaces_target_during_recovery(self) -> None:
        original = self.write_global(self.permission_drift())
        target_identity = self.module._file_handle_identity(self.global_path)
        self.assertIsNotNone(target_identity)
        temporary = self.module._write_same_directory_temp(self.global_path, b"replacement")
        original_move = self.module._move_path_by_name

        def delete_lease_and_create_competitor(source: Path, target: Path, *, replace_if_exists: bool) -> None:
            original_move(source, target, replace_if_exists=replace_if_exists)
            if target.name.endswith(".lease"):
                target.unlink(missing_ok=True)
                self.global_path.write_bytes(b"competitor")

        try:
            with mock.patch.object(
                self.module,
                "_move_path_by_name",
                side_effect=delete_lease_and_create_competitor,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent|lease"):
                    self.module._publish_temp_file(
                        self.global_path,
                        temporary,
                        expected_hash=hashlib.sha256(original).hexdigest(),
                        expected_identity=target_identity,
                    )
            self.assertEqual(self.global_path.read_bytes(), b"competitor")
            snapshots = list(self.global_path.parent.glob(f".{self.global_path.name}.*.snapshot"))
            self.assertTrue(snapshots)
            self.assertIn(original, [snapshot.read_bytes() for snapshot in snapshots])
        finally:
            temporary.unlink(missing_ok=True)
            for snapshot in self.global_path.parent.glob(f".{self.global_path.name}.*.snapshot"):
                snapshot.unlink(missing_ok=True)

    @unittest.skipUnless(os.name == "nt", "requires Windows handle-bound publish")
    def test_global_publish_keeps_lease_and_snapshot_when_lease_bytes_change(self) -> None:
        original = self.write_global(self.permission_drift())
        target_identity = self.module._file_handle_identity(self.global_path)
        self.assertIsNotNone(target_identity)
        temporary = self.module._write_same_directory_temp(self.global_path, b"replacement")
        original_move = self.module._move_path_by_name

        def pass_through_move(source: Path, target: Path, *, replace_if_exists: bool) -> None:
            original_move(source, target, replace_if_exists=replace_if_exists)

        original_read_bytes = Path.read_bytes

        def tampered_read(path: Path) -> bytes:
            if path.name.endswith(".lease"):
                return b"tampered-lease"
            return original_read_bytes(path)

        try:
            with mock.patch.object(self.module, "_move_path_by_name", side_effect=pass_through_move):
                with mock.patch.object(Path, "read_bytes", autospec=True, side_effect=tampered_read):
                    self.module._publish_temp_file(
                        self.global_path,
                        temporary,
                        expected_hash=hashlib.sha256(original).hexdigest(),
                        expected_identity=target_identity,
                    )
            leases = list(self.global_path.parent.glob(f".{self.global_path.name}.*.lease"))
            snapshots = list(self.global_path.parent.glob(f".{self.global_path.name}.*.snapshot"))
            self.assertTrue(leases)
            self.assertTrue(snapshots)
            self.assertIn(original, [snapshot.read_bytes() for snapshot in snapshots])
        finally:
            temporary.unlink(missing_ok=True)
            for artifact in self.global_path.parent.glob(f".{self.global_path.name}.*.lease"):
                artifact.unlink(missing_ok=True)
            for artifact in self.global_path.parent.glob(f".{self.global_path.name}.*.snapshot"):
                artifact.unlink(missing_ok=True)

    def test_sqlite_snapshot_binds_identity_for_same_bytes_replay(self) -> None:
        connection = self.create_db()
        connection.close()
        original = self.db_path.read_bytes()
        before = self.module._capture_sqlite_source(self.db_path)
        competitor = self.root / "same-bytes-state.sqlite"
        competitor.write_bytes(original)
        os.replace(competitor, self.db_path)
        after = self.module._capture_sqlite_source(self.db_path)
        self.assertEqual(tuple(before), tuple(after))
        self.assertNotEqual(before, after)

    def test_sqlite_snapshot_binds_sidecar_identity_for_same_bytes_replay(self) -> None:
        connection = self.create_db()
        connection.close()
        for suffix in ("-wal", "-shm", "-journal"):
            sidecar = Path(str(self.db_path) + suffix)
            sidecar.write_bytes(b"fixture-sidecar")
        try:
            before = self.module._capture_sqlite_source(self.db_path)
            replaced: list[str] = []
            for suffix in ("-wal", "-shm", "-journal"):
                sidecar = Path(str(self.db_path) + suffix)
                competitor = self.root / ("same-bytes" + suffix)
                competitor.write_bytes(sidecar.read_bytes())
                for _attempt in range(3):
                    try:
                        os.replace(competitor, sidecar)
                        replaced.append(suffix)
                        break
                    except PermissionError:
                        if _attempt == 2:
                            competitor.unlink(missing_ok=True)
            after = self.module._capture_sqlite_source(self.db_path)
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)
        self.assertEqual(tuple(before), tuple(after))
        self.assertTrue(replaced)
        self.assertNotEqual(before, after)

    def test_sqlite_snapshot_rejects_same_inode_sidecar_byte_mutation(self) -> None:
        connection = self.create_db()
        connection.close()
        sidecar = Path(str(self.db_path) + "-wal")
        sidecar.write_bytes(b"sidecar-original")
        try:
            before = self.module._capture_sqlite_source(self.db_path)
            identity = self.module._file_handle_identity(sidecar)
            sidecar.write_bytes(b"sidecar-mutated")
            after = self.module._capture_sqlite_source(self.db_path)
            self.assertEqual(before.identities[1], identity)
            self.assertNotEqual(before.payload[1], after.payload[1])
            with self.assertRaisesRegex(self.module.StatePolicyError, "sidecar|concurrent"):
                self.module._assert_sqlite_snapshot_identity(
                    before,
                    self.db_path,
                    allow_new_sidecars=False,
                    check_sidecar_content=True,
                )
        finally:
            sidecar.unlink(missing_ok=True)

    def test_sqlite_update_rejects_lexical_connection_to_competitor(self) -> None:
        connection = self.create_db()
        connection.close()
        competitor = self.root / "competitor.sqlite"
        shutil.copy2(self.db_path, competitor)
        original_connect = self.module.sqlite3.connect

        def connect_competitor(*_args: object, **_kwargs: object) -> sqlite3.Connection:
            return original_connect(competitor, timeout=1.5)

        with mock.patch.object(self.module.sqlite3, "connect", side_effect=connect_competitor):
            with self.assertRaisesRegex(self.module.StatePolicyError, "source|path|concurrent"):
                self.module.update_thread_state(self.db_path)
        verify = sqlite3.connect(self.db_path)
        self.assertEqual(
            verify.execute("select approval_mode from threads where id='target-a'").fetchone()[0],
            "on-request",
        )
        verify.close()

    def test_sqlite_update_rechecks_sidecar_generation_before_commit(self) -> None:
        connection = self.create_db()
        connection.close()
        original_capture = self.module._capture_sqlite_source
        original_assert = self.module._assert_sqlite_snapshot_identity
        assert_calls = 0
        mutate_next_capture = False

        def race_capture(path: Path):
            nonlocal mutate_next_capture
            snapshot = original_capture(path)
            payload = list(snapshot.payload)
            identities = list(snapshot.identities)
            metadata = list(snapshot.metadata)
            if payload[1] is None:
                payload[1] = b"synthetic-sidecar"
                identities[1] = (1, 999)
                exists, _size, _mtime, parent_identity = metadata[1]
                metadata[1] = (True, len(payload[1]), 1, parent_identity)
            if mutate_next_capture:
                mutate_next_capture = False
                payload[1] = bytes([(payload[1][0] ^ 0x01) if payload[1] else 1]) + payload[1][1:]
                exists, size, mtime, parent_identity = metadata[1]
                metadata[1] = (exists, size, (mtime or 0) + 1, parent_identity)
            return self.module.SqliteSourceSnapshot(
                payload=tuple(payload),
                identities=tuple(identities),
                metadata=tuple(metadata),
            )

        def race_assert(*args: object, **kwargs: object):
            nonlocal assert_calls, mutate_next_capture
            assert_calls += 1
            result = original_assert(*args, **kwargs)
            if assert_calls == 4:
                mutate_next_capture = True
            return result

        with mock.patch.object(self.module, "_capture_sqlite_source", side_effect=race_capture):
            with mock.patch.object(
                self.module,
                "_assert_sqlite_snapshot_identity",
                side_effect=race_assert,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "sidecar|concurrent"):
                    self.module.update_thread_state(self.db_path)

    def test_sqlite_update_rejects_sidecar_after_final_precommit_gate(self) -> None:
        connection = self.create_db()
        connection.close()
        original_assert = self.module._assert_sqlite_snapshot_identity
        assert_calls = 0

        def race_assert(*args: object, **kwargs: object):
            nonlocal assert_calls
            assert_calls += 1
            result = original_assert(*args, **kwargs)
            if assert_calls == 5:
                Path(str(self.db_path) + "-wal").write_bytes(b"late-sidecar")
            return result

        try:
            with mock.patch.object(
                self.module,
                "_assert_sqlite_snapshot_identity",
                side_effect=race_assert,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "sidecar|concurrent"):
                    self.module.update_thread_state(self.db_path)
            self.assertGreaterEqual(assert_calls, 6)
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_global_policy_source_change_after_final_assert_fails_closed(self) -> None:
        original = self.write_global(self.permission_drift())
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_assert = self.module._assert_permission_policy_unchanged
        calls = 0

        def stale_assert(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_assert(current_policy)
            if calls == 1:
                self.write_permission_config(approval_policy="on-request")

        with mock.patch.object(self.module, "_assert_permission_policy_unchanged", side_effect=stale_assert):
            with self.assertRaisesRegex(self.module.StatePolicyError, "policy|concurrent"):
                self.module.update_global_state(
                    self.global_path,
                    self.backup_root,
                    permission_policy=policy,
                )
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_sqlite_policy_source_change_after_select_assert_fails_closed(self) -> None:
        connection = self.create_db()
        connection.close()
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_assert = self.module._assert_permission_policy_unchanged
        calls = 0

        def stale_assert(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_assert(current_policy)
            if calls == 2:
                self.write_permission_config(approval_policy="on-request")

        try:
            with mock.patch.object(self.module, "_assert_permission_policy_unchanged", side_effect=stale_assert):
                with self.assertRaisesRegex(self.module.StatePolicyError, "policy|concurrent"):
                    self.module.update_thread_state(self.db_path, permission_policy=policy)
            verify = sqlite3.connect(self.db_path)
            self.assertEqual(
                verify.execute("select approval_mode from threads where id='target-a'").fetchone()[0],
                "on-request",
            )
            verify.close()
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_global_policy_change_after_publish_is_rolled_back(self) -> None:
        original = self.write_global(self.permission_drift())
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_fingerprint = self.module._assert_permission_policy_fingerprint
        calls = 0

        def race_fingerprint(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_fingerprint(current_policy)
            # Call three is the fingerprint inside _publish_temp_file, after
            # the target lease is verified and immediately before MoveFile.
            if calls == 3:
                self.write_permission_config(approval_policy="on-request")

        with mock.patch.object(
            self.module,
            "_assert_permission_policy_fingerprint",
            side_effect=race_fingerprint,
        ):
            with self.assertRaisesRegex(self.module.StatePolicyError, "policy|rollback"):
                self.module.update_global_state(
                    self.global_path,
                    self.backup_root,
                    permission_policy=policy,
                )
        self.assertGreaterEqual(calls, 3)
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_sqlite_policy_change_after_commit_is_rolled_back(self) -> None:
        connection = self.create_db()
        connection.close()
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_fingerprint = self.module._assert_permission_policy_fingerprint
        calls = 0

        def race_fingerprint(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_fingerprint(current_policy)
            # Call three is the last precommit fingerprint.  Mutating after it
            # forces the postcommit policy gate to reverse the committed rows.
            if calls == 3:
                self.write_permission_config(approval_policy="on-request")

        try:
            with mock.patch.object(
                self.module,
                "_assert_permission_policy_fingerprint",
                side_effect=race_fingerprint,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "policy|rollback"):
                    self.module.update_thread_state(
                        self.db_path,
                        permission_policy=policy,
                    )
            self.assertGreaterEqual(calls, 3)
            verify = sqlite3.connect(self.db_path)
            self.assertEqual(
                verify.execute("select approval_mode from threads where id='target-a'").fetchone()[0],
                "on-request",
            )
            self.assertEqual(
                verify.execute("select sandbox_policy from threads where id='target-a'").fetchone()[0],
                '{"type":"workspace-write"}',
            )
            verify.close()
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_global_policy_change_after_postpublish_check_is_rolled_back(self) -> None:
        original = self.write_global(self.permission_drift())
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_fingerprint = self.module._assert_permission_policy_fingerprint
        calls = 0

        def race_fingerprint(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_fingerprint(current_policy)
            # Call four is the post-publish check.  Mutate after it returns so
            # the final return gate must detect and reverse the publication.
            if calls == 4:
                self.write_permission_config(approval_policy="on-request")

        with mock.patch.object(
            self.module,
            "_assert_permission_policy_fingerprint",
            side_effect=race_fingerprint,
        ):
            with self.assertRaisesRegex(self.module.StatePolicyError, "policy|rollback"):
                self.module.update_global_state(
                    self.global_path,
                    self.backup_root,
                    permission_policy=policy,
                )
        self.assertGreaterEqual(calls, 4)
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_sqlite_policy_change_after_postcommit_check_is_rolled_back(self) -> None:
        connection = self.create_db()
        connection.close()
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_fingerprint = self.module._assert_permission_policy_fingerprint
        calls = 0

        def race_fingerprint(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_fingerprint(current_policy)
            if calls == 4:
                self.write_permission_config(approval_policy="on-request")

        try:
            with mock.patch.object(
                self.module,
                "_assert_permission_policy_fingerprint",
                side_effect=race_fingerprint,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "policy|rollback"):
                    self.module.update_thread_state(
                        self.db_path,
                        permission_policy=policy,
                    )
            self.assertGreaterEqual(calls, 4)
            verify = sqlite3.connect(self.db_path)
            self.assertEqual(
                verify.execute("select approval_mode from threads where id='target-a'").fetchone()[0],
                "on-request",
            )
            verify.close()
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_global_target_lease_rejects_competitor_after_final_policy_check(self) -> None:
        original = self.write_global(self.permission_drift())
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_fingerprint = self.module._assert_permission_policy_fingerprint
        calls = 0

        def race_fingerprint(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_fingerprint(current_policy)
            if calls == 5:
                competitor = self.root / "global-competitor.json"
                competitor.write_bytes(b'{"competitor":true}')
                try:
                    os.replace(competitor, self.global_path)
                except PermissionError as exc:
                    raise self.module.StatePolicyError(
                        "global target lease blocked competitor"
                    ) from exc

        with mock.patch.object(
            self.module,
            "_assert_permission_policy_fingerprint",
            side_effect=race_fingerprint,
        ):
            with self.assertRaisesRegex(self.module.StatePolicyError, "target|rollback"):
                self.module.update_global_state(
                    self.global_path,
                    self.backup_root,
                    permission_policy=policy,
                )
        self.assertGreaterEqual(calls, 5)
        self.assertNotEqual(self.global_path.read_bytes(), b'{"competitor":true}')
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_sqlite_target_lease_rejects_competitor_after_final_policy_check(self) -> None:
        connection = self.create_db()
        connection.close()
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_fingerprint = self.module._assert_permission_policy_fingerprint
        calls = 0

        def race_fingerprint(current_policy: object) -> None:
            nonlocal calls
            calls += 1
            original_fingerprint(current_policy)
            if calls == 5:
                competitor = sqlite3.connect(self.db_path, timeout=0)
                try:
                    competitor.execute(
                        "update threads set approval_mode='on-request' where id='target-a'"
                    )
                    competitor.commit()
                except sqlite3.OperationalError as exc:
                    raise self.module.StatePolicyError(
                        "sqlite target lease blocked competitor"
                    ) from exc
                finally:
                    competitor.close()

        try:
            with mock.patch.object(
                self.module,
                "_assert_permission_policy_fingerprint",
                side_effect=race_fingerprint,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "target|rollback"):
                    self.module.update_thread_state(
                        self.db_path,
                        permission_policy=policy,
                    )
            self.assertGreaterEqual(calls, 5)
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_sqlite_write_fails_closed_when_sidecar_content_is_unknown(self) -> None:
        connection = self.create_db()
        connection.close()
        original_capture = self.module._capture_sqlite_source

        def unavailable(path: Path):
            snapshot = original_capture(path)
            known = list(snapshot.content_known)
            payload = list(snapshot.payload)
            payload[1] = b"synthetic-wal"
            known[1] = False
            return self.module.SqliteSourceSnapshot(
                payload=tuple(payload),
                identities=snapshot.identities,
                metadata=snapshot.metadata,
                content_known=tuple(known),
            )

        try:
            with mock.patch.object(self.module, "_capture_sqlite_source", side_effect=unavailable):
                with self.assertRaisesRegex(self.module.StatePolicyError, "sidecar|unavailable"):
                    self.module.update_thread_state(self.db_path)
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_rejects_global_competitor_before_success_envelope(self) -> None:
        original = self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        original_update = self.module.update_global_state

        def update_then_replace(*args: object, **kwargs: object):
            result = original_update(*args, **kwargs)
            competitor = self.root / "run-policy-global-competitor.json"
            competitor.write_bytes(b'{"competitor":true}')
            os.replace(competitor, self.global_path)
            return result

        with mock.patch.object(self.module, "update_global_state", side_effect=update_then_replace):
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=io.StringIO(),
            )
        self.assertFalse(result["ok"])
        self.assertIn("unsafe-partial", result["errors"])
        self.assertEqual(result["threadState"]["status"], "not-run")
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_run_policy_rejects_sqlite_competitor_before_success_envelope(self) -> None:
        self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        original_update = self.module.update_thread_state

        def update_then_mutate(*args: object, **kwargs: object):
            result = original_update(*args, **kwargs)
            competitor = sqlite3.connect(self.db_path)
            try:
                competitor.execute(
                    "update threads set approval_mode='on-request' where id='target-a'"
                )
                competitor.commit()
            finally:
                competitor.close()
            return result

        try:
            with mock.patch.object(self.module, "update_thread_state", side_effect=update_then_mutate):
                result = self.module.run_policy(
                    self.codex_home,
                    check_only=False,
                    health_root=self.root / "health",
                    output=io.StringIO(),
                )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_holds_policy_lease_after_thread_update(self) -> None:
        self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        original_update = self.module.update_thread_state

        def update_then_change_policy(*args: object, **kwargs: object):
            result = original_update(*args, **kwargs)
            self.write_permission_config(approval_policy="on-request")
            return result

        with mock.patch.object(self.module, "update_thread_state", side_effect=update_then_change_policy):
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=io.StringIO(),
            )
        self.assertFalse(result["ok"])
        self.assertIn("unsafe-partial", result["errors"])

    def test_run_policy_rejects_new_sqlite_sidecar_after_thread_update(self) -> None:
        self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        original_update = self.module.update_thread_state

        def update_then_sidecar(*args: object, **kwargs: object):
            result = original_update(*args, **kwargs)
            Path(str(self.db_path) + "-wal").write_bytes(b"late-sidecar")
            return result

        try:
            with mock.patch.object(self.module, "update_thread_state", side_effect=update_then_sidecar):
                result = self.module.run_policy(
                    self.codex_home,
                    check_only=False,
                    health_root=self.root / "health",
                    output=io.StringIO(),
                )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    @unittest.skipUnless(os.name == "nt", "requires Windows missing-sidecar leases")
    def test_missing_sidecar_create_new_preserves_competing_journal(self) -> None:
        journal_path = Path(str(self.db_path) + "-journal")
        original = b"journal-created-in-race"
        journal_path.write_bytes(original)
        with self.assertRaisesRegex(self.module.StatePolicyError, "missing sidecar"):
            self.module._open_missing_sidecar_handle(journal_path)
        self.assertEqual(journal_path.read_bytes(), original)

    def test_run_policy_wal_cold_start_succeeds_with_reserved_journal_lease(self) -> None:
        self.write_global(self.permission_drift())
        keeper = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            keeper.executemany(
                "insert into threads values (?,?,?,?,?,?)",
                [
                    ("target-a", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep-a"),
                    ("target-null", "vscode", "user", None, None, "keep-null"),
                ],
            )
            keeper.commit()
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=io.StringIO(),
            )
            self.assertTrue(result["ok"])
            self.assertNotIn("generation-unbounded", result["errors"])
            self.assertNotIn("unsafe-partial", result["errors"])
            self.assertEqual(result["threadState"]["status"], "updated")
            self.assertEqual(
                keeper.execute("select approval_mode from threads where id='target-a'").fetchone()[0],
                "never",
            )
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_rejects_wal_mutation_during_output(self) -> None:
        self.write_global(self.permission_drift())
        keeper = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("target-a", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep-a"),
            )
            keeper.commit()
            wal_path = Path(str(self.db_path) + "-wal")

            class MutatingOutput(io.StringIO):
                mutated = False

                def write(self, value: str) -> int:
                    if not self.mutated:
                        self.mutated = True
                        wal_path.write_bytes(b"corrupted-wal")
                    return super().write(value)

            output = MutatingOutput()
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_rejects_main_sqlite_mutation_during_output(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()

        class MainOutput(io.StringIO):
            mutated = False

            def write(self, value: str) -> int:
                if not self.mutated:
                    self.mutated = True
                    self.db_path.write_bytes(b"corrupted-main")
                return super().write(value)

        output = MainOutput()
        output.db_path = self.db_path
        try:
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    @unittest.skipUnless(os.name == "nt", "requires Windows byte-range leases")
    def test_run_policy_rejects_shm_lock_byte_mutation_during_output(self) -> None:
        """Keep SQLite's writer lock across output; never use a close-to-lock handoff."""
        for offset in (120, 122, 127):
            with self.subTest(offset=offset):
                self.write_global(self.permission_drift())
                keeper = self.create_wal_db()
                keeper.execute("update threads set sentinel='shm-lock-seed' where id='target-a'")
                keeper.commit()
                shm_path = Path(str(self.db_path) + "-shm")
                original_shm = shm_path.read_bytes()

                class ShmOutput(io.StringIO):
                    mutated = False
                    blocked = False

                    def write(self, value: str) -> int:
                        if not self.mutated and not self.blocked:
                            try:
                                metadata = shm_path.stat()
                                with shm_path.open("r+b") as stream:
                                    stream.seek(offset)
                                    stream.write(b"X")
                                    stream.flush()
                                # Restore observable metadata to prove that the
                                # return gate cannot rely on size/mtime/identity
                                # instead of the SHM lock-window payload.
                                os.utime(
                                    shm_path,
                                    ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
                                )
                                self.mutated = True
                            except OSError:
                                self.blocked = True
                        return super().write(value)

                output = ShmOutput()
                try:
                    result = self.module.run_policy(
                        self.codex_home,
                        check_only=False,
                        health_root=self.root / "health",
                        output=output,
                    )
                finally:
                    keeper.close()
                    if output.mutated:
                        shm_path.write_bytes(original_shm)
                    for suffix in ("-wal", "-shm", "-journal"):
                        Path(str(self.db_path) + suffix).unlink(missing_ok=True)
                    self.db_path.unlink(missing_ok=True)
                self.assertTrue(output.mutated or output.blocked)
                if output.mutated:
                    # SQLite owns byte 120; the other WAL-index lock bytes
                    # may accept a raw callback write.  The metadata return
                    # gate must still reject the generation and rewrite a
                    # fail-closed envelope rather than report success.
                    self.assertFalse(result["ok"], (offset, result, output.getvalue()))
                    self.assertFalse(json.loads(output.getvalue())["ok"])
                else:
                    self.assertTrue(output.blocked, (offset, result, output.getvalue()))
                    self.assertTrue(result["ok"], (offset, result, output.getvalue()))
                    self.assertTrue(json.loads(output.getvalue())["ok"])

    @unittest.skipUnless(os.name == "nt", "requires Windows SHM mapping semantics")
    def test_run_policy_write_requires_observable_shm_lock_window(self) -> None:
        """An unobservable active SHM lock window is a maintenance prerequisite."""
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()
        try:
            original_global = self.global_path.read_bytes()
            with mock.patch.object(
                self.module,
                "_read_sqlite_shm_mapped_bytes",
                side_effect=self.module.StatePolicyError("thread state SHM lock window unavailable"),
            ):
                output = io.StringIO()
                result = self.module.run_policy(
                    self.codex_home,
                    check_only=False,
                    health_root=self.root / "health",
                    output=output,
                )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertFalse(result["converged"])
            self.assertEqual(self.global_path.read_bytes(), original_global)
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    @unittest.skipUnless(os.name == "nt", "requires Windows byte-range leases")
    def test_sqlite_writer_return_lease_keeps_connection_during_wal_shm_output(self) -> None:
        keeper = self.create_wal_db()
        try:
            keeper.execute("update threads set sentinel='lease-seed' where id='target-a'")
            keeper.commit()
            policy = self.module.resolve_permission_policy(self.codex_home)
            result = self.module.update_thread_state(
                self.db_path,
                permission_policy=policy,
                retain_return_lease=True,
            )
            lease = result.get("_returnLease")
            self.assertIsInstance(lease, self.module.SqliteTargetLease)
            self.assertIsNotNone(lease._connection)
            self.assertIsNotNone(lease.expected_snapshot)
            self.assertIsNotNone(lease.expected_snapshot.identities[1])
            self.assertIsNotNone(lease.expected_snapshot.identities[2])
            lease.assert_unchanged(strict_sidecar_content=True)
        finally:
            if isinstance(locals().get("lease"), self.module.SqliteTargetLease):
                lease.close()
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_missing_source_set_emits_single_line_fail_closed(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_db()

        class FailureOutput(io.StringIO):
            writes = 0

            def write(self, value: str) -> int:
                self.writes += 1
                return super().write(value)

        output = FailureOutput()
        try:
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)
        self.assertEqual(output.writes, 1)
        self.assertFalse(result["ok"])
        self.assertIn("generation-unbounded", result["errors"])
        self.assertFalse(json.loads(output.getvalue())["ok"])

    @unittest.skipUnless(os.name == "nt", "requires Windows byte-range leases")
    def test_run_policy_blocks_nonzero_offset_sqlite_write_during_output(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()
        keeper.execute("update threads set sentinel='lease-seed' where id='target-a'")
        keeper.commit()
        original_main = self.db_path.read_bytes()

        class NonzeroOffsetOutput(io.StringIO):
            attempted = False
            blocked = False
            mutated = False

            def write(self, value: str) -> int:
                if not self.attempted:
                    self.attempted = True
                    try:
                        with self.db_path.open("r+b") as stream:
                            stream.seek(1)
                            stream.write(b"X")
                        self.mutated = True
                    except OSError:
                        self.blocked = True
                return super().write(value)

        output = NonzeroOffsetOutput()
        output.db_path = self.db_path
        try:
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
        finally:
            keeper.close()
            if output.mutated:
                self.db_path.write_bytes(original_main)
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)
        self.assertTrue(output.attempted)
        self.assertTrue(output.blocked)
        self.assertTrue(result["ok"])
        self.assertTrue(json.loads(output.getvalue())["ok"])

    @unittest.skipUnless(os.name == "nt", "requires Windows read-only generation leases")
    def test_check_only_blocks_nonzero_offset_sqlite_write_during_output(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_db()
        original_main = self.db_path.read_bytes()

        class CheckOnlyMainOutput(io.StringIO):
            attempted = False
            blocked = False
            mutated = False

            def write(self, value: str) -> int:
                if not self.attempted:
                    self.attempted = True
                    try:
                        with self.db_path.open("r+b") as stream:
                            stream.seek(1)
                            stream.write(b"X")
                        self.mutated = True
                    except OSError:
                        self.blocked = True
                return super().write(value)

        output = CheckOnlyMainOutput()
        output.db_path = self.db_path
        try:
            result = self.module.run_policy(
                self.codex_home,
                check_only=True,
                health_root=self.root / "health",
                output=output,
            )
        finally:
            keeper.close()
            if output.mutated:
                self.db_path.write_bytes(original_main)
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)
        self.assertTrue(output.attempted)
        self.assertTrue(output.blocked)
        self.assertFalse(output.mutated)
        self.assertTrue(result["ok"])
        self.assertTrue(json.loads(output.getvalue())["ok"])

    @unittest.skipUnless(os.name == "nt", "requires Windows read-only generation leases")
    def test_check_only_blocks_sqlite_row_mutation_during_output(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_db()

        class CheckOnlyRowOutput(io.StringIO):
            attempted = False
            blocked = False
            mutated = False

            def write(self, value: str) -> int:
                if not self.attempted:
                    self.attempted = True
                    competitor = sqlite3.connect(self.db_path, timeout=0)
                    try:
                        competitor.execute(
                            "update threads set sentinel='competitor' where id='target-a'"
                        )
                        competitor.commit()
                        self.mutated = True
                    except sqlite3.Error:
                        self.blocked = True
                    finally:
                        try:
                            competitor.close()
                        except sqlite3.Error:
                            self.blocked = True
                return super().write(value)

        output = CheckOnlyRowOutput()
        output.db_path = self.db_path
        try:
            result = self.module.run_policy(
                self.codex_home,
                check_only=True,
                health_root=self.root / "health",
                output=output,
            )
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)
        self.assertTrue(output.attempted)
        self.assertTrue(output.blocked or not result["ok"])
        if output.mutated:
            self.assertFalse(result["ok"])

    @unittest.skipUnless(os.name == "nt", "requires Windows read-only generation leases")
    def test_read_only_sqlite_lease_rejects_unknown_shm_content(self) -> None:
        keeper = self.create_wal_db()
        keeper.execute("update threads set sentinel='lease-seed' where id='target-a'")
        keeper.commit()
        policy = self.module.resolve_permission_policy(self.codex_home)
        expected = self.module._capture_sqlite_source(self.db_path)
        lease = self.module.SqliteTargetLease(
            self.db_path,
            expected_identity=self.module._file_handle_identity(self.db_path),
            permission_policy=policy,
            expected_snapshot=expected,
            read_only=True,
        )

        original_capture = self.module._capture_sqlite_source

        def unavailable(path: Path, *args: object, **kwargs: object):
            snapshot = original_capture(path, *args, **kwargs)
            known = list(snapshot.content_known)
            payload = list(snapshot.payload)
            known[2] = False
            payload[2] = None
            return self.module.SqliteSourceSnapshot(
                payload=tuple(payload),
                identities=snapshot.identities,
                metadata=snapshot.metadata,
                content_known=tuple(known),
            )

        try:
            lease.__enter__()
            with mock.patch.object(self.module, "_capture_sqlite_source", side_effect=unavailable):
                with self.assertRaisesRegex(self.module.StatePolicyError, "unavailable"):
                    lease.assert_unchanged(strict_sidecar_content=True)
        finally:
            lease.close()
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    @unittest.skipUnless(os.name == "nt", "requires Windows missing-sidecar leases")
    def test_check_only_rejects_missing_journal_without_placeholder(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()
        keeper.execute("update threads set sentinel='lease-seed' where id='target-a'")
        keeper.commit()
        journal_path = Path(str(self.db_path) + "-journal")
        self.assertFalse(journal_path.exists())
        original_global = self.global_path.read_bytes()
        output = io.StringIO()
        try:
            result = self.module.run_policy(
                self.codex_home,
                check_only=True,
                health_root=self.root / "health",
                output=output,
            )
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)
        self.assertFalse(result["ok"])
        self.assertFalse(result["changed"])
        self.assertFalse(result["converged"])
        self.assertIn("generation-unbounded", result["errors"])
        self.assertIn("repair-required", result["errors"])
        self.assertEqual(self.global_path.read_bytes(), original_global)
        self.assertFalse(journal_path.exists())
        self.assertFalse(json.loads(output.getvalue())["ok"])

    def test_run_policy_rejects_new_sidecar_during_output(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()
        journal_path = Path(str(self.db_path) + "-journal")

        class SidecarOutput(io.StringIO):
            created = False

            def write(self, value: str) -> int:
                if not self.created:
                    self.created = True
                    journal_path.write_bytes(b"late-journal")
                return super().write(value)

        try:
            output = SidecarOutput()
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_rejects_policy_supplemental_created_during_output(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()
        policy_path = self.codex_home / "policy.json"

        class PolicyOutput(io.StringIO):
            created = False

            def write(self, value: str) -> int:
                if not self.created:
                    self.created = True
                    policy_path.write_text(
                        '{"approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite"}}',
                        encoding="utf-8",
                    )
                return super().write(value)

        try:
            output = PolicyOutput()
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            policy_path.unlink(missing_ok=True)

    def test_run_policy_rejects_short_output_write(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()

        class ShortOutput(io.StringIO):
            short = True

            def write(self, value: str) -> int:
                if self.short:
                    self.short = False
                    partial = value[:-1]
                    super().write(partial)
                    return len(partial)
                return super().write(value)

        try:
            output = ShortOutput()
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_rejects_output_exception(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()

        class RaisingOutput(io.StringIO):
            raised = True

            def write(self, value: str) -> int:
                if self.raised:
                    self.raised = False
                    raise OSError("fixture output failure")
                return super().write(value)

        try:
            output = RaisingOutput()
            result = self.module.run_policy(
                self.codex_home,
                check_only=False,
                health_root=self.root / "health",
                output=output,
            )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_rejects_sidecar_created_after_first_return_gate(self) -> None:
        self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        journal_path = Path(str(self.db_path) + "-journal")
        original_assert = self.module.SqliteTargetLease.assert_unchanged
        calls = 0

        def assert_then_create(lease: object, *args: object, **kwargs: object) -> None:
            nonlocal calls
            calls += 1
            original_assert(lease, *args, **kwargs)
            if calls == 2:
                journal_path.write_bytes(b"after-gate-journal")

        try:
            with mock.patch.object(
                self.module.SqliteTargetLease,
                "assert_unchanged",
                new=assert_then_create,
            ):
                output = io.StringIO()
                result = self.module.run_policy(
                    self.codex_home,
                    check_only=False,
                    health_root=self.root / "health",
                    output=output,
                )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
            self.assertIn("generation-unbounded", result["errors"])
            self.assertEqual(calls, 0)
        finally:
            journal_path.unlink(missing_ok=True)

    def test_run_policy_wal_missing_journal_created_after_last_return_gate_is_blocked(self) -> None:
        """A legal WAL cold-start reserves the absent journal name."""
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()
        journal_path = Path(str(self.db_path) + "-journal")
        keeper.execute("update threads set sentinel='wal-gap' where id='target-a'")
        keeper.commit()
        self.assertTrue(Path(str(self.db_path) + "-wal").exists())
        self.assertFalse(journal_path.exists())
        original_assert = self.module.SqliteTargetLease.assert_unchanged
        calls = 0

        blocked = False

        def assert_then_create(lease: object, *args: object, **kwargs: object) -> None:
            nonlocal blocked
            nonlocal calls
            calls += 1
            original_assert(lease, *args, **kwargs)
            # The current implementation has four return-gate calls.  Creating
            # the missing sidecar after the last one reproduces the unbounded
            # generation that the final envelope must not report as success.
            if calls == 4:
                try:
                    journal_path.write_bytes(b"late-journal")
                except OSError:
                    blocked = True

        try:
            with mock.patch.object(
                self.module.SqliteTargetLease,
                "assert_unchanged",
                new=assert_then_create,
            ):
                output = io.StringIO()
                result = self.module.run_policy(
                    self.codex_home,
                    check_only=False,
                    health_root=self.root / "health",
                    output=output,
                )
            self.assertTrue(result["ok"], (calls, result, output.getvalue(), journal_path.exists()))
            self.assertTrue(blocked, (calls, result, output.getvalue(), journal_path.exists()))
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertTrue(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    @unittest.skipUnless(os.name == "nt", "requires Windows reparse-point semantics")
    def test_run_policy_wal_missing_journal_reparse_after_last_return_gate_is_blocked(self) -> None:
        self.write_global(self.permission_drift())
        keeper = self.create_wal_db()
        keeper.execute("update threads set sentinel='wal-reparse' where id='target-a'")
        keeper.commit()
        journal_path = Path(str(self.db_path) + "-journal")
        outside = self.root / "journal-reparse-target"
        outside.mkdir()
        journal_literal = str(journal_path).replace("'", "''")
        outside_literal = str(outside).replace("'", "''")
        command = (
            "$ErrorActionPreference='Stop';"
            f"New-Item -ItemType Junction -Path '{journal_literal}' "
            f"-Target '{outside_literal}' | Out-Null"
        )
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        journal_path.unlink(missing_ok=True)
        original_assert = self.module.SqliteTargetLease.assert_unchanged
        calls = 0

        blocked = False

        def assert_then_create_reparse(lease: object, *args: object, **kwargs: object) -> None:
            nonlocal blocked
            nonlocal calls
            calls += 1
            original_assert(lease, *args, **kwargs)
            if calls == 4:
                created = subprocess.run(
                    [
                        r"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe",
                        "-NoProfile",
                        "-EncodedCommand",
                        encoded,
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                blocked = created.returncode != 0

        try:
            with mock.patch.object(
                self.module.SqliteTargetLease,
                "assert_unchanged",
                new=assert_then_create_reparse,
            ):
                output = io.StringIO()
                result = self.module.run_policy(
                    self.codex_home,
                    check_only=False,
                    health_root=self.root / "health",
                    output=output,
                )
            self.assertTrue(result["ok"])
            self.assertTrue(blocked)
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertTrue(json.loads(output.getvalue())["ok"])
        finally:
            keeper.close()
            if journal_path.exists() or journal_path.is_symlink():
                journal_path.rmdir()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_run_policy_rejects_policy_supplemental_after_first_return_gate(self) -> None:
        self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()
        policy_path = self.codex_home / "policy.json"
        original_assert = self.module.PermissionPolicySourceLease.assert_unchanged
        calls = 0

        def assert_then_create(lease: object, *args: object, **kwargs: object) -> None:
            nonlocal calls
            calls += 1
            original_assert(lease, *args, **kwargs)
            if calls == 5:
                policy_path.write_text(
                    '{"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}',
                    encoding="utf-8",
                )

        try:
            with mock.patch.object(
                self.module.PermissionPolicySourceLease,
                "assert_unchanged",
                new=assert_then_create,
            ):
                output = io.StringIO()
                result = self.module.run_policy(
                    self.codex_home,
                    check_only=False,
                    health_root=self.root / "health",
                    output=output,
                )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertGreaterEqual(calls, 3)
        finally:
            policy_path.unlink(missing_ok=True)

    def test_run_policy_nonseekable_failure_avoids_success_stdout(self) -> None:
        self.write_global(self.permission_drift())
        connection = self.create_db()
        connection.close()

        class NonSeekableOutput(io.StringIO):
            def seekable(self) -> bool:
                return False

        def fail_return_gate(lease: object, *args: object, **kwargs: object) -> None:
            raise self.module.StatePolicyError("return gate fixture failure")

        output = NonSeekableOutput()
        diagnostics = io.StringIO()
        try:
            with mock.patch.object(
                self.module.SqliteTargetLease,
                "assert_unchanged",
                new=fail_return_gate,
            ):
                with mock.patch.object(sys, "stderr", diagnostics):
                    result = self.module.run_policy(
                        self.codex_home,
                        check_only=False,
                        health_root=self.root / "health",
                        output=output,
                    )
            self.assertFalse(result["ok"])
            self.assertIn("unsafe-partial", result["errors"])
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(len(diagnostics.getvalue().splitlines()), 1)
            self.assertFalse(json.loads(diagnostics.getvalue())["ok"])
        finally:
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_sqlite_return_lease_unavailable_reports_unsafe_partial(self) -> None:
        connection = self.create_db()
        connection.close()
        policy = self.module.resolve_permission_policy(self.codex_home)
        original_fingerprint = self.module._assert_permission_policy_fingerprint
        locker: sqlite3.Connection | None = None
        calls = 0

        def lock_after_commit(current_policy: object) -> None:
            nonlocal calls, locker
            calls += 1
            original_fingerprint(current_policy)
            if calls == 4:
                locker = sqlite3.connect(self.db_path, timeout=0)
                locker.execute("begin immediate")

        try:
            with mock.patch.object(
                self.module,
                "_assert_permission_policy_fingerprint",
                side_effect=lock_after_commit,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "unsafe-partial"):
                    self.module.update_thread_state(
                        self.db_path,
                        permission_policy=policy,
                    )
            self.assertGreaterEqual(calls, 4)
        finally:
            if locker is not None:
                locker.rollback()
                locker.close()

    def test_malformed_and_backup_failure_preserve_original_bytes(self) -> None:
        malformed = b'{"broken":'
        self.global_path.write_bytes(malformed)
        with self.assertRaises(self.module.StatePolicyError):
            self.module.update_global_state(self.global_path, self.backup_root)
        self.assertEqual(self.global_path.read_bytes(), malformed)

        original_state = self.permission_drift()
        original_state["thread-workspace-root-hints"] = {
            "x": r"C:\Users\WINDOWS\Documents\Codex\a"
        }
        original = self.write_global(original_state)
        with mock.patch.object(self.module, "create_backup", side_effect=OSError("fixture backup denied")):
            with self.assertRaisesRegex(self.module.StatePolicyError, "backup"):
                self.module.update_global_state(self.global_path, self.backup_root)
        self.assertEqual(self.global_path.read_bytes(), original)

    def test_nonfinite_json_constants_fail_closed_without_artifacts(self) -> None:
        health_root = self.root / "health"
        for token in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(token=token):
                raw = ('{"unknown":' + token + '}').encode()
                self.global_path.write_bytes(raw)
                with self.assertRaisesRegex(self.module.StatePolicyError, "malformed"):
                    self.module.update_global_state(self.global_path, self.backup_root)
                self.assertEqual(self.global_path.read_bytes(), raw)
                self.assertFalse(self.backup_root.exists())
                self.assertFalse(health_root.exists())
                self.assertEqual(list(self.codex_home.glob(".*.tmp")), [])
        with self.assertRaisesRegex(self.module.StatePolicyError, "serialization"):
            self.module._json_bytes({"unknown": float("nan")})

    def test_check_only_and_idempotence(self) -> None:
        state = self.permission_drift()
        state["thread-workspace-root-hints"] = {
            "x": r"C:\Users\WINDOWS\Documents\Codex\a"
        }
        original = self.write_global(state)
        check = self.module.update_global_state(self.global_path, self.backup_root, check_only=True)
        self.assertEqual(self.global_path.read_bytes(), original)
        self.assertTrue(check["wouldChange"])
        first = self.module.update_global_state(self.global_path, self.backup_root)
        second = self.module.update_global_state(self.global_path, self.backup_root)
        self.assertTrue(first["changed"])
        self.assertFalse(second["changed"])
        self.assertGreater(second["driftCount"], 0)

    def test_write_mode_fails_closed_on_unbounded_sqlite_generation(self) -> None:
        self.write_global(self.permission_drift())
        original_global = self.global_path.read_bytes()
        connection = self.create_db()
        connection.close()
        output = io.StringIO()

        payload = self.module.run_policy(
            self.codex_home,
            check_only=False,
            health_root=self.root / "health",
            output=output,
        )

        self.assertFalse(payload["ok"])
        self.assertFalse(payload["converged"])
        self.assertIn("generation-unbounded", payload["errors"])
        self.assertIn("unsafe-partial", payload["errors"])
        self.assertEqual(self.global_path.read_bytes(), original_global)

    def test_sqlite_generation_unbounded_requires_wal_and_shm_but_allows_wal_journal_cold_start(
        self,
    ) -> None:
        payload = (b"db", b"wal", b"shm", None)
        identities = ((1, 1), (1, 2), (1, 3), None)
        metadata = (
            (True, 2, 1, (1, 0)),
            (True, 3, 1, (1, 0)),
            (True, 3, 1, (1, 0)),
            (False, None, None, (1, 0)),
        )
        cold_start = self.module.SqliteSourceSnapshot(
            payload=payload,
            identities=identities,
            metadata=metadata,
        )
        self.assertFalse(self.module._sqlite_generation_unbounded(cold_start, cold_start))
        for missing_index in (1, 2):
            missing_identities = list(identities)
            missing_identities[missing_index] = None
            missing = self.module.SqliteSourceSnapshot(
                payload=payload,
                identities=tuple(missing_identities),
                metadata=metadata,
            )
            self.assertTrue(
                self.module._sqlite_generation_unbounded(missing, cold_start),
                f"missing sidecar index {missing_index} must fail closed",
            )

    def test_check_only_removes_new_snapshot_root_and_empty_ancestors(self) -> None:
        conn = self.create_db()
        conn.close()
        snapshot_parent = self.root / "new-check-only-parent"
        snapshot_root = snapshot_parent / "sqlite-snapshots"
        self.assertFalse(snapshot_parent.exists())

        checked = self.module.update_thread_state(
            self.db_path, check_only=True, snapshot_root=snapshot_root
        )

        self.assertEqual(checked["wouldChangeCount"], 2)
        self.assertFalse(snapshot_root.exists())
        self.assertFalse(snapshot_parent.exists())

    def test_check_only_fails_closed_when_concurrent_content_blocks_new_root_cleanup(self) -> None:
        conn = self.create_db()
        conn.close()
        snapshot_root = self.root / "concurrent-cleanup-parent" / "sqlite-snapshots"

        def leave_concurrent_content(_attempt: int) -> None:
            (snapshot_root / "concurrent-owner.txt").write_text("keep", encoding="utf-8")

        with self.assertRaisesRegex(self.module.StatePolicyError, "cleanup"):
            self.module.update_thread_state(
                self.db_path,
                check_only=True,
                snapshot_root=snapshot_root,
                after_first_snapshot_capture=leave_concurrent_content,
            )
        self.assertTrue((snapshot_root / "concurrent-owner.txt").is_file())

    def test_check_only_rejects_snapshot_reparse_parent_before_any_write(self) -> None:
        connection = self.create_db()
        connection.close()
        outside = self.root / "snapshot-reparse-outside"
        outside.mkdir()
        junction = self.root / "snapshot-reparse-junction"
        junction_literal = str(junction).replace("'", "''")
        outside_literal = str(outside).replace("'", "''")
        command = (
            "$ErrorActionPreference='Stop';"
            f"New-Item -ItemType Junction -Path '{junction_literal}' "
            f"-Target '{outside_literal}' | Out-Null"
        )
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        created = subprocess.run(
            [
                r"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe",
                "-NoProfile",
                "-EncodedCommand",
                encoded,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(created.returncode, 0, created.stderr or created.stdout)
        try:
            before = self.db_path.read_bytes()
            with self.assertRaisesRegex(self.module.StatePolicyError, "reparse"):
                self.module.update_thread_state(
                    self.db_path,
                    check_only=True,
                    snapshot_root=junction / "sqlite-snapshots",
                )
            self.assertEqual(self.db_path.read_bytes(), before)
            self.assertEqual(list(outside.iterdir()), [])
        finally:
            if junction.exists() or junction.is_symlink():
                junction.rmdir()

    def test_sqlite_transaction_busy_check_only_and_drift_zero(self) -> None:
        conn = self.create_db()
        conn.close()
        db_before = self.db_path.read_bytes()
        checked = self.module.update_thread_state(
            self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
        )
        self.assertEqual(checked["wouldChangeCount"], 2)
        self.assertEqual(self.db_path.read_bytes(), db_before)
        self.assertFalse((self.db_path.parent / f"{self.db_path.name}-journal").exists())
        verify = sqlite3.connect(self.db_path)
        self.assertEqual(verify.execute("select approval_mode from threads where id='target-a'").fetchone()[0], "on-request")
        verify.close()

        updated = self.module.update_thread_state(self.db_path)
        self.assertEqual(updated["changedCount"], 2)
        self.assertEqual(updated["driftCount"], 0)
        verify = sqlite3.connect(self.db_path)
        row = verify.execute("select approval_mode,sandbox_policy,sentinel from threads where id='target-a'").fetchone()
        unknown = verify.execute("select approval_mode,sentinel from threads where id='unknown'").fetchone()
        verify.close()
        self.assertEqual(row, ("never", '{"type":"disabled"}', "keep-a"))
        self.assertEqual(unknown, ("on-request", "keep-unknown"))

        lock = sqlite3.connect(self.db_path, timeout=0)
        lock.execute("begin immediate")
        try:
            with self.assertRaisesRegex(self.module.StatePolicyError, "busy"):
                self.module.update_thread_state(self.db_path)
        finally:
            lock.rollback()
            lock.close()

    def test_wal_check_only_observes_latest_commits_without_sidecar_writes(self) -> None:
        keeper = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            keeper.commit()
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("wal-latest", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep"),
            )
            keeper.commit()

            paths = [
                self.db_path,
                Path(str(self.db_path) + "-wal"),
                Path(str(self.db_path) + "-shm"),
                Path(str(self.db_path) + "-journal"),
            ]

            def snapshot() -> list[tuple[bool, bytes | None]]:
                return [(path.exists(), path.read_bytes() if path.exists() else None) for path in paths]

            self.assertTrue(paths[1].exists())
            self.assertTrue(paths[2].exists())
            before = snapshot()
            first = self.module.update_thread_state(
                self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
            )
            self.assertEqual(first["wouldChangeCount"], 1)
            self.assertEqual(snapshot(), before)
            self.assertFalse(self.sqlite_snapshot_root.exists())
            second = self.module.update_thread_state(
                self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
            )
            self.assertEqual(second["wouldChangeCount"], 1)
            self.assertEqual(snapshot(), before)
            self.assertFalse(self.sqlite_snapshot_root.exists())

            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("wal-newer", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep-new"),
            )
            keeper.commit()
            latest = snapshot()
            third = self.module.update_thread_state(
                self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
            )
            self.assertEqual(third["wouldChangeCount"], 2)
            self.assertEqual(snapshot(), latest)

            injected = False

            def commit_between_samples(attempt: int) -> None:
                nonlocal injected
                if attempt == 1 and not injected:
                    keeper.execute(
                        "insert into threads values (?,?,?,?,?,?)",
                        ("wal-raced", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep-r"),
                    )
                    keeper.commit()
                    injected = True

            raced = self.module.update_thread_state(
                self.db_path,
                check_only=True,
                snapshot_root=self.sqlite_snapshot_root,
                after_first_snapshot_capture=commit_between_samples,
            )
            self.assertTrue(injected)
            self.assertEqual(raced["wouldChangeCount"], 3)
            stable_after_race = snapshot()
            self.assertEqual(self.module.update_thread_state(
                self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
            )["wouldChangeCount"], 3)
            self.assertEqual(snapshot(), stable_after_race)
            self.assertFalse(self.sqlite_snapshot_root.exists())

            checkpointed = False

            def checkpoint_between_samples(attempt: int) -> None:
                nonlocal checkpointed
                if attempt == 1 and not checkpointed:
                    keeper.execute("pragma wal_checkpoint(passive)").fetchone()
                    checkpointed = True

            after_checkpoint = self.module.update_thread_state(
                self.db_path,
                check_only=True,
                snapshot_root=self.sqlite_snapshot_root,
                after_first_snapshot_capture=checkpoint_between_samples,
            )
            self.assertTrue(checkpointed)
            self.assertEqual(after_checkpoint["wouldChangeCount"], 3)
            checkpoint_stable = snapshot()
            self.assertEqual(self.module.update_thread_state(
                self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
            )["wouldChangeCount"], 3)
            self.assertEqual(snapshot(), checkpoint_stable)
            self.assertFalse(self.sqlite_snapshot_root.exists())
        finally:
            keeper.close()

    def test_wal_write_allows_sqlite_owned_shm_and_wal_handles(self) -> None:
        keeper = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            keeper.executemany(
                "insert into threads values (?,?,?,?,?,?)",
                [
                    ("target-a", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep-a"),
                    ("target-null", "vscode", "user", None, None, "keep-null"),
                ],
            )
            keeper.commit()
            self.assertTrue(Path(str(self.db_path) + "-wal").exists())
            self.assertTrue(Path(str(self.db_path) + "-shm").exists())
            updated = self.module.update_thread_state(self.db_path)
            self.assertEqual(updated["changedCount"], 2)
            self.assertEqual(
                keeper.execute("select approval_mode from threads where id='target-a'").fetchone()[0],
                "never",
            )
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_check_only_fails_closed_when_wal_sidecar_bytes_are_unavailable(self) -> None:
        keeper = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            keeper.commit()
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("wal-hidden", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep"),
            )
            keeper.commit()
            original_capture = self.module._capture_sqlite_source

            def unavailable(path: Path):
                snapshot = original_capture(path)
                known = list(snapshot.content_known)
                payload = list(snapshot.payload)
                if snapshot.identities[1] is not None:
                    payload[1] = None
                    known[1] = False
                return self.module.SqliteSourceSnapshot(
                    payload=tuple(payload),
                    identities=snapshot.identities,
                    metadata=snapshot.metadata,
                    content_known=tuple(known),
                )

            with mock.patch.object(self.module, "_capture_sqlite_source", side_effect=unavailable):
                with self.assertRaisesRegex(self.module.StatePolicyError, "sidecar bytes unavailable"):
                    self.module.update_thread_state(
                        self.db_path,
                        check_only=True,
                        snapshot_root=self.sqlite_snapshot_root,
                    )
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_wal_write_policy_change_after_commit_rolls_back_rows(self) -> None:
        keeper = sqlite3.connect(self.db_path)
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            keeper.executemany(
                "insert into threads values (?,?,?,?,?,?)",
                [
                    ("target-a", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep-a"),
                    ("target-null", "vscode", "user", None, None, "keep-null"),
                ],
            )
            keeper.commit()
            policy = self.module.resolve_permission_policy(self.codex_home)
            original_fingerprint = self.module._assert_permission_policy_fingerprint
            calls = 0

            def race_fingerprint(current_policy: object) -> None:
                nonlocal calls
                calls += 1
                original_fingerprint(current_policy)
                if calls == 3:
                    self.write_permission_config(approval_policy="on-request")

            with mock.patch.object(
                self.module,
                "_assert_permission_policy_fingerprint",
                side_effect=race_fingerprint,
            ):
                with self.assertRaisesRegex(self.module.StatePolicyError, "policy|rollback"):
                    self.module.update_thread_state(
                        self.db_path,
                        permission_policy=policy,
                    )
            self.assertGreaterEqual(calls, 3)
            self.assertEqual(
                keeper.execute(
                    "select approval_mode, sandbox_policy from threads where id='target-a'"
                ).fetchone(),
                ("on-request", '{"type":"workspace-write"}'),
            )
            self.assertEqual(
                keeper.execute(
                    "select approval_mode, sandbox_policy from threads where id='target-null'"
                ).fetchone(),
                (None, None),
            )
        finally:
            keeper.close()
            for suffix in ("-wal", "-shm", "-journal"):
                Path(str(self.db_path) + suffix).unlink(missing_ok=True)

    def test_check_only_runs_quick_check_on_snapshot_and_uses_manifest_identity(self) -> None:
        self.write_global(self.permission_drift())
        conn = self.create_db()
        conn.close()
        result = self.module.update_thread_state(
            self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
        )
        self.assertTrue(result["integrityOk"])
        self.assertGreaterEqual(result["integrityResultCount"], 1)
        self.assertNotIn("rows", result)

        output = io.StringIO()
        payload = self.module.run_policy(
            self.codex_home, check_only=True, health_root=self.root / "health", output=output
        )
        self.assertEqual(payload["hookId"], "codex-state-policy")
        self.assertFalse(payload["converged"])
        self.assertGreater(payload["driftCount"], 0)
        self.assertFalse((self.root / "health" / "codex-state-policy.json").exists())

        self.module.run_policy(
            self.codex_home,
            check_only=True,
            health_root=self.root / "health",
            output=io.StringIO(),
            write_health=True,
        )
        self.assertTrue((self.root / "health" / "codex-state-policy.json").is_file())

    def test_rollback_on_sqlite_failure(self) -> None:
        conn = self.create_db()
        conn.close()
        def fail_before_commit() -> None:
            raise RuntimeError("fixture commit fault")

        with self.assertRaisesRegex(RuntimeError, "fixture commit fault"):
            self.module.update_thread_state(self.db_path, before_commit=fail_before_commit)
        verify = sqlite3.connect(self.db_path)
        self.assertEqual(verify.execute("select approval_mode from threads where id='target-a'").fetchone()[0], "on-request")
        verify.close()

    def test_sqlite_write_rechecks_main_bytes_before_commit(self) -> None:
        conn = self.create_db()
        conn.close()

        def mutate_same_inode() -> None:
            with self.db_path.open("r+b") as stream:
                stream.seek(0)
                stream.write(b"x")
                stream.flush()

        with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent"):
            self.module.update_thread_state(self.db_path, before_commit=mutate_same_inode)

    def test_health_envelope_and_stdout_are_redacted(self) -> None:
        self.write_global({"unknown": "keep"})
        conn = self.create_db()
        conn.execute("update threads set approval_mode='never',sandbox_policy='danger-full-access' where id in ('target-a','target-null')")
        conn.commit()
        conn.close()
        health_root = FIXTURE_ROOT / "health"
        output = io.StringIO()
        result = self.module.run_policy(
            self.codex_home,
            check_only=True,
            health_root=health_root,
            output=output,
            write_health=True,
        )
        payload = json.loads(output.getvalue())
        self.assertEqual(set(payload), {"hookId", "ok", "changed", "converged", "driftCount", "globalState", "threadState", "pathInventory", "restartRequired", "errors"})
        text = output.getvalue()
        self.assertNotRegex(text, r"target-a|redacted|codex-home|\\Users\\|thread[_ -]?id")
        health = json.loads((health_root / "codex-state-policy.json").read_text(encoding="utf-8"))
        self.assertEqual(
            list(health),
            ["hookId", "runId", "startedAtUtc", "completedAtUtc", "durationMs", "ok", "changed", "restartRequired", "errors"],
        )
        self.assertEqual(health["hookId"], "codex-state-policy")
        self.assertEqual(result["errors"], [])

    def test_health_failure_is_structured_and_redacted(self) -> None:
        self.write_global({"unknown": "keep"})
        conn = self.create_db()
        conn.close()
        output = io.StringIO()
        with mock.patch.object(self.module, "_write_health", side_effect=OSError("fixture secret path")):
            result = self.module.run_policy(
                self.codex_home,
                check_only=True,
                health_root=FIXTURE_ROOT / "health",
                output=output,
                write_health=True,
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["errors"], ["state policy health write failed"])
        self.assertNotIn("fixture secret", output.getvalue())

    def test_72kb_unknown_state_survives_100_check_only_runs(self) -> None:
        sentinel = "z" * (72 * 1024)
        self.write_global({"unknownSentinel": sentinel, "thread-workspace-root-hints": {}})
        conn = self.create_db()
        conn.execute("update threads set approval_mode='never',sandbox_policy='danger-full-access' where id in ('target-a','target-null')")
        conn.commit()
        conn.close()
        def check_once(_index: int):
            return self.module.update_global_state(self.global_path, self.backup_root, check_only=True)

        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(check_once, range(100)))
        for result in results:
            self.assertFalse(result["wouldChange"])
            self.assertEqual(json.loads(self.global_path.read_text(encoding="utf-8"))["unknownSentinel"], sentinel)

    def test_cli_rejects_fixture_write_and_production_health_from_check_only(self) -> None:
        with self.assertRaisesRegex(self.module.StatePolicyError, "fixed production"):
            self.module.main(["--codex-home", str(self.codex_home), "--json"])
        with self.assertRaisesRegex(self.module.StatePolicyError, "fixed fixture"):
            self.module.main(
                [
                    "--codex-home",
                    str(self.codex_home),
                    "--check-only",
                    "--health-root",
                    str(self.module.PRODUCTION_HEALTH_ROOT),
                    "--json",
                ]
            )

    def test_named_mutex_contract_and_contention(self) -> None:
        self.assertEqual(self.module.MUTEX_NAME, r"Local\CodexGlobalStatePolicy")
        self.assertEqual(self.module.MUTEX_TIMEOUT_MS, 1500)
        self.assertEqual(self.module.WindowsNamedMutex.WAIT_ABANDONED, 0x80)
        errors: list[str] = []

        def contender() -> None:
            try:
                with self.module.WindowsNamedMutex(timeout_ms=50):
                    pass
            except self.module.StatePolicyError as exc:
                errors.append(str(exc))

        with self.module.WindowsNamedMutex():
            worker = threading.Thread(target=contender)
            worker.start()
            worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, ["state policy mutex busy"])


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(FIXTURE_ROOT, ignore_errors=True)
