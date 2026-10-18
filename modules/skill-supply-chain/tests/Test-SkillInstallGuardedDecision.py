#!/usr/bin/env python3
"""Decision manifest tests for the guarded skill install: schema, gates, upstream paths, ledger updates."""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import unittest
from pathlib import Path
from unittest import mock


TESTS_ROOT = Path(__file__).resolve().parent
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from guarded_install_fixtures import BASE, DECISION, WRAPPER, GuardedInstallTestCase


class SkillInstallGuardedDecisionTests(GuardedInstallTestCase):
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
        result = DECISION.validate_decision_manifest(path)
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
        with self.assertRaisesRegex(BASE.InstallError, "已退役"):
            DECISION.validate_decision_manifest(path)

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
        with self.assertRaisesRegex(BASE.InstallError, "已退役"):
            DECISION.validate_decision_manifest(path)

    def test_manifest_disappearing_after_validation_returns_governed_error(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "决策清单竞态夹具")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        original_load = DECISION.load_and_validate_manifest

        def load_then_remove(path: Path, *, names: list[str]) -> dict[str, object]:
            result = original_load(path, names=names)
            path.unlink()
            return result

        stderr = io.StringIO()
        with (
            mock.patch.object(
                DECISION,
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


if __name__ == "__main__":
    unittest.main()
