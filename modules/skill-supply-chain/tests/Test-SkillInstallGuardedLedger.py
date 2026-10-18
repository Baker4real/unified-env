#!/usr/bin/env python3
"""Source ledger tests for the guarded skill install: ledger updates and the group checkpoint guard."""

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
    DECISION,
    LEDGER,
    WRAPPER,
    GuardedInstallTestCase,
)


class SkillInstallGuardedLedgerTests(GuardedInstallTestCase):
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
                BUNDLED.BundledSkillProof(
                    top_level_name="root-a",
                    path="vendor/new-skill",
                    name="new-skill",
                ),
            ),
            "overlay_status": "none",
            "overlay_summary": "",
        }

        result = LEDGER.update_ledger(data, names=["root-a"], context=context)

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

        result = LEDGER.update_ledger(data, names=["root-a"], context=context)

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
                BUNDLED.BundledSkillProof(
                    top_level_name="root-a",
                    path="vendor/new-skill",
                    name="new-skill",
                ),
            ),
            "overlay_status": "none",
            "overlay_summary": "",
        }

        result = LEDGER.update_ledger(data, names=["root-a"], context=context)

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

        result = LEDGER.update_ledger(
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
                    "date": BASE.today(),
                    "summary": "guarded wrapper: restore upstream provenance",
                },
                {
                    "skill": "skill-b",
                    "date": BASE.today(),
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

        result = LEDGER.update_ledger(
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
                    "date": BASE.today(),
                    "summary": "guarded wrapper: restore upstream provenance",
                },
            ],
        )

    def group_checkpoint_context(self, **overrides: object) -> dict[str, object]:
        context: dict[str, object] = {
            "source_id": "shared-source",
            "repo": "https://github.com/example/shared-source",
            "commit": "2222222222222222",
            "advance_group_checkpoint": False,
        }
        context.update(overrides)
        return context

    def group_checkpoint_ledger(
        self,
        *,
        skills: list[str],
        checkpoint: str = "1111111111",
    ) -> dict[str, object]:
        return {
            "sources": [
                {
                    "id": "shared-source",
                    "repo": "https://github.com/example/shared-source",
                    "skills": skills,
                    "last_checked_commit": checkpoint,
                    "catalog_ref": checkpoint,
                }
            ],
            "unresolved": [],
            "deleted": [],
        }

    def test_group_checkpoint_rejects_partial_group_advance(self) -> None:
        ledger = self.group_checkpoint_ledger(skills=["skill-a", "skill-b", "skill-c"])

        with self.assertRaisesRegex(BASE.InstallError, "advance_group_checkpoint") as raised:
            LEDGER.validate_group_checkpoint_advance(
                ledger,
                names=["skill-a"],
                context=self.group_checkpoint_context(),
            )

        message = str(raised.exception)
        self.assertIn("1111111111", message)
        self.assertIn("skill-b", message)
        self.assertIn("skill-c", message)
        self.assertIn("删掉 commit", message)

    def test_group_checkpoint_rename_counts_old_name_and_requires_declaration(self) -> None:
        ledger = self.group_checkpoint_ledger(skills=["skill-old", "skill-b"])

        with self.assertRaisesRegex(BASE.InstallError, "canonical rename 必须带 commit") as raised:
            LEDGER.validate_group_checkpoint_advance(
                ledger,
                names=["skill-new"],
                context=self.group_checkpoint_context(
                    canonical_rename={"old_name": "skill-old", "new_name": "skill-new"}
                ),
            )

        message = str(raised.exception)
        self.assertIn("另有 1 个 skill", message)
        self.assertNotIn("删掉 commit", message)

    def test_group_checkpoint_merge_retirement_counts_retired_name_and_skips_repo_match(self) -> None:
        ledger = self.group_checkpoint_ledger(skills=["skill-old", "skill-new"])
        retirement = {"retired": {"name": "skill-old"}}

        LEDGER.validate_group_checkpoint_advance(
            ledger,
            names=["skill-new"],
            context=self.group_checkpoint_context(merge_retirement=retirement),
        )
        LEDGER.validate_group_checkpoint_advance(
            self.group_checkpoint_ledger(skills=["skill-a", "skill-b"]),
            names=["skill-a"],
            context=self.group_checkpoint_context(
                source_id="successor-source",
                merge_retirement=retirement,
            ),
        )

    def test_group_checkpoint_allows_same_commit_by_hash_prefix(self) -> None:
        ledger = self.group_checkpoint_ledger(
            skills=["skill-a", "skill-b"],
            checkpoint="49dd158d10",
        )

        LEDGER.validate_group_checkpoint_advance(
            ledger,
            names=["skill-a"],
            context=self.group_checkpoint_context(
                commit="49dd158d1076134a641b33efb035946536778336"
            ),
        )

    def test_group_checkpoint_allows_declared_whole_group_check(self) -> None:
        ledger = self.group_checkpoint_ledger(skills=["skill-a", "skill-b"])

        LEDGER.validate_group_checkpoint_advance(
            ledger,
            names=["skill-a"],
            context=self.group_checkpoint_context(advance_group_checkpoint=True),
        )

    def test_group_checkpoint_allows_transaction_covering_whole_group(self) -> None:
        ledger = self.group_checkpoint_ledger(
            skills=["skill-a", "Skill-B", "skill-a/vendor/bundled"]
        )

        LEDGER.validate_group_checkpoint_advance(
            ledger,
            names=["skill-a", "skill-b"],
            context=self.group_checkpoint_context(),
        )

    def test_group_checkpoint_ignores_missing_commit_and_new_group(self) -> None:
        ledger = self.group_checkpoint_ledger(skills=["skill-a", "skill-b"])

        LEDGER.validate_group_checkpoint_advance(
            ledger,
            names=["skill-a"],
            context=self.group_checkpoint_context(commit=None),
        )
        LEDGER.validate_group_checkpoint_advance(
            ledger,
            names=["skill-a"],
            context=self.group_checkpoint_context(
                source_id="other-source",
                repo="https://github.com/example/other-source",
            ),
        )

    def test_group_checkpoint_matches_group_by_repo_and_revisions_exactly(self) -> None:
        ledger = self.group_checkpoint_ledger(skills=["skill-a", "skill-b"], checkpoint="v1.7")

        with self.assertRaisesRegex(BASE.InstallError, "advance_group_checkpoint"):
            LEDGER.validate_group_checkpoint_advance(
                ledger,
                names=["skill-a"],
                context=self.group_checkpoint_context(source_id="renamed-id", commit="v1.7.2"),
            )

    def test_source_context_validates_advance_group_checkpoint(self) -> None:
        candidate = self.write_candidate("test-skill-wrapper", "组级检查点字段夹具")
        manifest = self.write_manifest("test-skill-wrapper", "update")
        args = WRAPPER.build_parser().parse_args(self.wrapper_args(candidate, manifest))
        specs = [("test-skill-wrapper", str(candidate))]

        def decision(**source: object) -> dict[str, object]:
            return {"decision": "update", "source": {"id": "shared-source", "ref": "main", **source}}

        context = DECISION.source_context(
            args,
            decision(commit="2222222222222222", advance_group_checkpoint=True),
            specs,
        )
        self.assertTrue(context["advance_group_checkpoint"])
        self.assertFalse(DECISION.source_context(args, decision(), specs)["advance_group_checkpoint"])
        with self.assertRaisesRegex(BASE.InstallError, "布尔值"):
            DECISION.source_context(
                args,
                decision(commit="2222222222222222", advance_group_checkpoint="yes"),
                specs,
            )
        with self.assertRaisesRegex(BASE.InstallError, "需要同时提供"):
            DECISION.source_context(args, decision(advance_group_checkpoint=True), specs)

    def write_group_checkpoint_fixture(self, *, advance: bool) -> tuple[Path, Path]:
        candidate = self.write_candidate("test-skill-wrapper", "组级检查点夹具")
        manifest = self.write_manifest("test-skill-wrapper", "install")
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        payload["source"]["commit"] = "2222222222222222"
        if advance:
            payload["source"]["advance_group_checkpoint"] = True
        manifest.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        ledger["sources"].append(
            {
                "id": "local-test",
                "type": "local-candidate",
                "repo": "local candidate",
                "ref": "local",
                "skills": ["sibling-skill"],
                "last_checked_commit": "1111111111",
                "catalog_ref": "1111111111",
            }
        )
        self.ledger.write_text(json.dumps(ledger, ensure_ascii=False), encoding="utf-8")
        return candidate, manifest

    def test_dry_run_rejects_partial_group_checkpoint_before_evidence(self) -> None:
        candidate, manifest = self.write_group_checkpoint_fixture(advance=False)
        ledger_before = self.ledger.read_bytes()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest) + ["--dry-run"])

        self.assertEqual(code, 2, stderr.getvalue())
        self.assertIn("advance_group_checkpoint", stderr.getvalue())
        self.assertIn("sibling-skill", stderr.getvalue())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(list((self.temp / "evidence").glob("install-*")), [])

    def test_dry_run_accepts_declared_group_checkpoint_advance(self) -> None:
        candidate, manifest = self.write_group_checkpoint_fixture(advance=True)
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(self.wrapper_args(candidate, manifest) + ["--dry-run"])

        self.assertEqual(code, 0, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
