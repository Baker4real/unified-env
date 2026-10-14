"""Resource closure runs, the scoped closure gate and catalog verification.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Sequence

from generate_skill_catalog import (
    CLOSURE_FINDING_KEY_FIELDS,
    CatalogError,
    classify_closure_findings,
    verify_catalog_closure_check,
)
import install_skill_guarded_base as _base
from install_skill_guarded_base import InstallError
from install_skill_guarded_bundled import BundledSkillProof


def run_closure(
    *,
    root: Path,
    closure_script: Path,
    interpreter: Path,
    evidence_dir: Path,
    label: str,
) -> dict[str, Any]:
    """Run strict closure and return a structurally validated JSON payload.

    Exit 0 (clean) and 1 (strict findings) are normal outcomes; findings are
    judged by ``evaluate_closure_gate``.  Any other exit code, invalid JSON or
    an inconsistent payload is a hard failure.
    """
    result = _base.run_process(
        [
            str(interpreter),
            str(closure_script),
            "--root",
            str(root),
            "--strict",
            "--format",
            "json",
        ],
        evidence_dir=evidence_dir,
        label=label,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise InstallError(
            f"{label} 异常退出，退出码 {result.returncode}；详见 {evidence_dir}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise InstallError(f"{label} 未返回合法 JSON：{exc}") from exc
    summary = payload.get("summary") if isinstance(payload, dict) else None
    findings = payload.get("findings") if isinstance(payload, dict) else None
    if not isinstance(summary, dict) or not isinstance(findings, list):
        raise InstallError(f"{label} 结果缺少 summary 或 findings")
    if summary.get("finding_count") != len(findings):
        raise InstallError(f"{label} finding_count 与 findings 数量不一致")
    for finding in findings:
        if not isinstance(finding, dict) or any(
            not isinstance(finding.get(field), str) for field in CLOSURE_FINDING_KEY_FIELDS
        ):
            raise InstallError(f"{label} finding 结构无效：{finding!r}")
    if (result.returncode == 0) != (not findings):
        raise InstallError(
            f"{label} 退出码 {result.returncode} 与 finding 数量 {len(findings)} 不一致"
        )
    return payload


def evaluate_closure_gate(
    *,
    payload: dict[str, Any],
    baseline: dict[str, Any] | None,
    targets: Sequence[str],
    label: str,
) -> dict[str, Any]:
    """Baseline-diff + target-scoped closure gate.

    Blocks on findings absent from the pre-transaction baseline and on every
    finding attributed to a transaction target (pre-existing or not).
    Pre-existing findings outside the targets are reported, not blocking.
    ``baseline=None`` means no baseline exists, so every finding is new.
    """
    gate = {
        "label": label,
        **classify_closure_findings(
            payload["findings"],
            baseline_findings=None if baseline is None else baseline["findings"],
            targets=targets,
        ),
    }
    new_findings = gate["new_findings"]
    target_findings = gate["target_findings"]
    preexisting_findings = gate["preexisting_findings"]
    if gate["status"] != "pass":
        raise InstallError(
            f"{label} 门禁失败：新增 finding {len(new_findings)} 条，"
            f"target finding {len(target_findings)} 条："
            + json.dumps(
                {"new_findings": new_findings, "target_findings": target_findings},
                ensure_ascii=False,
            )
        )
    if preexisting_findings:
        print(
            f"[{label}] 既有非 target closure finding {len(preexisting_findings)} 条"
            "（不阻塞本事务，全根 strict 仍为红，见返回 payload 的 preexisting_findings）",
            file=sys.stderr,
        )
    return gate


def transaction_closure_targets(
    *,
    ledger_names: Sequence[str],
    rename: dict[str, Any] | None,
    merge_retirement: dict[str, Any] | None,
) -> list[str]:
    targets = list(ledger_names)
    if rename is not None:
        targets.append(str(rename["old_name"]))
    if merge_retirement is not None:
        targets.append(str(merge_retirement["retired"]["name"]))
    return targets


def verify_catalog(
    *,
    catalog_path: Path,
    active_root: Path,
    names: list[str],
    bundled_proofs: Sequence[BundledSkillProof],
    target_scope: str = "active",
    closure_targets: Sequence[str] | None = None,
    baseline_findings: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    catalog = _base.load_json(catalog_path, label="skill catalog")
    if not isinstance(catalog, dict) or not isinstance(catalog.get("artifacts"), list):
        raise InstallError("skill catalog 缺少 artifacts 数组")
    if closure_targets is None:
        closure_targets = [
            name if target_scope == "active" else f".system/{name}" for name in names
        ]
    try:
        closure_check = verify_catalog_closure_check(
            catalog.get("checks", {}).get("resource_closure"),
            targets=closure_targets,
            baseline_findings=baseline_findings,
        )
    except CatalogError as exc:
        raise InstallError(f"skill catalog 的资源闭包检查不可接受：{exc}") from exc
    verified: list[dict[str, Any]] = []

    def verify_target(
        *,
        path: str,
        name: str,
        proof: BundledSkillProof | None,
        scope: str = "active",
    ) -> None:
        matches = [
            artifact
            for artifact in catalog["artifacts"]
            if isinstance(artifact, dict)
            and artifact.get("scope") == scope
            and artifact.get("name") == name
            and artifact.get("relative_path") == f"{path}/SKILL.md"
        ]
        if len(matches) != 1:
            raise InstallError(f"skill catalog 对 {name} 的 active 条目数量不是 1：{len(matches)}")
        artifact = matches[0]
        if artifact.get("ledger_coverage") != "pass":
            raise InstallError(f"skill catalog 对 {name} 的 ledger coverage 不是 pass")
        source = artifact.get("source") if isinstance(artifact.get("source"), dict) else {}
        if (
            source.get("status") in {None, "missing"}
            or source.get("conflicts")
            or (proof is None and source.get("status") == "unknown")
        ):
            raise InstallError(f"skill catalog 对 {name} 的 SOURCE.md 存在冲突、未知或缺失")
        bundled_root: Path | None = None
        if proof is not None:
            bundled_root = _base.d_path(
                active_root / Path(*path.split("/")),
                label=f"bundled skill {name}",
                must_exist=True,
            )
            if _base.is_reparse(bundled_root) or not bundled_root.is_dir():
                raise InstallError(f"bundled skill {name} 不是安全目录")
            _base.ensure_tree_no_reparse(bundled_root, label=f"bundled skill {name}")
        skill_md = _base.d_path(
            (bundled_root or active_root / Path(*path.split("/"))) / "SKILL.md",
            label=f"skill {name} 的 SKILL.md",
            must_exist=True,
        )
        if _base.is_reparse(skill_md) or not skill_md.is_file():
            raise InstallError(f"skill {name} 的 SKILL.md 不是安全普通文件")
        actual = _base.sha256_file(skill_md)
        recorded = artifact.get("integrity", {}).get("skill_md_sha256")
        if actual != recorded:
            raise InstallError(f"skill catalog 对 {name} 的 SKILL.md 哈希不一致")
        verification = {"path": path, "name": name, "skill_md_sha256": actual}
        if proof is not None:
            expected_skill_md_sha256, expected_source_md_sha256 = proof.require_staged_integrity()
            if actual != expected_skill_md_sha256:
                raise InstallError(f"bundled skill {name} 的 SKILL.md 与暂存期哈希不一致")
            assert bundled_root is not None
            source_md = bundled_root / "SOURCE.md"
            if _base.is_reparse(source_md) or not source_md.is_file():
                raise InstallError(f"bundled skill {name} 的 SOURCE.md 不是安全普通文件")
            source_md_sha256 = _base.sha256_file(source_md)
            if source_md_sha256 != expected_source_md_sha256:
                raise InstallError(f"bundled skill {name} 的 SOURCE.md 与暂存期哈希不一致")
            verification["source_md_sha256"] = source_md_sha256
        verified.append(verification)

    for name in names:
        path = name if target_scope == "active" else f".system/{name}"
        expected_scope = "active" if target_scope == "active" else "system"
        verify_target(
            path=path,
            name=name,
            proof=None,
            scope=expected_scope,
        )
    for proof in bundled_proofs:
        verify_target(path=proof.ledger_key, name=proof.name, proof=proof)
    return {
        "generated_at": catalog.get("generated_at"),
        "skills": verified,
        "resource_closure": closure_check,
    }
