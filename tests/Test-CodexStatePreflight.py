from __future__ import annotations

from contextlib import closing, redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
import uuid
from unittest import mock


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
HOOK_ROOT = PROJECT_ROOT / "managed" / "codex-hooks" / "hooks"
PREFLIGHT = HOOK_ROOT / "codex-state-preflight.py"
WRAPPER = HOOK_ROOT / "codex-state-preflight.cmd"
PYTHON = Path(r"D:\Codex\tools\python314-official\python.exe")
FIXTURE_ROOT = PROJECT_ROOT / "reports" / "codex-state-preflight-test"
SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


class CodexStatePreflightTests(unittest.TestCase):
    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(FIXTURE_ROOT, ignore_errors=True)

    def setUp(self) -> None:
        FIXTURE_ROOT.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(dir=FIXTURE_ROOT))
        (self.root / ".codex-state-preflight-fixture").write_text(
            "codex-state-preflight-test-v1\n",
            encoding="utf-8",
        )
        self.codex_home = self.root / "codex-home"
        self.codex_home.mkdir()
        (self.codex_home / ".codex-global-state.json").write_text(
            '{"electron-persisted-atom-state":{}}',
            encoding="utf-8",
        )
        policy = '{"approvalPolicy":"never","sandboxPolicy":{"type":"dangerFullAccess"}}'
        (self.codex_home / "config.toml").write_text(
            'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n',
            encoding="utf-8",
        )
        for name in ("policy.json", "state-policy.json"):
            (self.codex_home / name).write_text(policy, encoding="utf-8")
        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as connection:
            connection.execute(
                "create table threads (id text primary key, source text, thread_source text, "
                "approval_mode text, sandbox_policy text, sentinel text)"
            )
            connection.commit()

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def load_preflight(self):
        spec = importlib.util.spec_from_file_location("codex_state_preflight_test", PREFLIGHT)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_wrapper_pins_official_python_and_managed_preflight(self) -> None:
        text = WRAPPER.read_text(encoding="utf-8")

        self.assertIn(
            r'"D:\Codex\tools\python314-official\python.exe"',
            text,
        )
        self.assertIn(
            r'"%~dp0codex-state-preflight.py"',
            text,
        )
        self.assertIn("%*", text)
        self.assertNotIn("%CD%", text.upper())
        self.assertTrue(PREFLIGHT.is_file())

    def test_check_only_json_uses_authorized_fixture_and_stable_schema(self) -> None:
        environment = os.environ.copy()
        environment.update(
            {
                "HTTP_PROXY": "http://127.0.0.1:1/should-not-be-used",
                "HTTPS_PROXY": "http://127.0.0.1:1/should-not-be-used",
                "ALL_PROXY": "socks5://127.0.0.1:1/should-not-be-used",
            }
        )
        result = subprocess.run(
            [
                str(PYTHON),
                str(PREFLIGHT),
                "--check-only",
                "--json",
                "--fixture-root",
                str(self.root),
            ],
            cwd=self.root,
            text=True,
            capture_output=True,
            env=environment,
            timeout=20,
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        payload = json.loads(result.stdout)
        self.assertEqual(
            set(payload),
            {"ok", "converged", "driftCount", "domains", "repairRequired", "reviewRequired"},
        )
        self.assertIs(payload["ok"], True)
        self.assertIs(payload["converged"], True)
        self.assertEqual(payload["driftCount"], 0)
        self.assertIs(payload["repairRequired"], False)
        self.assertIs(payload["reviewRequired"], False)
        self.assertEqual(set(payload["domains"]), {"globalState", "threadState", "paths"})

    def test_project_marks_unresolved_path_drift_as_review_only(self) -> None:
        module = self.load_preflight()

        payload = module._project(
            {
                "ok": True,
                "converged": False,
                "driftCount": 2,
                "globalState": {"status": "unresolved", "changedCount": 0, "driftCount": 2},
                "threadState": {"status": "converged", "changedCount": 0, "driftCount": 0},
                "pathInventory": {
                    "entries": [
                        {"safe": False, "reason": "unresolved-ambiguous"},
                        {"safe": False, "reason": "unresolved-outside-source-root"},
                    ]
                },
                "errors": [],
            }
        )

        self.assertIs(payload["ok"], True)
        self.assertIs(payload["converged"], False)
        self.assertEqual(payload["driftCount"], 2)
        self.assertIs(payload["repairRequired"], False)
        self.assertIs(payload["reviewRequired"], True)

    def test_project_keeps_safe_path_drift_repair_required(self) -> None:
        module = self.load_preflight()

        payload = module._project(
            {
                "ok": True,
                "converged": False,
                "driftCount": 1,
                "globalState": {"status": "drift", "changedCount": 0, "driftCount": 1},
                "threadState": {"status": "converged", "changedCount": 0, "driftCount": 0},
                "pathInventory": {"entries": [{"safe": True, "reason": "safe"}]},
                "errors": [],
            }
        )

        self.assertIs(payload["repairRequired"], True)
        self.assertIs(payload["reviewRequired"], False)

    @unittest.skipUnless(os.name == "nt", "requires Windows junction semantics")
    def test_fixture_codex_home_and_health_junctions_are_rejected(self) -> None:
        module = self.load_preflight()
        for leaf in ("codex-home", "health"):
            with self.subTest(leaf=leaf):
                target = self.root / leaf
                if target.exists():
                    shutil.rmtree(target)
                external = FIXTURE_ROOT / f"{self.root.name}-{leaf}-external"
                external.mkdir()
                try:
                    created = subprocess.run(
                        ["cmd.exe", "/d", "/c", "mklink", "/J", str(target), str(external)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        creationflags=SUBPROCESS_CREATION_FLAGS,
                        check=False,
                    )
                    self.assertEqual(created.returncode, 0, created.stderr)
                    with self.assertRaises(module.PreflightError):
                        module._fixture_home(self.root)
                finally:
                    if target.exists():
                        os.rmdir(target)
                    shutil.rmtree(external, ignore_errors=True)
                if leaf == "codex-home":
                    self.codex_home.mkdir()

    def test_forbidden_network_auth_url_and_untrusted_fixture_are_rejected(self) -> None:
        cases = (
            ["--check-only", "--json", "--check-network"],
            ["--check-only", "--json", "--check-auth"],
            ["--check-only", "--json", "https://example.invalid/secret"],
            ["--check-only", "--json", "--codex-home", str(self.codex_home)],
            ["--check-only", "--json", "--fixture-root", str(self.codex_home)],
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [str(PYTHON), str(PREFLIGHT), *arguments],
                    cwd=self.root,
                    text=True,
                    capture_output=True,
                    timeout=20,
                    check=False,
                    creationflags=SUBPROCESS_CREATION_FLAGS,
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, "")
                payload = json.loads(result.stdout)
                self.assertIs(payload["ok"], False)
                self.assertIs(payload["repairRequired"], True)
                self.assertNotIn("example.invalid", result.stdout)

    def test_lifecycle_success_is_quiet_and_uses_fixed_production_home(self) -> None:
        module = self.load_preflight()
        observed: dict[str, object] = {}

        class FakeCore:
            class Snapshot:
                identities = (None, None, None, None)

            @staticmethod
            def _capture_sqlite_source(_path):
                return FakeCore.Snapshot()

            @staticmethod
            def run_policy(codex_home, **kwargs):
                observed["codexHome"] = codex_home
                observed.update(kwargs)
                return {"ok": True, "converged": True, "driftCount": 0}

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(module, "_load_state_core", return_value=FakeCore()):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = module.main([])
        self.assertEqual(exit_code, 0)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(observed["codexHome"], module.PRODUCTION_CODEX_HOME)
        self.assertIs(observed["check_only"], False)
        self.assertIs(observed["write_health"], True)

    @unittest.skipUnless(os.name == "nt", "requires Windows active WAL semantics")
    def test_active_wal_repairs_global_domain_and_reports_sqlite_drift(self) -> None:
        module = self.load_preflight()
        core = module._load_state_core()
        global_state = {
            "electron-persisted-atom-state": {
                "heartbeat-thread-permissions-by-id": {
                    "target": {
                        "approvalPolicy": "on-request",
                        "sandboxPolicy": {"type": "workspaceWrite"},
                    }
                }
            }
        }
        (self.codex_home / ".codex-global-state.json").write_text(
            json.dumps(global_state, separators=(",", ":")),
            encoding="utf-8",
        )
        keeper = sqlite3.connect(self.codex_home / "state_5.sqlite")
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("target", "vscode", "user", "on-request", '{"type":"workspace-write"}', "keep"),
            )
            keeper.commit()
            payload = module._run_state_preflight(
                core,
                self.codex_home,
                self.root / "health",
                check_only=False,
                write_health=False,
            )
            self.assertIs(payload["ok"], True)
            self.assertEqual(payload["globalState"]["status"], "updated")
            self.assertEqual(payload["threadState"]["status"], "drift")
            self.assertEqual(payload["threadState"]["driftCount"], 1)
            heartbeat = json.loads(
                (self.codex_home / ".codex-global-state.json").read_text(encoding="utf-8")
            )["electron-persisted-atom-state"]["heartbeat-thread-permissions-by-id"]["target"]
            self.assertEqual(heartbeat["approvalPolicy"], "never")
            self.assertEqual(heartbeat["sandboxPolicy"], {"type": "dangerFullAccess"})
            row = keeper.execute(
                "select approval_mode, sandbox_policy from threads where id='target'"
            ).fetchone()
            self.assertEqual(row, ("on-request", '{"type":"workspace-write"}'))
        finally:
            keeper.close()

    @unittest.skipUnless(os.name == "nt", "requires Windows active WAL semantics")
    def test_active_wal_auto_repairs_safe_projectless_paths(self) -> None:
        module = self.load_preflight()
        core = module._load_state_core()
        relative = Path("codex-state-preflight-test") / uuid.uuid4().hex / "outputs"
        candidate = Path(r"D:\Documents\Codex") / relative
        candidate.mkdir(parents=True, exist_ok=True)
        source_value = str(Path(r"C:\Users\WINDOWS\Documents\Codex") / relative)
        candidate_value = str(candidate)
        global_state = {
            "thread-projectless-output-directories": {
                "target": source_value,
            },
            "electron-persisted-atom-state": {},
        }
        (self.codex_home / ".codex-global-state.json").write_text(
            json.dumps(global_state, separators=(",", ":")),
            encoding="utf-8",
        )
        keeper = sqlite3.connect(self.codex_home / "state_5.sqlite")
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("target", "vscode", "user", "never", 'danger-full-access', "keep"),
            )
            keeper.commit()

            payload = module._run_state_preflight(
                core,
                self.codex_home,
                self.root / "health",
                check_only=False,
                write_health=False,
            )

            self.assertIs(payload["ok"], True)
            self.assertIs(payload["changed"], True)
            self.assertEqual(payload["globalState"]["status"], "updated")
            repaired = json.loads(
                (self.codex_home / ".codex-global-state.json").read_text(encoding="utf-8")
            )["thread-projectless-output-directories"]["target"]
            self.assertEqual(repaired, candidate_value)
            projected = module._project(payload)
            self.assertIs(projected["repairRequired"], False)
        finally:
            keeper.close()
            shutil.rmtree(candidate.parent, ignore_errors=True)

    def test_loader_rejects_modified_sibling_core_before_execution(self) -> None:
        isolated = self.root / "isolated"
        isolated.mkdir()
        shutil.copy2(PREFLIGHT, isolated / PREFLIGHT.name)
        marker = self.root / "malicious-core-ran"
        (isolated / "codex-state-policy-guard.py").write_text(
            f"from pathlib import Path\nPath({str(marker)!r}).write_text('ran')\n",
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                str(PYTHON),
                str(isolated / PREFLIGHT.name),
                "--check-only",
                "--json",
                "--fixture-root",
                str(self.root),
            ],
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")
        self.assertIs(json.loads(result.stdout)["ok"], False)
        self.assertFalse(marker.exists())

    @unittest.skipUnless(os.name == "nt", "requires Windows target lease semantics")
    def test_active_wal_never_reports_success_after_global_competitor(self) -> None:
        module = self.load_preflight()
        core = module._load_state_core()
        state = {
            "electron-persisted-atom-state": {
                "heartbeat-thread-permissions-by-id": {
                    "target": {
                        "approvalPolicy": "on-request",
                        "sandboxPolicy": {"type": "workspaceWrite"},
                    }
                }
            }
        }
        global_path = self.codex_home / ".codex-global-state.json"
        global_path.write_text(json.dumps(state, separators=(",", ":")), encoding="utf-8")
        keeper = sqlite3.connect(self.codex_home / "state_5.sqlite")
        original_update = core.update_thread_state
        attack = {"wrote": False, "blocked": False}

        def competing_update(*args, **kwargs):
            try:
                global_path.write_bytes(b'{"competitor":true}')
                attack["wrote"] = True
            except OSError:
                attack["blocked"] = True
            return original_update(*args, **kwargs)

        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("target", "vscode", "user", "never", 'danger-full-access', "keep"),
            )
            keeper.commit()
            with mock.patch.object(core, "update_thread_state", side_effect=competing_update):
                payload = module._run_state_preflight(
                    core,
                    self.codex_home,
                    self.root / "health",
                    check_only=False,
                    write_health=False,
                )
            self.assertTrue(attack["wrote"] or attack["blocked"])
            self.assertFalse(attack["wrote"] and payload["ok"])
            if attack["blocked"]:
                self.assertIs(payload["ok"], True)
                self.assertNotEqual(global_path.read_bytes(), b'{"competitor":true}')
        finally:
            keeper.close()

    @unittest.skipUnless(os.name == "nt", "requires Windows active WAL semantics")
    def test_health_failure_preserves_committed_domain_facts(self) -> None:
        module = self.load_preflight()
        core = module._load_state_core()
        state = {
            "electron-persisted-atom-state": {
                "heartbeat-thread-permissions-by-id": {
                    "target": {
                        "approvalPolicy": "on-request",
                        "sandboxPolicy": {"type": "workspaceWrite"},
                    }
                }
            }
        }
        (self.codex_home / ".codex-global-state.json").write_text(
            json.dumps(state, separators=(",", ":")), encoding="utf-8"
        )
        keeper = sqlite3.connect(self.codex_home / "state_5.sqlite")
        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("target", "vscode", "user", "never", 'danger-full-access', "keep"),
            )
            keeper.commit()
            with mock.patch.object(core, "_write_health", side_effect=OSError("private path")):
                payload = module._run_state_preflight(
                    core,
                    self.codex_home,
                    self.root / "health",
                    check_only=False,
                    write_health=True,
                )
            self.assertIs(payload["ok"], False)
            self.assertIs(payload["changed"], True)
            self.assertEqual(payload["globalState"]["status"], "updated")
            self.assertIn("state preflight health write failed", payload["errors"])
            self.assertNotIn("private path", json.dumps(payload))
        finally:
            keeper.close()

    @unittest.skipUnless(os.name == "nt", "requires Windows active WAL semantics")
    def test_final_gate_failure_is_written_as_failed_health(self) -> None:
        module = self.load_preflight()
        core = module._load_state_core()
        keeper = sqlite3.connect(self.codex_home / "state_5.sqlite")
        captured_health: dict[str, object] = {}

        class FailingFinalLease:
            def __init__(inner_self, *_args, **_kwargs) -> None:
                inner_self.assertions = 0

            def __enter__(inner_self):
                return inner_self

            def assert_unchanged(inner_self) -> None:
                inner_self.assertions += 1
                if inner_self.assertions == 3:
                    raise core.StatePolicyError("injected final drift")

            def close(inner_self) -> None:
                return None

        def capture_health(_path, payload) -> None:
            captured_health.update(payload)

        try:
            self.assertEqual(keeper.execute("pragma journal_mode=wal").fetchone()[0], "wal")
            keeper.execute("pragma wal_autocheckpoint=0")
            keeper.execute(
                "insert into threads values (?,?,?,?,?,?)",
                ("target", "vscode", "user", "never", 'danger-full-access', "keep"),
            )
            keeper.commit()
            with (
                mock.patch.object(core, "StateTargetLease", FailingFinalLease),
                mock.patch.object(core, "_write_health", side_effect=capture_health),
            ):
                payload = module._run_state_preflight(
                    core,
                    self.codex_home,
                    self.root / "health",
                    check_only=False,
                    write_health=True,
                )
            self.assertIs(payload["ok"], False)
            self.assertIn("global state changed before preflight return", payload["errors"])
            self.assertIs(captured_health["ok"], False)
            self.assertIn(
                "global state changed before preflight return",
                captured_health["errors"],
            )
        finally:
            keeper.close()

    def test_empty_fixture_root_never_falls_back_to_production(self) -> None:
        module = self.load_preflight()
        core = mock.Mock()
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(module, "_load_state_core", return_value=core):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = module.main(["--fixture-root=", "--json"])
        self.assertEqual(exit_code, 1)
        core.run_policy.assert_not_called()
        self.assertEqual(stderr.getvalue(), "")
        self.assertIs(json.loads(stdout.getvalue())["ok"], False)

    def test_argument_and_core_failures_are_controlled_and_redacted(self) -> None:
        module = self.load_preflight()
        for arguments in (["--fixture-root", "--json"], ["--check-only=true", "--json"]):
            with self.subTest(arguments=arguments):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    exit_code = module.main(list(arguments))
                self.assertEqual(exit_code, 1)
                self.assertEqual(stderr.getvalue(), "")
                self.assertIs(json.loads(stdout.getvalue())["ok"], False)
                self.assertNotIn("traceback", stdout.getvalue().casefold())
        stdout = io.StringIO()
        stderr = io.StringIO()
        secret = r"D:\private\sensitive\value"
        with mock.patch.object(module, "_load_state_core", side_effect=RuntimeError(secret)):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = module.main([])
        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertNotIn(secret, stderr.getvalue())
        self.assertNotIn("traceback", stderr.getvalue().casefold())

    def test_preflight_source_has_no_network_or_process_capability(self) -> None:
        sources = (
            PREFLIGHT.read_text(encoding="utf-8").casefold(),
            (HOOK_ROOT / "codex-state-policy-guard.py").read_text(encoding="utf-8").casefold(),
        )
        for forbidden in (
            "import socket",
            "import subprocess",
            "import urllib",
            "import http",
            "requests",
            "create_connection",
            "popen(",
        ):
            for source in sources:
                self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
