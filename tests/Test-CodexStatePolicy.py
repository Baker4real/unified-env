from __future__ import annotations

import hashlib
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
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

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def write_global(self, state: object) -> bytes:
        data = json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode()
        self.global_path.write_bytes(data)
        return data

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
        normalized, summary = self.module.normalize_global_state(state)
        self.assertEqual(normalized["thread-workspace-root-hints"]["redacted-a"], r"D:\Users\WINDOWS\Documents\Codex\a")
        self.assertEqual(normalized["thread-projectless-output-directories"]["redacted-b"], r"D:\Users\WINDOWS\Documents\Codex\b")
        heartbeat = normalized["electron-persisted-atom-state"]["heartbeat-thread-permissions-by-id"]
        self.assertEqual(heartbeat["redacted-c"]["approvalPolicy"], "never")
        self.assertEqual(heartbeat["redacted-c"]["sandboxPolicy"], {"type": "dangerFullAccess"})
        self.assertEqual(heartbeat["redacted-d"], "unknown-shape")
        self.assertEqual(normalized["unknown"], "keep")
        self.assertEqual(summary["pathChangedCount"], 2)
        self.assertEqual(summary["heartbeatChangedCount"], 1)
        self.assertNotIn("redacted-a", json.dumps(summary))

    def test_select_thread_updates_preserves_unknown_rows(self) -> None:
        conn = self.create_db()
        try:
            self.assertEqual(self.module.select_thread_updates(conn), ["target-a", "target-null"])
        finally:
            conn.close()

    def test_global_writer_replays_latest_competitor_state(self) -> None:
        original = self.write_global({"thread-workspace-root-hints": {"x": r"C:\Users\WINDOWS\Documents\Codex\a"}})
        competitor = {
            "thread-workspace-root-hints": {"x": r"C:\Users\WINDOWS\Documents\Codex\a"},
            "competitorSentinel": "keep",
        }
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
        self.assertTrue(after["thread-workspace-root-hints"]["x"].startswith("D:"))
        self.assertNotEqual(hashlib.sha256(original).hexdigest(), result["afterSha256"])

    def test_global_writer_never_overwrites_unstable_competitor(self) -> None:
        self.write_global({"thread-workspace-root-hints": {"x": r"C:\Users\WINDOWS\Documents\Codex\a"}})
        latest = b""

        def race(attempt: int) -> None:
            nonlocal latest
            latest = json.dumps(
                {
                    "competitor": attempt,
                    "thread-workspace-root-hints": {
                        "x": r"C:\Users\WINDOWS\Documents\Codex\a"
                    },
                }
            ).encode()
            self.global_path.write_bytes(latest)

        with self.assertRaisesRegex(self.module.StatePolicyError, "concurrent"):
            self.module.update_global_state(
                self.global_path, self.backup_root, before_prewrite_check=race
            )
        self.assertEqual(self.global_path.read_bytes(), latest)

    def test_malformed_and_backup_failure_preserve_original_bytes(self) -> None:
        malformed = b'{"broken":'
        self.global_path.write_bytes(malformed)
        with self.assertRaises(self.module.StatePolicyError):
            self.module.update_global_state(self.global_path, self.backup_root)
        self.assertEqual(self.global_path.read_bytes(), malformed)

        original = self.write_global({"thread-workspace-root-hints": {"x": r"C:\Users\WINDOWS\Documents\Codex\a"}})
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
        original = self.write_global({"thread-workspace-root-hints": {"x": r"C:\Users\WINDOWS\Documents\Codex\a"}})
        check = self.module.update_global_state(self.global_path, self.backup_root, check_only=True)
        self.assertEqual(self.global_path.read_bytes(), original)
        self.assertTrue(check["wouldChange"])
        first = self.module.update_global_state(self.global_path, self.backup_root)
        second = self.module.update_global_state(self.global_path, self.backup_root)
        self.assertTrue(first["changed"])
        self.assertFalse(second["changed"])

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
            self.assertEqual(list(self.sqlite_snapshot_root.iterdir()), [])
            second = self.module.update_thread_state(
                self.db_path, check_only=True, snapshot_root=self.sqlite_snapshot_root
            )
            self.assertEqual(second["wouldChangeCount"], 1)
            self.assertEqual(snapshot(), before)

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
            self.assertEqual(list(self.sqlite_snapshot_root.iterdir()), [])

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
            self.assertEqual(list(self.sqlite_snapshot_root.iterdir()), [])
        finally:
            keeper.close()

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
        )
        payload = json.loads(output.getvalue())
        self.assertEqual(set(payload), {"ok", "changed", "globalState", "threadState", "restartRequired", "errors"})
        text = output.getvalue()
        self.assertNotRegex(text, r"target-a|redacted|codex-home|\\Users\\|thread[_ -]?id")
        health = json.loads((health_root / "state-policy.json").read_text(encoding="utf-8"))
        self.assertEqual(
            list(health),
            ["hookId", "runId", "startedAtUtc", "completedAtUtc", "durationMs", "ok", "changed", "restartRequired", "errors"],
        )
        self.assertEqual(health["hookId"], "state-policy")
        self.assertEqual(result["errors"], [])

    def test_health_failure_is_structured_and_redacted(self) -> None:
        self.write_global({"unknown": "keep"})
        output = io.StringIO()
        with mock.patch.object(self.module, "_write_health", side_effect=OSError("fixture secret path")):
            result = self.module.run_policy(
                self.codex_home,
                check_only=True,
                health_root=FIXTURE_ROOT / "health",
                output=output,
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
