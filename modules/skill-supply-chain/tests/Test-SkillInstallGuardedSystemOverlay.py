#!/usr/bin/env python3
"""skill-creator compatibility overlay tests for the guarded skill install."""

from __future__ import annotations

import contextlib
import hashlib
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

from guarded_install_fixtures import ACTIVATION, BASE, REPAIR, SOURCE_RECORD, STAGING, WRAPPER
from guarded_install_system_fixtures import SystemRepairTestCase


class SkillInstallGuardedSystemOverlayTests(SystemRepairTestCase):
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
        current = SOURCE_RECORD.current_source_record(active / "SOURCE.md")
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
            spec["source_before_sha256"] = BASE.sha256_file(root / "SOURCE.md")
            spec["official_integrity"] = previous["official_integrity"]
            spec["effective_integrity"] = REPAIR.system_skill_integrity(root)
            spec["critical_files"] = {relative: BASE.sha256_file(root / relative) for relative in previous["critical_files"]}
            previous_overlay = previous["overlay"]
            spec["overlay"] = {
                "kind": "display-only",
                "baseline_files": baseline,
                "base_overlay": previous_overlay["base_overlay"] if previous_overlay["kind"] == "display-only" else previous_overlay,
            }
        plan["ledger_before_sha256"] = BASE.sha256_file(self.ledger)
        plan["catalog_before_sha256"] = BASE.sha256_file(Path(system_state["catalog"]))
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
        original_stage = STAGING.stage_candidate

        def stage_then_drift(*args: object, **kwargs: object) -> dict[str, object]:
            staged = original_stage(*args, **kwargs)
            (active_skill / "scripts" / "quick_validate.py").write_text(
                "# concurrent mutation\n",
                encoding="utf-8",
            )
            return staged

        stderr = io.StringIO()
        with (
            mock.patch.object(STAGING, "stage_candidate", side_effect=stage_then_drift),
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
        original_activate = ACTIVATION.activate_directories

        def change_source_then_activate(*args: object, **kwargs: object) -> None:
            (active / "SOURCE.md").write_bytes(external_source)
            original_activate(*args, **kwargs)

        stderr = io.StringIO()
        with (
            mock.patch.object(ACTIVATION, "activate_directories", side_effect=change_source_then_activate),
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


if __name__ == "__main__":
    unittest.main()
