"""Guarded retrieval, candidate staging and the staged result projection.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
from pathlib import Path
from typing import Any

import install_skill_guarded_base as _base
import install_skill_guarded_tree as _tree
import install_skill_guarded_payload as _payload
import install_skill_guarded_source_record as _source_record
import install_skill_guarded_bundled as _bundled
import install_skill_guarded_closure as _closure
import install_skill_guarded_ledger as _ledger
import install_skill_guarded_system_overlay as _system_overlay
from install_skill_guarded_base import InstallError
from install_skill_guarded_bundled import BundledSkillProof


def guarded_retrieval(args: argparse.Namespace) -> str:
    if args.candidate:
        return "guarded wrapper local candidate verified by candidate_integrity"
    if args.url:
        return f"guarded wrapper --url {args.url}"
    return f"guarded wrapper --repo {args.repo} --path {' '.join(args.paths)}"


def stage_candidate(
    *,
    args: argparse.Namespace,
    specs: list[tuple[str, str]],
    stage_root: Path,
    context: dict[str, Any],
    active_root: Path,
    target_scope: str,
    closure_script: Path,
    interpreter: Path,
    evidence_dir: Path,
    decision: dict[str, Any],
) -> dict[str, Any]:
    _base.ensure_dir(stage_root, label="staging root")
    stage_target_root = (
        stage_root
        if target_scope == "active"
        else _base.ensure_dir(stage_root / ".system", label="system staging root")
    )
    ledger_names = [
        name if target_scope == "active" else f".system/{name}"
        for name, _ in specs
    ]
    candidate_integrity: dict[str, Any] | None = None
    if args.candidate:
        candidate = _base.d_path(args.candidate, label="candidate", must_exist=True)
        _base.ensure_tree_no_reparse(candidate, label="candidate")
        candidate_integrity = _payload.validate_candidate_integrity(candidate, decision)
        name = specs[0][0]
        shutil.copytree(candidate, stage_target_root / name, ignore=_payload.candidate_copy_ignore)
        copied_seal = _tree.tree_content_seal(stage_target_root / name)
        expected_copied_seal = {
            field: candidate_integrity[field]
            for field in ("directory_count", "file_count", "tree_sha256")
        }
        if copied_seal != expected_copied_seal:
            raise InstallError("复制后的 candidate 安装载荷指纹不一致")
    else:
        command = [str(interpreter), str(args.system_installer)]
        if args.url:
            command.extend(["--url", args.url])
        else:
            command.extend(["--repo", args.repo, "--path", *args.paths])
        if args.ref and not args.url:
            command.extend(["--ref", args.ref])
        if args.name:
            command.extend(["--name", args.name])
        if args.method:
            command.extend(["--method", args.method])
        command.extend(["--dest", str(stage_root)])
        _base.run_process(command, evidence_dir=evidence_dir, label="upstream-installer")

    names = [name for name, _ in specs]
    for name, upstream_path in specs:
        target = stage_target_root / name
        if not target.is_dir() or _base.is_reparse(target):
            raise InstallError(f"staging 缺少安全的 skill 目录：{target}")
        _base.ensure_tree_no_reparse(target, label=f"staging skill {name}")
        skill_md = target / "SKILL.md"
        if not skill_md.is_file() or _base.is_reparse(skill_md):
            raise InstallError(f"staging 缺少安全的 SKILL.md：{skill_md}")
        actual_name = _payload.read_skill_name(skill_md)
        if actual_name != name:
            raise InstallError(f"SKILL.md name 与目标目录不一致：{actual_name!r} != {name!r}")
        _payload.validate_openai_display_name(target, label=f"staging skill {name}")
        _payload.validate_chinese_display_metadata(target, label=f"staging skill {name}")
        system_overlay_context = context.get("system_provenance_overlay")
        if (
            isinstance(system_overlay_context, dict)
            and target_scope == "system"
            and name == "skill-creator"
        ):
            source_bytes = system_overlay_context.get("source_bytes")
            if not isinstance(source_bytes, bytes):
                raise InstallError("skill-creator system provenance SOURCE bytes are missing")
            _base.atomic_write_bytes(target / "SOURCE.md", source_bytes)
            if (target / "SOURCE.md").read_bytes() != source_bytes:
                raise InstallError("skill-creator system provenance SOURCE staging hash mismatch")
        else:
            _source_record.append_source_record(
                target / "SOURCE.md",
                skill_name=(name if target_scope == "active" else f".system/{name}"),
                active_root=active_root,
                upstream_path=upstream_path,
                context=context,
                command=guarded_retrieval(args),
            )
            if args.candidate:
                _source_record.validate_durable_source_record(
                    target / "SOURCE.md",
                    durable_fields={
                        "Local path": active_root / ledger_names[names.index(name)],
                        "Active root": active_root,
                        "Guarded transaction evidence": Path(context["evidence_path"]),
                        "Decision manifest": Path(context["manifest_path"]),
                    },
                    transient_paths=[Path(args.candidate), Path(args.decision_manifest)],
                )
    bundled_validation = _bundled.validate_staged_bundled_skills(
        stage_root=stage_target_root,
        active_root=active_root,
        top_level_name=names[0],
        bundled_proofs=context.get("bundled_skill_proofs", ()),
        args=args,
    )
    _base.atomic_write_json(
        stage_root / ".downloaded-skills-source-state.json",
        _ledger.make_staging_ledger(ledger_names, context),
    )
    closure = _closure.run_closure(
        root=stage_root,
        closure_script=closure_script,
        interpreter=interpreter,
        evidence_dir=evidence_dir,
        label="staged-resource-closure",
    )
    # The staging root only holds this transaction's skills: no baseline, so
    # every staged finding blocks (equivalent to zero-finding strict).
    staged_gate = _closure.evaluate_closure_gate(
        payload=closure,
        baseline=None,
        targets=ledger_names,
        label="staged-resource-closure",
    )
    staged_payloads = {
        name: _tree.tree_content_seal(stage_target_root / name) for name in names
    }
    system_overlay_context = context.get("system_provenance_overlay")
    if isinstance(system_overlay_context, dict):
        source_bytes = _system_overlay.validate_staged_system_overlay(
            staged_root=stage_target_root,
            overlay_context=system_overlay_context,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
        )
        system_overlay_context["source_md_sha256"] = hashlib.sha256(source_bytes).hexdigest()
    return {
        "names": names,
        "closure": closure,
        "closure_gate": staged_gate,
        "candidate_integrity": candidate_integrity,
        "bundled_skill_proofs": bundled_validation,
        "staged_payloads": staged_payloads,
    }


def staged_result_projection(staged: dict[str, Any] | None) -> dict[str, Any] | None:
    if staged is None:
        return None
    bundled_proofs = staged.get("bundled_skill_proofs", ())
    if (
        not isinstance(bundled_proofs, tuple)
        or not all(isinstance(proof, BundledSkillProof) for proof in bundled_proofs)
    ):
        raise InstallError("bundled skill 暂存期证明对象不合法")
    return {
        **{
            key: value
            for key, value in staged.items()
            if key != "bundled_skill_proofs"
        },
        "bundled_skills": [
            proof.staged_projection()
            for proof in bundled_proofs
        ],
    }
