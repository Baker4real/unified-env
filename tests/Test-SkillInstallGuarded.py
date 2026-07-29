#!/usr/bin/env python3
"""Focused tests for the guarded skill install transaction."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import stat
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[1]
WRAPPER_PATH = PROJECT_ROOT / "scripts" / "install_skill_guarded.py"
SPEC = importlib.util.spec_from_file_location("install_skill_guarded", WRAPPER_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 wrapper：{WRAPPER_PATH}")
WRAPPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WRAPPER)
SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
SUBPROCESS_TEXT_ENCODING = "oem" if os.name == "nt" else "utf-8"


class SkillInstallGuardedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_parent = Path(r"D:\Codex\tmp")
        self.temp_parent.mkdir(parents=True, exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(prefix="skill-install-guarded-test-", dir=self.temp_parent))
        self.active = self.temp / "active"
        self.plugin_cache = self.temp / "plugin-cache"
        self.active.mkdir()
        self.plugin_cache.mkdir()
        self._grant_active_root_runtime_access()
        self.ledger = self.active / ".downloaded-skills-source-state.json"
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [],
                    "unresolved": [],
                    "deleted": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        self.generator = PROJECT_ROOT / "scripts" / "generate_skill_catalog.py"
        self.closure = Path(
            r"D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py"
        )
        self.interpreter = Path(sys.executable).resolve()

    def _powershell(self) -> str:
        executable = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
        if not executable:
            self.fail("测试需要 PowerShell 读取 Windows ACL")
        return executable

    def _grant_active_root_runtime_access(self) -> None:
        result = subprocess.run(
            [
                "icacls.exe",
                str(self.active),
                "/inheritancelevel:e",
                "/grant:r",
                "*S-1-5-11:(OI)(CI)(M)",
                "*S-1-5-32-545:(OI)(CI)(RX)",
            ],
            capture_output=True,
            text=True,
            encoding=SUBPROCESS_TEXT_ENCODING,
            errors="replace",
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    def protect_private_candidate_tree(self, path: Path) -> None:
        for arguments in (
            ["/inheritance:r", "/T", "/C"],
            [
                "/grant:r",
                "*S-1-3-4:(OI)(CI)(F)",
                "*S-1-5-18:(OI)(CI)(F)",
                "*S-1-5-32-544:(OI)(CI)(F)",
                "/T",
                "/C",
            ],
        ):
            result = subprocess.run(
                ["icacls.exe", str(path), *arguments],
                capture_output=True,
                text=True,
                encoding=SUBPROCESS_TEXT_ENCODING,
                errors="replace",
                check=False,
                creationflags=SUBPROCESS_CREATION_FLAGS,
            )
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertTrue(self.acl_state(path)["protected"])

    def acl_state(self, path: Path) -> dict[str, object]:
        script = (
            "$pathValue=[Environment]::GetEnvironmentVariable('SKILL_ACL_TEST_PATH','Process');"
            "$acl=Get-Acl -LiteralPath $pathValue -ErrorAction Stop;"
            "[ordered]@{protected=$acl.AreAccessRulesProtected;"
            "owner=$acl.Owner;sddl=$acl.Sddl;"
            "rules=@($acl.Access|ForEach-Object{[ordered]@{"
            "identity=[string]$_.IdentityReference;"
            "type=[string]$_.AccessControlType;"
            "inherited=$_.IsInherited}})}|ConvertTo-Json -Depth 5 -Compress"
        )
        result = subprocess.run(
            [
                self._powershell(),
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                script,
            ],
            env={**os.environ, "SKILL_ACL_TEST_PATH": str(path)},
            capture_output=True,
            text=True,
            encoding=SUBPROCESS_TEXT_ENCODING,
            errors="replace",
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        return json.loads(result.stdout)

    def create_junction(self, path: Path, target: Path) -> None:
        target.mkdir(parents=True, exist_ok=True)
        script = (
            "$link=[Environment]::GetEnvironmentVariable('SKILL_JUNCTION_PATH','Process');"
            "$target=[Environment]::GetEnvironmentVariable('SKILL_JUNCTION_TARGET','Process');"
            "New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop|Out-Null"
        )
        result = subprocess.run(
            [
                self._powershell(),
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                script,
            ],
            env={
                **os.environ,
                "SKILL_JUNCTION_PATH": str(path),
                "SKILL_JUNCTION_TARGET": str(target),
            },
            capture_output=True,
            text=True,
            encoding=SUBPROCESS_TEXT_ENCODING,
            errors="replace",
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertTrue(WRAPPER.is_reparse(path))

    def tearDown(self) -> None:
        def retry_read_only(function: object, path: str, error: BaseException) -> None:
            if not isinstance(error, PermissionError):
                raise error
            target = Path(path)
            target.chmod(target.stat().st_mode | stat.S_IWRITE)
            function(path)

        shutil.rmtree(self.temp, onexc=retry_read_only)

    def write_candidate(self, name: str, description: str) -> Path:
        candidate = self.temp / f"candidate-{name}"
        candidate.mkdir()
        (candidate / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n",
            encoding="utf-8",
        )
        return candidate

    def write_manifest(
        self,
        name: str,
        decision: str,
        source_id: str = "local-test",
        ledger_updates: dict[str, object] | None = None,
        upstream_path: str | None = None,
        include_candidate_integrity: bool = True,
    ) -> Path:
        path = self.temp / f"manifest-{name}-{decision}.json"
        source: dict[str, object] = {"id": source_id, "ref": "local"}
        if ledger_updates is not None:
            source["ledger_updates"] = ledger_updates
        if upstream_path is not None:
            source["upstream_path"] = upstream_path
        payload: dict[str, object] = {
            "decision": decision,
            "source_status": "source-review",
            "writing_great_skills": {"status": "no-change"},
            "skills": [name],
            "source": source,
        }
        if include_candidate_integrity:
            candidate = self.temp / f"candidate-{name}"
            payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
        path.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )
        return path

    def wrapper_args(self, candidate: Path, manifest: Path, *, generator: Path | None = None) -> list[str]:
        return [
            "--candidate",
            str(candidate),
            "--name",
            "test-skill-wrapper",
            "--decision-manifest",
            str(manifest),
            "--active-root",
            str(self.active),
            "--plugin-cache-root",
            str(self.plugin_cache),
            "--ledger",
            str(self.ledger),
            "--catalog",
            str(self.temp / "catalog.json"),
            "--generator",
            str(generator or self.generator),
            "--closure-script",
            str(self.closure),
            "--python",
            str(self.interpreter),
            "--temp-root",
            str(self.temp / "staging"),
            "--lock-root",
            str(self.temp / "lock"),
            "--evidence-root",
            str(self.temp / "evidence"),
        ]

    def test_install_updates_source_ledger_and_catalog(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "测试 guarded wrapper")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            ledger_updates={
                "action": "updated",
                "installed_version": "3.5.1",
                "path": ".codex/skills/test-skill-wrapper",
                "resource_paths": ["skill/SKILL.md"],
                "status": "updated-with-local-overlay",
                "tag": "v3.5.1",
            },
        )
        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))
        self.assertEqual(code, 0)
        active_skill = self.active / "test-skill-wrapper"
        self.assertTrue((active_skill / "SKILL.md").is_file())
        self.assertTrue((active_skill / "SOURCE.md").is_file())
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = next(item for item in ledger["sources"] if item["id"] == "local-test")
        self.assertEqual(source["skills"], ["test-skill-wrapper"])
        self.assertEqual(source["action"], "updated")
        self.assertEqual(source["installed_version"], "3.5.1")
        self.assertEqual(source["path"], ".codex/skills/test-skill-wrapper")
        self.assertEqual(source["resource_paths"], ["skill/SKILL.md"])
        self.assertEqual(source["status"], "updated-with-local-overlay")
        self.assertEqual(source["tag"], "v3.5.1")
        catalog = json.loads((self.temp / "catalog.json").read_text(encoding="utf-8"))
        artifact = next(item for item in catalog["artifacts"] if item.get("name") == "test-skill-wrapper")
        self.assertEqual(artifact["ledger_coverage"], "pass")
        self.assertEqual(catalog["checks"]["resource_closure"]["status"], "pass")

    def test_candidate_metadata_is_excluded_from_active_payload(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "排除候选元数据")
        (candidate / ".git" / "hooks").mkdir(parents=True)
        (candidate / ".git" / "config").write_text("[core]\n\tbare = false\n", encoding="utf-8")
        (candidate / ".git" / "hooks" / "post-checkout").write_text(
            "should-not-install\n", encoding="utf-8"
        )
        (candidate / "__pycache__").mkdir()
        (candidate / "__pycache__" / "cached.pyc").write_bytes(b"cache")
        (candidate / "scripts").mkdir()
        (candidate / "scripts" / "helper.pyc").write_bytes(b"cache")
        (candidate / "scripts" / "helper.py").write_text("VALUE = 1\n", encoding="utf-8")
        manifest = self.write_manifest("test-skill-wrapper", "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        active_skill = self.active / "test-skill-wrapper"
        self.assertFalse((active_skill / ".git").exists())
        self.assertFalse((active_skill / "__pycache__").exists())
        self.assertFalse((active_skill / "scripts" / "helper.pyc").exists())
        self.assertTrue((active_skill / "scripts" / "helper.py").is_file())
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        integrity = result["staged"]["candidate_integrity"]
        self.assertEqual(integrity["excluded_files"]["file_count"], 4)
        self.assertEqual(integrity["tree_sha256"], result["decision"]["candidate_integrity"]["tree_sha256"])

    def test_candidate_git_pointer_file_is_excluded_from_active_payload(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "排除 worktree 指针")
        (candidate / ".git").write_text(
            "gitdir: D:/Codex/tmp/worktrees/test-skill-wrapper\n",
            encoding="utf-8",
        )
        (candidate / "__pycache__").write_text("not-a-directory\n", encoding="utf-8")
        manifest = self.write_manifest("test-skill-wrapper", "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        active_skill = self.active / "test-skill-wrapper"
        self.assertFalse((active_skill / ".git").exists())
        self.assertFalse((active_skill / "__pycache__").exists())
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["staged"]["candidate_integrity"]["excluded_files"]["file_count"], 2)

    def test_pyc_named_directory_is_preserved_and_bound(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "保留 pyc 后缀目录")
        payload_directory = candidate / "assets.pyc"
        payload_directory.mkdir()
        (payload_directory / "payload.txt").write_text("payload\n", encoding="utf-8")
        manifest = self.write_manifest("test-skill-wrapper", "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        installed = self.active / "test-skill-wrapper" / "assets.pyc" / "payload.txt"
        self.assertEqual(installed.read_text(encoding="utf-8"), "payload\n")

    def test_candidate_integrity_is_required_before_activation(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "缺少候选绑定")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            include_candidate_integrity=False,
        )

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_candidate_integrity_drift_is_rejected_before_activation(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "候选漂移")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        (candidate / "SKILL.md").write_text(
            "---\nname: test-skill-wrapper\ndescription: drifted\n---\n\n# drifted\n",
            encoding="utf-8",
        )

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_candidate_integrity_rejects_boolean_file_count(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "拒绝布尔文件数")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["candidate_integrity"]["file_count"] = True
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_staging_seal_drift_is_rejected_before_activation(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "拒绝 staging seal 漂移")
        manifest = self.write_manifest(name, "install")
        original_activate = WRAPPER.activate_directories

        def mutate_staging_then_activate(**kwargs: object) -> list[dict[str, object]]:
            stage_root = Path(kwargs["stage_root"])
            (stage_root / name / ".git").mkdir()
            return original_activate(**kwargs)

        with (
            mock.patch.object(WRAPPER, "activate_directories", mutate_staging_then_activate),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertFalse((self.active / name).exists())

    def test_activation_temp_junction_is_rejected_before_atomic_replace(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "拒绝 activation temp junction")
        manifest = self.write_manifest(name, "install")
        original_copy = WRAPPER.copy_tree_without_security_metadata
        junction_target = self.temp / "junction-target"
        junction_target.mkdir()
        sentinel = junction_target / "sentinel.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")

        def copy_then_mutate(source: Path, destination: Path) -> None:
            original_copy(source, destination)
            self.create_junction(destination / "late-junction", junction_target)

        with (
            mock.patch.object(WRAPPER, "copy_tree_without_security_metadata", copy_then_mutate),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertFalse((self.active / name).exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_candidate_integrity_only_reports_managed_payload_without_transaction(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "只读候选指纹")
        (candidate / ".git").write_text("gitdir: D:/Codex/tmp/worktree\n", encoding="utf-8")
        stdout = io.StringIO()

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(
                [
                    "--candidate",
                    str(candidate),
                    "--candidate-integrity-only",
                ]
            )

        self.assertEqual(code, 0)
        result = json.loads(stdout.getvalue())
        integrity = result["candidate_integrity"]
        self.assertEqual(integrity["directory_count"], 0)
        self.assertEqual(integrity["file_count"], 1)
        self.assertEqual(integrity["skill_md_sha256"], WRAPPER.sha256_file(candidate / "SKILL.md"))
        self.assertEqual(result["excluded_files"]["file_count"], 1)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_transaction_without_decision_manifest_fails_closed(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "缺少 decision")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        args = self.wrapper_args(candidate, manifest)
        manifest_index = args.index("--decision-manifest")
        del args[manifest_index : manifest_index + 2]

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())
        self.assertFalse((self.temp / "staging").exists())
        self.assertFalse((self.temp / "lock").exists())
        self.assertFalse((self.temp / "evidence").exists())

    def test_update_excludes_git_but_keeps_old_git_in_transaction_backup(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        (active_skill / ".git").mkdir(parents=True)
        (active_skill / ".git" / "sentinel").write_text("old-history\n", encoding="utf-8")
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [
                        {"id": "local-test", "type": "local-candidate", "skills": [name]}
                    ],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(name, "replacement")
        (candidate / ".git").mkdir()
        (candidate / ".git" / "candidate-sentinel").write_text(
            "candidate-history\n", encoding="utf-8"
        )
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        self.assertFalse((active_skill / ".git").exists())
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        old_git = transaction.parent / "backups" / "active-skills" / name / ".git"
        self.assertEqual((old_git / "sentinel").read_text(encoding="utf-8"), "old-history\n")
        self.assertFalse((old_git / "candidate-sentinel").exists())

    def test_update_normalizes_read_only_metadata_before_backup_move(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        pack_file = active_skill / ".git" / "objects" / "pack" / "pack-test.idx"
        pack_file.parent.mkdir(parents=True)
        pack_file.write_bytes(b"read-only-pack\n")
        pack_file.chmod(stat.S_IREAD)
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [
                        {"id": "local-test", "type": "local-candidate", "skills": [name]}
                    ],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(name, "replacement")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")
        original_move = WRAPPER.shutil.move

        def reject_read_only_source(source: str, destination: str) -> str:
            source_root = Path(source)
            read_only = [
                path
                for path in source_root.rglob("*")
                if path.is_file() and not (path.stat().st_mode & stat.S_IWRITE)
            ]
            if read_only:
                raise PermissionError(f"read-only source: {read_only[0]}")
            return original_move(source, destination)

        with (
            mock.patch.object(WRAPPER.shutil, "move", side_effect=reject_read_only_source),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        old_pack = transaction.parent / "backups" / "active-skills" / name / ".git" / "objects" / "pack" / "pack-test.idx"
        self.assertEqual(old_pack.read_bytes(), b"read-only-pack\n")
        self.assertFalse(old_pack.stat().st_mode & stat.S_IWRITE)

    def test_partial_backup_move_failure_restores_complete_active_tree(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        old_git = active_skill / ".git"
        old_git.mkdir(parents=True)
        sentinel = old_git / "sentinel"
        sentinel.write_text("old-history\n", encoding="utf-8")
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [
                        {"id": "local-test", "type": "local-candidate", "skills": [name]}
                    ],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(name, "replacement")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        def partial_move_then_fail(source: str, destination: str) -> None:
            shutil.copytree(source, destination)
            (Path(source) / ".git" / "sentinel").unlink()
            raise PermissionError("injected cleanup failure after backup copy")

        with (
            mock.patch.object(WRAPPER.shutil, "move", side_effect=partial_move_then_fail),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "old-history\n")
        self.assertIn("baseline", (active_skill / "SKILL.md").read_text(encoding="utf-8"))
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")

    def test_unrecoverable_partial_backup_move_reports_rollback_failed(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        active_skill.mkdir()
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [
                        {"id": "local-test", "type": "local-candidate", "skills": [name]}
                    ],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(name, "replacement")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        with (
            mock.patch.object(
                WRAPPER.shutil,
                "move",
                side_effect=PermissionError("injected backup move failure"),
            ),
            mock.patch.object(
                WRAPPER,
                "restore_move_union",
                side_effect=WRAPPER.InstallError("injected restore failure"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rollback-failed")
        self.assertTrue(result["rollback_errors"])

    def test_missing_transaction_backup_keeps_active_and_reports_rollback_failed(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        active_skill.mkdir()
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [
                        {"id": "local-test", "type": "local-candidate", "skills": [name]}
                    ],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(name, "replacement")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        def hide_backup_then_fail(**_: object) -> dict[str, object]:
            transaction = max((self.temp / "evidence").glob("install-*"))
            backup = transaction / "backups" / "active-skills" / name
            withheld = transaction / "withheld-active-backup"
            shutil.move(backup, withheld)
            raise WRAPPER.InstallError("injected postcheck failure after backup loss")

        with (
            mock.patch.object(WRAPPER, "verify_catalog", side_effect=hide_backup_then_fail),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertTrue(active_skill.is_dir())
        self.assertIn("replacement", (active_skill / "SKILL.md").read_text(encoding="utf-8"))
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rollback-failed")
        self.assertTrue(result["rollback_errors"])

    def test_partial_writable_normalization_restores_original_read_only_paths(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        first_read_only = active_skill / "nested" / "first.txt"
        second_read_only = active_skill / "second.txt"
        first_read_only.parent.mkdir(parents=True)
        first_read_only.write_text("first\n", encoding="utf-8")
        second_read_only.write_text("second\n", encoding="utf-8")
        first_read_only.chmod(stat.S_IREAD)
        second_read_only.chmod(stat.S_IREAD)
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [
                        {"id": "local-test", "type": "local-candidate", "skills": [name]}
                    ],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(name, "replacement")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")
        path_type = type(first_read_only)
        original_chmod = path_type.chmod
        injected = False

        def fail_second_clear(
            path: Path,
            mode: int,
            *,
            follow_symlinks: bool = True,
        ) -> None:
            nonlocal injected
            if Path(path) == second_read_only and mode & stat.S_IWRITE and not injected:
                injected = True
                raise PermissionError("injected chmod failure")
            original_chmod(path, mode, follow_symlinks=follow_symlinks)

        with (
            mock.patch.object(path_type, "chmod", autospec=True, side_effect=fail_second_clear),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertTrue(injected)
        self.assertFalse(first_read_only.stat().st_mode & stat.S_IWRITE)
        self.assertFalse(second_read_only.stat().st_mode & stat.S_IWRITE)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")

    def test_candidate_source_manifest_preserves_reviewed_upstream_path(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "测试候选来源路径")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            upstream_path="plugins/qima/skills/test-skill-wrapper",
        )

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        source_record = (self.active / "test-skill-wrapper" / "SOURCE.md").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "Upstream path: `plugins/qima/skills/test-skill-wrapper`",
            source_record,
        )
        self.assertNotIn(f"Upstream path: `{candidate.name}`", source_record)

    def test_candidate_source_manifest_accepts_repository_root(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "测试仓库根来源路径")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            upstream_path=".",
        )

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        source_record = (self.active / "test-skill-wrapper" / "SOURCE.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("Upstream path: `.`", source_record)

    def test_candidate_upstream_path_must_be_repo_relative_posix_path(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "测试候选来源路径校验")
        invalid_paths = (
            "",
            "../outside",
            "/absolute/path",
            "C:/absolute/path",
            r"plugins\qima\skills\test-skill-wrapper",
            "plugins//qima",
            "plugins/./qima",
            "plugins/qima\nStatus: forged",
            "plugins/qima\x00skill",
            "plugins/qima\x7fskill",
            "plugins/qima`forged",
        )

        for upstream_path in invalid_paths:
            with self.subTest(upstream_path=upstream_path):
                manifest = self.write_manifest(
                    "test-skill-wrapper",
                    "install",
                    upstream_path=upstream_path,
                )
                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(self.wrapper_args(candidate, manifest))

                active_skill = self.active / "test-skill-wrapper"
                try:
                    self.assertEqual(code, 2)
                    self.assertFalse(active_skill.exists())
                finally:
                    shutil.rmtree(active_skill, ignore_errors=True)

    def test_install_uses_default_status_without_ledger_updates(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "默认 ledger 状态")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))
        self.assertEqual(code, 0)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = next(item for item in ledger["sources"] if item["id"] == "local-test")
        self.assertEqual(source["status"], "installed-by-guarded-wrapper")

    def test_install_rejects_unknown_ledger_update_field_before_activation(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "未知 ledger 字段")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            ledger_updates={"unknown": "not allowed"},
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))
        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_install_rejects_non_list_resource_paths_before_activation(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "错误 resource paths")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            ledger_updates={"resource_paths": "skill/SKILL.md"},
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))
        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_install_rejects_empty_resource_paths_before_activation(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "空 resource paths")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            ledger_updates={"resource_paths": []},
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))
        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_install_drops_private_staging_acl_and_verifies_new_process_readability(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "测试 ACL 继承")
        references = candidate / "references"
        references.mkdir()
        (references / "guide.md").write_text("runtime-readable\n", encoding="utf-8")
        self.protect_private_candidate_tree(candidate)
        manifest = self.write_manifest("test-skill-wrapper", "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        active_skill = self.active / "test-skill-wrapper"
        acl = self.acl_state(active_skill)
        self.assertFalse(acl["protected"])
        inherited_identities = {
            item["identity"]
            for item in acl["rules"]
            if item["inherited"] and item["type"] == "Allow"
        }
        self.assertIn("NT AUTHORITY\\Authenticated Users", inherited_identities)
        self.assertIn("BUILTIN\\Users", inherited_identities)

        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["activation_readability"]["status"], "passed")
        self.assertGreaterEqual(result["activation_readability"]["file_count"], 3)

    def test_staging_failure_before_backups_preserves_ledger_and_catalog(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "测试 staging 失败")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"artifacts":[{"name":"existing"}]}\n')
        ledger_before = self.ledger.read_bytes()
        catalog_before = catalog.read_bytes()
        args = [*self.wrapper_args(candidate, manifest), "--dry-run"]

        with (
            mock.patch.object(
                WRAPPER,
                "stage_candidate",
                side_effect=WRAPPER.InstallError("injected staging failure"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(catalog.read_bytes(), catalog_before)

    def test_catalog_failure_rolls_back_active_skill_and_ledger(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        active_skill.mkdir()
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [{"id": "local-test", "type": "local-candidate", "skills": [name]}],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(name, "replacement")
        manifest = self.write_manifest(name, "update")
        failing_generator = self.temp / "failing-generator.py"
        failing_generator.write_text("import sys\nsys.exit(7)\n", encoding="utf-8")
        args = self.wrapper_args(candidate, manifest, generator=failing_generator)
        args.insert(2, "--update")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(args)
        self.assertEqual(code, 2)
        self.assertIn("baseline", (active_skill / "SKILL.md").read_text(encoding="utf-8"))
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        self.assertEqual(ledger["sources"][0]["skills"], [name])

    def test_activation_readability_failure_restores_content_acl_and_ledger(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        active_skill.mkdir()
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (active_skill / "SOURCE.md").write_text(
            f"# Source Provenance\n\nSkill: `{name}`\nStatus: source-review\n",
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [{"id": "local-test", "type": "local-candidate", "skills": [name]}],
                    "unresolved": [],
                    "deleted": [],
                }
            ),
            encoding="utf-8",
        )
        before_acl = self.acl_state(active_skill)
        before_ledger = self.ledger.read_bytes()
        candidate = self.write_candidate(name, "replacement")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        with (
            mock.patch.object(
                WRAPPER,
                "verify_activation_readability",
                side_effect=WRAPPER.InstallError("injected runtime readability failure"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertIn("baseline", (active_skill / "SKILL.md").read_text(encoding="utf-8"))
        self.assertEqual(self.ledger.read_bytes(), before_ledger)
        after_acl = self.acl_state(active_skill)
        self.assertEqual(after_acl["owner"], before_acl["owner"])
        self.assertEqual(after_acl["sddl"], before_acl["sddl"])
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")


if __name__ == "__main__":
    unittest.main()
