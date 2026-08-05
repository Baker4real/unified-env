#!/usr/bin/env python3
"""Focused tests for the guarded skill install transaction."""

from __future__ import annotations

import contextlib
import hashlib
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

    def write_openai_yaml(self, candidate: Path, display_name: str) -> None:
        agents = candidate / "agents"
        agents.mkdir()
        (agents / "openai.yaml").write_text(
            "\n".join(
                [
                    "interface:",
                    f'  display_name: "{display_name}"',
                    '  short_description: "中文说明"',
                    '  default_prompt: "使用 $test-skill-wrapper 完成任务。"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

    def write_bundled_skill(
        self,
        candidate: Path,
        relative_path: str,
        name: str,
        *,
        include_source: bool = True,
    ) -> Path:
        bundled = candidate.joinpath(*relative_path.split("/"))
        bundled.mkdir(parents=True)
        (bundled / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: bundled fixture\n---\n\n# {name}\n",
            encoding="utf-8",
        )
        if include_source:
            (bundled / "SOURCE.md").write_text(
                "\n".join(
                    [
                        "# Source Provenance",
                        "",
                        f"Skill: `{name}`",
                        "Source repository: `https://github.com/example/bundled-runtime`",
                        f"Upstream path: `{relative_path}`",
                        "Ref: `v1.2.3`",
                        "Commit or revision: `0123456789abcdef`",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
        return bundled

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

    def wrapper_args(
        self,
        candidate: Path,
        manifest: Path,
        *,
        generator: Path | None = None,
        name: str = "test-skill-wrapper",
    ) -> list[str]:
        return [
            "--candidate",
            str(candidate),
            "--name",
            name,
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

    def prepare_canonical_rename(
        self,
        *,
        old_name: str = "old-orchestration",
        new_name: str = "new-orchestration",
        source_id: str = "orchestration-source",
        source_repo: str = "https://github.com/example/orchestration",
    ) -> dict[str, object]:
        source_commit = "0123456789abcdef"
        upstream_path = "skills/orchestration"
        old_skill = self.active / old_name
        old_skill.mkdir()
        (old_skill / "SKILL.md").write_text(
            f"---\nname: {old_name}\ndescription: baseline\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (old_skill / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Source Provenance",
                    "",
                    f"Skill: `{old_name}`",
                    f"Source repository: `{source_repo}`",
                    f"Upstream path: `{upstream_path}`",
                    "Ref: `main`",
                    f"Commit or revision: `{source_commit}`",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [
                        {
                            "id": f"{source_id}-same-repo-decoy",
                            "type": "github",
                            "repo": source_repo,
                            "ref": "main",
                            "skills": [],
                        },
                        {
                            "id": source_id,
                            "type": "github",
                            "repo": source_repo,
                            "ref": "main",
                            "skills": [old_name],
                            "last_checked_commit": source_commit,
                            "catalog_ref": source_commit,
                        }
                    ],
                    "unresolved": [],
                    "deleted": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(new_name, "canonical successor")
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Source Provenance",
                    "",
                    f"Skill: `{new_name}`",
                    f"Canonical predecessor: `{old_name}`",
                    f"Source identity: `{source_id}`",
                    f"Source repository: `{source_repo}`",
                    f"Upstream path: `{upstream_path}`",
                    "Ref: `main`",
                    f"Commit or revision: `{source_commit}`",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        manifest = self.write_manifest(new_name, "update", source_id=source_id)
        manifest_payload = json.loads(manifest.read_text(encoding="utf-8"))
        manifest_payload["source"].update(
            {
                "repo": source_repo,
                "ref": "main",
                "commit": source_commit,
                "upstream_path": upstream_path,
            }
        )
        manifest_payload["canonical_rename"] = {
            "old_name": old_name,
            "new_name": new_name,
            "source_id": source_id,
        }
        manifest_payload["local_overlay"] = {
            "status": "replayed",
            "summary": f"canonical rename {old_name} -> {new_name}",
        }
        manifest_payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(
            candidate
        )
        manifest.write_text(
            json.dumps(manifest_payload, ensure_ascii=False),
            encoding="utf-8",
        )
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"sentinel":"before"}\n')
        return {
            "old_name": old_name,
            "new_name": new_name,
            "old_skill": old_skill,
            "candidate": candidate,
            "manifest": manifest,
            "catalog": catalog,
            "source_id": source_id,
            "source_repo": source_repo,
            "source_commit": source_commit,
            "upstream_path": upstream_path,
        }

    def assert_canonical_rename_rollback(
        self,
        state: dict[str, object],
        *,
        ledger_before: bytes,
        catalog_before: bytes,
        old_seal: dict[str, object],
    ) -> None:
        old_skill = Path(state["old_skill"])
        new_skill = self.active / str(state["new_name"])
        self.assertTrue(old_skill.is_dir())
        self.assertFalse(new_skill.exists())
        self.assertEqual(WRAPPER.tree_content_seal(old_skill), old_seal)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")

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

        artifact["source"]["status"] = "unknown"
        artifact["source"]["conflicts"] = []
        (self.temp / "catalog.json").write_text(
            json.dumps(catalog, ensure_ascii=False),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            WRAPPER.InstallError,
            "SOURCE.md 存在冲突、未知或缺失",
        ):
            WRAPPER.verify_catalog(
                catalog_path=self.temp / "catalog.json",
                active_root=self.active,
                names=["test-skill-wrapper"],
                bundled_proofs=(),
            )

    def test_install_rejects_chinese_display_name_before_activation(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "中文 identity 必须失败闭锁")
        self.write_openai_yaml(candidate, "测试写作")
        manifest = self.write_manifest(name, "install")
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"artifacts":[{"name":"existing"}]}\n')
        ledger_before = self.ledger.read_bytes()
        catalog_before = catalog.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("interface.display_name 必须保留英文", stderr.getvalue())
        self.assertFalse((self.active / name).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(catalog.read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*"))
        self.assertFalse((transaction / "backups").exists())

    def test_install_rejects_non_ascii_display_name_before_activation(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "非 ASCII identity 必须失败闭锁")
        self.write_openai_yaml(candidate, "\U00020000")
        manifest = self.write_manifest(name, "install")
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"artifacts":[{"name":"existing"}]}\n')
        ledger_before = self.ledger.read_bytes()
        catalog_before = catalog.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("interface.display_name 必须保留英文", stderr.getvalue())
        self.assertFalse((self.active / name).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(catalog.read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*"))
        self.assertFalse((transaction / "backups").exists())

    def test_install_rejects_malformed_openai_yaml_before_backups(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "非法 YAML 必须失败闭锁")
        agents = candidate / "agents"
        agents.mkdir()
        (agents / "openai.yaml").write_text(
            "interface: [unterminated\n",
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"artifacts":[{"name":"existing"}]}\n')
        ledger_before = self.ledger.read_bytes()
        catalog_before = catalog.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("agents/openai.yaml 不是合法 YAML", stderr.getvalue())
        self.assertFalse((self.active / name).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(catalog.read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*"))
        self.assertFalse((transaction / "backups").exists())

    def test_install_governs_declared_bundled_skill_in_same_transaction(self) -> None:
        name = "test-skill-wrapper"
        relative_path = "node_modules/example-runtime/lib/skills/trace"
        bundled_name = "example-trace"
        candidate = self.write_candidate(name, "bundled skill transaction")
        self.write_bundled_skill(candidate, relative_path, bundled_name)
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["bundled_skills"] = [
            {"path": relative_path, "name": bundled_name}
        ]
        payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0, stdout.getvalue())
        ledger_key = f"{name}/{relative_path}"
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = next(item for item in ledger["sources"] if item["id"] == "local-test")
        self.assertEqual(source["skills"], [name, ledger_key])
        self.assertEqual(
            source["bundled_skills"],
            [{"path": ledger_key, "name": bundled_name}],
        )

        catalog = json.loads((self.temp / "catalog.json").read_text(encoding="utf-8"))
        bundled = [
            item
            for item in catalog["artifacts"]
            if item.get("scope") == "active"
            and item.get("relative_path") == f"{ledger_key}/SKILL.md"
        ]
        self.assertEqual(len(bundled), 1)
        self.assertEqual(bundled[0]["name"], bundled_name)
        self.assertEqual(bundled[0]["ledger_coverage"], "pass")

        result = json.loads(stdout.getvalue())
        verified_paths = {
            item["path"] for item in result["catalog_verification"]["skills"]
        }
        self.assertEqual(verified_paths, {name, ledger_key})
        bundled_verification = next(
            item
            for item in result["catalog_verification"]["skills"]
            if item["path"] == ledger_key
        )
        self.assertIn("source_md_sha256", bundled_verification)
        self.assertEqual(
            set(result["staged"]["bundled_skills"][0]),
            {
                "path",
                "name",
                "ledger_key",
                "skill_md_sha256",
                "source_md_sha256",
            },
        )
        staged_proofs = tuple(
            WRAPPER.BundledSkillProof.from_staged_projection(item)
            for item in result["staged"]["bundled_skills"]
        )

        active_source = self.active / ledger_key / "SOURCE.md"
        original_source = active_source.read_text(encoding="utf-8")
        active_source.write_text(
            original_source.replace(
                "0123456789abcdef",
                "fedcba9876543210",
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            WRAPPER.InstallError,
            "SOURCE.md 与暂存期哈希不一致",
        ):
            WRAPPER.verify_catalog(
                catalog_path=self.temp / "catalog.json",
                active_root=self.active,
                names=[name],
                bundled_proofs=staged_proofs,
            )
        active_source.write_text(original_source, encoding="utf-8")

        active_skill = self.active / ledger_key / "SKILL.md"
        active_skill.write_text(
            active_skill.read_text(encoding="utf-8").replace(
                "bundled fixture",
                "modified bundled fixture",
            ),
            encoding="utf-8",
        )
        bundled[0]["integrity"]["skill_md_sha256"] = WRAPPER.sha256_file(active_skill)
        (self.temp / "catalog.json").write_text(
            json.dumps(catalog, ensure_ascii=False),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            WRAPPER.InstallError,
            "SKILL.md 与暂存期哈希不一致",
        ):
            WRAPPER.verify_catalog(
                catalog_path=self.temp / "catalog.json",
                active_root=self.active,
                names=[name],
                bundled_proofs=staged_proofs,
            )

    def test_update_ledger_preserves_bundled_entries_for_other_source_roots(self) -> None:
        data = {
            "sources": [
                {
                    "id": "shared-source",
                    "skills": [
                        "root-a",
                        "root-a/vendor/old-skill",
                        "root-b",
                        "root-b/vendor/kept-skill",
                    ],
                    "bundled_skills": [
                        {"path": "root-a/vendor/old-skill", "name": "old-skill"},
                        {"path": "root-b/vendor/kept-skill", "name": "kept-skill"},
                    ],
                }
            ],
            "unresolved": [],
            "deleted": [],
        }
        context = {
            "source_id": "shared-source",
            "source_type": "github",
            "repo": "https://github.com/example/shared-source",
            "ref": "v2.0.0",
            "commit": "abcdef0123456789",
            "ledger_updates": {},
            "bundled_skill_proofs": (
                WRAPPER.BundledSkillProof(
                    top_level_name="root-a",
                    path="vendor/new-skill",
                    name="new-skill",
                ),
            ),
            "overlay_status": "none",
            "overlay_summary": "",
        }

        result = WRAPPER.update_ledger(data, names=["root-a"], context=context)

        source = result["sources"][0]
        self.assertEqual(
            source["bundled_skills"],
            [
                {"path": "root-b/vendor/kept-skill", "name": "kept-skill"},
                {"path": "root-a/vendor/new-skill", "name": "new-skill"},
            ],
        )
        self.assertEqual(
            set(source["skills"]),
            {
                "root-a",
                "root-a/vendor/new-skill",
                "root-b",
                "root-b/vendor/kept-skill",
            },
        )

    def test_update_ledger_without_bundled_skills_removes_only_current_root_entries(self) -> None:
        data = {
            "sources": [
                {
                    "id": "shared-source",
                    "skills": [
                        "root-a",
                        "root-a/vendor/old-skill",
                        "root-b",
                        "root-b/vendor/kept-skill",
                    ],
                    "bundled_skills": [
                        {"path": "root-a/vendor/old-skill", "name": "old-skill"},
                        {"path": "root-b/vendor/kept-skill", "name": "kept-skill"},
                    ],
                }
            ],
            "unresolved": [],
            "deleted": [],
        }
        context = {
            "source_id": "shared-source",
            "source_type": "github",
            "repo": "https://github.com/example/shared-source",
            "ref": "v2.0.0",
            "commit": "abcdef0123456789",
            "ledger_updates": {},
            "bundled_skill_proofs": (),
            "overlay_status": "none",
            "overlay_summary": "",
        }

        result = WRAPPER.update_ledger(data, names=["root-a"], context=context)

        source = result["sources"][0]
        self.assertEqual(
            source["bundled_skills"],
            [{"path": "root-b/vendor/kept-skill", "name": "kept-skill"}],
        )
        self.assertEqual(
            set(source["skills"]),
            {"root-a", "root-b", "root-b/vendor/kept-skill"},
        )

    def test_update_ledger_removes_replaced_bundle_from_other_source(self) -> None:
        data = {
            "sources": [
                {
                    "id": "old-source",
                    "skills": ["root-a", "root-a/vendor/old-skill"],
                    "bundled_skills": [
                        {"path": "root-a/vendor/old-skill", "name": "old-skill"}
                    ],
                },
                {"id": "new-source", "skills": []},
            ],
            "unresolved": [],
            "deleted": [],
        }
        context = {
            "source_id": "new-source",
            "source_type": "github",
            "repo": "https://github.com/example/new-source",
            "ref": "v2.0.0",
            "commit": "abcdef0123456789",
            "ledger_updates": {},
            "bundled_skill_proofs": (
                WRAPPER.BundledSkillProof(
                    top_level_name="root-a",
                    path="vendor/new-skill",
                    name="new-skill",
                ),
            ),
            "overlay_status": "none",
            "overlay_summary": "",
        }

        result = WRAPPER.update_ledger(data, names=["root-a"], context=context)

        old_source = next(item for item in result["sources"] if item["id"] == "old-source")
        new_source = next(item for item in result["sources"] if item["id"] == "new-source")
        self.assertEqual(old_source["skills"], [])
        self.assertNotIn("bundled_skills", old_source)
        self.assertEqual(
            new_source["bundled_skills"],
            [{"path": "root-a/vendor/new-skill", "name": "new-skill"}],
        )

    def test_bundled_skill_rejects_parent_traversal_path(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "reject bundled traversal")
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["bundled_skills"] = [
            {"path": "../outside/skill", "name": "outside-skill"}
        ]
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("bundled_skills[0].path", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_bundled_skill_requires_source_record(self) -> None:
        name = "test-skill-wrapper"
        relative_path = "vendor/runtime/skill"
        candidate = self.write_candidate(name, "require bundled source")
        self.write_bundled_skill(
            candidate,
            relative_path,
            "vendor-runtime",
            include_source=False,
        )
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["bundled_skills"] = [
            {"path": relative_path, "name": "vendor-runtime"}
        ]
        payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("bundled skill 缺少安全的 SOURCE.md", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_bundled_skill_frontmatter_name_must_match_manifest(self) -> None:
        name = "test-skill-wrapper"
        relative_path = "vendor/runtime/skill"
        candidate = self.write_candidate(name, "bind bundled name")
        self.write_bundled_skill(candidate, relative_path, "actual-runtime")
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["bundled_skills"] = [
            {"path": relative_path, "name": "declared-runtime"}
        ]
        payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("bundled skill name 与 manifest 不一致", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_bundled_skill_rejects_chinese_display_name_before_activation(self) -> None:
        name = "test-skill-wrapper"
        bundled_name = "vendor-runtime"
        relative_path = "vendor/runtime/skill"
        candidate = self.write_candidate(name, "reject bundled Chinese identity")
        bundled = self.write_bundled_skill(candidate, relative_path, bundled_name)
        self.write_openai_yaml(bundled, "供应商运行时")
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["bundled_skills"] = [{"path": relative_path, "name": bundled_name}]
        payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"artifacts":[{"name":"existing"}]}\n')
        ledger_before = self.ledger.read_bytes()
        catalog_before = catalog.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("interface.display_name 必须保留英文", stderr.getvalue())
        self.assertFalse((self.active / name).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(catalog.read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*"))
        self.assertFalse((transaction / "backups").exists())

    def test_bundled_skill_rejects_casefold_collision_with_top_level_name(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "reject bundle name collision")
        self.write_bundled_skill(candidate, "vendor/runtime/skill", "Test-Skill-Wrapper")
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["bundled_skills"] = [
            {"path": "vendor/runtime/skill", "name": "Test-Skill-Wrapper"}
        ]
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("bundled_skills[0].name 重复", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_bundled_skill_rejects_unsafe_source_repository_url(self) -> None:
        invalid_urls = (
            "https://token@example.invalid/bundled-runtime",
            "https://example.invalid/bundled-runtime?token=secret",
            "https://example.invalid/bundled-runtime#fragment",
            "https:///bundled-runtime",
            "https://example.invalid",
        )
        relative_path = "vendor/runtime/skill"
        for index, invalid_url in enumerate(invalid_urls):
            with self.subTest(source_repository=invalid_url):
                name = f"test-skill-wrapper-{index}"
                candidate = self.write_candidate(name, "reject unsafe bundle source")
                bundled = self.write_bundled_skill(
                    candidate,
                    relative_path,
                    f"vendor-runtime-{index}",
                )
                source = bundled / "SOURCE.md"
                source.write_text(
                    source.read_text(encoding="utf-8").replace(
                        "https://github.com/example/bundled-runtime",
                        invalid_url,
                    ),
                    encoding="utf-8",
                )
                manifest = self.write_manifest(name, "install")
                payload = json.loads(manifest.read_text(encoding="utf-8"))
                payload["bundled_skills"] = [
                    {"path": relative_path, "name": f"vendor-runtime-{index}"}
                ]
                payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
                manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    code = WRAPPER.main(
                        self.wrapper_args(candidate, manifest, name=name)
                    )

                self.assertEqual(code, 2)
                self.assertIn(
                    f"bundled skill vendor-runtime-{index}",
                    stderr.getvalue(),
                )
                self.assertIn("不含凭据的 HTTPS source repository", stderr.getvalue())
                self.assertFalse((self.active / name).exists())

    def test_candidate_source_uses_only_final_record(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "current source record")
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Historical provenance",
                    "Skill: `retired-skill`",
                    "Status: retired",
                    "",
                    "---",
                    "",
                    "# Current provenance",
                    f"Skill: `{name}`",
                    "Status: source-review",
                    "Status: source-review",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        self.assertTrue((self.active / name / "SOURCE.md").is_file())

    def test_candidate_source_normalizes_quoted_current_identity(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "quoted current source identity")
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    f"Skill: ` {name} `",
                    "Status: source-review",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        self.assertTrue((self.active / name / "SOURCE.md").is_file())

    def test_candidate_source_blank_current_identity_fails_closed(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "blank current source identity")
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "Skill:",
                    f"Skill: `{name}`",
                    "Status: source-review",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("候选 SOURCE.md 当前记录存在冲突", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_candidate_source_without_current_identity_fails_closed(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "unknown current source record")
        (candidate / "SOURCE.md").write_text(
            "Arbitrary note: value\n",
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("候选 SOURCE.md 当前记录缺少 Skill identity", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_candidate_source_empty_final_record_fails_closed(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "empty final source record")
        source = candidate / "SOURCE.md"
        source.write_text(
            f"Skill: `{name}`\nStatus: source-review\n---\n",
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("候选 SOURCE.md 当前记录存在冲突", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_candidate_source_current_conflict_fails_closed(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "conflicting current source record")
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "Skill: `retired-skill`",
                    "Status: retired",
                    "",
                    "---",
                    "",
                    f"Skill: `{name}`",
                    "Status: source-review",
                    "Status: pending-review",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("候选 SOURCE.md 当前记录存在冲突", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_bundled_skill_source_current_conflict_fails_closed(self) -> None:
        name = "test-skill-wrapper"
        relative_path = "vendor/runtime/skill"
        candidate = self.write_candidate(name, "conflicting bundled source record")
        bundled = self.write_bundled_skill(candidate, relative_path, "runtime-skill")
        source = bundled / "SOURCE.md"
        source.write_text(
            source.read_text(encoding="utf-8")
            + "Status: source-review\nStatus: pending-review\n",
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["bundled_skills"] = [
            {"path": relative_path, "name": "runtime-skill"}
        ]
        payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("SOURCE.md 当前记录存在冲突", stderr.getvalue())
        self.assertFalse((self.active / name).exists())

    def test_candidate_activation_records_durable_decision_evidence(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "持久 provenance")
        manifest = self.write_manifest("test-skill-wrapper", "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        transaction_manifest = max(
            (self.temp / "evidence").glob("install-*/manifest.json")
        )
        result = json.loads(transaction_manifest.read_text(encoding="utf-8"))
        decision_snapshot = transaction_manifest.parent / "decision-manifest.json"
        self.assertEqual(
            result["decision_manifest_snapshot"],
            {
                "path": str(decision_snapshot),
                "sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
            },
        )
        self.assertEqual(decision_snapshot.read_bytes(), manifest.read_bytes())

        source_record = (
            self.active / "test-skill-wrapper" / "SOURCE.md"
        ).read_text(encoding="utf-8")
        self.assertIn(
            f"Guarded transaction evidence: `{transaction_manifest.parent}`",
            source_record,
        )
        self.assertIn(f"Decision manifest: `{decision_snapshot}`", source_record)
        self.assertNotIn(str(candidate), source_record)
        self.assertNotIn(str(manifest), source_record)

        catalog = json.loads((self.temp / "catalog.json").read_text(encoding="utf-8"))
        artifact = next(
            item for item in catalog["artifacts"] if item.get("name") == "test-skill-wrapper"
        )
        source_fields = artifact["source"]["fields"]
        self.assertEqual(source_fields["decision_manifest"], str(decision_snapshot))
        self.assertEqual(
            source_fields["guarded_transaction_evidence"],
            str(transaction_manifest.parent),
        )
        source_values = "\n".join(
            value for value in source_fields.values() if isinstance(value, str)
        )
        self.assertNotIn(str(candidate), source_values)
        self.assertNotIn(str(manifest), source_values)

    def test_candidate_activation_rejects_transient_source_provenance(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "拒绝临时 provenance")
        manifest = self.active / "transient-decision.json"
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Source Provenance",
                    "",
                    "Skill: `test-skill-wrapper`",
                    f"Original decision manifest: `{manifest}`",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        generated_manifest = self.write_manifest("test-skill-wrapper", "install")
        generated_manifest.replace(manifest)
        ledger_before = self.ledger.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertFalse((self.temp / "catalog.json").exists())
        self.assertIn("SOURCE.md 不得保留临时 provenance 路径", stderr.getvalue())
        transaction_manifest = max(
            (self.temp / "evidence").glob("install-*/manifest.json")
        )
        result = json.loads(transaction_manifest.read_text(encoding="utf-8"))
        decision_snapshot = transaction_manifest.parent / "decision-manifest.json"
        self.assertEqual(result["status"], "rolled-back")
        self.assertEqual(
            result["decision_manifest_snapshot"]["path"], str(decision_snapshot)
        )
        self.assertEqual(decision_snapshot.read_bytes(), manifest.read_bytes())

    def test_manifest_disappearing_after_validation_returns_governed_error(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "decision manifest race")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        original_load = WRAPPER.load_and_validate_manifest

        def load_then_remove(path: Path, *, names: list[str]) -> dict[str, object]:
            result = original_load(path, names=names)
            path.unlink()
            return result

        stderr = io.StringIO()
        with (
            mock.patch.object(
                WRAPPER,
                "load_and_validate_manifest",
                side_effect=load_then_remove,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(stderr),
        ):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        error = json.loads(stderr.getvalue())
        self.assertIn("无法读取 decision manifest 快照", error["error"])
        self.assertFalse((self.active / "test-skill-wrapper").exists())
        self.assertFalse(any((self.temp / "evidence").glob("install-*")))

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

    def test_candidate_parent_junction_is_rejected_without_touching_target(self) -> None:
        target = self.temp / "external-candidate-target"
        junction = self.temp / "candidate-parent-junction"
        self.create_junction(junction, target)
        candidate = target / "candidate-through-junction"
        candidate.mkdir()
        (candidate / "SKILL.md").write_text(
            "---\nname: junction-candidate\ndescription: reject parent junction\n---\n",
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
        candidate = self.write_candidate("test-skill-wrapper", "reject active parent junction")
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

    def test_canonical_rename_rejects_candidate_inner_reparse_before_identity_read(
        self,
    ) -> None:
        state = self.prepare_canonical_rename()
        candidate = Path(state["candidate"])
        self.create_junction(candidate / "linked-content", self.temp / "external-content")
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            candidate,
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            mock.patch.object(
                WRAPPER,
                "read_skill_name",
                wraps=WRAPPER.read_skill_name,
            ) as read_skill_name,
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        read_skill_name.assert_not_called()
        self.assertTrue(Path(state["old_skill"]).is_dir())
        self.assertFalse((self.active / str(state["new_name"])).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)

    def test_canonical_rename_rejects_old_active_inner_reparse_before_old_identity_read(
        self,
    ) -> None:
        state = self.prepare_canonical_rename()
        old_skill = Path(state["old_skill"])
        self.create_junction(old_skill / "linked-content", self.temp / "external-old-content")
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            mock.patch.object(
                WRAPPER,
                "read_skill_name",
                wraps=WRAPPER.read_skill_name,
            ) as read_skill_name,
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        read_paths = [Path(call.args[0]) for call in read_skill_name.call_args_list]
        self.assertIn(Path(state["candidate"]) / "SKILL.md", read_paths)
        self.assertNotIn(old_skill / "SKILL.md", read_paths)
        self.assertTrue(old_skill.is_dir())
        self.assertFalse((self.active / str(state["new_name"])).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)

    def test_canonical_rename_accepts_historical_source_records(self) -> None:
        state = self.prepare_canonical_rename()
        old_source = Path(state["old_skill"]) / "SOURCE.md"
        current_record = old_source.read_text(encoding="utf-8")
        historical_record = (
            current_record.replace(
                f"Upstream path: `{state['upstream_path']}`",
                "Upstream path: `skills/legacy-orchestration`",
            )
            .replace("Ref: `main`", "Ref: `legacy`")
            .replace(
                f"Commit or revision: `{state['source_commit']}`",
                "Commit or revision: `legacy-commit`",
            )
        )
        old_source.write_text(
            historical_record.rstrip() + "\n\n---\n\n" + current_record,
            encoding="utf-8",
        )
        stdout = io.StringIO()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout.getvalue())["status"], "dry-run-pass")
        self.assertTrue(Path(state["old_skill"]).is_dir())
        self.assertFalse((self.active / str(state["new_name"])).exists())

    def test_canonical_rename_dry_run_has_no_active_or_state_side_effects(self) -> None:
        state = self.prepare_canonical_rename()
        old_skill = Path(state["old_skill"])
        old_seal = WRAPPER.tree_content_seal(old_skill)
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        stdout = io.StringIO()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        result = json.loads(stdout.getvalue())
        self.assertEqual(result["status"], "dry-run-pass")
        evidence = Path(result["evidence"])
        decision_snapshot = evidence / "decision-manifest.json"
        self.assertEqual(
            result["decision_manifest_snapshot"]["path"], str(decision_snapshot)
        )
        self.assertEqual(
            result["decision_manifest_snapshot"]["sha256"],
            hashlib.sha256(Path(state["manifest"]).read_bytes()).hexdigest(),
        )
        self.assertEqual(
            decision_snapshot.read_bytes(), Path(state["manifest"]).read_bytes()
        )
        self.assertEqual(WRAPPER.tree_content_seal(old_skill), old_seal)
        self.assertFalse((self.active / str(state["new_name"])).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)

    def test_canonical_rename_succeeds_with_one_live_successor_coverage(self) -> None:
        state = self.prepare_canonical_rename()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        old_name = str(state["old_name"])
        new_name = str(state["new_name"])
        self.assertFalse((self.active / old_name).exists())
        self.assertTrue((self.active / new_name / "SKILL.md").is_file())
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        live_coverage = [
            entry.get("id")
            for entry in ledger["sources"]
            if new_name in entry.get("skills", [])
        ]
        self.assertEqual(live_coverage, [state["source_id"]])
        self.assertFalse(
            any(old_name in entry.get("skills", []) for entry in ledger["sources"])
        )
        rename_records = [
            entry for entry in ledger["deleted"] if entry.get("name") == old_name
        ]
        self.assertEqual(len(rename_records), 1)
        self.assertEqual(rename_records[0]["new_name"], new_name)
        self.assertEqual(rename_records[0]["reason"], "canonical rename")
        catalog = json.loads(Path(state["catalog"]).read_text(encoding="utf-8"))
        active_names = [
            item["name"]
            for item in catalog["artifacts"]
            if item.get("scope") == "active"
        ]
        self.assertEqual(active_names.count(new_name), 1)
        self.assertNotIn(old_name, active_names)
        artifact = next(
            item
            for item in catalog["artifacts"]
            if item.get("scope") == "active" and item.get("name") == new_name
        )
        self.assertEqual(artifact["ledger_coverage"], "pass")
        source_record = (self.active / new_name / "SOURCE.md").read_text(
            encoding="utf-8"
        )
        for expected in (
            f"Canonical predecessor: `{old_name}`",
            f"Source identity: `{state['source_id']}`",
            f"Source repository: `{state['source_repo']}`",
            f"Upstream path: `{state['upstream_path']}`",
            "Ref: `main`",
            f"Commit or revision: `{state['source_commit']}`",
            "writing-great-skills gate:",
            f"Local overlay: replayed (canonical rename {old_name} -> {new_name})",
            "Guarded transaction evidence:",
            "Decision manifest:",
        ):
            self.assertIn(expected, source_record)
        source_fields = artifact["source"]["fields"]
        self.assertEqual(source_fields["canonical_predecessor"], old_name)
        self.assertEqual(source_fields["source_identity"], state["source_id"])
        self.assertEqual(source_fields["source_repository"], state["source_repo"])
        self.assertEqual(source_fields["upstream_path"], state["upstream_path"])
        self.assertEqual(source_fields["ref"], "main")
        self.assertEqual(source_fields["commit_or_revision"], state["source_commit"])
        self.assertIn("canonical rename", source_fields["local_overlay"])
        self.assertIn("decision-manifest.json", source_fields["decision_manifest"])

    def test_canonical_rename_migrates_direct_source_coverage(self) -> None:
        state = self.prepare_canonical_rename()
        old_name = str(state["old_name"])
        new_name = str(state["new_name"])
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source_entry = next(
            item for item in ledger["sources"] if item["id"] == state["source_id"]
        )
        source_entry.pop("skills")
        source_entry["name"] = old_name
        self.ledger.write_text(
            json.dumps(ledger, ensure_ascii=False),
            encoding="utf-8",
        )
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=new_name,
        )
        args.append("--update")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        updated = json.loads(self.ledger.read_text(encoding="utf-8"))
        updated_source = next(
            item for item in updated["sources"] if item["id"] == state["source_id"]
        )
        self.assertNotIn("name", updated_source)
        self.assertEqual(updated_source["skills"], [new_name])
        self.assertFalse((self.active / old_name).exists())
        self.assertTrue((self.active / new_name / "SKILL.md").is_file())

    def test_canonical_rename_rejects_successor_created_after_preflight(self) -> None:
        state = self.prepare_canonical_rename()
        old_skill = Path(state["old_skill"])
        old_seal = WRAPPER.tree_content_seal(old_skill)
        new_skill = self.active / str(state["new_name"])
        sentinel = new_skill / "sentinel.txt"
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_retire = WRAPPER.retire_directories

        def retire_then_create_successor(**keywords: object) -> list[dict[str, object]]:
            records = original_retire(**keywords)
            new_skill.mkdir()
            sentinel.write_text("unexpected-successor\n", encoding="utf-8")
            return records

        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")
        with (
            mock.patch.object(
                WRAPPER,
                "retire_directories",
                side_effect=retire_then_create_successor,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(WRAPPER.tree_content_seal(old_skill), old_seal)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "unexpected-successor\n")
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")
        unexpected_backup = (
            transaction.parent
            / "backups"
            / "active-skills"
            / str(state["new_name"])
        )
        self.assertFalse(unexpected_backup.exists())

    def test_canonical_rename_atomic_race_preserves_successor(self) -> None:
        state = self.prepare_canonical_rename()
        old_skill = Path(state["old_skill"])
        old_seal = WRAPPER.tree_content_seal(old_skill)
        new_skill = self.active / str(state["new_name"])
        sentinel = new_skill / "sentinel.txt"
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_rename = WRAPPER.os.rename
        injected = False

        def create_successor_at_atomic_rename(source: object, destination: object) -> None:
            nonlocal injected
            if Path(destination) == new_skill and not injected:
                injected = True
                new_skill.mkdir()
                sentinel.write_text("atomic-race-successor\n", encoding="utf-8")
            original_rename(source, destination)

        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")
        with (
            mock.patch.object(
                WRAPPER.os,
                "rename",
                side_effect=create_successor_at_atomic_rename,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertTrue(injected)
        self.assertEqual(WRAPPER.tree_content_seal(old_skill), old_seal)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "atomic-race-successor\n")
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")
        unexpected_backup = (
            transaction.parent
            / "backups"
            / "active-skills"
            / str(state["new_name"])
        )
        self.assertFalse(unexpected_backup.exists())

    def test_canonical_rename_post_activation_identical_race_preserves_successor(
        self,
    ) -> None:
        state = self.prepare_canonical_rename()
        old_skill = Path(state["old_skill"])
        old_seal = WRAPPER.tree_content_seal(old_skill)
        new_name = str(state["new_name"])
        new_skill = self.active / new_name
        displaced_payload = self.temp / "displaced-transaction-payload"
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_rename = WRAPPER.os.rename
        injected = False

        def replace_after_atomic_rename(source: object, destination: object) -> None:
            nonlocal injected
            original_rename(source, destination)
            if Path(destination) == new_skill and not injected:
                injected = True
                original_rename(new_skill, displaced_payload)
                shutil.copytree(displaced_payload, new_skill)

        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=new_name,
        )
        args.append("--update")
        with (
            mock.patch.object(
                WRAPPER.os,
                "rename",
                side_effect=replace_after_atomic_rename,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertTrue(injected)
        self.assertEqual(WRAPPER.tree_content_seal(old_skill), old_seal)
        self.assertTrue(new_skill.is_dir())
        self.assertTrue(displaced_payload.is_dir())
        self.assertEqual(
            WRAPPER.tree_content_seal(new_skill),
            WRAPPER.tree_content_seal(displaced_payload),
        )
        self.assertNotEqual(
            WRAPPER.directory_identity(new_skill, label="竞争 successor"),
            WRAPPER.directory_identity(displaced_payload, label="被移走事务 payload"),
        )
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rollback-failed")
        self.assertTrue(
            any("identity 漂移" in error for error in result["rollback_errors"])
        )

    def test_canonical_rename_rejects_structured_source_identity_drift(self) -> None:
        mismatch_kinds = (
            "wrong-predecessor",
            "missing-source-id",
            "ambiguous-upstream",
            "wrong-ref",
            "wrong-commit",
            "ledger-ref",
            "ledger-commit",
            "ledger-source-id-duplicate",
            "ledger-direct-field-conflict",
            "manifest-upstream",
        )
        for index, mismatch_kind in enumerate(mismatch_kinds):
            with self.subTest(mismatch_kind=mismatch_kind):
                old_name = f"old-identity-{index}"
                new_name = f"new-identity-{index}"
                source_id = f"identity-source-{index}"
                state = self.prepare_canonical_rename(
                    old_name=old_name,
                    new_name=new_name,
                    source_id=source_id,
                )
                candidate = Path(state["candidate"])
                source_path = candidate / "SOURCE.md"
                source_text = source_path.read_text(encoding="utf-8")
                if mismatch_kind == "wrong-predecessor":
                    source_text = source_text.replace(
                        f"Canonical predecessor: `{old_name}`",
                        "Canonical predecessor: `different-predecessor`",
                    )
                elif mismatch_kind == "missing-source-id":
                    source_text = source_text.replace(
                        f"Source identity: `{source_id}`\n",
                        "",
                    )
                elif mismatch_kind == "ambiguous-upstream":
                    source_text += "Upstream path: `skills/different`\n"
                elif mismatch_kind == "wrong-ref":
                    source_text = source_text.replace("Ref: `main`", "Ref: `next`")
                elif mismatch_kind == "wrong-commit":
                    source_text = source_text.replace(
                        f"Commit or revision: `{state['source_commit']}`",
                        "Commit or revision: `different-commit`",
                    )
                if source_text != source_path.read_text(encoding="utf-8"):
                    source_path.write_text(source_text, encoding="utf-8")

                manifest = Path(state["manifest"])
                manifest_payload = json.loads(manifest.read_text(encoding="utf-8"))
                if mismatch_kind == "ledger-ref":
                    ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
                    next(
                        item for item in ledger["sources"] if item["id"] == source_id
                    )["ref"] = "next"
                    self.ledger.write_text(
                        json.dumps(ledger, ensure_ascii=False), encoding="utf-8"
                    )
                elif mismatch_kind == "ledger-commit":
                    ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
                    source_entry = next(
                        item for item in ledger["sources"] if item["id"] == source_id
                    )
                    source_entry["last_checked_commit"] = "different-commit"
                    source_entry["catalog_ref"] = "different-commit"
                    self.ledger.write_text(
                        json.dumps(ledger, ensure_ascii=False), encoding="utf-8"
                    )
                elif mismatch_kind == "ledger-source-id-duplicate":
                    ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
                    ledger["sources"].insert(
                        0,
                        {
                            "id": source_id,
                            "type": "github",
                            "repo": state["source_repo"],
                            "ref": "main",
                            "skills": [],
                            "last_checked_commit": state["source_commit"],
                            "catalog_ref": state["source_commit"],
                        },
                    )
                    self.ledger.write_text(
                        json.dumps(ledger, ensure_ascii=False), encoding="utf-8"
                    )
                elif mismatch_kind == "ledger-direct-field-conflict":
                    ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
                    ledger["sources"].insert(
                        0,
                        {
                            "id": "ambiguous-direct-coverage",
                            "type": "local",
                            "repo": "local",
                            "name": "unrelated-skill",
                            "skill": old_name,
                        },
                    )
                    self.ledger.write_text(
                        json.dumps(ledger, ensure_ascii=False), encoding="utf-8"
                    )
                elif mismatch_kind == "manifest-upstream":
                    manifest_payload["source"]["upstream_path"] = "skills/different"
                manifest_payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(
                    candidate
                )
                manifest.write_text(
                    json.dumps(manifest_payload, ensure_ascii=False), encoding="utf-8"
                )
                ledger_before = self.ledger.read_bytes()
                catalog_before = Path(state["catalog"]).read_bytes()
                args = self.wrapper_args(candidate, manifest, name=new_name)
                args.extend(["--update", "--dry-run"])

                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(args)

                self.assertEqual(code, 2)
                self.assertTrue((self.active / old_name).is_dir())
                self.assertFalse((self.active / new_name).exists())
                self.assertEqual(self.ledger.read_bytes(), ledger_before)
                self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)

    def test_canonical_rename_rejects_candidate_old_name_and_source_mismatches(self) -> None:
        mismatch_kinds = ("candidate", "old_name", "source", "missing-skills")
        for index, mismatch_kind in enumerate(mismatch_kinds):
            with self.subTest(mismatch_kind=mismatch_kind):
                old_name = f"old-orchestration-{index}"
                new_name = f"new-orchestration-{index}"
                state = self.prepare_canonical_rename(
                    old_name=old_name,
                    new_name=new_name,
                    source_id=f"orchestration-source-{index}",
                )
                candidate = Path(state["candidate"])
                manifest = Path(state["manifest"])
                if mismatch_kind == "candidate":
                    (candidate / "SKILL.md").write_text(
                        "---\nname: wrong-successor\ndescription: mismatch\n---\n",
                        encoding="utf-8",
                    )
                    payload = json.loads(manifest.read_text(encoding="utf-8"))
                    payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(
                        candidate
                    )
                    manifest.write_text(
                        json.dumps(payload, ensure_ascii=False), encoding="utf-8"
                    )
                elif mismatch_kind == "old_name":
                    (Path(state["old_skill"]) / "SKILL.md").write_text(
                        "---\nname: wrong-predecessor\ndescription: mismatch\n---\n",
                        encoding="utf-8",
                    )
                elif mismatch_kind == "source":
                    payload = json.loads(manifest.read_text(encoding="utf-8"))
                    payload["source"]["id"] = "different-source"
                    payload["canonical_rename"]["source_id"] = "different-source"
                    manifest.write_text(
                        json.dumps(payload, ensure_ascii=False), encoding="utf-8"
                    )
                else:
                    payload = json.loads(manifest.read_text(encoding="utf-8"))
                    payload.pop("skills")
                    manifest.write_text(
                        json.dumps(payload, ensure_ascii=False), encoding="utf-8"
                    )
                ledger_before = self.ledger.read_bytes()
                catalog_before = Path(state["catalog"]).read_bytes()
                args = self.wrapper_args(
                    candidate,
                    manifest,
                    name=new_name,
                )
                args.extend(["--update", "--dry-run"])

                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(args)

                self.assertEqual(code, 2)
                self.assertTrue((self.active / old_name).is_dir())
                self.assertFalse((self.active / new_name).exists())
                self.assertEqual(self.ledger.read_bytes(), ledger_before)
                self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)

    def test_canonical_rename_activation_failure_restores_all_state(self) -> None:
        state = self.prepare_canonical_rename()
        old_seal = WRAPPER.tree_content_seal(Path(state["old_skill"]))
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")

        with (
            mock.patch.object(
                WRAPPER,
                "activate_directories",
                side_effect=WRAPPER.InstallError("injected rename activation failure"),
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assert_canonical_rename_rollback(
            state,
            ledger_before=ledger_before,
            catalog_before=catalog_before,
            old_seal=old_seal,
        )

    def test_canonical_rename_ledger_failure_restores_all_state(self) -> None:
        state = self.prepare_canonical_rename()
        old_seal = WRAPPER.tree_content_seal(Path(state["old_skill"]))
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")
        original_update_ledger = WRAPPER.update_ledger
        update_calls = 0

        def fail_live_ledger_update(*arguments: object, **keywords: object) -> dict[str, object]:
            nonlocal update_calls
            update_calls += 1
            if update_calls == 2:
                raise WRAPPER.InstallError("injected rename ledger failure")
            return original_update_ledger(*arguments, **keywords)

        with (
            mock.patch.object(WRAPPER, "update_ledger", side_effect=fail_live_ledger_update),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(update_calls, 2)
        self.assert_canonical_rename_rollback(
            state,
            ledger_before=ledger_before,
            catalog_before=catalog_before,
            old_seal=old_seal,
        )

    def test_canonical_rename_catalog_failure_restores_all_state(self) -> None:
        state = self.prepare_canonical_rename()
        old_seal = WRAPPER.tree_content_seal(Path(state["old_skill"]))
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        failing_generator = self.temp / "failing-rename-generator.py"
        failing_generator.write_text("import sys\nsys.exit(9)\n", encoding="utf-8")
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            generator=failing_generator,
            name=str(state["new_name"]),
        )
        args.append("--update")

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assert_canonical_rename_rollback(
            state,
            ledger_before=ledger_before,
            catalog_before=catalog_before,
            old_seal=old_seal,
        )

    def test_canonical_rename_closure_failure_restores_all_state(self) -> None:
        state = self.prepare_canonical_rename()
        old_seal = WRAPPER.tree_content_seal(Path(state["old_skill"]))
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")
        original_run_closure = WRAPPER.run_closure
        closure_calls = 0

        def fail_post_closure(*arguments: object, **keywords: object) -> dict[str, object]:
            nonlocal closure_calls
            closure_calls += 1
            if closure_calls == 2:
                raise WRAPPER.InstallError("injected rename closure failure")
            return original_run_closure(*arguments, **keywords)

        with (
            mock.patch.object(WRAPPER, "run_closure", side_effect=fail_post_closure),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(closure_calls, 2)
        self.assert_canonical_rename_rollback(
            state,
            ledger_before=ledger_before,
            catalog_before=catalog_before,
            old_seal=old_seal,
        )


if __name__ == "__main__":
    unittest.main()
