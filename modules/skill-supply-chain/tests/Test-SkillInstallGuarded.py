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


PROJECT_ROOT = Path(__file__).resolve().parents[3]
IMPLEMENTATION_ROOT = PROJECT_ROOT / "modules" / "skill-supply-chain" / "implementation"
WRAPPER_PATH = IMPLEMENTATION_ROOT / "install_skill_guarded.py"
SPEC = importlib.util.spec_from_file_location("install_skill_guarded", WRAPPER_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 wrapper：{WRAPPER_PATH}")
WRAPPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WRAPPER)
REPAIR_PATH = IMPLEMENTATION_ROOT / "system_skill_provenance_repair.py"
REPAIR_SPEC = importlib.util.spec_from_file_location("system_skill_provenance_repair", REPAIR_PATH)
if REPAIR_SPEC is None or REPAIR_SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 system repair：{REPAIR_PATH}")
REPAIR = importlib.util.module_from_spec(REPAIR_SPEC)
REPAIR_SPEC.loader.exec_module(REPAIR)
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
        self.generator = IMPLEMENTATION_ROOT / "generate_skill_catalog.py"
        self.closure = Path(
            r"D:\agents\skills-manager\skills\skill-install-guard\scripts\skill_resource_closure.py"
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
            f"---\nname: {name}\ndescription: 捆绑夹具技能描述\n---\n\n# {name}\n",
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
            "writing_for_agents": {"status": "no-change"},
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
        predecessor_identity: dict[str, str] | None = None,
        successor_identity: dict[str, str] | None = None,
    ) -> dict[str, object]:
        source_commit = "0123456789abcdef"
        upstream_path = "skills/orchestration"
        default_identity = {
            "upstream_path": upstream_path,
            "ref": "main",
            "commit": source_commit,
        }
        predecessor = dict(predecessor_identity or default_identity)
        successor = dict(successor_identity or default_identity)
        old_skill = self.active / old_name
        old_skill.mkdir()
        (old_skill / "SKILL.md").write_text(
            f"---\nname: {old_name}\ndescription: 基线夹具技能描述\n---\n\n# baseline\n",
            encoding="utf-8",
        )
        (old_skill / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Source Provenance",
                    "",
                    f"Skill: `{old_name}`",
                    f"Source repository: `{source_repo}`",
                    f"Upstream path: `{predecessor['upstream_path']}`",
                    f"Ref: `{predecessor['ref']}`",
                    f"Commit or revision: `{predecessor['commit']}`",
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
                            "ref": predecessor["ref"],
                            "skills": [old_name],
                            "last_checked_commit": predecessor["commit"],
                            "catalog_ref": predecessor["commit"],
                        }
                    ],
                    "unresolved": [],
                    "deleted": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(new_name, "规范后继夹具")
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Source Provenance",
                    "",
                    f"Skill: `{new_name}`",
                    f"Canonical predecessor: `{old_name}`",
                    f"Source identity: `{source_id}`",
                    f"Source repository: `{source_repo}`",
                    f"Upstream path: `{successor['upstream_path']}`",
                    f"Ref: `{successor['ref']}`",
                    f"Commit or revision: `{successor['commit']}`",
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
                "ref": successor["ref"],
                "commit": successor["commit"],
                "upstream_path": successor["upstream_path"],
            }
        )
        manifest_payload["canonical_rename"] = {
            "old_name": old_name,
            "new_name": new_name,
            "source_id": source_id,
            "predecessor_source": dict(predecessor),
            "successor_source": dict(successor),
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
            "source_commit": successor["commit"],
            "upstream_path": successor["upstream_path"],
            "predecessor_identity": predecessor,
            "successor_identity": successor,
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

    def prepare_merge_retirement(
        self,
        *,
        target_name: str = "survivor-target",
        other_survivor_name: str = "survivor-existing",
        retired_name: str = "retired-bridge",
    ) -> dict[str, object]:
        def write_active_skill(name: str, body: str) -> Path:
            root = self.active / name
            root.mkdir()
            (root / "SKILL.md").write_text(
                f"---\nname: {name}\ndescription: 夹具技能描述\n---\n\n# {body}\n",
                encoding="utf-8",
            )
            skill_hash = WRAPPER.sha256_file(root / "SKILL.md")
            (root / "SOURCE.md").write_text(
                "\n".join(
                    [
                        "# Source Provenance",
                        "",
                        f"Skill: `{name}`",
                        f"Local path: `{root}`",
                        f"Active root: `{self.active}`",
                        "Recorded: 2026-08-06",
                        "Status: source-review",
                        "Decision: install",
                        "Source type: local-candidate",
                        "Source repository: `local candidate supplied by the user`",
                        f"Upstream path: `{name}`",
                        "Ref: `local`",
                        f"Commit or revision: `sha256:{skill_hash}`",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            return root

        target_active = write_active_skill(target_name, "old target")
        other_survivor = write_active_skill(other_survivor_name, "existing survivor")
        retired_active = write_active_skill(retired_name, "retired bridge")
        target_source_id = "survivor-target-source"
        other_source_id = "survivor-existing-source"
        retired_source_id = "retired-bridge-source"
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-08-06",
                    "notes": [],
                    "sources": [
                        {
                            "id": target_source_id,
                            "type": "local-candidate",
                            "repo": "local candidate",
                            "ref": "local",
                            "skills": [target_name],
                        },
                        {
                            "id": other_source_id,
                            "type": "local-candidate",
                            "repo": "local candidate",
                            "ref": "local",
                            "skills": [other_survivor_name],
                        },
                        {
                            "id": retired_source_id,
                            "type": "local-candidate",
                            "repo": "local candidate",
                            "ref": "local",
                            "skills": [retired_name],
                        },
                    ],
                    "unresolved": [],
                    "deleted": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        candidate = self.write_candidate(target_name, "合并幸存目标夹具")
        candidate_sha256 = WRAPPER.sha256_file(candidate / "SKILL.md")
        other_survivor_sha256 = WRAPPER.sha256_file(other_survivor / "SKILL.md")
        retired_sha256 = WRAPPER.sha256_file(retired_active / "SKILL.md")
        manifest = self.write_manifest(
            target_name,
            "update",
            source_id=target_source_id,
            upstream_path=target_name,
        )
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["source"]["commit"] = f"sha256:{candidate_sha256}"
        payload["source"]["ledger_updates"] = {
            "status": "updated-with-local-overlay"
        }
        payload["merge_retirement"] = {
            "retired": {
                "name": retired_name,
                "source_id": retired_source_id,
                "skill_md_sha256": retired_sha256,
                "tree_seal": WRAPPER.tree_content_seal(retired_active),
            },
            "survivors": [
                {
                    "name": target_name,
                    "skill_md_sha256": candidate_sha256,
                },
                {
                    "name": other_survivor_name,
                    "skill_md_sha256": other_survivor_sha256,
                },
            ],
            "reason": f"merged into {target_name} and {other_survivor_name}",
        }
        payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
        manifest.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"sentinel":"before"}\n')
        return {
            "target_name": target_name,
            "target_active": target_active,
            "target_before_seal": WRAPPER.tree_content_seal(target_active),
            "other_survivor_name": other_survivor_name,
            "other_survivor": other_survivor,
            "retired_name": retired_name,
            "retired_active": retired_active,
            "retired_before_seal": WRAPPER.tree_content_seal(retired_active),
            "retired_source_id": retired_source_id,
            "candidate": candidate,
            "candidate_sha256": candidate_sha256,
            "manifest": manifest,
            "catalog": catalog,
        }

    def test_decision_manifest_accepts_writing_for_agents_gate(self) -> None:
        path = self.temp / "decision-writing-for-agents.json"
        path.write_text(
            json.dumps(
                {
                    "decision": "update",
                    "source_status": "source-pass",
                    "writing_for_agents": {"status": "pass"},
                }
            ),
            encoding="utf-8",
        )
        result = WRAPPER.validate_decision_manifest(path)
        self.assertEqual(result["decision"], "update")

    def test_decision_manifest_rejects_retired_gate_field(self) -> None:
        path = self.temp / "decision-retired-writing-gate.json"
        path.write_text(
            json.dumps(
                {
                    "decision": "update",
                    "source_status": "source-pass",
                    "writing_great_skills": {"status": "pass"},
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(WRAPPER.InstallError, "已退役"):
            WRAPPER.validate_decision_manifest(path)

    def test_decision_manifest_rejects_both_writing_gate_fields(self) -> None:
        path = self.temp / "decision-conflicting-writing-gates.json"
        path.write_text(
            json.dumps(
                {
                    "decision": "update",
                    "source_status": "source-pass",
                    "writing_for_agents": {"status": "pass"},
                    "writing_great_skills": {"status": "pass"},
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(WRAPPER.InstallError, "已退役"):
            WRAPPER.validate_decision_manifest(path)

    def test_canonical_rename_accepts_distinct_bound_identities(self) -> None:
        predecessor = {
            "upstream_path": "skills/old-orchestration",
            "ref": "legacy",
            "commit": "1111111111111111",
        }
        successor = {
            "upstream_path": "skills/new-orchestration",
            "ref": "main",
            "commit": "2222222222222222",
        }
        state = self.prepare_canonical_rename(
            predecessor_identity=predecessor,
            successor_identity=successor,
        )
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source_entry = next(
            item for item in ledger["sources"] if item["id"] == state["source_id"]
        )
        source_entry["last_checked_commit"] = successor["commit"]
        source_entry["catalog_ref"] = successor["commit"]
        self.ledger.write_text(json.dumps(ledger), encoding="utf-8")
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)

    def test_canonical_rename_rejects_unbound_or_mismatched_successor(self) -> None:
        for mismatch_kind in ("unbound", "successor"):
            with self.subTest(mismatch_kind=mismatch_kind):
                state = self.prepare_canonical_rename(
                    old_name=f"old-bound-{mismatch_kind}",
                    new_name=f"new-bound-{mismatch_kind}",
                    source_id=f"source-bound-{mismatch_kind}",
                )
                manifest = Path(state["manifest"])
                payload = json.loads(manifest.read_text(encoding="utf-8"))
                if mismatch_kind == "unbound":
                    payload["canonical_rename"].pop("predecessor_source")
                    payload["canonical_rename"].pop("successor_source")
                else:
                    payload["canonical_rename"]["successor_source"]["commit"] = (
                        "different-commit"
                    )
                manifest.write_text(json.dumps(payload), encoding="utf-8")
                args = self.wrapper_args(
                    Path(state["candidate"]),
                    manifest,
                    name=str(state["new_name"]),
                )
                args.extend(["--update", "--dry-run"])

                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(args)

                self.assertEqual(code, 2)
                self.assertTrue(Path(state["old_skill"]).is_dir())
                self.assertFalse((self.active / str(state["new_name"])).exists())

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
        source_record = WRAPPER.parse_current_source_record(
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

    def prepare_system_provenance_repair(self, *, include_creator_scripts: bool = False) -> dict[str, object]:
        names = [
            "imagegen",
            "openai-docs",
            "review-agent",
            "skill-creator",
            "skill-installer",
        ]
        system_root = self.active / ".system"
        if system_root.exists():
            shutil.rmtree(system_root)
        system_root.mkdir()
        marker = system_root / ".codex-system-skills.marker"
        marker.write_bytes(b"fixture-marker-v1\n")

        baseline_skill_bytes: dict[str, bytes] = {}
        for name in names:
            skill_root = system_root / name
            skill_root.mkdir()
            skill_text = (
                f"---\nname: {name}\ndescription: 系统修复夹具技能：{name}。\n"
                "---\n\n"
                f"# {name}\n"
            )
            skill_path = skill_root / "SKILL.md"
            skill_path.write_text(skill_text, encoding="utf-8")
            baseline_skill_bytes[name] = skill_path.read_bytes()
            if name == "skill-creator" and include_creator_scripts:
                scripts = skill_root / "scripts"
                scripts.mkdir()
                (scripts / "quick_validate.py").write_text("# official quick validator\nLEGACY = True\n", encoding="utf-8")
                (scripts / "test_quick_validate.py").write_text("# official quick validator tests\nLEGACY = True\n", encoding="utf-8")
            if name == "review-agent":
                agents = skill_root / "agents"
                agents.mkdir()
                (agents / "openai.yaml").write_text(
                    "interface:\n"
                    '  display_name: "Review Agent"\n'
                    "policy:\n"
                    "  allow_implicit_invocation: false\n",
                    encoding="utf-8",
                )

        source_root = str(system_root).replace("\\", "/")
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-08-18",
                    "notes": [],
                    "sources": [
                        {
                            "id": "codex-bundled-system-skills",
                            "type": "codex-bundled-system",
                            "source_root": source_root,
                            "status": "tracked-bundled-system-skills",
                            "skills": [f".system/{name}" for name in names],
                            "local_changes": [],
                        }
                    ],
                    "unresolved": [],
                    "deleted": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"sentinel":"before"}\n')

        package_full_name = "OpenAI.Codex_26.810.7004.0_x64__fixture"
        package_root = self.temp / package_full_name
        if package_root.exists():
            shutil.rmtree(package_root)
        package_root.mkdir()
        manifest_path = package_root / "AppxManifest.xml"
        signature_path = package_root / "AppxSignature.p7x"
        manifest_path.write_bytes(b"<Package fixture='system-provenance' />\n")
        signature_path.write_bytes(b"fixture-valid-store-signature\n")
        package_identity = {
            "schema_version": 1,
            "package_name": "OpenAI.Codex",
            "package_full_name": package_full_name,
            "package_family_name": "OpenAI.Codex_fixture",
            "version": "26.810.7004.0",
            "publisher": "CN=FIXTURE",
            "signature_kind": "Store",
            "signature_status": "Valid",
            "appx_status": "Ok",
            "install_location": str(package_root),
            "appx_manifest_path": str(manifest_path),
            "appx_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            "appx_signature_path": str(signature_path),
            "appx_signature_sha256": hashlib.sha256(signature_path.read_bytes()).hexdigest(),
        }
        provider = self.temp / "fixture_system_package_provider.py"
        provider.write_text(
            "import json\n"
            f"print(json.dumps({package_identity!r}))\n",
            encoding="utf-8",
        )

        skills: list[dict[str, object]] = []
        for name in names:
            skill_root = system_root / name
            official = WRAPPER.candidate_integrity_payload(skill_root)
            overlay: dict[str, object] = {"kind": "none"}
            effective = dict(official)
            critical_files: dict[str, str] = {}
            if name == "review-agent":
                parity_path = skill_root / "agents" / "openai.yaml"
                critical_files["agents/openai.yaml"] = WRAPPER.sha256_file(parity_path)
                baseline_text = baseline_skill_bytes[name].decode("utf-8")
                newline = "\r\n" if "\r\n" in baseline_text else "\n"
                patched_text = baseline_text.replace(
                    f"---{newline}{newline}# review-agent",
                    f"disable-model-invocation: true{newline}---{newline}{newline}# review-agent",
                    1,
                )
                (skill_root / "SKILL.md").write_bytes(patched_text.encode("utf-8"))
                effective = WRAPPER.candidate_integrity_payload(skill_root)
                (skill_root / "SKILL.md").write_bytes(baseline_skill_bytes[name])
                overlay = {
                    "kind": "review-agent-invocation-parity",
                    "disable_model_invocation": True,
                    "allow_implicit_invocation": False,
                    "parity_file": "agents/openai.yaml",
                }
            skills.append(
                {
                    "name": name,
                    "source_before_sha256": None,
                    "official_integrity": official,
                    "effective_integrity": effective,
                    "critical_files": critical_files,
                    "overlay": overlay,
                }
            )

        plan = self.temp / "system-provenance-repair-plan.json"
        plan.write_text(
            json.dumps(
                {
                    "artifact_type": "codex.system-skill-provenance-repair",
                    "schema_version": 1,
                    "mode": "atomic-six-skill-bootstrap",
                    "source_group_id": "codex-bundled-system-skills",
                    "package_identity_provider_sha256": hashlib.sha256(
                        provider.read_bytes()
                    ).hexdigest(),
                    "package_identity": package_identity,
                    "marker": {
                        "relative_path": ".system/.codex-system-skills.marker",
                        "sha256": hashlib.sha256(marker.read_bytes()).hexdigest(),
                    },
                    "ledger_before_sha256": hashlib.sha256(
                        self.ledger.read_bytes()
                    ).hexdigest(),
                    "catalog_before_sha256": hashlib.sha256(
                        catalog.read_bytes()
                    ).hexdigest(),
                    "stability_check": {"observations": 2, "interval_seconds": 0},
                    "skills": skills,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        return {
            "names": names,
            "system_root": system_root,
            "marker": marker,
            "provider": provider,
            "package_identity": package_identity,
            "plan": plan,
            "catalog": catalog,
            "baseline_skill_bytes": baseline_skill_bytes,
        }

    def system_provenance_repair_args(
        self,
        state: dict[str, object],
        *,
        generator: Path | None = None,
    ) -> list[str]:
        return [
            "--system-provenance-repair-plan",
            str(state["plan"]),
            "--system-package-provider",
            str(state["provider"]),
            "--active-root",
            str(self.active),
            "--plugin-cache-root",
            str(self.plugin_cache),
            "--ledger",
            str(self.ledger),
            "--catalog",
            str(state["catalog"]),
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

    def prepare_system_display_reconcile(self, *, include_creator_scripts: bool = False) -> dict[str, object]:
        state = self.prepare_system_provenance_repair(include_creator_scripts=include_creator_scripts)
        bootstrap = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
        for spec in bootstrap["skills"]:
            root = Path(state["system_root"]) / spec["name"]
            agents = root / "agents"
            agents.mkdir(exist_ok=True)
            agent_file = agents / "openai.yaml"
            text = agent_file.read_text(encoding="utf-8") if agent_file.exists() else "interface:\n"
            agent_file.write_text(
                text.replace("interface:\n", 'interface:\n  short_description: "原始菜单文本"\n  default_prompt: "原始提示词"\n'),
                encoding="utf-8",
            )
            spec["official_integrity"] = REPAIR.system_skill_integrity(root)
            spec["effective_integrity"] = spec["official_integrity"]
            if spec["name"] == "review-agent":
                spec["critical_files"]["agents/openai.yaml"] = WRAPPER.sha256_file(agent_file)
                spec["effective_integrity"] = REPAIR._tree_integrity(root, overrides={
                    "SKILL.md": REPAIR._review_overlay_bytes(root / "SKILL.md", (root / "SKILL.md").read_bytes()),
                })
        Path(state["plan"]).write_text(json.dumps(bootstrap), encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(WRAPPER.main(self.system_provenance_repair_args(state)), 0)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        records = ledger["sources"][0]["system_provenance"]["skills"]
        plan = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
        plan["mode"] = "atomic-six-skill-display-reconcile"
        for spec, previous in zip(plan["skills"], records):
            root = Path(state["system_root"]) / spec["name"]
            baseline = {"SKILL.md": (root / "SKILL.md").read_bytes().decode("utf-8")}
            if (root / "agents/openai.yaml").exists():
                baseline["agents/openai.yaml"] = (root / "agents/openai.yaml").read_bytes().decode("utf-8")
            (root / "SKILL.md").write_bytes(
                baseline["SKILL.md"].replace(
                    f"description: 系统修复夹具技能：{spec['name']}。",
                    'description: "本夹具已重放的中文展示文本。"',
                ).encode("utf-8")
            )
            agent_file = root / "agents/openai.yaml"
            agent_file.write_bytes(
                agent_file.read_bytes().replace("原始菜单文本".encode("utf-8"), "翻译后的菜单文本".encode("utf-8"))
                .replace("原始提示词".encode("utf-8"), "翻译后的提示词".encode("utf-8"))
            )
            spec["critical_files"] = {
                relative: WRAPPER.sha256_file(root / relative)
                for relative in previous["critical_files"]
            }
            spec["source_before_sha256"] = WRAPPER.sha256_file(root / "SOURCE.md")
            spec["effective_integrity"] = REPAIR.system_skill_integrity(root)
            spec["overlay"] = {
                "kind": "display-only",
                "baseline_files": baseline,
                "base_overlay": previous["overlay"],
            }
        plan["ledger_before_sha256"] = WRAPPER.sha256_file(self.ledger)
        plan["catalog_before_sha256"] = WRAPPER.sha256_file(Path(state["catalog"]))
        Path(state["plan"]).write_text(json.dumps(plan), encoding="utf-8")
        state["previous_records"] = records
        return state

    def test_system_display_reconcile_preserves_payload_and_official_baseline(self) -> None:
        state = self.prepare_system_display_reconcile()
        root = Path(state["system_root"])
        payload_before = {
            p: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns)
            for p in root.rglob("*") if p.is_file() and p.name != "SOURCE.md"
        }
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.system_provenance_repair_args(state))
        self.assertEqual(code, 0, stderr.getvalue())
        self.assertEqual(json.loads(stdout.getvalue())["status"], "succeeded")
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        after = ledger["sources"][0]["system_provenance"]["skills"]
        for old, new in zip(state["previous_records"], after):
            self.assertEqual(old["official_integrity"], new["official_integrity"])
            self.assertEqual(new["effective_integrity"], REPAIR.system_skill_integrity(root / new["name"]))
            self.assertEqual(new["overlay"]["kind"], "display-only")
            self.assertNotIn("baseline_files", new["overlay"])
        for path, value in payload_before.items():
            self.assertEqual((path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns), value)

    def system_display_state_bytes(self, state: dict[str, object]) -> dict[Path, bytes]:
        paths = [self.ledger, Path(state["catalog"])]
        paths.extend(p for p in Path(state["system_root"]).rglob("*") if p.is_file())
        return {p: p.read_bytes() for p in paths}

    def test_system_display_reconcile_dry_run_is_read_only(self) -> None:
        state = self.prepare_system_display_reconcile()
        before = self.system_display_state_bytes(state)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = WRAPPER.main(self.system_provenance_repair_args(state) + ["--dry-run"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout.getvalue())["status"], "dry-run-pass")
        self.assertEqual(self.system_display_state_bytes(state), before)

    def test_system_display_reconcile_rejects_non_display_and_forged_baselines(self) -> None:
        for case in (
            "body", "name", "duplicate-key", "policy", "resource", "official", "baseline",
            "underlying-overlay", "comment", "agent-comment", "removed-field", "field-type",
            "delimiter", "bom",
        ):
            with self.subTest(case=case):
                state = self.prepare_system_display_reconcile()
                plan = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
                spec = plan["skills"][0]
                root = Path(state["system_root"]) / spec["name"]
                skill = root / "SKILL.md"
                if case == "body":
                    skill.write_bytes(skill.read_bytes() + b"\nUnapproved body change.\n")
                elif case == "name":
                    skill.write_bytes(skill.read_bytes().replace(b"name: imagegen", b"name: renamed"))
                elif case == "duplicate-key":
                    skill.write_bytes(skill.read_bytes().replace(b"name: imagegen", b"name: imagegen\nname: imagegen"))
                elif case == "policy":
                    spec = plan["skills"][3]
                    root = Path(state["system_root"]) / spec["name"]
                    yaml_path = root / "agents/openai.yaml"
                    yaml_path.write_bytes(yaml_path.read_bytes().replace(b": false", b": true"))
                    spec["critical_files"]["agents/openai.yaml"] = WRAPPER.sha256_file(yaml_path)
                elif case == "resource":
                    (root / "new-script.py").write_bytes(b"print('unapproved')\n")
                elif case == "official":
                    spec["official_integrity"]["tree_sha256"] = "a" * 64
                elif case == "baseline":
                    spec["overlay"]["baseline_files"]["SKILL.md"] += "\nForged old body.\n"
                elif case == "comment":
                    skill.write_bytes(skill.read_bytes().replace(b"name: imagegen", b"name: imagegen\n# New instruction"))
                elif case == "delimiter":
                    lines = skill.read_bytes().splitlines(keepends=True)
                    end = next(i for i in range(1, len(lines)) if lines[i].strip() == b"---")
                    lines[end] = lines[end].replace(b"---", b"...")
                    skill.write_bytes(b"".join(lines))
                elif case == "bom":
                    skill.write_bytes(b"\xef\xbb\xbf" + skill.read_bytes())
                elif case in {"agent-comment", "removed-field", "field-type"}:
                    path = root / "agents/openai.yaml"
                    value = path.read_bytes()
                    if case == "agent-comment":
                        value += b"# New instruction\n"
                    elif case == "removed-field":
                        value = b"".join(
                            line for line in value.splitlines(keepends=True)
                            if not line.startswith(b"  default_prompt:")
                        )
                    else:
                        value = value.replace('  default_prompt: "翻译后的提示词"'.encode("utf-8"), b"  default_prompt: false")
                    self.assertNotEqual(value, path.read_bytes())
                    path.write_bytes(value)
                else:
                    spec["overlay"]["base_overlay"] = {"kind": "arbitrary-code"}
                spec["effective_integrity"] = REPAIR.system_skill_integrity(root)
                Path(state["plan"]).write_text(json.dumps(plan), encoding="utf-8")
                before = self.system_display_state_bytes(state)
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    code = WRAPPER.main(self.system_provenance_repair_args(state))
                self.assertEqual(code, 2)
                self.assertEqual(self.system_display_state_bytes(state), before)

    def test_system_display_reconcile_failure_restores_all_metadata(self) -> None:
        state = self.prepare_system_display_reconcile()
        before = self.system_display_state_bytes(state)
        failing_generator = self.temp / "display-failing-generator.py"
        failing_generator.write_text("raise SystemExit(23)\n", encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.system_provenance_repair_args(state, generator=failing_generator))
        self.assertEqual(code, 2)
        self.assertEqual(self.system_display_state_bytes(state), before)
        transaction = max((self.temp / "evidence").glob("system-provenance-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")
        self.assertEqual(len(result["backups"]), 7)
        self.assertEqual(result["rollback_errors"], [])

    def prepare_skill_creator_compatibility_overlay(self, *, localized: bool = False) -> dict[str, object]:
        state = (
            self.prepare_system_display_reconcile(include_creator_scripts=True)
            if localized else self.prepare_system_provenance_repair(include_creator_scripts=True)
        )
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(
                WRAPPER.main(self.system_provenance_repair_args(state)),
                0,
            )
        active_skill = Path(state["system_root"]) / "skill-creator"
        candidate = self.temp / "candidate-skill-creator"
        shutil.copytree(active_skill, candidate)
        (candidate / "SKILL.md").write_text(
            (active_skill / "SKILL.md").read_text(encoding="utf-8")
            + "\nCompatible metadata: argument-hint and disable-model-invocation.\n",
            encoding="utf-8",
        )
        (candidate / "scripts" / "quick_validate.py").write_text(
            "# compatibility quick validator\n"
            "ALLOWED = {'argument-hint', 'disable-model-invocation'}\n",
            encoding="utf-8",
        )
        (candidate / "scripts" / "test_quick_validate.py").write_text(
            "# compatibility quick validator tests\n"
            "assert {'argument-hint', 'disable-model-invocation'}\n",
            encoding="utf-8",
        )
        ledger_before = json.loads(self.ledger.read_text(encoding="utf-8"))
        record_before = next(item for item in ledger_before["sources"][0]["system_provenance"]["skills"] if item["name"] == "skill-creator")
        official = record_before["official_integrity"]
        effective = REPAIR.system_skill_integrity(candidate)
        critical = {
            relative: hashlib.sha256(
                (candidate / Path(*relative.split("/"))).read_bytes()
            ).hexdigest()
            for relative in REPAIR.SKILL_CREATOR_CRITICAL_FILES
        }
        manifest = self.write_manifest(
            "skill-creator",
            "update",
            source_id="codex-bundled-system-skills",
        )
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["target_scope"] = "system"
        payload["source"]["ref"] = "unversioned-codex-bundled-system"
        payload["local_overlay"] = {
            "status": "replayed",
            "summary": "skill-creator quick_validate compatibility overlay",
        }
        payload["system_provenance_overlay"] = {
            "schema_version": 1,
            "kind": REPAIR.SKILL_CREATOR_OVERLAY_KIND,
            "skill": REPAIR.SKILL_CREATOR_OVERLAY_SKILL,
            "package_identity_provider_sha256": hashlib.sha256(
                Path(state["provider"]).read_bytes()
            ).hexdigest(),
            "official_integrity": official,
            "effective_integrity": effective,
            "critical_files": critical,
            "contract": REPAIR.SKILL_CREATOR_OVERLAY_CONTRACT,
        }
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        args = self.wrapper_args(candidate, manifest, name="skill-creator")
        args.extend(["--system-package-provider", str(state["provider"])])
        return {
            "state": state,
            "candidate": candidate,
            "manifest": manifest,
            "args": args,
            "official": official,
            "effective": effective,
            "critical": critical,
            "ledger_before": ledger_before,
            "record_before": record_before,
            "source_before": (active_skill / "SOURCE.md").read_bytes(),
        }

    def test_skill_creator_compatibility_preserves_display_provenance(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay(localized=True)
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(state["args"])
        self.assertEqual(code, 0, stderr.getvalue())
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = ledger["sources"][0]
        record = next(item for item in source["system_provenance"]["skills"] if item["name"] == "skill-creator")
        before = state["record_before"]
        self.assertNotEqual(before["official_integrity"], before["effective_integrity"])
        self.assertEqual(record["official_integrity"], before["official_integrity"])
        self.assertEqual(record["overlay"]["base_overlay"], before["overlay"])
        self.assertEqual(record["overlay"]["baseline_integrity"], before["effective_integrity"])
        for old in state["ledger_before"]["sources"][0]["system_provenance"]["skills"]:
            if old["name"] != "skill-creator":
                self.assertIn(old, source["system_provenance"]["skills"])
        for old in state["ledger_before"]["sources"][0]["local_changes"]:
            self.assertIn(old, source["local_changes"])
        active = Path(state["state"]["system_root"]) / "skill-creator"
        source_bytes = (active / "SOURCE.md").read_bytes()
        self.assertTrue(source_bytes.startswith(state["source_before"].rstrip(b"\r\n")))
        current = WRAPPER.current_source_record(active / "SOURCE.md")
        self.assertIn("display-only", source_bytes.decode("utf-8").split("# Current Source Record")[-1])
        self.assertIn(before["official_integrity"]["tree_sha256"], source_bytes.decode("utf-8").split("# Current Source Record")[-1])
        self.assertFalse(current.conflicts)

    def test_skill_creator_display_baseline_drift_fails_before_activation(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay(localized=True)
        active = Path(state["state"]["system_root"]) / "skill-creator"
        manifest = Path(state["manifest"])
        original_manifest = manifest.read_bytes()
        original_ledger = self.ledger.read_bytes()
        original_skill = (active / "SKILL.md").read_bytes()
        for label in ("localized-as-official", "payload-drift", "source-drift", "unknown-base"):
            with self.subTest(label=label):
                manifest.write_bytes(original_manifest)
                self.ledger.write_bytes(original_ledger)
                (active / "SKILL.md").write_bytes(original_skill)
                (active / "SOURCE.md").write_bytes(state["source_before"])
                if label == "localized-as-official":
                    decision = json.loads(original_manifest)
                    decision["system_provenance_overlay"]["official_integrity"] = state["record_before"]["effective_integrity"]
                    manifest.write_text(json.dumps(decision), encoding="utf-8")
                elif label == "payload-drift":
                    (active / "SKILL.md").write_bytes(original_skill + b"\nDrift.\n")
                elif label == "source-drift":
                    (active / "SOURCE.md").write_bytes(state["source_before"] + b"\nDrift.\n")
                else:
                    ledger = json.loads(original_ledger)
                    record = next(item for item in ledger["sources"][0]["system_provenance"]["skills"] if item["name"] == "skill-creator")
                    record["overlay"]["base_overlay"] = {"kind": "unknown"}
                    self.ledger.write_text(json.dumps(ledger), encoding="utf-8")
                before = self.system_display_state_bytes(state["state"])
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    code = WRAPPER.main(state["args"])
                self.assertEqual(code, 2)
                self.assertEqual(self.system_display_state_bytes(state["state"]), before)
                self.assertFalse(list((self.temp / "evidence").glob("install-*/manifest.json")))

    def test_display_reconcile_preserves_creator_compatibility_and_prior_display_chain(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay(localized=True)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(WRAPPER.main(state["args"]), 0)
        system_state = state["state"]
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        records = ledger["sources"][0]["system_provenance"]["skills"]
        creator_before = next(item for item in records if item["name"] == "skill-creator")
        plan = json.loads(Path(system_state["plan"]).read_text(encoding="utf-8"))
        for spec, previous in zip(plan["skills"], records):
            root = Path(system_state["system_root"]) / spec["name"]
            baseline = {
                relative: (root / relative).read_bytes().decode("utf-8")
                for relative in ("SKILL.md", "agents/openai.yaml")
                if (root / relative).is_file()
            }
            (root / "SKILL.md").write_bytes(
                baseline["SKILL.md"].replace("本夹具已重放的中文展示文本。", "更新后的中文展示译文。").encode("utf-8")
            )
            spec["source_before_sha256"] = WRAPPER.sha256_file(root / "SOURCE.md")
            spec["official_integrity"] = previous["official_integrity"]
            spec["effective_integrity"] = REPAIR.system_skill_integrity(root)
            spec["critical_files"] = {relative: WRAPPER.sha256_file(root / relative) for relative in previous["critical_files"]}
            previous_overlay = previous["overlay"]
            spec["overlay"] = {
                "kind": "display-only",
                "baseline_files": baseline,
                "base_overlay": previous_overlay["base_overlay"] if previous_overlay["kind"] == "display-only" else previous_overlay,
            }
        plan["ledger_before_sha256"] = WRAPPER.sha256_file(self.ledger)
        plan["catalog_before_sha256"] = WRAPPER.sha256_file(Path(system_state["catalog"]))
        Path(system_state["plan"]).write_text(json.dumps(plan), encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.system_provenance_repair_args(system_state))
        self.assertEqual(code, 0, stderr.getvalue())
        after = json.loads(self.ledger.read_text(encoding="utf-8"))["sources"][0]["system_provenance"]["skills"]
        creator_after = next(item for item in after if item["name"] == "skill-creator")
        self.assertEqual(creator_after["official_integrity"], creator_before["official_integrity"])
        self.assertEqual(creator_after["overlay"]["base_overlay"], creator_before["overlay"])
        self.assertEqual(creator_after["overlay"]["base_overlay"]["base_overlay"], state["record_before"]["overlay"])
        for relative in ("scripts/quick_validate.py", "scripts/test_quick_validate.py"):
            self.assertEqual(creator_after["critical_files"][relative], creator_before["critical_files"][relative])

    def test_system_provenance_repair_commits_five_skills_atomically(self) -> None:
        state = self.prepare_system_provenance_repair()

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.system_provenance_repair_args(state))

        self.assertEqual(code, 0)
        system_root = Path(state["system_root"])
        for name in state["names"]:
            self.assertTrue((system_root / name / "SOURCE.md").is_file())
        review_text = (system_root / "review-agent" / "SKILL.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("disable-model-invocation: true", review_text)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = ledger["sources"][0]
        self.assertEqual(source["id"], "codex-bundled-system-skills")
        self.assertEqual(source["system_provenance"]["schema_version"], 1)
        self.assertEqual(len(source["system_provenance"]["skills"]), 5)
        catalog = json.loads(Path(state["catalog"]).read_text(encoding="utf-8"))
        repaired = [
            item
            for item in catalog["artifacts"]
            if item.get("relative_path", "").startswith(".system/")
        ]
        self.assertEqual(len(repaired), 5)
        self.assertTrue(all(item["ledger_coverage"] == "pass" for item in repaired))
        review = next(item for item in repaired if item["name"] == "review-agent")
        self.assertEqual(review["invocation"]["mode"], "user-invoked")
        self.assertFalse(review["invocation"]["allow_implicit_invocation"])
        transaction = max((self.temp / "evidence").glob("system-provenance-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["targets"], state["names"])

    def test_skill_creator_compatibility_overlay_updates_provenance_atomically(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay()
        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(state["args"])
        self.assertEqual(code, 0)
        active_skill = Path(state["state"]["system_root"]) / "skill-creator"
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = next(item for item in ledger["sources"] if item["id"] == "codex-bundled-system-skills")
        record = next(item for item in source["system_provenance"]["skills"] if item["name"] == "skill-creator")
        overlay = json.loads(Path(state["manifest"]).read_text(encoding="utf-8"))["system_provenance_overlay"]
        self.assertEqual(record["official_integrity"], overlay["official_integrity"])
        self.assertEqual(record["effective_integrity"], overlay["effective_integrity"])
        self.assertEqual(record["critical_files"], overlay["critical_files"])
        self.assertEqual(record["overlay"]["kind"], REPAIR.SKILL_CREATOR_OVERLAY_KIND)
        self.assertEqual(record["overlay"]["payload_files"], overlay["critical_files"])
        self.assertEqual(
            record["source_md_sha256"],
            hashlib.sha256((active_skill / "SOURCE.md").read_bytes()).hexdigest(),
        )
        self.assertTrue(
            any(
                item.get("skill") == ".system/skill-creator"
                and "quick_validate" in item.get("summary", "")
                for item in source["local_changes"]
            )
        )
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(
            result["system_provenance_overlay_postcondition"]["overlay"]["kind"],
            REPAIR.SKILL_CREATOR_OVERLAY_KIND,
        )

    def test_skill_creator_update_without_managed_overlay_fails_closed(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay()
        manifest = Path(state["manifest"])
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload.pop("system_provenance_overlay")
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        before = self.ledger.read_bytes()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(state["args"])
        self.assertEqual(code, 2)
        self.assertIn("system_provenance_overlay", stderr.getvalue())
        self.assertEqual(self.ledger.read_bytes(), before)

    def test_skill_creator_overlay_rejects_non_target_and_critical_drift(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay()
        manifest = Path(state["manifest"])
        original = json.loads(manifest.read_text(encoding="utf-8"))
        for label, mutate in (
            (
                "wrong-kind",
                lambda value: value["system_provenance_overlay"].update(
                    {"kind": "review-agent-invocation-parity"}
                ),
            ),
            (
                "extra-file",
                lambda value: value["system_provenance_overlay"]["critical_files"].update(
                    {"references/extra.md": "0" * 64}
                ),
            ),
        ):
            with self.subTest(label=label):
                manifest.write_text(json.dumps(original, ensure_ascii=False), encoding="utf-8")
                changed = json.loads(manifest.read_text(encoding="utf-8"))
                mutate(changed)
                manifest.write_text(json.dumps(changed, ensure_ascii=False), encoding="utf-8")
                stderr = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                    code = WRAPPER.main(state["args"])
                self.assertEqual(code, 2)
                self.assertIn("overlay", stderr.getvalue())

    def test_skill_creator_overlay_generator_failure_rolls_back_payload_and_state(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay(localized=True)
        active_skill = Path(state["state"]["system_root"]) / "skill-creator"
        before = {
            "skill": REPAIR.system_skill_payload_inventory(active_skill),
            "ledger": self.ledger.read_bytes(),
            "catalog": Path(state["state"]["catalog"]).read_bytes(),
        }
        failing_generator = self.temp / "overlay-failing-generator.py"
        failing_generator.write_text("raise SystemExit(29)\n", encoding="utf-8")
        args = list(state["args"])
        args[args.index("--generator") + 1] = str(failing_generator)
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(args)
        self.assertEqual(code, 2)
        self.assertEqual(REPAIR.system_skill_payload_inventory(active_skill), before["skill"])
        self.assertEqual((active_skill / "SOURCE.md").read_bytes(), state["source_before"])
        self.assertEqual(self.ledger.read_bytes(), before["ledger"])
        self.assertEqual(Path(state["state"]["catalog"]).read_bytes(), before["catalog"])
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")

    def test_skill_creator_overlay_rejects_active_drift_before_swap(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay()
        active_skill = Path(state["state"]["system_root"]) / "skill-creator"
        before_ledger = self.ledger.read_bytes()
        original_stage = WRAPPER.stage_candidate

        def stage_then_drift(*args: object, **kwargs: object) -> dict[str, object]:
            staged = original_stage(*args, **kwargs)
            (active_skill / "scripts" / "quick_validate.py").write_text(
                "# concurrent mutation\n",
                encoding="utf-8",
            )
            return staged

        stderr = io.StringIO()
        with (
            mock.patch.object(WRAPPER, "stage_candidate", side_effect=stage_then_drift),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(stderr),
        ):
            code = WRAPPER.main(state["args"])
        self.assertEqual(code, 2)
        self.assertIn("active payload changed", stderr.getvalue())
        self.assertEqual(self.ledger.read_bytes(), before_ledger)
        self.assertEqual(
            (active_skill / "scripts" / "quick_validate.py").read_text(encoding="utf-8"),
            "# concurrent mutation\n",
        )

    def test_skill_creator_source_change_after_precheck_rolls_back_without_losing_change(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay(localized=True)
        active = Path(state["state"]["system_root"]) / "skill-creator"
        external_source = state["source_before"] + b"\nExternal provenance annotation.\n"
        before_ledger = self.ledger.read_bytes()
        before_catalog = Path(state["state"]["catalog"]).read_bytes()
        original_activate = WRAPPER.activate_directories

        def change_source_then_activate(*args: object, **kwargs: object) -> None:
            (active / "SOURCE.md").write_bytes(external_source)
            original_activate(*args, **kwargs)

        stderr = io.StringIO()
        with (
            mock.patch.object(WRAPPER, "activate_directories", side_effect=change_source_then_activate),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(stderr),
        ):
            code = WRAPPER.main(state["args"])
        self.assertEqual(code, 2, stderr.getvalue())
        self.assertIn("backup SOURCE.md", stderr.getvalue())
        self.assertEqual((active / "SOURCE.md").read_bytes(), external_source)
        self.assertEqual(REPAIR.system_skill_integrity(active), state["record_before"]["effective_integrity"])
        self.assertEqual(self.ledger.read_bytes(), before_ledger)
        self.assertEqual(Path(state["state"]["catalog"]).read_bytes(), before_catalog)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        self.assertEqual(json.loads(transaction.read_text(encoding="utf-8"))["status"], "rolled-back")

    def test_skill_creator_overlay_live_readback_catches_post_generation_payload_drift(self) -> None:
        state = self.prepare_skill_creator_compatibility_overlay()
        active_skill = Path(state["state"]["system_root"]) / "skill-creator"
        tampering_generator = self.temp / "overlay-tampering-generator.py"
        tampering_generator.write_text(
            "import subprocess, sys\n"
            "from pathlib import Path\n"
            f"generator = Path({str(self.generator)!r})\n"
            f"target = Path({str(active_skill / 'scripts' / 'quick_validate.py')!r})\n"
            "result = subprocess.run([sys.executable, str(generator), *sys.argv[1:]], capture_output=True)\n"
            "sys.stdout.buffer.write(result.stdout)\n"
            "sys.stderr.buffer.write(result.stderr)\n"
            "if result.returncode == 0:\n"
            "    target.write_text('# post-generation concurrent mutation\\n', encoding='utf-8')\n"
            "raise SystemExit(result.returncode)\n",
            encoding="utf-8",
        )
        args = list(state["args"])
        args[args.index("--generator") + 1] = str(tampering_generator)
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(args)
        self.assertEqual(code, 2)
        self.assertIn("effective integrity", stderr.getvalue())
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rollback-failed")

    def test_system_provenance_repair_detects_package_identity_replacement_and_rolls_back(
        self,
    ) -> None:
        state = self.prepare_system_provenance_repair()
        system_root = Path(state["system_root"])
        before = {
            "review": (system_root / "review-agent" / "SKILL.md").read_bytes(),
            "ledger": self.ledger.read_bytes(),
            "catalog": Path(state["catalog"]).read_bytes(),
        }
        manifest_path = Path(state["package_identity"]["appx_manifest_path"])
        replacement_generator = self.temp / "replace-package-identity-generator.py"
        replacement_generator.write_text(
            "import os, subprocess, sys, uuid\n"
            "from pathlib import Path\n"
            f"generator = Path({str(self.generator)!r})\n"
            f"manifest = Path({str(manifest_path)!r})\n"
            "result = subprocess.run([sys.executable, '-X', 'utf8', '-I', str(generator), *sys.argv[1:]], capture_output=True)\n"
            "sys.stdout.buffer.write(result.stdout)\n"
            "sys.stderr.buffer.write(result.stderr)\n"
            "if result.returncode == 0:\n"
            "    temporary = manifest.with_name('.' + manifest.name + '.' + uuid.uuid4().hex + '.tmp')\n"
            "    temporary.write_bytes(manifest.read_bytes())\n"
            "    os.replace(temporary, manifest)\n"
            "raise SystemExit(result.returncode)\n",
            encoding="utf-8",
        )

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(
                self.system_provenance_repair_args(
                    state,
                    generator=replacement_generator,
                )
            )

        self.assertEqual(code, 2)
        for name in state["names"]:
            self.assertFalse((system_root / name / "SOURCE.md").exists())
        self.assertEqual(
            (system_root / "review-agent" / "SKILL.md").read_bytes(), before["review"]
        )
        self.assertEqual(self.ledger.read_bytes(), before["ledger"])
        self.assertEqual(Path(state["catalog"]).read_bytes(), before["catalog"])
        transaction = max((self.temp / "evidence").glob("system-provenance-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")

    def test_system_provenance_repair_rejects_plan_schema_drift_before_write(
        self,
    ) -> None:
        state = self.prepare_system_provenance_repair()
        system_root = Path(state["system_root"])
        before = {
            "review": (system_root / "review-agent" / "SKILL.md").read_bytes(),
            "ledger": self.ledger.read_bytes(),
            "catalog": Path(state["catalog"]).read_bytes(),
        }
        provider = Path(state["provider"])
        plan = Path(state["plan"])
        count_path = self.temp / "provider-call-count.txt"
        provider.write_text(
            "import json\n"
            "from pathlib import Path\n"
            f"plan = Path({str(plan)!r})\n"
            f"count_path = Path({str(count_path)!r})\n"
            "count = int(count_path.read_text()) + 1 if count_path.exists() else 1\n"
            "count_path.write_text(str(count))\n"
            "if count == 2:\n"
            "    value = json.loads(plan.read_text(encoding='utf-8'))\n"
            "    value['schema_version'] = 2\n"
            "    plan.write_text(json.dumps(value), encoding='utf-8')\n"
            f"print(json.dumps({state['package_identity']!r}))\n",
            encoding="utf-8",
        )
        plan_value = json.loads(plan.read_text(encoding="utf-8"))
        plan_value["package_identity_provider_sha256"] = hashlib.sha256(
            provider.read_bytes()
        ).hexdigest()
        plan.write_text(json.dumps(plan_value, ensure_ascii=False), encoding="utf-8")

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(self.system_provenance_repair_args(state))

        self.assertEqual(code, 2)
        for name in state["names"]:
            self.assertFalse((system_root / name / "SOURCE.md").exists())
        self.assertEqual(
            (system_root / "review-agent" / "SKILL.md").read_bytes(), before["review"]
        )
        self.assertEqual(self.ledger.read_bytes(), before["ledger"])
        self.assertEqual(Path(state["catalog"]).read_bytes(), before["catalog"])

    def test_system_provenance_repair_mismatches_preserve_all_target_bytes(
        self,
    ) -> None:
        state = self.prepare_system_provenance_repair()
        system_root = Path(state["system_root"])
        plan = Path(state["plan"])
        original_plan = json.loads(plan.read_text(encoding="utf-8"))
        before = {
            "review": (system_root / "review-agent" / "SKILL.md").read_bytes(),
            "ledger": self.ledger.read_bytes(),
            "catalog": Path(state["catalog"]).read_bytes(),
        }

        def package_mismatch(value: dict[str, object]) -> None:
            value["package_identity"]["version"] = "26.810.7004.1"

        def marker_mismatch(value: dict[str, object]) -> None:
            value["marker"]["sha256"] = "0" * 64

        def tree_mismatch(value: dict[str, object]) -> None:
            value["skills"][0]["official_integrity"]["tree_sha256"] = "0" * 64

        def schema_mismatch(value: dict[str, object]) -> None:
            value["schema_version"] = 2

        for label, mutate in (
            ("package", package_mismatch),
            ("marker", marker_mismatch),
            ("tree", tree_mismatch),
            ("schema", schema_mismatch),
        ):
            with self.subTest(label=label):
                changed = json.loads(json.dumps(original_plan))
                mutate(changed)
                plan.write_text(json.dumps(changed), encoding="utf-8")
                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(self.system_provenance_repair_args(state))
                self.assertEqual(code, 2)
                for name in state["names"]:
                    self.assertFalse((system_root / name / "SOURCE.md").exists())
                self.assertEqual(
                    (system_root / "review-agent" / "SKILL.md").read_bytes(),
                    before["review"],
                )
                self.assertEqual(self.ledger.read_bytes(), before["ledger"])
                self.assertEqual(Path(state["catalog"]).read_bytes(), before["catalog"])
        plan.write_text(json.dumps(original_plan, ensure_ascii=False), encoding="utf-8")

    def test_system_provenance_repair_injected_failure_restores_all_target_bytes(
        self,
    ) -> None:
        state = self.prepare_system_provenance_repair()
        system_root = Path(state["system_root"])
        before = {
            "review": (system_root / "review-agent" / "SKILL.md").read_bytes(),
            "ledger": self.ledger.read_bytes(),
            "catalog": Path(state["catalog"]).read_bytes(),
        }
        failing_generator = self.temp / "failing-catalog-generator.py"
        failing_generator.write_text("raise SystemExit(23)\n", encoding="utf-8")

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(
                self.system_provenance_repair_args(
                    state,
                    generator=failing_generator,
                )
            )

        self.assertEqual(code, 2)
        for name in state["names"]:
            self.assertFalse((system_root / name / "SOURCE.md").exists())
        self.assertEqual(
            (system_root / "review-agent" / "SKILL.md").read_bytes(), before["review"]
        )
        self.assertEqual(self.ledger.read_bytes(), before["ledger"])
        self.assertEqual(Path(state["catalog"]).read_bytes(), before["catalog"])
        transaction = max((self.temp / "evidence").glob("system-provenance-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")
        self.assertEqual(len(result["backups"]), 8)
        self.assertEqual(result["rollback_errors"], [])

    def test_system_provenance_repair_rejects_post_generation_state_drift(self) -> None:
        state = self.prepare_system_provenance_repair()
        generator = self.temp / "post-generation-ledger.py"
        generator.write_text(
            "import subprocess, sys\n"
            "from pathlib import Path\n"
            f"result = subprocess.run([sys.executable, '-X', 'utf8', '-I', {str(self.generator)!r}, *sys.argv[1:]], capture_output=True)\n"
            "sys.stdout.buffer.write(result.stdout); sys.stderr.buffer.write(result.stderr)\n"
            f"Path({str(self.ledger)!r}).write_bytes(Path({str(self.ledger)!r}).read_bytes() + b'\\n')\n"
            "raise SystemExit(result.returncode)\n",
            encoding="utf-8",
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.system_provenance_repair_args(state, generator=generator))
        self.assertEqual(code, 2)
        self.assertFalse((Path(state["system_root"]) / "review-agent" / "SOURCE.md").exists())

    def test_system_provenance_repair_rejects_post_generation_catalog_drift(self) -> None:
        state = self.prepare_system_provenance_repair()
        generator = self.temp / "post-generation-catalog.py"
        generator.write_text(
            "import json, subprocess, sys\n"
            "from pathlib import Path\n"
            f"result = subprocess.run([sys.executable, '-X', 'utf8', '-I', {str(self.generator)!r}, *sys.argv[1:]], capture_output=True)\n"
            "sys.stdout.buffer.write(result.stdout); sys.stderr.buffer.write(result.stderr)\n"
            f"value = json.loads(Path({str(state['catalog'])!r}).read_text()); value['tampered'] = True; Path({str(state['catalog'])!r}).write_text(json.dumps(value), encoding='utf-8')\n"
            "raise SystemExit(result.returncode)\n",
            encoding="utf-8",
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.system_provenance_repair_args(state, generator=generator))
        self.assertEqual(code, 2)
        self.assertFalse((Path(state["system_root"]) / "review-agent" / "SOURCE.md").exists())

    def test_system_provenance_repair_malformed_preflight_is_structured_fail_closed(self) -> None:
        state = self.prepare_system_provenance_repair()
        parity_path = Path(state["system_root"]) / "review-agent" / "agents" / "openai.yaml"
        parity_path.write_text("policy: null\n", encoding="utf-8")
        plan = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
        plan["skills"][3]["critical_files"]["agents/openai.yaml"] = hashlib.sha256(parity_path.read_bytes()).hexdigest()
        Path(state["plan"]).write_text(json.dumps(plan), encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.system_provenance_repair_args(state))
        self.assertEqual(code, 2)
        self.assertIn('"ok": false', stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_system_provenance_repair_malformed_ledger_is_structured_fail_closed(self) -> None:
        state = self.prepare_system_provenance_repair()
        ledger_value = json.loads(self.ledger.read_text(encoding="utf-8"))
        ledger_value["sources"][0]["skills"] = [{"bad": "unhashable"}]
        self.ledger.write_text(json.dumps(ledger_value), encoding="utf-8")
        plan = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
        plan["ledger_before_sha256"] = hashlib.sha256(self.ledger.read_bytes()).hexdigest()
        Path(state["plan"]).write_text(json.dumps(plan), encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.system_provenance_repair_args(state))
        self.assertEqual(code, 2)
        self.assertIn('"ok": false', stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_review_overlay_preserves_utf8_bom(self) -> None:
        state = self.prepare_system_provenance_repair()
        path = Path(state["system_root"]) / "review-agent" / "SKILL.md"
        baseline = "\ufeff---\nname: review-agent\ndescription: \u57fa\u7ebf\u5939\u5177\u6280\u80fd\u63cf\u8ff0\n---\n\n# review-agent\n".encode("utf-8")
        path.write_bytes(baseline)
        patched = REPAIR._review_overlay_bytes(path, baseline)
        self.assertTrue(patched.startswith(b"\xef\xbb\xbf"))
        self.assertIn(b"disable-model-invocation: true", patched)

    def test_system_repair_rejects_ordinary_cli_options(self) -> None:
        for option, value in (("--system-installer", str(self.temp / "installer.ps1")), ("--ref", "main"), ("--method", "auto")):
            with self.subTest(option=option):
                state = self.prepare_system_provenance_repair()
                stderr = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                    code = WRAPPER.main(self.system_provenance_repair_args(state) + [option, value])
                self.assertEqual(code, 2)
                self.assertIn("不能与普通 install/update 参数混用", stderr.getvalue())

    def test_update_refreshes_repo_stars_and_preserves_existing_source_fields(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "旧采用度")
        initial_manifest = self.write_manifest(
            name,
            "install",
            ledger_updates={
                "path": ".codex/skills/test-skill-wrapper",
                "repo_stars": 15700,
                "repo_stars_checked_at": "2026-08-05",
                "status": "updated-with-local-overlay",
                "tag": "v3.5.1",
            },
        )
        with contextlib.redirect_stdout(io.StringIO()):
            initial_code = WRAPPER.main(self.wrapper_args(candidate, initial_manifest))
        self.assertEqual(initial_code, 0)

        (candidate / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: 新采用度\n---\n\n# {name}\n",
            encoding="utf-8",
        )
        update_manifest = self.write_manifest(
            name,
            "update",
            ledger_updates={
                "repo_stars": 19292,
                "repo_stars_checked_at": "2026-08-06",
            },
        )
        update_args = self.wrapper_args(candidate, update_manifest)
        update_args.append("--update")
        with contextlib.redirect_stdout(io.StringIO()):
            update_code = WRAPPER.main(update_args)
        self.assertEqual(update_code, 0)

        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        source = next(item for item in ledger["sources"] if item["id"] == "local-test")
        self.assertEqual(source["repo_stars"], 19292)
        self.assertEqual(source["repo_stars_checked_at"], "2026-08-06")
        self.assertEqual(source["path"], ".codex/skills/test-skill-wrapper")
        self.assertEqual(source["status"], "updated-with-local-overlay")
        self.assertEqual(source["tag"], "v3.5.1")

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
        candidate = self.write_candidate(name, "捆绑事务夹具")
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
                "捆绑夹具技能描述",
                "已被修改的捆绑夹具描述",
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

    def test_update_ledger_records_overlay_change_for_each_skill(self) -> None:
        data = {
            "sources": [{"id": "shared-source", "skills": []}],
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
            "overlay_status": "replayed",
            "overlay_summary": "restore upstream provenance",
        }

        result = WRAPPER.update_ledger(
            data,
            names=["skill-a", "skill-b"],
            context=context,
        )

        source = result["sources"][0]
        self.assertEqual(
            source["local_changes"],
            [
                {
                    "skill": "skill-a",
                    "date": WRAPPER.today(),
                    "summary": "guarded wrapper: restore upstream provenance",
                },
                {
                    "skill": "skill-b",
                    "date": WRAPPER.today(),
                    "summary": "guarded wrapper: restore upstream provenance",
                },
            ],
        )

    def test_update_ledger_assigns_legacy_overlay_change_before_appending(self) -> None:
        data = {
            "sources": [
                {
                    "id": "shared-source",
                    "skills": [],
                    "local_changes": [
                        {
                            "date": "2026-08-05",
                            "summary": "guarded wrapper: restore upstream provenance",
                        }
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
            "overlay_status": "replayed",
            "overlay_summary": "restore upstream provenance",
        }

        result = WRAPPER.update_ledger(
            data,
            names=["skill-a", "skill-b"],
            context=context,
        )

        source = result["sources"][0]
        self.assertEqual(
            source["local_changes"],
            [
                {
                    "skill": "skill-a",
                    "date": "2026-08-05",
                    "summary": "guarded wrapper: restore upstream provenance",
                },
                {
                    "skill": "skill-b",
                    "date": WRAPPER.today(),
                    "summary": "guarded wrapper: restore upstream provenance",
                },
            ],
        )

    def test_bundled_skill_rejects_parent_traversal_path(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "拒绝捆绑路径穿越的夹具")
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
        candidate = self.write_candidate(name, "需要捆绑来源的夹具")
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
        candidate = self.write_candidate(name, "绑定捆绑名称的夹具")
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
        candidate = self.write_candidate(name, "拒绝捆绑中文身份的夹具")
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
        candidate = self.write_candidate(name, "拒绝捆绑名称冲突的夹具")
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
                candidate = self.write_candidate(name, "拒绝不安全捆绑来源的夹具")
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
        candidate = self.write_candidate(name, "当前来源记录夹具")
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
        candidate = self.write_candidate(name, "带引号的当前来源身份夹具")
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
        candidate = self.write_candidate(name, "空白当前来源身份的夹具")
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
        candidate = self.write_candidate(name, "未知当前来源记录的夹具")
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
        candidate = self.write_candidate(name, "空白的最终来源记录夹具")
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
        candidate = self.write_candidate(name, "冲突的当前来源记录夹具")
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
        candidate = self.write_candidate(name, "冲突的捆绑来源记录夹具")
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

    def test_candidate_source_rejects_c0_control_characters_in_any_record(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "拒绝来源记录控制字符的夹具")
        # What a non-raw "D:\agents\..." literal writes: "\a" becomes BEL.
        corrupted_root = "D:\x07gents\\skills-manager\\skills"
        (candidate / "SOURCE.md").write_text(
            "\n".join(
                [
                    "# Source Provenance",
                    "",
                    f"Skill: `{name}`",
                    f"Local path: `{corrupted_root}\\{name}`",
                    f"Active root: `{corrupted_root}`",
                    "",
                    "---",
                    "",
                    f"Skill: `{name}`",
                    "Status: source-review",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        manifest = self.write_manifest(name, "install")
        ledger_before = self.ledger.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn(
            "C0 控制字符：第 4 行 U+0007、第 5 行 U+0007",
            json.loads(stderr.getvalue())["error"],
        )
        self.assertFalse((self.active / name).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)

    def test_candidate_source_allows_tab_and_crlf(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "允许制表符与 CRLF 的夹具")
        (candidate / "SOURCE.md").write_bytes(
            f"# Source Provenance\r\n\r\nSkill: `{name}`\r\nNote:\tkept\r\n".encode("utf-8")
        )
        manifest = self.write_manifest(name, "install")

        with contextlib.redirect_stdout(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 0)
        self.assertIn(
            "Note:\tkept",
            (self.active / name / "SOURCE.md").read_text(encoding="utf-8"),
        )

    def test_generated_source_record_rejects_manifest_control_characters(self) -> None:
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "拒绝追加记录控制字符的夹具")
        manifest = self.write_manifest(name, "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["local_overlay"] = {"status": "replayed", "summary": "D:\x07gents overlay"}
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        ledger_before = self.ledger.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn(
            "受管追加的 SOURCE.md 记录（来自 decision manifest 或安装参数）",
            json.loads(stderr.getvalue())["error"],
        )
        self.assertFalse((self.active / name).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)

    def test_candidate_source_rejects_current_record_path_mismatch(self) -> None:
        elsewhere = self.temp / "elsewhere"
        for index, field in enumerate(("Local path", "Active root")):
            with self.subTest(field=field):
                name = f"test-skill-wrapper-{index}"
                local_path = elsewhere / name if field == "Local path" else self.active / name
                active_root = elsewhere if field == "Active root" else self.active
                candidate = self.write_candidate(name, "拒绝来源路径漂移的夹具")
                (candidate / "SOURCE.md").write_text(
                    "\n".join(
                        [
                            f"Skill: `{name}`",
                            f"Local path: `{local_path}`",
                            f"Active root: `{active_root}`",
                            "",
                        ]
                    ),
                    encoding="utf-8",
                )
                manifest = self.write_manifest(name, "install")
                stderr = io.StringIO()

                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                    code = WRAPPER.main(self.wrapper_args(candidate, manifest, name=name))

                self.assertEqual(code, 2)
                self.assertIn(
                    f"候选 SOURCE.md 当前记录的 {field} 与实际路径不一致",
                    json.loads(stderr.getvalue())["error"],
                )
                self.assertFalse((self.active / name).exists())

    def test_source_record_paths_resolve_local_junction_alias_only(self) -> None:
        name = "test-skill-wrapper"
        legacy_root = self.temp / "legacy-active-root"
        self.create_junction(legacy_root, self.active)
        record = WRAPPER.parse_current_source_record(
            "\n".join(
                [
                    f"Skill: `{name}`",
                    rf"Local path: `C:\Users\retired\.agents\skills\{name}`",
                    "",
                    "---",
                    "",
                    f"Skill: `{name}`",
                    f"Local path: `{legacy_root / name}`",
                    f"Active root: `{legacy_root}`",
                    "",
                ]
            )
        )

        WRAPPER.validate_source_record_paths(
            record,
            label="候选 SOURCE.md",
            local_path=self.active / name,
            active_root=self.active,
        )
        with mock.patch.object(
            WRAPPER.os.path, "realpath", side_effect=AssertionError("UNC 路径不得解析")
        ):
            self.assertFalse(
                WRAPPER.same_filesystem_location(r"\\remote-host\share\skills", self.active)
            )

    def test_bundled_skill_source_rejects_control_characters_and_path_drift(self) -> None:
        relative_path = "vendor/runtime/skill"
        for index, case in enumerate(("control", "path-drift")):
            with self.subTest(case=case):
                name = f"test-skill-wrapper-{index}"
                bundled_name = f"vendor-runtime-{index}"
                expected_path = self.active / name / "vendor" / "runtime" / "skill"
                candidate = self.write_candidate(name, "校验捆绑来源记录的夹具")
                bundled = self.write_bundled_skill(candidate, relative_path, bundled_name)
                extra = (
                    "Note: `D:\x07gents`\n"
                    if case == "control"
                    else f"Local path: `{self.temp / 'elsewhere' / bundled_name}`\n"
                )
                source = bundled / "SOURCE.md"
                source.write_text(
                    source.read_text(encoding="utf-8") + extra,
                    encoding="utf-8",
                )
                manifest = self.write_manifest(name, "install")
                payload = json.loads(manifest.read_text(encoding="utf-8"))
                payload["bundled_skills"] = [{"path": relative_path, "name": bundled_name}]
                payload["candidate_integrity"] = WRAPPER.candidate_integrity_payload(candidate)
                manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
                stderr = io.StringIO()

                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                    code = WRAPPER.main(self.wrapper_args(candidate, manifest, name=name))

                self.assertEqual(code, 2)
                error = json.loads(stderr.getvalue())["error"]
                self.assertIn(f"bundled skill {bundled_name} SOURCE.md", error)
                if case == "control":
                    self.assertIn("C0 控制字符：第 8 行 U+0007", error)
                else:
                    self.assertIn("当前记录的 Local path 与实际路径不一致", error)
                    self.assertIn(f"`{expected_path}`", error)
                self.assertFalse((self.active / name).exists())

    def test_candidate_activation_records_durable_decision_evidence(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "持久的来源记录夹具")
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
        candidate = self.write_candidate("test-skill-wrapper", "决策清单竞态夹具")
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
            "---\nname: test-skill-wrapper\ndescription: 已漂移的夹具描述\n---\n\n# drifted\n",
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
            raise WRAPPER.InstallError("injected postcheck failure after backup loss")

        with (
            mock.patch.object(WRAPPER, "verify_catalog", side_effect=hide_backup_then_fail),
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

    def test_install_rejects_null_ledger_updates_before_activation(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "空 ledger updates")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["source"]["ledger_updates"] = None
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
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

    def test_install_rejects_invalid_repo_stars_before_activation(self) -> None:
        invalid_values = (-1, True, 19.2, "19292")
        for index, value in enumerate(invalid_values):
            with self.subTest(value=value):
                name = f"test-skill-wrapper-invalid-stars-{index}"
                candidate = self.write_candidate(name, "错误 star 数")
                manifest = self.write_manifest(
                    name,
                    "install",
                    ledger_updates={
                        "repo_stars": value,
                        "repo_stars_checked_at": "2026-08-06",
                    },
                )
                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(
                        self.wrapper_args(candidate, manifest, name=name)
                    )
                self.assertEqual(code, 2)
                self.assertFalse((self.active / name).exists())

    def test_install_rejects_invalid_repo_stars_date_before_activation(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "错误 star 观测日期")
        manifest = self.write_manifest(
            "test-skill-wrapper",
            "install",
            ledger_updates={
                "repo_stars": 19292,
                "repo_stars_checked_at": "2026-02-30",
            },
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))
        self.assertEqual(code, 2)
        self.assertFalse((self.active / "test-skill-wrapper").exists())

    def test_install_rejects_unpaired_repo_stars_metadata_before_activation(self) -> None:
        for index, ledger_updates in enumerate((
            {"repo_stars": 19292},
            {"repo_stars_checked_at": "2026-08-06"},
        )):
            with self.subTest(ledger_updates=ledger_updates):
                name = f"test-skill-wrapper-unpaired-stars-{index}"
                candidate = self.write_candidate(name, "未配对 star 元数据")
                manifest = self.write_manifest(
                    name,
                    "install",
                    ledger_updates=ledger_updates,
                )
                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(
                        self.wrapper_args(candidate, manifest, name=name)
                    )
                self.assertEqual(code, 2)
                self.assertFalse((self.active / name).exists())

    def test_install_rejects_noncanonical_ledger_strings_before_activation(self) -> None:
        invalid_updates = (
            {"status": " updated "},
            {"status": "updated\nforged"},
            {"resource_paths": [" SKILL.md "]},
            {"resource_paths": ["SKILL.md\nforged"]},
        )
        for index, ledger_updates in enumerate(invalid_updates):
            with self.subTest(ledger_updates=ledger_updates):
                name = f"test-skill-wrapper-noncanonical-{index}"
                candidate = self.write_candidate(name, "非规范 ledger 字符串")
                manifest = self.write_manifest(
                    name,
                    "install",
                    ledger_updates=ledger_updates,
                )
                with (
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(io.StringIO()),
                ):
                    code = WRAPPER.main(
                        self.wrapper_args(candidate, manifest, name=name)
                    )
                self.assertEqual(code, 2)
                self.assertFalse((self.active / name).exists())

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
            "writing-for-agents gate:",
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
                        "---\nname: wrong-successor\ndescription: 不匹配的夹具\n---\n",
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
                        "---\nname: wrong-predecessor\ndescription: 不匹配的夹具\n---\n",
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
            # baseline-resource-closure is call 1; post-resource-closure is call 3.
            if closure_calls == 3:
                raise WRAPPER.InstallError("injected rename closure failure")
            return original_run_closure(*arguments, **keywords)

        with (
            mock.patch.object(WRAPPER, "run_closure", side_effect=fail_post_closure),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(closure_calls, 3)
        self.assert_canonical_rename_rollback(
            state,
            ledger_before=ledger_before,
            catalog_before=catalog_before,
            old_seal=old_seal,
        )

    def test_merge_retirement_rejects_missing_target_survivor(self) -> None:
        state = self.prepare_merge_retirement()
        manifest = Path(state["manifest"])
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["merge_retirement"]["survivors"] = [
            payload["merge_retirement"]["survivors"][1]
        ]
        manifest.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            manifest,
            name=str(state["target_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertTrue(Path(state["retired_active"]).is_dir())

    def test_merge_retirement_rejects_casefold_target_alias_before_backup(self) -> None:
        state = self.prepare_merge_retirement(target_name="foo")
        manifest = Path(state["manifest"])
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["merge_retirement"]["retired"]["name"] = "Foo"
        manifest.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            manifest,
            name=str(state["target_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertFalse(any((self.temp / "evidence").glob("install-*")))

    def test_merge_retirement_rejects_same_repo_source_id_fallback(self) -> None:
        state = self.prepare_merge_retirement()
        manifest = Path(state["manifest"])
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["source"]["id"] = "missing-survivor-source"
        manifest.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            manifest,
            name=str(state["target_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertTrue(Path(state["retired_active"]).is_dir())

    def test_merge_retirement_rejects_casefold_ledger_alias_in_other_source(self) -> None:
        state = self.prepare_merge_retirement()
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        ledger["sources"].append(
            {
                "id": "casefold-alias-source",
                "type": "local-candidate",
                "repo": "other local candidate",
                "ref": "local",
                "skills": [str(state["retired_name"]).upper()],
            }
        )
        self.ledger.write_text(
            json.dumps(ledger, ensure_ascii=False),
            encoding="utf-8",
        )
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["target_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertTrue(Path(state["retired_active"]).is_dir())

    def test_merge_retirement_rejects_retired_hash_drift(self) -> None:
        state = self.prepare_merge_retirement()
        retired_skill_md = Path(state["retired_active"]) / "SKILL.md"
        retired_skill_md.write_text(
            retired_skill_md.read_text(encoding="utf-8") + "\nchanged\n",
            encoding="utf-8",
        )
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["target_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertTrue(Path(state["retired_active"]).is_dir())

    def test_merge_retirement_rejects_payload_drift_during_backup_move(self) -> None:
        state = self.prepare_merge_retirement()
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_retire = WRAPPER.retire_directories

        def drift_then_retire(**keywords: object) -> list[dict[str, object]]:
            retired_root = Path(state["retired_active"])
            (retired_root / "late-drift.txt").write_text(
                "concurrent content",
                encoding="utf-8",
            )
            return original_retire(**keywords)

        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["target_name"]),
        )
        args.append("--update")
        with (
            mock.patch.object(
                WRAPPER,
                "retire_directories",
                side_effect=drift_then_retire,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertTrue((Path(state["retired_active"]) / "late-drift.txt").is_file())
        self.assertEqual(
            WRAPPER.tree_content_seal(Path(state["target_active"])),
            state["target_before_seal"],
        )
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")

    def test_merge_retirement_dry_run_has_no_state_side_effects(self) -> None:
        state = self.prepare_merge_retirement()
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["target_name"]),
        )
        args.extend(["--update", "--dry-run"])

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertEqual(
            WRAPPER.tree_content_seal(Path(state["target_active"])),
            state["target_before_seal"],
        )
        self.assertEqual(
            WRAPPER.tree_content_seal(Path(state["retired_active"])),
            state["retired_before_seal"],
        )
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "dry-run-pass")
        self.assertEqual(
            result["merge_retirement"]["retired"]["name"],
            state["retired_name"],
        )

    def test_merge_retirement_succeeds_and_records_exact_retirement(self) -> None:
        state = self.prepare_merge_retirement()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["target_name"]),
        )
        args.append("--update")

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        self.assertFalse(Path(state["retired_active"]).exists())
        self.assertEqual(
            WRAPPER.sha256_file(Path(state["target_active"]) / "SKILL.md"),
            state["candidate_sha256"],
        )
        self.assertTrue(Path(state["other_survivor"]).is_dir())
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        retired_rows = [
            row
            for row in ledger["deleted"]
            if row.get("name") == state["retired_name"]
        ]
        self.assertEqual(len(retired_rows), 1)
        self.assertEqual(retired_rows[0]["status"], "deleted-by-user")
        self.assertEqual(
            retired_rows[0]["survivors"],
            [state["target_name"], state["other_survivor_name"]],
        )
        retired_source = next(
            source
            for source in ledger["sources"]
            if source.get("id") == state["retired_source_id"]
        )
        self.assertEqual(retired_source["skills"], [])
        self.assertEqual(retired_source["status"], "deleted-by-user")
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "succeeded")
        self.assertTrue(
            result["merge_retirement_verification"]["retired"]["active_absent"]
        )
        self.assertTrue(
            result["merge_retirement_verification"]["retired"][
                "source_deleted_skills_recorded"
            ]
        )
        retirement = result["merge_retirement"]
        top_level_reason_drift = json.loads(json.dumps(ledger))
        top_level_reason_drift["deleted"][0]["reason"] = "wrong reason"
        with self.assertRaisesRegex(
            WRAPPER.InstallError,
            "ledger deleted 记录不唯一或不完整",
        ):
            WRAPPER.verify_merge_retirement_postcondition(
                active_root=self.active,
                ledger=top_level_reason_drift,
                catalog_path=Path(state["catalog"]),
                retirement=retirement,
            )
        source_reason_drift = json.loads(json.dumps(ledger))
        retired_source_with_drift = next(
            source
            for source in source_reason_drift["sources"]
            if source.get("id") == state["retired_source_id"]
        )
        retired_source_with_drift["deleted_skills"][0]["reason"] = "wrong reason"
        with self.assertRaisesRegex(
            WRAPPER.InstallError,
            "source.deleted_skills 记录不唯一或不完整",
        ):
            WRAPPER.verify_merge_retirement_postcondition(
                active_root=self.active,
                ledger=source_reason_drift,
                catalog_path=Path(state["catalog"]),
                retirement=retirement,
            )
        retired_record = next(
            record
            for record in result["directory_records"]
            if record.get("retired")
        )
        self.assertTrue(Path(retired_record["backup"]).is_dir())
        self.assertEqual(
            result["merge_retirement_verification"]["backup_cleanup"],
            "required-after-transaction-success",
        )

    def test_merge_retirement_accepts_direct_entry_retired_coverage(self) -> None:
        state = self.prepare_merge_retirement()
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        retired_source = next(
            source
            for source in ledger["sources"]
            if source.get("id") == state["retired_source_id"]
        )
        retired_source["name"] = state["retired_name"]
        retired_source.pop("skills")
        self.ledger.write_text(
            json.dumps(ledger, ensure_ascii=False),
            encoding="utf-8",
        )
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["target_name"]),
        )
        args.append("--update")

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 0)
        updated_ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        retired_source = next(
            source
            for source in updated_ledger["sources"]
            if source.get("id") == state["retired_source_id"]
        )
        self.assertNotIn("name", retired_source)
        self.assertEqual(retired_source["skills"], [])
        self.assertEqual(len(retired_source["deleted_skills"]), 1)

    def test_merge_retirement_ledger_drift_during_postcheck_rolls_back(self) -> None:
        state = self.prepare_merge_retirement()
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_run_closure = WRAPPER.run_closure
        closure_calls = 0

        def drift_after_post_closure(
            *arguments: object, **keywords: object
        ) -> dict[str, object]:
            nonlocal closure_calls
            closure_calls += 1
            result = original_run_closure(*arguments, **keywords)
            # baseline-resource-closure is call 1; post-resource-closure is call 3.
            if closure_calls == 3:
                persisted = json.loads(self.ledger.read_text(encoding="utf-8"))
                persisted["notes"].append("injected ledger drift")
                self.ledger.write_text(
                    json.dumps(persisted, ensure_ascii=False),
                    encoding="utf-8",
                )
            return result

        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["target_name"]),
        )
        args.append("--update")

        with (
            mock.patch.object(
                WRAPPER,
                "run_closure",
                side_effect=drift_after_post_closure,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(closure_calls, 3)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertEqual(
            WRAPPER.tree_content_seal(Path(state["target_active"])),
            state["target_before_seal"],
        )
        self.assertEqual(
            WRAPPER.tree_content_seal(Path(state["retired_active"])),
            state["retired_before_seal"],
        )

    def test_merge_retirement_catalog_failure_restores_all_state(self) -> None:
        state = self.prepare_merge_retirement()
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        failing_generator = self.temp / "failing-merge-generator.py"
        failing_generator.write_text("import sys\nsys.exit(9)\n", encoding="utf-8")
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            generator=failing_generator,
            name=str(state["target_name"]),
        )
        args.append("--update")

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        self.assertEqual(
            WRAPPER.tree_content_seal(Path(state["target_active"])),
            state["target_before_seal"],
        )
        self.assertEqual(
            WRAPPER.tree_content_seal(Path(state["retired_active"])),
            state["retired_before_seal"],
        )
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")


if __name__ == "__main__":
    unittest.main()
