#!/usr/bin/env python3
"""Transaction tests for the guarded skill install: activation, backups, rollback, ACLs, junctions.

Each other installer responsibility has its own ``Test-SkillInstallGuarded<Area>.py`` file;
the shared fixtures are in ``guarded_install_fixtures.py``.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import msvcrt
import os
import stat
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock


TESTS_ROOT = Path(__file__).resolve().parent
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from guarded_install_fixtures import (
    ACTIVATION,
    BASE,
    CLOSURE,
    SOURCE_RECORD,
    STAGING,
    SUBPROCESS_CREATION_FLAGS,
    SUBPROCESS_TEXT_ENCODING,
    TREE,
    WRAPPER,
    GuardedInstallTestCase,
)


class SkillInstallGuardedTests(GuardedInstallTestCase):
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

    def test_install_updates_source_ledger_and_catalog(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "受管包装器的安装测试夹具")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            ledger_updates={
                "action": "updated",
                "installed_version": "3.5.1",
                "path": ".codex/skills/test-skill-wrapper",
                "repo_stars": 19292,
                "repo_stars_checked_at": "2026-08-06",
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
        self.assertEqual(source["repo_stars"], 19292)
        self.assertEqual(source["repo_stars_checked_at"], "2026-08-06")
        self.assertEqual(source["resource_paths"], ["skill/SKILL.md"])
        self.assertEqual(source["status"], "updated-with-local-overlay")
        self.assertEqual(source["tag"], "v3.5.1")
        catalog = json.loads((self.temp / "catalog.json").read_text(encoding="utf-8"))
        artifact = next(item for item in catalog["artifacts"] if item.get("name") == "test-skill-wrapper")
        self.assertEqual(artifact["ledger_coverage"], "pass")
        self.assertEqual(catalog["checks"]["resource_closure"]["status"], "pass")
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        snapshot = json.loads(transaction.read_text(encoding="utf-8"))["source_state_after"]
        ledger_bytes = self.ledger.read_bytes()
        self.assertEqual(Path(snapshot["path"]), transaction.parent / "backups" / "source-state-after.json")
        self.assertEqual(Path(snapshot["path"]).read_bytes(), ledger_bytes)
        self.assertEqual(snapshot["sha256"], hashlib.sha256(ledger_bytes).hexdigest())

        artifact["source"]["status"] = "unknown"
        artifact["source"]["conflicts"] = []
        (self.temp / "catalog.json").write_text(
            json.dumps(catalog, ensure_ascii=False),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            BASE.InstallError,
            "SOURCE.md 存在冲突、未知或缺失",
        ):
            CLOSURE.verify_catalog(
                catalog_path=self.temp / "catalog.json",
                active_root=self.active,
                names=["test-skill-wrapper"],
                bundled_proofs=(),
            )

    def test_system_scope_installs_under_system_and_verifies_catalog(self) -> None:
        name = "test-system-skill"
        (self.active / ".system").mkdir()
        candidate = self.write_candidate(name, "系统作用域安装测试夹具")
        manifest = self.write_manifest(
            name,
            "install",
            source_id="codex-bundled-system-skills",
        )
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["target_scope"] = "system"
        payload["local_overlay"] = {
            "status": "replayed",
            "summary": "writing-for-agents system overlay",
        }
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest, name=name))

        self.assertEqual(code, 0)
        system_skill = self.active / ".system" / name
        self.assertTrue((system_skill / "SKILL.md").is_file())
        self.assertFalse((self.active / name).exists())
        source_record = SOURCE_RECORD.parse_current_source_record(
            (system_skill / "SOURCE.md").read_text(encoding="utf-8")
        )
        self.assertEqual(source_record.fields["skill"], f".system/{name}")
        self.assertEqual(
            source_record.fields["local_path"],
            str(system_skill),
        )

        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = next(
            item
            for item in ledger["sources"]
            if item["id"] == "codex-bundled-system-skills"
        )
        self.assertEqual(source["skills"], [f".system/{name}"])
        self.assertEqual(
            source["local_changes"][0]["skill"],
            f".system/{name}",
        )

        catalog = json.loads((self.temp / "catalog.json").read_text(encoding="utf-8"))
        artifact = next(
            item
            for item in catalog["artifacts"]
            if item.get("relative_path") == f".system/{name}/SKILL.md"
        )
        self.assertEqual(artifact["scope"], "system")
        self.assertEqual(artifact["ledger_coverage"], "pass")
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["target_scope"], "system")
        self.assertEqual(Path(result["target_root"]), self.active / ".system")

    def test_candidate_source_allows_non_temp_prefix_peer(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "允许相邻持久路径")
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Source Provenance",
                    "",
                    "Skill: `test-skill-wrapper`",
                    r"Reference archive: `D:\Codex\tmp-archive\reviewed-source`",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        manifest = self.write_manifest("test-skill-wrapper", "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        source_record = (
            self.active / "test-skill-wrapper" / "SOURCE.md"
        ).read_text(encoding="utf-8")
        self.assertIn(r"D:\Codex\tmp-archive\reviewed-source", source_record)

    def test_staging_seal_drift_is_rejected_before_activation(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "拒绝 staging seal 漂移")
        manifest = self.write_manifest(name, "install")
        original_activate = ACTIVATION.activate_directories

        def mutate_staging_then_activate(**kwargs: object) -> list[dict[str, object]]:
            stage_root = Path(kwargs["stage_root"])
            (stage_root / name / ".git").mkdir()
            return original_activate(**kwargs)

        with (
            mock.patch.object(ACTIVATION, "activate_directories", mutate_staging_then_activate),
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
        original_copy = TREE.copy_tree_without_security_metadata
        junction_target = self.temp / "junction-target"
        junction_target.mkdir()
        sentinel = junction_target / "sentinel.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")

        def copy_then_mutate(source: Path, destination: Path) -> None:
            original_copy(source, destination)
            self.create_junction(destination / "late-junction", junction_target)

        with (
            mock.patch.object(TREE, "copy_tree_without_security_metadata", copy_then_mutate),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertFalse((self.active / name).exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_update_excludes_git_but_keeps_old_git_in_transaction_backup(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        (active_skill / ".git").mkdir(parents=True)
        (active_skill / ".git" / "sentinel").write_text("old-history\n", encoding="utf-8")
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
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
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")
        original_move = shutil.move

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
            mock.patch.object(shutil, "move", side_effect=reject_read_only_source),
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
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        def partial_move_then_fail(source: str, destination: str) -> None:
            shutil.copytree(source, destination)
            (Path(source) / ".git" / "sentinel").unlink()
            raise PermissionError("injected cleanup failure after backup copy")

        with (
            mock.patch.object(shutil, "move", side_effect=partial_move_then_fail),
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
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        with (
            mock.patch.object(
                shutil,
                "move",
                side_effect=PermissionError("injected backup move failure"),
            ),
            mock.patch.object(
                ACTIVATION,
                "restore_move_union",
                side_effect=BASE.InstallError("injected restore failure"),
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
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        def hide_backup_then_fail(**_: object) -> dict[str, object]:
            transaction = max((self.temp / "evidence").glob("install-*"))
            backup = transaction / "backups" / "active-skills" / name
            withheld = transaction / "withheld-active-backup"
            shutil.move(backup, withheld)
            raise BASE.InstallError("injected postcheck failure after backup loss")

        with (
            mock.patch.object(CLOSURE, "verify_catalog", side_effect=hide_backup_then_fail),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertTrue(active_skill.is_dir())
        self.assertIn("替换后的夹具描述", (active_skill / "SKILL.md").read_text(encoding="utf-8"))
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
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
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
                STAGING,
                "stage_candidate",
                side_effect=BASE.InstallError("injected staging failure"),
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
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
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
        self.assertEqual(list((self.temp / "evidence").glob("install-*/backups/source-state-after.json")), [])

    def test_activation_readability_failure_restores_content_acl_and_ledger(self) -> None:
        name = "test-skill-wrapper"
        active_skill = self.active / name
        active_skill.mkdir()
        (active_skill / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
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
        candidate = self.write_candidate(name, "替换后的夹具描述")
        manifest = self.write_manifest(name, "update")
        args = self.wrapper_args(candidate, manifest)
        args.insert(2, "--update")

        with (
            mock.patch.object(
                ACTIVATION,
                "verify_activation_readability",
                side_effect=BASE.InstallError("injected runtime readability failure"),
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

    def test_candidate_parent_junction_is_rejected_without_touching_target(self) -> None:
        target = self.temp / "external-candidate-target"
        junction = self.temp / "candidate-parent-junction"
        self.create_junction(junction, target)
        candidate = target / "candidate-through-junction"
        candidate.mkdir()
        (candidate / "SKILL.md").write_text(
            "---\nname: junction-candidate\ndescription: 拒绝父级 junction 的夹具\n---\n",
            encoding="utf-8",
        )
        sentinel = target / "sentinel.txt"
        sentinel.write_text("outside-preserved\n", encoding="utf-8")

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(
                [
                    "--candidate",
                    str(junction / candidate.name),
                    "--candidate-integrity-only",
                ]
            )

        self.assertEqual(code, 2)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside-preserved\n")
        self.assertTrue(candidate.is_dir())

    def test_active_root_parent_junction_is_rejected_without_touching_target(self) -> None:
        target = self.temp / "external-active-target"
        junction = self.temp / "active-parent-junction"
        self.create_junction(junction, target)
        linked_active = junction / "active"
        (target / "active").mkdir()
        sentinel = target / "sentinel.txt"
        sentinel.write_text("outside-preserved\n", encoding="utf-8")
        candidate = self.write_candidate("test-skill-wrapper", "拒绝激活父级 junction 夹具")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        args = self.wrapper_args(candidate, manifest)
        active_index = args.index("--active-root")
        args[active_index + 1] = str(linked_active)
        args.append("--dry-run")

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside-preserved\n")
        self.assertEqual(list((target / "active").iterdir()), [])


    def test_summary_payload_excludes_full_manifest(self) -> None:
        result = {
            "status": "succeeded",
            "targets": ["example"],
            "evidence": "D:/agents/run-evidence/example",
            "autoBackup": {"after": {"active": False}},
            "staged": {"large": "manifest"},
            "directory_records": [{"large": "records"}],
        }
        summary = WRAPPER.summary_payload(result)
        self.assertEqual("succeeded", summary["status"])
        self.assertFalse(summary["autoBackup"]["after"]["active"])
        self.assertNotIn("staged", summary)
        self.assertNotIn("directory_records", summary)

    def test_auto_backup_state_treats_an_unlocked_file_as_idle_whatever_it_names(self) -> None:
        lock = self.temp / ".skills-manager.lock"
        for operation in ("auto backup", "auto backup on exit"):
            with self.subTest(operation=operation):
                lock.write_text(f"pid={os.getpid()}\nhostname=fixture\noperation={operation}\nstart_time=fixture\n", encoding="utf-8")
                state = WRAPPER.auto_backup_state(self.active)
                self.assertFalse(state["active"])
                self.assertEqual(operation, state["operation"])
                self.assertEqual(os.getpid(), state["pid"])

    def test_wait_for_auto_backup_waits_while_the_lock_is_held_then_times_out(self) -> None:
        lock = self.temp / ".skills-manager.lock"
        lock.write_text(f"pid={os.getpid()}\nhostname=fixture\noperation=auto backup\nstart_time=fixture\n", encoding="utf-8")
        # Skills Manager holds a byte-range lock on the file while a round runs; a second handle in
        # this process is shut out of the locked bytes the same way another process is.
        with lock.open("r+b") as holder:
            msvcrt.locking(holder.fileno(), msvcrt.LK_NBLCK, 1 << 20)
            try:
                self.assertTrue(WRAPPER.auto_backup_state(self.active)["active"])
                started = time.monotonic()
                with self.assertRaisesRegex(BASE.InstallError, "auto backup remains active"):
                    WRAPPER.wait_for_auto_backup(self.active, timeout_seconds=0.6)
                self.assertGreaterEqual(time.monotonic() - started, 0.6)
            finally:
                holder.seek(0)
                msvcrt.locking(holder.fileno(), msvcrt.LK_UNLCK, 1 << 20)
        self.assertFalse(WRAPPER.wait_for_auto_backup(self.active, timeout_seconds=0.6)["active"])

    def test_active_backup_times_out_instead_of_claiming_success(self) -> None:
        with mock.patch.object(WRAPPER, "auto_backup_state", return_value={"active": True, "path": "fixture-lock"}):
            with self.assertRaisesRegex(WRAPPER.InstallError if hasattr(WRAPPER, "InstallError") else BASE.InstallError, "auto backup remains active"):
                WRAPPER.wait_for_auto_backup(self.active, timeout_seconds=0)


if __name__ == "__main__":
    unittest.main()
