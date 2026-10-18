#!/usr/bin/env python3
"""Merge retirement tests for the guarded skill install: retired coverage, drift and rollback."""

from __future__ import annotations

import contextlib
import io
import json
import sys
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
    PAYLOAD,
    RETIREMENT,
    TREE,
    WRAPPER,
    GuardedInstallTestCase,
)


class SkillInstallGuardedMergeRetirementTests(GuardedInstallTestCase):
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
            skill_hash = BASE.sha256_file(root / "SKILL.md")
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
        candidate_sha256 = BASE.sha256_file(candidate / "SKILL.md")
        other_survivor_sha256 = BASE.sha256_file(other_survivor / "SKILL.md")
        retired_sha256 = BASE.sha256_file(retired_active / "SKILL.md")
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
                "tree_seal": TREE.tree_content_seal(retired_active),
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
        payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
        manifest.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"sentinel":"before"}\n')
        return {
            "target_name": target_name,
            "target_active": target_active,
            "target_before_seal": TREE.tree_content_seal(target_active),
            "other_survivor_name": other_survivor_name,
            "other_survivor": other_survivor,
            "retired_name": retired_name,
            "retired_active": retired_active,
            "retired_before_seal": TREE.tree_content_seal(retired_active),
            "retired_source_id": retired_source_id,
            "candidate": candidate,
            "candidate_sha256": candidate_sha256,
            "manifest": manifest,
            "catalog": catalog,
        }

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
        original_retire = ACTIVATION.retire_directories

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
                ACTIVATION,
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
            TREE.tree_content_seal(Path(state["target_active"])),
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
            TREE.tree_content_seal(Path(state["target_active"])),
            state["target_before_seal"],
        )
        self.assertEqual(
            TREE.tree_content_seal(Path(state["retired_active"])),
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
            BASE.sha256_file(Path(state["target_active"]) / "SKILL.md"),
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
            BASE.InstallError,
            "ledger deleted 记录不唯一或不完整",
        ):
            RETIREMENT.verify_merge_retirement_postcondition(
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
            BASE.InstallError,
            "source.deleted_skills 记录不唯一或不完整",
        ):
            RETIREMENT.verify_merge_retirement_postcondition(
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
        original_run_closure = CLOSURE.run_closure
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
                CLOSURE,
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
            TREE.tree_content_seal(Path(state["target_active"])),
            state["target_before_seal"],
        )
        self.assertEqual(
            TREE.tree_content_seal(Path(state["retired_active"])),
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
            TREE.tree_content_seal(Path(state["target_active"])),
            state["target_before_seal"],
        )
        self.assertEqual(
            TREE.tree_content_seal(Path(state["retired_active"])),
            state["retired_before_seal"],
        )
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")


if __name__ == "__main__":
    unittest.main()
