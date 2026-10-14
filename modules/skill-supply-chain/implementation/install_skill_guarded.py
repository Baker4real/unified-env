#!/usr/bin/env python3
"""Install a Codex skill and atomically reconcile its local governance state.

The model-facing ``skill-install-guard`` skill decides whether a candidate may
be installed.  This wrapper is the operational boundary: it stages the
candidate, writes provenance and the unified ledger, runs resource closure,
regenerates the local catalog, verifies the postcondition, and rolls back on
failure.  The bundled system installer remains an upstream helper and is not
modified.

This entry keeps the transaction, the CLI and the default paths; each other
responsibility lives in an ``install_skill_guarded_<area>.py`` module beside it.
Source: ``D:/agents/projects/统一环境/modules/skill-supply-chain/implementation``.
Edit them there, then run that repo's ``scripts/Deploy-SkillInstallGuarded.ps1``
to copy them into ``D:/Codex/.codex/scripts``.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as _datetime
import hashlib
import json
import os
import shutil
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Iterator

# Only the installer modules use these, but loading them before this directory joins
# sys.path, as the single-file installer did, keeps a same-named file beside the deployed
# scripts (a yaml.py, say) from shadowing them.
import subprocess  # noqa: F401
import urllib.parse  # noqa: F401

import yaml  # noqa: F401


sys.dont_write_bytecode = True

_SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(_SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIRECTORY))

from generate_skill_catalog import (
    closure_finding_key,
    finding_hits_targets,
)
from system_skill_provenance_repair import (
    SKILL_CREATOR_OVERLAY_KIND,
    SystemProvenanceRepairError,
    _identity as system_path_identity,
    _query_package_identity as query_system_package_identity,
    _source_record as system_source_record,
    system_skill_payload_inventory,
    system_skill_integrity,
)
import install_skill_guarded_base as _base
import install_skill_guarded_activation as _activation
import install_skill_guarded_payload as _payload
import install_skill_guarded_bundled as _bundled
import install_skill_guarded_closure as _closure
import install_skill_guarded_decision as _decision
import install_skill_guarded_ledger as _ledger
import install_skill_guarded_rename as _rename
import install_skill_guarded_retirement as _retirement
import install_skill_guarded_system_overlay as _system_overlay
import install_skill_guarded_staging as _staging
from install_skill_guarded_base import InstallError


DEFAULT_ACTIVE_ROOT = Path(r"D:\agents\skills-manager\skills")
DEFAULT_PLUGIN_CACHE_ROOT = Path(r"D:\Codex\.codex\plugins\cache")
DEFAULT_LEDGER = Path(r"D:\agents\skills-manager\skills\.downloaded-skills-source-state.json")
DEFAULT_CATALOG = Path(r"D:\Codex\.codex\skill-catalog\catalog.json")
DEFAULT_GENERATOR = Path(__file__).absolute().with_name("generate_skill_catalog.py")
DEFAULT_SYSTEM_PACKAGE_PROVIDER = Path(__file__).absolute().with_name(
    "system_package_identity.py"
)
DEFAULT_CLOSURE = Path(
    r"D:\agents\skills-manager\skills\skill-install-guard\scripts\skill_resource_closure.py"
)
DEFAULT_SYSTEM_INSTALLER = Path(
    r"D:\agents\skills-manager\skills\.system\skill-installer\scripts\install-skill-from-github.py"
)
DEFAULT_PYTHON = Path(r"D:\Codex\tools\python315-official\python.exe")
DEFAULT_TEMP_ROOT = Path(r"D:\Codex\tmp\skill-install-guarded")
DEFAULT_LOCK_ROOT = Path(r"D:\Codex\.codex\skill-install")
DEFAULT_EVIDENCE_ROOT = Path(r"D:\agents\run-evidence\skill-install-guarded")


@contextlib.contextmanager
def installation_lock(lock_path: Path) -> Iterator[None]:
    _base.ensure_dir(lock_path.parent, label="skill 安装锁目录")
    try:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        raise InstallError(f"已有 skill 安装事务或遗留锁：{lock_path}；请先检查证据后再处理") from exc
    try:
        os.write(descriptor, f"pid={os.getpid()}\nutc={_base.utc_now()}\n".encode("utf-8"))
        os.close(descriptor)
        descriptor = -1
        yield
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        lock_path.unlink(missing_ok=True)


def write_transaction_manifest(path: Path, payload: dict[str, Any]) -> None:
    _base.atomic_write_json(path, payload)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="通过事务 wrapper 安装并校验 Codex skill")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--candidate", type=Path, help="已通过候选审查的本地 skill 目录")
    source.add_argument("--repo", help="GitHub owner/repo")
    source.add_argument("--url", help="GitHub skill tree/blob URL")
    source.add_argument(
        "--system-provenance-repair-plan",
        type=Path,
        help="精确五项 bundled .system provenance 原子修复计划",
    )
    parser.add_argument("--path", dest="paths", nargs="+", help="GitHub repo 内的 skill path")
    parser.add_argument("--ref", default="main")
    parser.add_argument("--name", help="单个 skill 的 active name")
    parser.add_argument("--method", choices=("auto", "download", "git"), default="auto")
    parser.add_argument("--decision-manifest", type=Path)
    parser.add_argument(
        "--candidate-integrity-only",
        action="store_true",
        help="只读计算本地 candidate 的受管安装载荷指纹，不执行事务",
    )
    parser.add_argument("--update", action="store_true", help="兼容旧调用；实际更新权限仍由 manifest decision=update 决定")
    parser.add_argument("--dry-run", action="store_true", help="只暂存和验证，不改变 active root、ledger 或 catalog")
    parser.add_argument("--active-root", type=Path, default=DEFAULT_ACTIVE_ROOT)
    parser.add_argument("--plugin-cache-root", type=Path, default=DEFAULT_PLUGIN_CACHE_ROOT)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--generator", type=Path, default=DEFAULT_GENERATOR)
    parser.add_argument("--closure-script", type=Path, default=DEFAULT_CLOSURE)
    parser.add_argument("--system-installer", type=Path, default=DEFAULT_SYSTEM_INSTALLER)
    parser.add_argument(
        "--system-package-provider",
        type=Path,
        default=DEFAULT_SYSTEM_PACKAGE_PROVIDER,
        help="返回当前 Codex Store package/signature identity 的受管 provider",
    )
    parser.add_argument("--python", dest="interpreter", type=Path, default=DEFAULT_PYTHON)
    parser.add_argument("--temp-root", type=Path, default=DEFAULT_TEMP_ROOT)
    parser.add_argument("--lock-root", type=Path, default=DEFAULT_LOCK_ROOT)
    parser.add_argument("--evidence-root", type=Path, default=DEFAULT_EVIDENCE_ROOT)
    return parser


def execute(args: argparse.Namespace) -> dict[str, Any]:
    active_root = _base.ensure_dir(args.active_root, label="active root")
    plugin_cache_root = _base.ensure_dir(args.plugin_cache_root, label="plugin cache root")
    ledger_path = _base.ensure_file(args.ledger, label="source ledger")
    generator = _base.ensure_file(args.generator, label="catalog generator")
    closure_script = _base.ensure_file(args.closure_script, label="resource closure script")
    interpreter = _base.ensure_file(args.interpreter, label="Python interpreter")
    system_installer = _base.d_path(args.system_installer, label="system installer")
    if not args.candidate:
        if not system_installer.exists() or not system_installer.is_file():
            raise InstallError(f"系统 skill installer 不存在：{system_installer}")
    catalog_path = _base.d_path(args.catalog, label="catalog output")
    temp_root = _base.ensure_dir(args.temp_root, label="skill staging temp root")
    evidence_root = _base.ensure_dir(args.evidence_root, label="skill install evidence root")
    lock_root = _base.ensure_dir(args.lock_root, label="skill install lock root")
    decision_path = _base.d_path(args.decision_manifest, label="decision manifest", must_exist=True)
    specs = _decision.target_specs(args)
    names = [name for name, _ in specs]
    decision = _decision.load_and_validate_manifest(decision_path, names=names)
    target_scope, target_root, ledger_names = _decision.target_layout(
        active_root,
        names=names,
        decision=decision,
    )
    if target_scope == "system" and not args.candidate:
        raise InstallError("system scope 只支持经过 candidate_integrity 绑定的本地 candidate")
    try:
        decision_snapshot_bytes = decision_path.read_bytes()
    except OSError as exc:
        raise InstallError(
            f"无法读取 decision manifest 快照：{decision_path}：{exc}"
        ) from exc
    try:
        decision_snapshot_value = json.loads(
            decision_snapshot_bytes.decode("utf-8-sig")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InstallError(f"decision manifest 快照无法解析：{exc}") from exc
    if decision_snapshot_value != decision:
        raise InstallError("decision manifest 在验证期间发生变化")
    rename = _rename.canonical_rename_spec(args=args, decision=decision, names=names)
    merge_retirement = _retirement.merge_retirement_spec(
        args=args,
        decision=decision,
        names=names,
    )
    if target_scope == "system" and (rename is not None or merge_retirement is not None):
        raise InstallError("system scope 暂不支持 canonical rename 或 merge retirement")
    specs = _decision.apply_candidate_upstream_path(args, decision, specs)
    if args.update and decision["decision"] != "update":
        raise InstallError("--update 只能与 decision=update 的 manifest 一起使用")
    if decision["decision"] == "update" and not args.update:
        # The guard manifest is the authorization.  The explicit flag is an
        # extra compatibility signal, not a second approval gate.
        pass
    context = _decision.source_context(args, decision, specs)
    context["target_scope"] = target_scope
    initial_ledger_bytes = ledger_path.read_bytes()
    initial_ledger_identity = system_path_identity(ledger_path)
    initial_catalog_bytes = catalog_path.read_bytes() if catalog_path.exists() else None
    initial_catalog_identity = (
        system_path_identity(catalog_path) if catalog_path.exists() else None
    )
    initial_ledger = _base.load_json(ledger_path, label="source ledger")
    system_overlay_context = _system_overlay.prepare_system_provenance_overlay(
        args=args,
        decision=decision,
        target_scope=target_scope,
        names=names,
        active_root=active_root,
        ledger=initial_ledger,
    )
    if system_overlay_context is not None:
        overlay = system_overlay_context["overlay"]
        overlay_projection = system_overlay_context["overlay_projection"]
        new_source = system_source_record(
            active_root=active_root,
            source_group_id="codex-bundled-system-skills",
            package=system_overlay_context["package"],
            marker_sha256=initial_ledger["sources"][system_overlay_context["source_index"]]["system_provenance"]["marker"]["sha256"],
            spec={
                "name": "skill-creator",
                "official_integrity": overlay["official_integrity"],
                "effective_integrity": overlay["effective_integrity"],
                "critical_files": overlay["critical_files"],
                "overlay": overlay_projection,
            },
        )
        system_overlay_context["source_bytes"] = (
            system_overlay_context["source_before"].rstrip(b"\r\n")
            + b"\n\n---\n"
            + new_source.split(b"---\n", 1)[1]
        )
        context["system_provenance_overlay"] = system_overlay_context
        # The managed provenance record below is the sole local-change entry for
        # this payload; do not also emit the generic candidate overlay marker.
        context["overlay_status"] = "none"
        context["overlay_summary"] = ""
        system_overlay_context["ledger_before_bytes"] = initial_ledger_bytes
        system_overlay_context["ledger_before_identity"] = initial_ledger_identity
        system_overlay_context["catalog_before_bytes"] = initial_catalog_bytes
        system_overlay_context["catalog_before_identity"] = initial_catalog_identity
    context["bundled_skill_proofs"] = _bundled.bundled_skill_specs(
        args=args,
        decision=decision,
        names=names,
    )
    if target_scope == "system" and context["bundled_skill_proofs"]:
        raise InstallError("system scope 暂不支持 bundled_skills")
    if rename is not None:
        context["canonical_rename"] = rename
        _rename.validate_canonical_rename_state(
            args=args,
            active_root=active_root,
            ledger=_base.load_json(ledger_path, label="source ledger"),
            context=context,
            rename=rename,
        )
    if merge_retirement is not None:
        context["merge_retirement"] = merge_retirement
        _retirement.validate_merge_retirement_state(
            args=args,
            active_root=active_root,
            ledger=_base.load_json(ledger_path, label="source ledger"),
            names=names,
            retirement=merge_retirement,
        )
    _ledger.validate_group_checkpoint_advance(
        _base.load_json(ledger_path, label="source ledger"),
        names=ledger_names,
        context=context,
    )
    transaction_id = uuid.uuid4().hex
    evidence_dir = evidence_root / f"install-{_datetime.datetime.now().strftime('%Y%m%dT%H%M%S')}-{transaction_id}"
    _base.ensure_dir(evidence_dir, label="transaction evidence directory")
    manifest_path = evidence_dir / "manifest.json"
    decision_snapshot_path = evidence_dir / "decision-manifest.json"
    decision_snapshot = {
        "path": str(decision_snapshot_path),
        "sha256": hashlib.sha256(decision_snapshot_bytes).hexdigest(),
    }
    context["evidence_path"] = str(evidence_dir)
    context["manifest_path"] = str(decision_snapshot_path)
    plan = {
        "schema_version": 1,
        "transaction_id": transaction_id,
        "status": "prepared",
        "started_at": _base.utc_now(),
        "decision": decision,
        "decision_manifest_snapshot": decision_snapshot,
        "targets": names,
        "merge_retirement": merge_retirement,
        "active_root": str(active_root),
        "target_scope": target_scope,
        "target_root": str(target_root),
        "ledger": str(ledger_path),
        "catalog": str(catalog_path),
        "wrapper": "D:/Codex/.codex/scripts/install-skill-guarded.cmd",
    }
    write_transaction_manifest(manifest_path, plan)

    stage_dir = Path(tempfile.mkdtemp(prefix=f"transaction-{transaction_id}-", dir=temp_root))
    directory_records: list[dict[str, Any]] = []
    ledger_backup: Path | None = None
    catalog_backup: Path | None = None
    state_backups_ready = False
    staged: dict[str, Any] | None = None
    system_overlay_context = context.get("system_provenance_overlay")
    closure_targets = _closure.transaction_closure_targets(
        ledger_names=ledger_names,
        rename=rename,
        merge_retirement=merge_retirement,
    )
    baseline_closure: dict[str, Any] | None = None
    try:
        # Baseline before any staging or active-root write; post-write closure
        # is judged against it (new findings + target findings block).
        baseline_closure = _closure.run_closure(
            root=active_root,
            closure_script=closure_script,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
            label="baseline-resource-closure",
        )
        baseline_closure_path = evidence_dir / "baseline-resource-closure.json"
        _base.atomic_write_json(baseline_closure_path, baseline_closure)
        _base.atomic_write_bytes(decision_snapshot_path, decision_snapshot_bytes)
        if _base.sha256_file(decision_snapshot_path) != decision_snapshot["sha256"]:
            raise InstallError("decision manifest 事务快照指纹不一致")
        staged = _staging.stage_candidate(
            args=args,
            specs=specs,
            stage_root=stage_dir,
            context=context,
            active_root=active_root,
            target_scope=target_scope,
            closure_script=closure_script,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
            decision=decision,
        )
        if args.dry_run:
            result = {
                **plan,
                "status": "dry-run-pass",
                "completed_at": _base.utc_now(),
                "baseline_resource_closure": baseline_closure,
                "staged": _staging.staged_result_projection(staged),
                "evidence": str(evidence_dir),
            }
            write_transaction_manifest(manifest_path, result)
            return result

        active_state = _base.load_json(ledger_path, label="source ledger")
        system_overlay_context = context.get("system_provenance_overlay")
        if isinstance(system_overlay_context, dict):
            if (
                system_path_identity(ledger_path) != system_overlay_context["ledger_before_identity"]
                or ledger_path.read_bytes() != system_overlay_context["ledger_before_bytes"]
            ):
                raise InstallError("source ledger changed while staging system overlay")
            _system_overlay.assert_system_overlay_baseline(
                overlay_context=system_overlay_context,
                active_root=active_root,
            )
            # Re-read the signed package identity immediately before any active swap.
            try:
                query_system_package_identity(
                    interpreter=interpreter,
                    provider=system_overlay_context["provider"],
                    expected=system_overlay_context["package"],
                    evidence_dir=evidence_dir,
                    label="system-overlay-package-prewrite",
                )
            except SystemProvenanceRepairError as exc:
                raise InstallError(str(exc)) from exc
        if rename is not None:
            _rename.validate_canonical_rename_state(
                args=args,
                active_root=active_root,
                ledger=active_state,
                context=context,
                rename=rename,
            )
        if merge_retirement is not None:
            _retirement.validate_merge_retirement_state(
                args=args,
                active_root=active_root,
                ledger=active_state,
                names=names,
                retirement=merge_retirement,
            )
        # Re-check against the ledger this transaction will write; writers
        # outside the install lock may have moved the checkpoint during staging.
        _ledger.validate_group_checkpoint_advance(active_state, names=ledger_names, context=context)
        backup_root = evidence_dir / "backups"
        _base.ensure_dir(backup_root, label="transaction backup root")
        ledger_backup = _activation.backup_file(ledger_path, backup_root, "source-state-before.json")
        catalog_backup = _activation.backup_file(catalog_path, backup_root, "catalog-before.json")
        state_backups_ready = True
        if rename is None and merge_retirement is None:
            for name in names:
                active = target_root / name
                if decision["decision"] == "install" and active.exists():
                    raise InstallError(f"install 分支不能覆盖已有 active skill：{active}")
                if decision["decision"] == "update" and not active.exists():
                    raise InstallError(f"update 分支要求已有 active skill：{active}")
        elif merge_retirement is not None:
            _activation.retire_directories(
                active_root=active_root,
                names=[merge_retirement["retired"]["name"]],
                backup_root=backup_root / "active-skills",
                records=directory_records,
            )
            retired_record = directory_records[-1]
            if (
                retired_record.get("name") != merge_retirement["retired"]["name"]
                or retired_record.get("backup_seal")
                != merge_retirement["retired"]["tree_seal"]
            ):
                raise InstallError(
                    "merge retirement 退役 payload 在预检与备份移动之间发生漂移"
                )
        else:
            _activation.retire_directories(
                active_root=active_root,
                names=[rename["old_name"]],
                backup_root=backup_root / "active-skills",
                records=directory_records,
            )
        _activation.activate_directories(
            stage_root=(stage_dir if target_scope == "active" else stage_dir / ".system"),
            active_root=target_root,
            names=names,
            backup_root=backup_root / "active-skills",
            records=directory_records,
            payload_seals=staged["staged_payloads"],
            must_not_exist={rename["new_name"]} if rename is not None else None,
        )
        if isinstance(system_overlay_context, dict):
            skill_record = next(
                record
                for record in directory_records
                if record.get("name") == "skill-creator"
            )
            backup_skill = Path(skill_record["backup"])
            if system_skill_integrity(backup_skill) != system_overlay_context["baseline_integrity"]:
                raise InstallError("skill-creator backup payload does not match the bound effective baseline")
            if system_skill_payload_inventory(backup_skill) != system_overlay_context["baseline_inventory"]:
                raise InstallError("skill-creator backup topology does not match the bound effective baseline")
            if (backup_skill / "SOURCE.md").read_bytes() != system_overlay_context["source_before"]:
                raise InstallError("skill-creator backup SOURCE.md does not match the bound baseline")
        activation_readability = _activation.verify_activation_readability(
            active_root=target_root,
            names=names,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
        )
        updated_ledger = _ledger.update_ledger(active_state, names=ledger_names, context=context)
        if isinstance(system_overlay_context, dict):
            source_md_sha256 = system_overlay_context.get("source_md_sha256")
            if not isinstance(source_md_sha256, str):
                raise InstallError("skill-creator system provenance SOURCE hash is missing")
            updated_ledger = _system_overlay.apply_system_provenance_overlay_to_ledger(
                ledger=updated_ledger,
                overlay_context=system_overlay_context,
                source_md_sha256=source_md_sha256,
            )
            if ledger_path.read_bytes() != system_overlay_context["ledger_before_bytes"]:
                raise InstallError("source ledger changed before system overlay write")
        ledger_after_bytes = _base.json_document_bytes(updated_ledger)
        _base.atomic_write_bytes(ledger_path, ledger_after_bytes)
        if isinstance(system_overlay_context, dict):
            system_overlay_context["ledger_written_bytes"] = ledger_path.read_bytes()
            system_overlay_context["ledger_written_identity"] = system_path_identity(ledger_path)
        catalog_generation_output = (
            stage_dir / "system-overlay-catalog.json"
            if isinstance(system_overlay_context, dict)
            else catalog_path
        )
        _base.run_process(
            [
                str(interpreter),
                str(generator),
                "--write",
                "--active-root",
                str(active_root),
                "--plugin-cache-root",
                str(plugin_cache_root),
                "--ledger",
                str(ledger_path),
                "--output",
                str(catalog_generation_output),
                "--closure-baseline",
                str(baseline_closure_path),
                *[
                    argument
                    for target in closure_targets
                    for argument in ("--closure-target", target)
                ],
            ],
            evidence_dir=evidence_dir,
            label="catalog-generation",
        )
        if isinstance(system_overlay_context, dict):
            if (
                system_path_identity(ledger_path) != system_overlay_context.get("ledger_written_identity")
                or ledger_path.read_bytes() != system_overlay_context.get("ledger_written_bytes")
            ):
                raise InstallError("source ledger changed during system overlay catalog generation")
            before_catalog_bytes = system_overlay_context["catalog_before_bytes"]
            before_catalog_identity = system_overlay_context["catalog_before_identity"]
            if before_catalog_bytes is None or before_catalog_identity is None:
                if catalog_path.exists():
                    raise InstallError("catalog appeared before system overlay CAS write")
            elif (
                system_path_identity(catalog_path) != before_catalog_identity
                or catalog_path.read_bytes() != before_catalog_bytes
            ):
                raise InstallError("catalog changed before system overlay CAS write")
            generated_catalog_bytes = catalog_generation_output.read_bytes()
            _base.atomic_write_bytes(catalog_path, generated_catalog_bytes)
            system_overlay_context["catalog_written_bytes"] = generated_catalog_bytes
            system_overlay_context["catalog_written_identity"] = system_path_identity(catalog_path)
        post_closure = _closure.run_closure(
            root=active_root,
            closure_script=closure_script,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
            label="post-resource-closure",
        )
        post_closure_gate = _closure.evaluate_closure_gate(
            payload=post_closure,
            baseline=baseline_closure,
            targets=closure_targets,
            label="post-resource-closure",
        )
        persisted_ledger = _base.load_json(ledger_path, label="postcondition source ledger")
        if merge_retirement is not None and persisted_ledger != updated_ledger:
            raise InstallError("merge retirement 写入后的 source ledger 发生漂移")
        catalog_verification = _closure.verify_catalog(
            catalog_path=catalog_path,
            active_root=active_root,
            names=names,
            bundled_proofs=staged["bundled_skill_proofs"],
            target_scope=target_scope,
            closure_targets=closure_targets,
            baseline_findings=baseline_closure["findings"],
        )
        system_overlay_postcondition = (
            _system_overlay.verify_system_provenance_overlay_postcondition(
                active_root=active_root,
                ledger=persisted_ledger,
                catalog_path=catalog_path,
                overlay_context=system_overlay_context,
            )
            if isinstance(system_overlay_context, dict)
            else None
        )
        merge_retirement_verification = (
            _retirement.verify_merge_retirement_postcondition(
                active_root=active_root,
                ledger=persisted_ledger,
                catalog_path=catalog_path,
                retirement=merge_retirement,
            )
            if merge_retirement is not None
            else None
        )
        # Other sessions may edit the shared live ledger later; keep the bytes this transaction wrote.
        source_state_after_path = backup_root / "source-state-after.json"
        _base.atomic_write_bytes(source_state_after_path, ledger_after_bytes)
        result = {
            **plan,
            "status": "succeeded",
            "completed_at": _base.utc_now(),
            "targets": names,
            "staged": _staging.staged_result_projection(staged),
            "directory_records": directory_records,
            "activation_readability": activation_readability,
            "baseline_resource_closure": baseline_closure,
            "post_resource_closure": post_closure,
            "post_resource_closure_gate": post_closure_gate,
            "preexisting_findings": post_closure_gate["preexisting_findings"],
            "catalog_verification": catalog_verification,
            "system_provenance_overlay_postcondition": system_overlay_postcondition,
            "merge_retirement_verification": merge_retirement_verification,
            "source_state_after": {
                "path": str(source_state_after_path),
                "sha256": hashlib.sha256(ledger_after_bytes).hexdigest(),
            },
            "catalog_sha256": _base.sha256_file(catalog_path),
            "evidence": str(evidence_dir),
        }
        write_transaction_manifest(manifest_path, result)
        return result
    except Exception as exc:
        rollback_errors = _activation.rollback_directories(directory_records)
        if state_backups_ready:
            try:
                if isinstance(system_overlay_context, dict):
                    _activation.restore_file_cas(
                        ledger_path,
                        before=system_overlay_context["ledger_before_bytes"],
                        before_identity=system_overlay_context["ledger_before_identity"],
                        written=system_overlay_context.get("ledger_written_bytes"),
                        written_identity=system_overlay_context.get("ledger_written_identity"),
                        backup=ledger_backup,
                    )
                    _activation.restore_file_cas(
                        catalog_path,
                        before=system_overlay_context["catalog_before_bytes"],
                        before_identity=system_overlay_context["catalog_before_identity"],
                        written=system_overlay_context.get("catalog_written_bytes"),
                        written_identity=system_overlay_context.get("catalog_written_identity"),
                        backup=catalog_backup,
                    )
                else:
                    _activation.restore_file(ledger_path, ledger_backup)
                    _activation.restore_file(catalog_path, catalog_backup)
            except Exception as restore_exc:
                rollback_errors.append(f"state restore: {restore_exc}")
        failure = {
            **plan,
            "status": "rollback-failed" if rollback_errors else "rolled-back",
            "completed_at": _base.utc_now(),
            "error": str(exc),
            "rollback_errors": rollback_errors,
            "baseline_resource_closure": baseline_closure,
            "staged": _staging.staged_result_projection(staged),
            "evidence": str(evidence_dir),
        }
        write_transaction_manifest(manifest_path, failure)
        raise InstallError(
            f"skill 安装未完成，状态={failure['status']}；原因：{exc}；证据：{evidence_dir}"
        ) from exc
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    args = parser.parse_args(argv)
    try:
        if args.system_provenance_repair_plan is not None:
            ordinary_flags = {
                "--system-installer",
                "--ref",
                "--method",
            }
            if (
                args.candidate is not None
                or args.repo is not None
                or args.url is not None
                or args.paths is not None
                or args.name is not None
                or args.decision_manifest is not None
                or args.candidate_integrity_only
                or args.update
                or any(
                    token in ordinary_flags
                    or any(token.startswith(flag + "=") for flag in ordinary_flags)
                    for token in raw_argv
                )
            ):
                raise InstallError(
                    "--system-provenance-repair-plan 不能与普通 install/update 参数混用"
                )
            from system_skill_provenance_repair import (
                SystemProvenanceRepairError,
                execute as execute_system_provenance_repair,
            )

            try:
                with installation_lock(
                    _base.d_path(args.lock_root, label="skill install lock root")
                    / "install.lock"
                ):
                    result = execute_system_provenance_repair(args)
            except SystemProvenanceRepairError as exc:
                raise InstallError(str(exc)) from exc
            except Exception as exc:
                raise InstallError(f"system provenance repair 输入或运行态无效：{exc}") from exc
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.candidate is None and args.repo is None and args.url is None:
            raise InstallError(
                "必须提供 --candidate、--repo、--url 或 --system-provenance-repair-plan"
            )
        if args.candidate_integrity_only:
            if not args.candidate:
                raise InstallError("--candidate-integrity-only 必须配合 --candidate")
            if args.decision_manifest is not None or args.update or args.dry_run:
                raise InstallError(
                    "--candidate-integrity-only 不能与 decision/update/dry-run 事务参数混用"
                )
            candidate = _base.d_path(args.candidate, label="candidate", must_exist=True)
            if not candidate.is_dir():
                raise InstallError(f"candidate 必须是目录：{candidate}")
            result = _payload.inspect_candidate_integrity(candidate)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.decision_manifest is None:
            raise InstallError("安装事务必须提供 --decision-manifest")
        with installation_lock(_base.d_path(args.lock_root, label="skill install lock root") / "install.lock"):
            result = execute(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except InstallError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
