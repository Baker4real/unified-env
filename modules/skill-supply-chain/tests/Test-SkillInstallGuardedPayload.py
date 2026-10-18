#!/usr/bin/env python3
"""Candidate payload tests for the guarded skill install: integrity binding, exclusions, display metadata."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import unittest
from pathlib import Path


TESTS_ROOT = Path(__file__).resolve().parent
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from guarded_install_fixtures import BASE, PAYLOAD, WRAPPER, GuardedInstallTestCase


class SkillInstallGuardedPayloadTests(GuardedInstallTestCase):
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

    def test_install_rejects_english_first_description_before_activation(self) -> None:
        # Technical tokens may outnumber CJK characters if the text starts in Chinese.
        accepted = self.write_candidate("display-accepted", "使用 React、GSAP 和 PowerShell 实现界面")
        PAYLOAD.validate_chinese_display_metadata(accepted, label="candidate")
        name = "test-skill-wrapper"
        candidate = self.write_candidate(name, "English 中文")
        manifest = self.write_manifest(name, "install")
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"artifacts":[{"name":"existing"}]}\n')
        ledger_before = self.ledger.read_bytes()
        catalog_before = catalog.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest))

        self.assertEqual(code, 2)
        self.assertIn("description 必须以中文为主体", stderr.getvalue())
        self.assertFalse((self.active / name).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(catalog.read_bytes(), catalog_before)

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
        self.assertEqual(integrity["skill_md_sha256"], BASE.sha256_file(candidate / "SKILL.md"))
        self.assertEqual(result["excluded_files"]["file_count"], 1)
        self.assertFalse((self.active / "test-skill-wrapper").exists())


if __name__ == "__main__":
    unittest.main()
