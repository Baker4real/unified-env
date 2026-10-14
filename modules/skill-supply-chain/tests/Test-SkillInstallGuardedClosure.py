#!/usr/bin/env python3
"""Resource closure gate tests: baseline diff, target scoping and catalog checks for install and repair."""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


TESTS_ROOT = Path(__file__).resolve().parent
if str(TESTS_ROOT) not in sys.path:
    sys.path.insert(0, str(TESTS_ROOT))

from guarded_install_fixtures import BASE, CLOSURE, REPAIR


def closure_finding(
    kind: str, skill: str, *, line: int = 1, resolved: str = "x"
) -> dict[str, object]:
    return {
        "kind": kind,
        "skill": skill,
        "source": "SKILL.md",
        "line": line,
        "reference": "description",
        "resolved": resolved,
    }


def closure_payload(*findings: dict[str, object]) -> dict[str, object]:
    return {
        "summary": {"finding_count": len(findings)},
        "findings": [dict(item) for item in findings],
    }


def preexisting_closure_catalog(
    *findings: dict[str, object], targets: list[str]
) -> dict[str, object]:
    return {
        "artifacts": [],
        "checks": {
            "resource_closure": {
                "status": "preexisting-findings",
                "finding_count": len(findings),
                "gate": {
                    "targets": targets,
                    "new_findings": [],
                    "target_findings": [],
                    "preexisting_findings": list(findings),
                },
            }
        },
    }


