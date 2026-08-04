from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = PROJECT_ROOT / "scripts"
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))
SPEC = importlib.util.spec_from_file_location(
    "reconcile_skill_source_records",
    SCRIPT_ROOT / "reconcile_skill_source_records.py",
)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class SkillSourceRecordMigrationTests(unittest.TestCase):
    def write_complete_manifest(self, root: Path) -> tuple[Path, dict[str, object]]:
        active = root / "active"
        runtime = root / "runtime-target"
        ledger = root / "ledger.json"
        catalog = root / "catalog.json"
        recovery_payload = b"verified-tool"
        recovery_tool_names = (
            "reconcile_skill_source_records.py",
            "skill_source_record.py",
        )
        document: dict[str, object] = {
            "schema_version": 2,
            "kind": "skill-source-current-record-rollback",
            "backup_root": str(root),
            "allowed_targets": {
                "active_root": str(active),
                "ledger": str(ledger),
                "catalog": str(catalog),
                "runtime_root": str(runtime),
            },
            "entries": [
                {
                    "target": str(active / "example" / "SOURCE.md"),
                    "backup_relative": "sources/example/SOURCE.md",
                    "before_exists": False,
                    "before_sha256": None,
                    "before_size": None,
                },
                {
                    "target": str(ledger),
                    "backup_relative": "state/ledger.json",
                    "before_exists": False,
                    "before_sha256": None,
                    "before_size": None,
                },
                {
                    "target": str(catalog),
                    "backup_relative": "state/catalog.json",
                    "before_exists": False,
                    "before_sha256": None,
                    "before_size": None,
                },
                *[
                    {
                        "target": str(runtime / name),
                        "backup_relative": f"runtime/{name}",
                        "before_exists": False,
                        "before_sha256": None,
                        "before_size": None,
                    }
                    for name in module.RUNTIME_FILES
                ],
            ],
            "recovery_tools": [
                {
                    "backup_relative": f"tools/{name}",
                    "sha256": module._sha256(recovery_payload),
                    "size": len(recovery_payload),
                }
                for name in recovery_tool_names
            ],
            "restore_command": ["python", "tool.py", "--restore"],
        }
        tools = root / "tools"
        tools.mkdir(parents=True)
        for name in recovery_tool_names:
            (tools / name).write_bytes(recovery_payload)
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps(document), encoding="utf-8")
        return manifest, document

    def test_plain_fields_promote_multiline_narrative_without_changing_history(self) -> None:
        before = """# Source

Skill: `example-skill`
Repository: https://example.test/owner/repo
Ref: `main`

Local overlay:
- 2026-01-01: Preserved the local description.
- none dropped.
"""
        after, section, fields, narrative = module._canonical_record(
            before, expected_name="example-skill", scope="active"
        )

        self.assertTrue(after.startswith(before.rstrip("\r\n") + "\n\n---\n\n"))
        self.assertEqual(section, 0)
        self.assertIn("local_overlay", fields)
        self.assertEqual(narrative, ("local_overlay",))
        current = module.parse_current_source_record(after)
        self.assertEqual(current.conflicts, {})
        self.assertEqual(current.fields["skill"], "example-skill")
        self.assertIn("Preserved the local description", current.fields["local_overlay"])
        self.assertIn("none dropped", current.fields["local_overlay"])

    def test_markdown_bullet_fields_become_a_valid_current_record(self) -> None:
        before = """# Source Record

## Installed Skill

- Skill: `example-skill`
- Local active path: `D:\\Codex\\.codex\\skills\\example-skill`

## Download Source

- Repository: `https://example.test/owner/repo`
- Ref: `v1.2.3`
"""
        after, section, fields, narrative = module._canonical_record(
            before, expected_name="example-skill", scope="active"
        )

        self.assertEqual(section, 0)
        self.assertEqual(narrative, ())
        self.assertIn("local_active_path", fields)
        current = module.parse_current_source_record(after)
        self.assertEqual(current.conflicts, {})
        self.assertEqual(current.fields["skill"], "example-skill")
        self.assertEqual(current.fields["ref"], "v1.2.3")

    def test_previous_nonempty_section_is_replayed_after_empty_tail(self) -> None:
        before = """Skill: example-skill
Repository: https://example.test/owner/repo

---

# narrative only
"""
        after, section, _, _ = module._canonical_record(
            before, expected_name="example-skill", scope="active"
        )

        self.assertEqual(section, 0)
        self.assertEqual(
            module.parse_current_source_record(after).fields["repository"],
            "https://example.test/owner/repo",
        )

    def test_distinct_scalar_values_fail_closed(self) -> None:
        before = """Skill: example-skill
Ref: v1
Ref: v2
"""
        with self.assertRaisesRegex(module.MigrationError, "多个不同值"):
            module._canonical_record(
                before, expected_name="example-skill", scope="active"
            )

    def test_system_identity_accepts_and_preserves_system_prefix(self) -> None:
        before = """# Source
Skill: `.system/review-agent`
Source type: codex-bundled-system
"""
        after, _, _, _ = module._canonical_record(
            before, expected_name="review-agent", scope="system"
        )
        current = module.parse_current_source_record(after)
        self.assertEqual(current.conflicts, {})
        self.assertEqual(current.fields["skill"], ".system/review-agent")

    def test_existing_bytes_are_never_rewritten(self) -> None:
        before = "Skill: example-skill\r\nStatus: local-only\r\n"
        after, _, _, _ = module._canonical_record(
            before, expected_name="example-skill", scope="active"
        )
        self.assertTrue(after.startswith(before))
        self.assertIn("\r\n\n---\n\n# Current Source Record", after)

    def test_utf8_bom_crlf_and_trailing_newlines_remain_an_exact_byte_prefix(self) -> None:
        before = b"\xef\xbb\xbfSkill: example-skill\r\nStatus: local-only\r\n\r\n"
        text = before.decode("utf-8-sig")
        after_text, _, _, _ = module._canonical_record(
            text, expected_name="example-skill", scope="active"
        )
        after = before + after_text[len(text) :].encode("utf-8")
        self.assertEqual(after[: len(before)], before)

    def test_verify_backup_rejects_payload_hash_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            active = root / "active"
            runtime = root / "runtime-target"
            ledger = root / "ledger.json"
            catalog = root / "catalog.json"
            payload = root / "sources" / "example" / "SOURCE.md"
            payload.parent.mkdir(parents=True)
            payload.write_bytes(b"before")
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "kind": "skill-source-current-record-rollback",
                        "backup_root": str(root),
                        "allowed_targets": {
                            "active_root": str(active),
                            "ledger": str(ledger),
                            "catalog": str(catalog),
                            "runtime_root": str(runtime),
                        },
                        "entries": [
                            {
                                "target": str(active / "example" / "SOURCE.md"),
                                "backup_relative": "sources/example/SOURCE.md",
                                "before_exists": True,
                                "before_sha256": module._sha256(b"different"),
                                "before_size": len(b"different"),
                            },
                            {
                                "target": str(ledger),
                                "backup_relative": "state/ledger.json",
                                "before_exists": False,
                                "before_sha256": None,
                                "before_size": None,
                            },
                            {
                                "target": str(catalog),
                                "backup_relative": "state/catalog.json",
                                "before_exists": False,
                                "before_sha256": None,
                                "before_size": None,
                            },
                            *[
                                {
                                    "target": str(runtime / name),
                                    "backup_relative": f"runtime/{name}",
                                    "before_exists": False,
                                    "before_sha256": None,
                                    "before_size": None,
                                }
                                for name in module.RUNTIME_FILES
                            ],
                        ],
                        "restore_command": ["python", "tool.py", "--restore"],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(module.MigrationError, "校验失败"):
                module.verify_backup(manifest)

    def test_restore_backup_restores_bytes_and_removes_transaction_created_file(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            active = root / "active"
            runtime = root / "runtime-target"
            ledger = root / "ledger.json"
            catalog = root / "catalog.json"
            payload = root / "sources" / "example" / "SOURCE.md"
            payload.parent.mkdir(parents=True)
            payload.write_bytes(b"before")
            target = active / "example" / "SOURCE.md"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"after")
            created = runtime / module.RUNTIME_FILES[0]
            created.parent.mkdir(parents=True)
            created.write_bytes(b"transaction-created")
            recovery_payload = b"verified-tool"
            recovery_tool_names = (
                "reconcile_skill_source_records.py",
                "skill_source_record.py",
            )
            recovery_root = root / "tools"
            recovery_root.mkdir()
            for name in recovery_tool_names:
                (recovery_root / name).write_bytes(recovery_payload)
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "kind": "skill-source-current-record-rollback",
                        "backup_root": str(root),
                        "allowed_targets": {
                            "active_root": str(active),
                            "ledger": str(ledger),
                            "catalog": str(catalog),
                            "runtime_root": str(runtime),
                        },
                        "entries": [
                            {
                                "target": str(target),
                                "backup_relative": "sources/example/SOURCE.md",
                                "before_exists": True,
                                "before_sha256": module._sha256(b"before"),
                                "before_size": len(b"before"),
                            },
                            {
                                "target": str(ledger),
                                "backup_relative": "state/ledger.json",
                                "before_exists": False,
                                "before_sha256": None,
                                "before_size": None,
                            },
                            {
                                "target": str(catalog),
                                "backup_relative": "state/catalog.json",
                                "before_exists": False,
                                "before_sha256": None,
                                "before_size": None,
                            },
                            *[
                                {
                                    "target": str(created if index == 0 else runtime / name),
                                    "backup_relative": f"runtime/{name}",
                                    "before_exists": False,
                                    "before_sha256": None,
                                    "before_size": None,
                                }
                                for index, name in enumerate(module.RUNTIME_FILES)
                            ],
                        ],
                        "recovery_tools": [
                            {
                                "backup_relative": f"tools/{name}",
                                "sha256": module._sha256(recovery_payload),
                                "size": len(recovery_payload),
                            }
                            for name in recovery_tool_names
                        ],
                        "restore_command": ["python", "tool.py", "--restore"],
                    }
                ),
                encoding="utf-8",
            )
            module._protect_acl(root)

            result = module.restore_backup(manifest)

            self.assertEqual(result["status"], "restored")
            self.assertEqual(result["entry_count"], 7)
            self.assertEqual(target.read_bytes(), b"before")
            self.assertFalse(created.exists())

    def test_verify_backup_rejects_source_target_escape(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest, document = self.write_complete_manifest(root)
            document["entries"][0]["target"] = str(root / "outside" / "SOURCE.md")
            manifest.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(module.MigrationError, "target 映射不一致"):
                module.verify_backup(manifest)

    def test_verify_backup_rejects_wrong_state_and_runtime_targets(self) -> None:
        for entry_index in (1, 3):
            with self.subTest(entry_index=entry_index):
                with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
                    root = Path(temp)
                    manifest, document = self.write_complete_manifest(root)
                    document["entries"][entry_index]["target"] = str(
                        root / "wrong-target.bin"
                    )
                    manifest.write_text(json.dumps(document), encoding="utf-8")

                    with self.assertRaisesRegex(
                        module.MigrationError, "target 映射不一致"
                    ):
                        module.verify_backup(manifest)

    def test_schema_one_compatibility_is_limited_to_the_adopted_manifest(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest, document = self.write_complete_manifest(root)
            document["schema_version"] = 1
            document.pop("allowed_targets")
            manifest.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(module.MigrationError, "仅兼容已采用"):
                module.verify_backup(manifest)

    def test_reharden_rejects_legacy_manifest_hash_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest = root / "manifest.json"
            original = b'{"schema_version":1}'
            manifest.write_bytes(original)
            expected_sha256 = module._sha256(original).upper()
            manifest.write_bytes(original + b"\n")

            with (
                mock.patch.object(module, "LEGACY_ADOPTED_SCHEMA1_BACKUP_ROOT", root),
                mock.patch.object(
                    module,
                    "LEGACY_ADOPTED_SCHEMA1_MANIFEST_SHA256",
                    expected_sha256,
                ),
                self.assertRaisesRegex(module.MigrationError, "manifest 哈希漂移"),
            ):
                module._verify_exact_legacy_backup(manifest)

    def test_verify_backup_rejects_recovery_tool_hash_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest, document = self.write_complete_manifest(root)
            tools = []
            for name in ("reconcile_skill_source_records.py", "skill_source_record.py"):
                path = root / "tools" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"verified-tool")
                tools.append(
                    {
                        "backup_relative": f"tools/{name}",
                        "sha256": module._sha256(b"verified-tool"),
                        "size": len(b"verified-tool"),
                    }
                )
            document["recovery_tools"] = tools
            manifest.write_text(json.dumps(document), encoding="utf-8")
            (root / "tools" / "reconcile_skill_source_records.py").write_bytes(
                b"drifted-tool"
            )

            with self.assertRaisesRegex(module.MigrationError, "recovery tool 哈希漂移"):
                module.verify_backup(manifest)

    def test_verify_backup_rejects_unbound_recovery_tool_file(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest, document = self.write_complete_manifest(root)
            tools = []
            for name in ("reconcile_skill_source_records.py", "skill_source_record.py"):
                path = root / "tools" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"verified-tool")
                tools.append(
                    {
                        "backup_relative": f"tools/{name}",
                        "sha256": module._sha256(b"verified-tool"),
                        "size": len(b"verified-tool"),
                    }
                )
            document["recovery_tools"] = tools
            manifest.write_text(json.dumps(document), encoding="utf-8")
            (root / "tools" / "unbound.pyc").write_bytes(b"unbound")

            with self.assertRaisesRegex(module.MigrationError, "未绑定"):
                module.verify_backup(manifest)

    def test_verify_backup_rejects_partial_schema_two_closure(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest, document = self.write_complete_manifest(root)
            document["entries"].pop()
            manifest.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(module.MigrationError, "缺少 SOURCE"):
                module.verify_backup(manifest)

    def test_verify_backup_rejects_missing_schema_two_recovery_tools(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest, document = self.write_complete_manifest(root)
            document.pop("recovery_tools")
            manifest.write_text(json.dumps(document), encoding="utf-8")

            with self.assertRaisesRegex(module.MigrationError, "recovery_tools 闭包无效"):
                module.verify_backup(manifest)

    def test_acl_verifier_rejects_descendant_acl_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest = root / "manifest.json"
            manifest.write_bytes(b"protected")
            drifted = False

            def fake_run(command: list[str], **_: object) -> mock.Mock:
                nonlocal drifted
                if command[0] == "whoami.exe":
                    return mock.Mock(returncode=0, stdout="BAKER\\WINDOWS\n")
                if "/verify" in command:
                    return mock.Mock(returncode=0, stdout="verified")
                candidate = Path(command[1])
                if drifted and candidate == manifest:
                    principals = (
                        "BAKER\\WINDOWS:(F)",
                        "NT AUTHORITY\\SYSTEM:(F)",
                        "NT AUTHORITY\\LogonSessionId_0_1:(RX)",
                    )
                else:
                    principals = (
                        "BUILTIN\\Administrators:(F)",
                        "NT AUTHORITY\\SYSTEM:(F)",
                        "BAKER\\WINDOWS:(F)",
                    )
                stdout = f"{candidate} {principals[0]}\n  {principals[1]}\n  {principals[2]}\n"
                return mock.Mock(returncode=0, stdout=stdout)

            with mock.patch.object(module.subprocess, "run", side_effect=fake_run):
                self.assertEqual(module._verify_acl(root)["verified_item_count"], 2)
                drifted = True
                with self.assertRaisesRegex(
                    module.MigrationError, "protected FullControl DACL"
                ):
                    module._verify_acl(root)

    def test_acl_protection_repairs_atomic_rewrite_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest = root / "manifest.json"
            manifest.write_bytes(b"protected")
            module._protect_acl(root)
            self.assertEqual(module._verify_acl(root)["verified_item_count"], 2)

            module._atomic_write(manifest, b"rewritten-after-protection")
            with self.assertRaisesRegex(module.MigrationError, "protected FullControl DACL"):
                module._verify_acl(root)

            module._protect_acl(root)
            self.assertEqual(module._verify_acl(root)["verified_item_count"], 2)

    def test_schema_two_verifier_rejects_post_creation_acl_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=Path(r"D:\Codex\tmp")) as temp:
            root = Path(temp)
            manifest, _ = self.write_complete_manifest(root)
            module._protect_acl(root)
            self.assertEqual(module.verify_backup(manifest)["entry_count"], 7)

            module._atomic_write(manifest, manifest.read_bytes())
            with self.assertRaisesRegex(module.MigrationError, "protected FullControl DACL"):
                module.verify_backup(manifest)
            module._protect_acl(root)


if __name__ == "__main__":
    unittest.main()
