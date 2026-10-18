#!/usr/bin/env python3
"""Canonical rename tests for the guarded skill install: identity binding, races and rollback."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import shutil
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
    LEDGER,
    PAYLOAD,
    TREE,
    WRAPPER,
    GuardedInstallTestCase,
)


class SkillInstallGuardedCanonicalRenameTests(GuardedInstallTestCase):
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
        manifest_payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(
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
        self.assertEqual(TREE.tree_content_seal(old_skill), old_seal)
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)
        transaction = max((self.temp / "evidence").glob("install-*/manifest.json"))
        result = json.loads(transaction.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "rolled-back")

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

    def test_canonical_rename_rejects_old_active_source_outside_predecessor_identity(
        self,
    ) -> None:
        state = self.prepare_canonical_rename()
        old_source = Path(state["old_skill"]) / "SOURCE.md"
        old_text = old_source.read_text(encoding="utf-8")
        drifted_text = old_text.replace(
            "Commit or revision: `0123456789abcdef`",
            "Commit or revision: `fedcba9876543210`",
        )
        self.assertNotEqual(drifted_text, old_text)
        old_source.write_text(drifted_text, encoding="utf-8")
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.extend(["--update", "--dry-run"])
        stderr = io.StringIO()

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2, stderr.getvalue())
        self.assertIn(
            "旧 active SOURCE.md 与 canonical predecessor source identity 不一致",
            stderr.getvalue(),
        )
        self.assertTrue(Path(state["old_skill"]).is_dir())
        self.assertFalse((self.active / str(state["new_name"])).exists())
        self.assertEqual(self.ledger.read_bytes(), ledger_before)
        self.assertEqual(Path(state["catalog"]).read_bytes(), catalog_before)

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
                PAYLOAD,
                "read_skill_name",
                wraps=PAYLOAD.read_skill_name,
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
                PAYLOAD,
                "read_skill_name",
                wraps=PAYLOAD.read_skill_name,
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
        old_seal = TREE.tree_content_seal(old_skill)
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
        self.assertEqual(TREE.tree_content_seal(old_skill), old_seal)
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
        old_seal = TREE.tree_content_seal(old_skill)
        new_skill = self.active / str(state["new_name"])
        sentinel = new_skill / "sentinel.txt"
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_retire = ACTIVATION.retire_directories

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
                ACTIVATION,
                "retire_directories",
                side_effect=retire_then_create_successor,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertEqual(TREE.tree_content_seal(old_skill), old_seal)
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
        old_seal = TREE.tree_content_seal(old_skill)
        new_skill = self.active / str(state["new_name"])
        sentinel = new_skill / "sentinel.txt"
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_rename = os.rename
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
                os,
                "rename",
                side_effect=create_successor_at_atomic_rename,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertTrue(injected)
        self.assertEqual(TREE.tree_content_seal(old_skill), old_seal)
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
        old_seal = TREE.tree_content_seal(old_skill)
        new_name = str(state["new_name"])
        new_skill = self.active / new_name
        displaced_payload = self.temp / "displaced-transaction-payload"
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        original_rename = os.rename
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
                os,
                "rename",
                side_effect=replace_after_atomic_rename,
            ),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = WRAPPER.main(args)

        self.assertEqual(code, 2)
        self.assertTrue(injected)
        self.assertEqual(TREE.tree_content_seal(old_skill), old_seal)
        self.assertTrue(new_skill.is_dir())
        self.assertTrue(displaced_payload.is_dir())
        self.assertEqual(
            TREE.tree_content_seal(new_skill),
            TREE.tree_content_seal(displaced_payload),
        )
        self.assertNotEqual(
            TREE.directory_identity(new_skill, label="竞争 successor"),
            TREE.directory_identity(displaced_payload, label="被移走事务 payload"),
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
                manifest_payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(
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
                    payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(
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
        old_seal = TREE.tree_content_seal(Path(state["old_skill"]))
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
                ACTIVATION,
                "activate_directories",
                side_effect=BASE.InstallError("injected rename activation failure"),
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
        old_seal = TREE.tree_content_seal(Path(state["old_skill"]))
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")
        original_update_ledger = LEDGER.update_ledger
        update_calls = 0

        def fail_live_ledger_update(*arguments: object, **keywords: object) -> dict[str, object]:
            nonlocal update_calls
            update_calls += 1
            if update_calls == 2:
                raise BASE.InstallError("injected rename ledger failure")
            return original_update_ledger(*arguments, **keywords)

        with (
            mock.patch.object(LEDGER, "update_ledger", side_effect=fail_live_ledger_update),
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
        old_seal = TREE.tree_content_seal(Path(state["old_skill"]))
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
        old_seal = TREE.tree_content_seal(Path(state["old_skill"]))
        ledger_before = self.ledger.read_bytes()
        catalog_before = Path(state["catalog"]).read_bytes()
        args = self.wrapper_args(
            Path(state["candidate"]),
            Path(state["manifest"]),
            name=str(state["new_name"]),
        )
        args.append("--update")
        original_run_closure = CLOSURE.run_closure
        closure_calls = 0

        def fail_post_closure(*arguments: object, **keywords: object) -> dict[str, object]:
            nonlocal closure_calls
            closure_calls += 1
            # baseline-resource-closure is call 1; post-resource-closure is call 3.
            if closure_calls == 3:
                raise BASE.InstallError("injected rename closure failure")
            return original_run_closure(*arguments, **keywords)

        with (
            mock.patch.object(CLOSURE, "run_closure", side_effect=fail_post_closure),
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


if __name__ == "__main__":
    unittest.main()