class ScopedClosureGateTests(unittest.TestCase):
    def setUp(self) -> None:
        temp_parent = Path(r"D:\Codex\tmp")
        temp_parent.mkdir(parents=True, exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(prefix="skill-closure-gate-test-", dir=temp_parent))
        self.addCleanup(shutil.rmtree, self.temp)

    def evaluate(
        self,
        *,
        baseline: dict[str, object] | None,
        post: dict[str, object],
        targets: list[str],
    ) -> tuple[dict[str, object], str]:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            gate = CLOSURE.evaluate_closure_gate(
                payload=post,
                baseline=baseline,
                targets=targets,
                label="post-resource-closure",
            )
        return gate, stderr.getvalue()

    def fake_closure(self, *, stdout: str, exit_code: int) -> Path:
        script = self.temp / "fake_closure.py"
        script.write_text(
            f"import sys\nsys.stdout.write({stdout!r})\nraise SystemExit({exit_code})\n",
            encoding="utf-8",
        )
        return script

    def run_fake_closure(self, *, stdout: str, exit_code: int) -> dict[str, object]:
        return CLOSURE.run_closure(
            root=self.temp,
            closure_script=self.fake_closure(stdout=stdout, exit_code=exit_code),
            interpreter=Path(sys.executable).resolve(),
            evidence_dir=self.temp,
            label="baseline-resource-closure",
        )

    def test_preexisting_non_target_findings_are_reported_without_blocking(self) -> None:
        other = closure_finding("non-chinese-display", "animate")
        system = closure_finding("missing-source", ".system/imagegen")
        gate, stderr = self.evaluate(
            baseline=closure_payload(other, system),
            # line/resolved drift must not turn an existing finding into a new one.
            post=closure_payload(
                closure_finding("non-chinese-display", "animate", line=9, resolved="y"),
                system,
            ),
            targets=[".system/skill-creator"],
        )

        self.assertEqual(gate["status"], "pass")
        self.assertEqual(gate["new_findings"], [])
        self.assertEqual(gate["target_findings"], [])
        self.assertEqual(len(gate["preexisting_findings"]), 2)
        self.assertIn("既有非 target closure finding 2 条", stderr)

    def test_new_finding_target_finding_or_missing_baseline_blocks(self) -> None:
        other = closure_finding("non-chinese-display", "animate")
        target = closure_finding("non-chinese-display", "new-skill")
        cases = {
            "new-non-target": (
                closure_payload(other),
                closure_payload(other, closure_finding("stale-ledger", "unrelated")),
                "新增 finding 1 条，target finding 0 条",
            ),
            "preexisting-target": (
                closure_payload(target),
                closure_payload(target),
                "新增 finding 0 条，target finding 1 条",
            ),
            "missing-baseline": (
                None,
                closure_payload(closure_finding("missing-source", "other")),
                "新增 finding 1 条，target finding 0 条",
            ),
        }
        for case, (baseline, post, message) in cases.items():
            with self.subTest(case=case):
                with self.assertRaisesRegex(BASE.InstallError, message):
                    self.evaluate(baseline=baseline, post=post, targets=["new-skill"])

    def test_target_match_is_exact_or_nested(self) -> None:
        sibling = closure_finding("missing-source", "new-skill-extra")
        gate, _ = self.evaluate(
            baseline=closure_payload(sibling),
            post=closure_payload(sibling),
            targets=["new-skill"],
        )
        self.assertEqual(gate["preexisting_findings"], [sibling])

        nested = closure_finding("missing-resource", "new-skill/sub")
        with self.assertRaisesRegex(BASE.InstallError, "target finding 1 条"):
            self.evaluate(
                baseline=closure_payload(nested),
                post=closure_payload(nested),
                targets=["new-skill"],
            )

    def test_rename_and_retirement_names_are_targets(self) -> None:
        self.assertEqual(
            CLOSURE.transaction_closure_targets(
                ledger_names=["new-orchestration"],
                rename={"old_name": "old-orchestration"},
                merge_retirement={"retired": {"name": "retired-bridge"}},
            ),
            ["new-orchestration", "old-orchestration", "retired-bridge"],
        )

    def test_run_closure_returns_strict_findings(self) -> None:
        payload = closure_payload(closure_finding("non-chinese-display", "animate"))

        result = self.run_fake_closure(stdout=json.dumps(payload), exit_code=1)

        self.assertEqual(result["findings"], payload["findings"])

    def test_run_closure_rejects_crash_or_inconsistent_output(self) -> None:
        cases = (
            ("not json", 1, "未返回合法 JSON"),
            (json.dumps(closure_payload()), 2, "异常退出，退出码 2"),
            (json.dumps({"summary": {"finding_count": 0}}), 0, "缺少 summary 或 findings"),
            (json.dumps(closure_payload()), 1, "退出码 1 与 finding 数量 0 不一致"),
        )
        for stdout, exit_code, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(BASE.InstallError, message):
                    self.run_fake_closure(stdout=stdout, exit_code=exit_code)

    def test_install_catalog_verification_rejects_preexisting_target_finding(self) -> None:
        catalog_path = self.temp / "catalog.json"
        catalog_path.write_text(
            json.dumps(
                preexisting_closure_catalog(
                    closure_finding("non-chinese-display", "new-skill"),
                    targets=["new-skill"],
                )
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            BASE.InstallError, "资源闭包检查不可接受：.*落在 target 上"
        ):
            CLOSURE.verify_catalog(
                catalog_path=catalog_path,
                active_root=self.temp,
                names=["new-skill"],
                bundled_proofs=(),
            )

    def test_system_repair_targets_are_bundled_system_skills(self) -> None:
        self.assertEqual(
            REPAIR.system_closure_targets(),
            [
                ".system/imagegen",
                ".system/openai-docs",
                ".system/review-agent",
                ".system/skill-creator",
                ".system/skill-installer",
            ],
        )

    def test_system_repair_gate_allows_only_preexisting_non_system_findings(self) -> None:
        others = [
            closure_finding("non-chinese-display", name) for name in ("animate", "apple-design")
        ]
        residual = closure_finding("missing-source", ".system/imagegen")
        gate = REPAIR.evaluate_system_closure_gate(
            payload=closure_payload(*others),
            baseline=closure_payload(residual, *others),
            targets=REPAIR.system_closure_targets(),
            label="post-resource-closure",
        )
        self.assertEqual(gate["status"], "pass")
        self.assertEqual(gate["preexisting_findings"], others)

        cases = {
            "residual-target": (
                closure_payload(residual),
                closure_payload(residual),
                "新增 finding 0 条，target finding 1 条",
            ),
            "new-non-target": (
                closure_payload(),
                closure_payload(closure_finding("stale-ledger", "animate")),
                "新增 finding 1 条，target finding 0 条",
            ),
        }
        for case, (baseline, post, message) in cases.items():
            with self.subTest(case=case):
                with self.assertRaisesRegex(REPAIR.SystemProvenanceRepairError, message):
                    REPAIR.evaluate_system_closure_gate(
                        payload=post,
                        baseline=baseline,
                        targets=REPAIR.system_closure_targets(),
                        label="post-resource-closure",
                    )

    def test_system_repair_strict_closure_returns_findings_and_fails_closed(self) -> None:
        def run(stdout: str, exit_code: int) -> dict[str, object]:
            return REPAIR._run_strict_closure(
                interpreter=Path(sys.executable).resolve(),
                closure_script=self.fake_closure(stdout=stdout, exit_code=exit_code),
                active_root=self.temp,
                evidence_dir=self.temp,
                label="post-resource-closure",
            )

        payload = closure_payload(closure_finding("non-chinese-display", "animate"))
        self.assertEqual(run(json.dumps(payload), 1)["findings"], payload["findings"])
        cases = (
            ("nope", 1, "未返回合法 JSON"),
            (json.dumps(closure_payload()), 3, "异常退出，退出码 3"),
        )
        for stdout, exit_code, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(REPAIR.SystemProvenanceRepairError, message):
                    run(stdout, exit_code)

    def test_system_repair_catalog_verification_scopes_preexisting_findings(self) -> None:
        catalog_path = self.temp / "catalog.json"
        other = closure_finding("non-chinese-display", "animate")
        catalog_path.write_text(
            json.dumps(
                preexisting_closure_catalog(other, targets=REPAIR.system_closure_targets())
            ),
            encoding="utf-8",
        )
        verified = REPAIR._verify_catalog(
            catalog_path=catalog_path,
            active_root=self.temp,
            plan={"skills": []},
            baseline_findings=[other],
        )
        self.assertEqual(verified["resource_closure"]["preexisting_findings"], [other])

        catalog_path.write_text(
            json.dumps(
                preexisting_closure_catalog(
                    closure_finding("missing-source", ".system/imagegen"),
                    targets=REPAIR.system_closure_targets(),
                )
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            REPAIR.SystemProvenanceRepairError, "资源闭包检查不可接受：.*落在 target 上"
        ):
            REPAIR._verify_catalog(
                catalog_path=catalog_path,
                active_root=self.temp,
                plan={"skills": []},
            )


if __name__ == "__main__":
    unittest.main()
