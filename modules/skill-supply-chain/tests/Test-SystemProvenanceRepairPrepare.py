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
from unittest import mock


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
        next_steps = "\n".join(prepared["next"])
        self.assertIn(r"pwsh -NoProfile -File D:\Codex\.codex\scripts\install-skill-guarded.ps1", next_steps)
        self.assertNotIn("install-skill-guarded.cmd", next_steps)
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

    def add_statusline(self, state: dict[str, object]) -> tuple[str, bytes]:
        root = Path(state["system_root"]) / "create-statusline"
        (root / "agents").mkdir(parents=True)
        (root / "agents" / "openai.yaml").write_bytes(b"policy:\n  allow_implicit_invocation: false\n")
        source = "---\nname: create-statusline\ndescription: Build a custom statusline for the Codex CLI.\n---\n\n# Statusline\n"
        (root / "SKILL.md").write_bytes(source.encode("utf-8"))
        translated = source.replace("Build a custom statusline for the Codex CLI.", "为 Codex CLI 创建自定义状态栏。")
        return "create-statusline", translated.encode("utf-8")

    def test_bootstrap_repairs_statusline_and_migrates_old_ledger(self) -> None:
        state = self.prepare_system_display_bootstrap()
        self.give_skill_creator_the_official_validator(state)
        translated = self.restore_official_display(state)
        name, translated_skill = self.add_statusline(state)
        translated[name] = {"SKILL.md": translated_skill}
        root = Path(state["system_root"])
        trees = {n: REPAIR.system_skill_integrity(root / n)["tree_sha256"] for n in (name, *state["names"])}
        self.enterContext(mock.patch.object(PREPARE.REPAIR, "REVIEWED_DAEMON_TREES", trees))
        self.enterContext(mock.patch.object(PREPARE.REPAIR, "REVIEWED_DAEMON_MARKER", BASE.sha256_file(Path(state["marker"]))))
        code, status = self.run_status(state)
        self.assertEqual(code, 1, status)
        self.assertEqual(status["display"].get(name), "official")
        evidence = self.temp / "six-skills"
        code, stdout, stderr = self.run_prepare(state, "preserve-official", "--evidence", str(evidence))
        self.assertEqual(code, 0, stderr)
        self.assertIn(name, json.loads(stdout)["preserved"])
        self.write_display(state, translated)
        plan_path = self.temp / "prepared-display-plan.json"
        code, _, stderr = self.run_prepare(
            state, "plan", "--evidence", str(evidence), "--out", str(plan_path), "--stability-interval", "0"
        )
        self.assertEqual(code, 0, stderr)
        args = self.system_provenance_repair_args({**state, "plan": plan_path})
        original_plan = plan_path.read_bytes()
        plan = json.loads(original_plan)
        plan["payload_release"]["asset_sha256"] = "0" * 64
        plan_path.write_text(json.dumps(plan), encoding="utf-8")
        code, _, stderr = self.run_wrapper([*args, "--dry-run"])
        self.assertEqual(code, 2)
        self.assertIn("payload_release", stderr)
        plan_path.write_bytes(original_plan)

        before = {path: path.read_bytes() for path in (
            self.ledger, Path(state["catalog"]), root / name / "SKILL.md", root / "review-agent" / "SKILL.md"
        )}
        broken_generator = self.temp / "fail-catalog.py"
        broken_generator.write_text("raise SystemExit(23)\n", encoding="utf-8")
        code, _, stderr = self.run_wrapper(self.system_provenance_repair_args({**state, "plan": plan_path}, generator=broken_generator))
        self.assertEqual(code, 2)
        self.assertIn("rolled-back", stderr)
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.assertTrue(all(not (root / n / "SOURCE.md").exists() for n in trees))

        statusline = root / name / "SKILL.md"
        external = before[statusline] + b"\nthird-party write\n"
        optional_bytes = PREPARE.REPAIR._optional_bytes
        injected = False

        def interleave(path):
            nonlocal injected
            if not injected and path == statusline and any(path.parent.glob(".SKILL.md.*.tmp")):
                injected = True
                path.write_bytes(external)
            return optional_bytes(path)

        with mock.patch.object(PREPARE.REPAIR, "_optional_bytes", side_effect=interleave):
            code, _, stderr = self.run_wrapper(args)
        self.assertTrue(injected)
        self.assertEqual(code, 2)
        self.assertIn("rollback-failed", stderr)
        self.assertEqual(statusline.read_bytes(), external)
        self.assertEqual(self.ledger.read_bytes(), before[self.ledger])
        self.assertTrue(all(not (root / n / "SOURCE.md").exists() for n in trees))
        statusline.write_bytes(before[statusline])

        code, stdout, stderr = self.run_wrapper([*args, "--dry-run"])
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["targets"], list(trees))
        code, stdout, stderr = self.run_wrapper(args)
        self.assertEqual(code, 0, stderr)
        self.assertEqual(len(json.loads(stdout)["backups"]), 10)
        group = json.loads(self.ledger.read_text(encoding="utf-8"))["sources"][0]
        self.assertEqual(group["skills"], [f".system/{n}" for n in trees])
        specs = group["system_provenance"]["skills"]
        self.assertEqual(specs[0]["overlay"]["base_overlay"]["kind"], "create-statusline-invocation-parity")
        root = Path(state["system_root"])
        for skill_name in (name, "review-agent"):
            self.assertIn(b"disable-model-invocation: true", (root / skill_name / "SKILL.md").read_bytes())
        self.assertEqual(group["system_provenance"]["payload_release"], REPAIR.REVIEWED_DAEMON_RELEASE)
        self.assertEqual(self.run_status(state)[1]["state"], "needs-skill-creator-overlay")
        self.bind_skill_creator_overlay(state, evidence / "creator")
        release_name = REPAIR.REVIEWED_DAEMON_RELEASE["tag"].encode("utf-8")
        creator_source = root / "skill-creator" / "SOURCE.md"
        creator_history = creator_source.read_bytes()
        self.assertIn(release_name, creator_history.rsplit(b"---\n", 1)[1])
        self.reconcile_a_later_menu_replay(state, plan_path)
        self.assertTrue(creator_source.read_bytes().startswith(creator_history))
        self.assertEqual(self.run_status(state)[1]["state"], "healthy")
        after = json.loads(self.ledger.read_text(encoding="utf-8"))["sources"][0]["system_provenance"]
        self.assertEqual(after["payload_release"], REPAIR.REVIEWED_DAEMON_RELEASE)
        self.assertIn(release_name, creator_source.read_bytes().rsplit(b"---\n", 1)[1])

    def test_legacy_plan_rejects_partial_coverage_of_active_system(self) -> None:
        state = self.prepare_system_provenance_repair()
        self.add_statusline(state)
        code, _, stderr = self.run_wrapper([*self.system_provenance_repair_args(state), "--dry-run"])
        self.assertNotEqual(code, 0)
        self.assertIn("system skill inventory", stderr)

    def test_closure_rule_import_is_registered_during_module_execution(self) -> None:
        closure = self.temp / "closure-with-dataclass.py"
        closure.write_text(
            "from __future__ import annotations\nfrom dataclasses import dataclass\nimport sys\n"
            "assert __name__ in sys.modules\n@dataclass\nclass Value:\n    text: str\n"
            "def chinese_dominant(text):\n    return Value(text).text == '中文'\n",
            encoding="utf-8",
        )
        self.assertTrue(PREPARE._load_chinese_dominant(closure)("中文"))

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
        self.assertIn(r"pwsh -NoProfile -File D:\Codex\.codex\scripts\install-skill-guarded.ps1", steps)
        self.assertNotIn("install-skill-guarded.cmd", steps)

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

    def test_cli_help_names_canonical_ps1_wrapper(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), self.assertRaises(SystemExit) as exited:
            PREPARE.main(["--help"])
        self.assertEqual(exited.exception.code, 0)
        help_text = stdout.getvalue()
        self.assertIn("install-skill-guarded.ps1", help_text)
        self.assertNotIn("install-skill-guarded.cmd", help_text)


if __name__ == "__main__":
    unittest.main()
