#!/usr/bin/env python3
"""Focused tests for the guarded skill install transaction."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
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
            encoding="utf-8",
            errors="replace",
            check=False,
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
                encoding="utf-8",
                errors="replace",
                check=False,
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
            encoding="utf-8-sig",
            errors="replace",
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        return json.loads(result.stdout)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp, ignore_errors=True)

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
    ) -> Path:
        path = self.temp / f"manifest-{name}-{decision}.json"
        source: dict[str, object] = {"id": source_id, "ref": "local"}
        if ledger_updates is not None:
            source["ledger_updates"] = ledger_updates
        path.write_text(
            json.dumps(
                {
                    "decision": decision,
                    "source_status": "source-review",
                    "writing_great_skills": {"status": "no-change"},
                    "skills": [name],
                    "source": source,
                },
                ensure_ascii=False,
            ),
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
        catalog = json.loads((self.temp / "catalog.json").read_text(encoding="utf-8"))
        artifact = next(item for item in catalog["artifacts"] if item.get("name") == "test-skill-wrapper")
        self.assertEqual(artifact["ledger_coverage"], "pass")
        self.assertEqual(catalog["checks"]["resource_closure"]["status"], "pass")

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
