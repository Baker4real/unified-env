#!/usr/bin/env python3
"""Bundled skill tests for the guarded skill install: declared bundles, names, paths, source records."""

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

from guarded_install_fixtures import (
    BASE,
    BUNDLED,
    CLOSURE,
    PAYLOAD,
    WRAPPER,
    GuardedInstallTestCase,
)


class SkillInstallGuardedBundledTests(GuardedInstallTestCase):
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
        payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
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
            BUNDLED.BundledSkillProof.from_staged_projection(item)
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
            BASE.InstallError,
            "SOURCE.md 与暂存期哈希不一致",
        ):
            CLOSURE.verify_catalog(
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
        bundled[0]["integrity"]["skill_md_sha256"] = BASE.sha256_file(active_skill)
        (self.temp / "catalog.json").write_text(
            json.dumps(catalog, ensure_ascii=False),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            BASE.InstallError,
            "SKILL.md 与暂存期哈希不一致",
        ):
            CLOSURE.verify_catalog(
                catalog_path=self.temp / "catalog.json",
                active_root=self.active,
                names=[name],
                bundled_proofs=staged_proofs,
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
        payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
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
        payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
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
        payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
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
                payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
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


if __name__ == "__main__":
    unittest.main()
