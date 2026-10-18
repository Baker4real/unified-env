#!/usr/bin/env python3
"""SOURCE.md record tests for the guarded skill install: current record, control characters, evidence."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock


TESTS_ROOT = Path(__file__).resolve().parent
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from guarded_install_fixtures import PAYLOAD, SOURCE_RECORD, WRAPPER, GuardedInstallTestCase


class SkillInstallGuardedSourceRecordTests(GuardedInstallTestCase):
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
        payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
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
        record = SOURCE_RECORD.parse_current_source_record(
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

        SOURCE_RECORD.validate_source_record_paths(
            record,
            label="候选 SOURCE.md",
            local_path=self.active / name,
            active_root=self.active,
        )
        with mock.patch.object(
            os.path, "realpath", side_effect=AssertionError("UNC 路径不得解析")
        ):
            self.assertFalse(
                SOURCE_RECORD.same_filesystem_location(r"\\remote-host\share\skills", self.active)
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
                payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
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


if __name__ == "__main__":
    unittest.main()
