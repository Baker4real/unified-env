#!/usr/bin/env python3
"""prepare_system_provenance_repair.py tests: what it prepares must pass the guarded wrapper."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path


TESTS_ROOT = Path(__file__).resolve().parent
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from guarded_install_fixtures import BASE, IMPLEMENTATION_ROOT, REPAIR, WRAPPER
from guarded_install_system_fixtures import SystemRepairTestCase

PREPARE_PATH = IMPLEMENTATION_ROOT / "prepare_system_provenance_repair.py"
PREPARE_SPEC = importlib.util.spec_from_file_location("prepare_system_provenance_repair", PREPARE_PATH)
if PREPARE_SPEC is None or PREPARE_SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 prepare 工具：{PREPARE_PATH}")
PREPARE = importlib.util.module_from_spec(PREPARE_SPEC)
PREPARE_SPEC.loader.exec_module(PREPARE)


class PrepareSystemProvenanceRepairTests(SystemRepairTestCase):
    def run_prepare(self, state: dict[str, object], command: str, *extra: str) -> tuple[int, str, str]:
        args = [
            command,
            *extra,
            "--active-root",
            str(self.active),
            "--ledger",
            str(self.ledger),
            "--catalog",
            str(state["catalog"]),
            "--system-package-provider",
            str(state["provider"]),
            "--closure-script",
            str(self.closure),
            "--python",
            str(self.interpreter),
        ]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = PREPARE.main(args)
        return code, stdout.getvalue(), stderr.getvalue()

    def run_wrapper(self, args: list[str]) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = WRAPPER.main(args)
        return code, stdout.getvalue(), stderr.getvalue()

    def run_status(self, state: dict[str, object]) -> tuple[int, dict[str, object]]:
        code, stdout, stderr = self.run_prepare(state, "status")
        self.assertNotEqual(code, 2, stderr)
        return code, json.loads(stdout)

    def restore_official_display(self, state: dict[str, object]) -> dict[str, dict[str, bytes]]:
        """Put the official menu text back, as a refresh leaves it; return the translated bytes."""
        root = Path(state["system_root"])
        translated = {
            name: {relative: (root / name / relative).read_bytes() for relative in files}
            for name, files in state["official_texts"].items()
        }
        for name, files in state["official_texts"].items():
            for relative, text in files.items():
                (root / name / relative).write_bytes(text.encode("utf-8"))
        return translated

    def write_display(self, state: dict[str, object], display: dict[str, dict[str, bytes]]) -> None:
        root = Path(state["system_root"])
        for name, files in display.items():
            for relative, data in files.items():
                (root / name / relative).write_bytes(data)

    def commit_skills_root(self, message: str) -> str:
        """Snapshot the fixture active root the way the skills root backup does: worktree bytes as-is."""

        def git(*args: str) -> str:
            command = ["git", "-C", str(self.active), "-c", "core.autocrlf=false", *args]
            return subprocess.run(command, capture_output=True, text=True, check=True).stdout.strip()

        git("init", "-q")
        git("add", "-A", ".system")
        git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", message)
        return git("rev-parse", "HEAD")

    def give_skill_creator_the_official_validator(self, state: dict[str, object]) -> None:
        """The two official skill-creator files the compatibility overlay patches, in their CRLF shape."""
        root = Path(state["system_root"]) / "skill-creator"
        sentence = "Keep the frontmatter minimal; preserve supported optional fields such as existing `metadata` when appropriate.\r\n"
        texts = state["official_texts"]["skill-creator"]
        texts["SKILL.md"] += sentence
        skill = root / "SKILL.md"
        skill.write_bytes(skill.read_bytes() + sentence.encode("utf-8"))
        scripts = root / "scripts"
        scripts.mkdir(exist_ok=True)
        (scripts / "quick_validate.py").write_bytes(
            (
                "def validate_frontmatter(frontmatter):\r\n"
                '    allowed_properties = {"name", "description", "license", "allowed-tools", "metadata"}\r\n'
                '    if "description" not in frontmatter:\r\n'
                "        return False, \"Missing 'description' in frontmatter\"\r\n"
                "\r\n"
                '    name = frontmatter.get("name", "")\r\n'
                "    return True, name\r\n"
            ).encode("utf-8")
        )

    def plan_and_bind(self, state: dict[str, object], evidence: Path) -> Path:
        plan = self.temp / "prepared-display-plan.json"
        code, _, stderr = self.run_prepare(
            state, "plan", "--evidence", str(evidence), "--out", str(plan), "--stability-interval", "0"
        )
        self.assertEqual(code, 0, stderr)
        code, stdout, stderr = self.run_wrapper(self.system_provenance_repair_args({**state, "plan": plan}))
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "succeeded")
        return plan

    def bind_skill_creator_overlay(self, state: dict[str, object], evidence: Path) -> None:
        code, stdout, stderr = self.run_prepare(state, "skill-creator-overlay", "--evidence", str(evidence))
        self.assertEqual(code, 0, stderr)
        prepared = json.loads(stdout)
        args = self.wrapper_args(Path(prepared["candidate"]), Path(prepared["decision_manifest"]), name="skill-creator")
        code, _, stderr = self.run_wrapper([*args, "--update", "--system-package-provider", str(state["provider"])])
        self.assertEqual(code, 0, stderr)

    def reconcile_a_later_menu_replay(self, state: dict[str, object], bootstrap_plan: Path) -> None:
        """The menu tool rewrites the display again; a display reconcile keeps each record's overlay underneath."""
        root = Path(state["system_root"])
        records = json.loads(self.ledger.read_text(encoding="utf-8"))["sources"][0]["system_provenance"]["skills"]
        plan = json.loads(bootstrap_plan.read_text(encoding="utf-8"))
        plan.pop("official_baseline_source", None)
        plan["mode"] = "atomic-six-skill-display-reconcile"
        for spec, previous in zip(plan["skills"], records):
            skill_root = root / spec["name"]
            baseline = {
                relative: (skill_root / relative).read_bytes().decode("utf-8")
                for relative in ("SKILL.md", "agents/openai.yaml")
            }
            self.write_display(state, {spec["name"]: {
                "SKILL.md": baseline["SKILL.md"].replace("本夹具的中文展示文本", "本夹具重放后的中文展示文本").encode("utf-8"),
                "agents/openai.yaml": baseline["agents/openai.yaml"].replace("中文菜单文本", "新的中文菜单文本").encode("utf-8"),
            }})
            underneath = previous["overlay"]
            if underneath["kind"] == "display-only":
                underneath = underneath["base_overlay"]
            spec.update({
                "source_before_sha256": BASE.sha256_file(skill_root / "SOURCE.md"),
                "effective_integrity": REPAIR.system_skill_integrity(skill_root),
                "critical_files": {
                    relative: BASE.sha256_file(skill_root / relative) for relative in previous["critical_files"]
                },
                "overlay": {"kind": "display-only", "baseline_files": baseline, "base_overlay": underneath},
            })
        plan["ledger_before_sha256"] = BASE.sha256_file(self.ledger)
        plan["catalog_before_sha256"] = BASE.sha256_file(Path(state["catalog"]))
        reconcile = self.temp / "reconcile-plan.json"
        reconcile.write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")
        code, stdout, stderr = self.run_wrapper(self.system_provenance_repair_args({**state, "plan": reconcile}))
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["status"], "succeeded")

    def test_display_bootstrap_binds_the_official_text_preserved_before_the_menu_replay(self) -> None:
        state = self.prepare_system_display_bootstrap()
        translated = self.restore_official_display(state)
        evidence = self.temp / "repair-evidence"

        code, _, stderr = self.run_prepare(state, "preserve-official", "--evidence", str(evidence))
        self.assertEqual(code, 0, stderr)
        self.write_display(state, translated)
        plan = self.plan_and_bind(state, evidence)

        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        for record in ledger["sources"][0]["system_provenance"]["skills"]:
            self.assertEqual(record["official_integrity"], state["official_trees"][record["name"]])
            self.assertEqual(record["overlay"]["kind"], "display-only")
        baseline_source = json.loads(plan.read_text(encoding="utf-8"))["official_baseline_source"]
        self.assertIn("preserve-official", baseline_source)
        root = Path(state["system_root"])
        self.assertIn(baseline_source, (root / "imagegen" / "SOURCE.md").read_text(encoding="utf-8"))

    def test_preserve_official_refuses_a_translated_menu(self) -> None:
        state = self.prepare_system_display_bootstrap()
        evidence = self.temp / "repair-evidence"

        code, _, stderr = self.run_prepare(state, "preserve-official", "--evidence", str(evidence))

        self.assertEqual(code, 2)
        self.assertIn("--from-git", stderr)
        self.assertFalse(evidence.exists())

    def test_preserve_official_from_git_reads_the_snapshot_taken_before_the_menu_replay(self) -> None:
        state = self.prepare_system_display_bootstrap()
        translated = self.restore_official_display(state)
        commit = self.commit_skills_root("auto backup after the refresh")
        self.write_display(state, translated)
        evidence = self.temp / "repair-evidence"

        code, _, stderr = self.run_prepare(state, "preserve-official", "--from-git", commit, "--evidence", str(evidence))
        self.assertEqual(code, 0, stderr)
        plan = self.plan_and_bind(state, evidence)

        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        for record in ledger["sources"][0]["system_provenance"]["skills"]:
            self.assertEqual(record["official_integrity"], state["official_trees"][record["name"]])
        self.assertIn(commit, json.loads(plan.read_text(encoding="utf-8"))["official_baseline_source"])

    def test_status_walks_a_refresh_to_the_skill_creator_overlay(self) -> None:
        state = self.prepare_system_display_bootstrap(include_creator_scripts=True)
        translated = self.restore_official_display(state)

        code, report = self.run_status(state)
        self.assertEqual((code, report["state"]), (1, "needs-bootstrap"))
        steps = "\n".join(report["next"])
        self.assertIn("preserve-official --evidence", steps)
        self.assertIn("--system-only", steps)

        evidence = self.temp / "repair-evidence"
        code, _, stderr = self.run_prepare(state, "preserve-official", "--evidence", str(evidence))
        self.assertEqual(code, 0, stderr)
        self.write_display(state, translated)
        self.plan_and_bind(state, evidence)

        code, report = self.run_status(state)
        self.assertEqual((code, report["state"]), (1, "needs-skill-creator-overlay"), report)
        self.assertIn("skill-creator-overlay --evidence", "\n".join(report["next"]))

    def test_skill_creator_overlay_candidate_passes_the_wrapper_and_status_turns_healthy(self) -> None:
        state = self.prepare_system_display_bootstrap()
        self.give_skill_creator_the_official_validator(state)
        translated = self.restore_official_display(state)
        evidence = self.temp / "repair-evidence"
        code, _, stderr = self.run_prepare(state, "preserve-official", "--evidence", str(evidence))
        self.assertEqual(code, 0, stderr)
        self.write_display(state, translated)
        self.plan_and_bind(state, evidence)

        self.bind_skill_creator_overlay(state, evidence)

        scripts =Path(state["system_root"]) / "skill-creator" / "scripts"
        self.assertIn(b'        "disable-model-invocation",\r\n', (scripts / "quick_validate.py").read_bytes())
        self.assertIn(b"def test_accepts_codex_invocation_frontmatter", (scripts / "test_quick_validate.py").read_bytes())
        code, report = self.run_status(state)
        self.assertEqual((code, report["state"]), (0, "healthy"), report)

    def test_status_stays_healthy_after_a_menu_reconcile_wraps_the_skill_creator_overlay(self) -> None:
        state = self.prepare_system_display_bootstrap()
        self.give_skill_creator_the_official_validator(state)
        translated = self.restore_official_display(state)
        evidence = self.temp / "repair-evidence"
        code, _, stderr = self.run_prepare(state, "preserve-official", "--evidence", str(evidence))
        self.assertEqual(code, 0, stderr)
        self.write_display(state, translated)
        plan = self.plan_and_bind(state, evidence)
        self.bind_skill_creator_overlay(state, evidence)

        self.reconcile_a_later_menu_replay(state, plan)

        code, report = self.run_status(state)
        self.assertEqual((code, report["state"]), (0, "healthy"), report)
        code, _, stderr = self.run_prepare(state, "skill-creator-overlay", "--evidence", str(self.temp / "again"))
        self.assertEqual(code, 2)
        self.assertIn("已绑定兼容 overlay", stderr)


if __name__ == "__main__":
    unittest.main()
