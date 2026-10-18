#!/usr/bin/env python3
"""Bundled ``.system`` provenance repair and display reconcile tests for the guarded skill install."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import sys
import unittest
from pathlib import Path


TESTS_ROOT = Path(__file__).resolve().parent
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from guarded_install_fixtures import BASE, REPAIR, WRAPPER
from guarded_install_system_fixtures import SystemRepairTestCase


class SkillInstallGuardedSystemRepairTests(SystemRepairTestCase):
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
                    spec["critical_files"]["agents/openai.yaml"] = BASE.sha256_file(yaml_path)
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


if __name__ == "__main__":
    unittest.main()
