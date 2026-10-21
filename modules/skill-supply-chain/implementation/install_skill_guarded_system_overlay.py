"""Bundled .system provenance overlay: baseline, staging check, postcondition, ledger.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

from system_skill_provenance_repair import (
    SKILL_CREATOR_CRITICAL_FILES,
    SystemProvenanceRepairError,
    _identity as system_path_identity,
    _query_package_identity as query_system_package_identity,
    skill_creator_overlay_ledger_projection,
    system_skill_payload_inventory,
    system_skill_integrity,
    validate_skill_creator_compatibility_overlay,
)
import install_skill_guarded_base as _base
import install_skill_guarded_tree as _tree
from install_skill_guarded_base import InstallError


def system_provenance_overlay_from_decision(
    *,
    decision: dict[str, Any],
    target_scope: str,
    names: list[str],
) -> dict[str, Any] | None:
    """Normalize the one candidate-driven system provenance overlay."""
    raw = decision.get("system_provenance_overlay")
    if raw is None:
        if target_scope == "system" and names == ["skill-creator"] and decision.get("decision") == "update":
            raise InstallError(
                "system scope skill-creator update must bind system_provenance_overlay"
            )
        return None
    try:
        return validate_skill_creator_compatibility_overlay(raw)
    except SystemProvenanceRepairError as exc:
        raise InstallError(str(exc)) from exc


def _system_source_entry(
    *,
    ledger: dict[str, Any],
    active_root: Path,
) -> tuple[dict[str, Any], int]:
    """Validate the existing five-skill system provenance source before an update."""
    matches = [
        (index, entry)
        for index, entry in enumerate(ledger.get("sources", []))
        if isinstance(entry, dict) and entry.get("id") == "codex-bundled-system-skills"
    ]
    if len(matches) != 1:
        raise InstallError("codex-bundled-system-skills source group must be unique")
    index, entry = matches[0]
    expected = {f".system/{name}" for name in ("imagegen", "openai-docs", "review-agent", "skill-creator", "skill-installer")}
    skills = entry.get("skills")
    source_root = str(entry.get("source_root", "")).replace("\\", "/").casefold()
    if (
        entry.get("type") != "codex-bundled-system"
        or not isinstance(skills, list)
        or set(skills) != expected
        or len(skills) != len(expected)
        or source_root != str(active_root / ".system").replace("\\", "/").casefold()
    ):
        raise InstallError("system source group type/skill set/source_root drifted")
    provenance = entry.get("system_provenance")
    if not isinstance(provenance, dict) or provenance.get("schema_version") != 1:
        raise InstallError("system source group lacks managed system_provenance")
    package = provenance.get("package_identity")
    marker = provenance.get("marker")
    records = provenance.get("skills")
    if (
        not isinstance(package, dict)
        or not isinstance(marker, dict)
        or marker.get("relative_path") != ".system/.codex-system-skills.marker"
        or not isinstance(records, list)
        or [item.get("name") if isinstance(item, dict) else None for item in records]
        != ["imagegen", "openai-docs", "review-agent", "skill-creator", "skill-installer"]
    ):
        raise InstallError("system provenance skill/package/marker schema drifted")
    for item in records:
        if not isinstance(item, dict) or item.get("path") != f".system/{item.get('name')}":
            raise InstallError("system provenance skill path binding drifted")
        if not isinstance(item.get("official_integrity"), dict) or not isinstance(item.get("effective_integrity"), dict):
            raise InstallError("system provenance integrity records are incomplete")
    return entry, index


def prepare_system_provenance_overlay(
    *,
    args: argparse.Namespace,
    decision: dict[str, Any],
    target_scope: str,
    names: list[str],
    active_root: Path,
    ledger: dict[str, Any],
) -> dict[str, Any] | None:
    overlay = system_provenance_overlay_from_decision(
        decision=decision, target_scope=target_scope, names=names
    )
    if overlay is None:
        return None
    entry, source_index = _system_source_entry(ledger=ledger, active_root=active_root)
    provider = _base.ensure_file(args.system_package_provider, label="Store package identity provider")
    interpreter = _base.ensure_file(args.interpreter, label="Python interpreter")
    provider_bytes = provider.read_bytes()
    if _base.sha256_file(provider) != overlay["package_identity_provider_sha256"]:
        raise InstallError("Store package identity provider SHA-256 does not match overlay")
    provenance = entry["system_provenance"]
    package = provenance["package_identity"]
    try:
        observed_package = query_system_package_identity(
            interpreter=interpreter,
            provider=provider,
            expected=package,
            evidence_dir=None,
            label="system-overlay-package-preflight",
        )
    except SystemProvenanceRepairError as exc:
        raise InstallError(str(exc)) from exc
    marker = provenance["marker"]
    marker_path = _base.d_path(
        active_root / Path(*str(marker["relative_path"]).split("/")),
        label="system skill marker",
        must_exist=True,
    )
    if _base.sha256_file(marker_path) != marker.get("sha256"):
        raise InstallError("system skill marker hash does not match ledger")
    skill_root = _base.d_path(active_root / ".system" / "skill-creator", label="skill-creator active root", must_exist=True)
    record = next(item for item in provenance["skills"] if item["name"] == "skill-creator")
    if record["official_integrity"] != overlay["official_integrity"]:
        raise InstallError("skill-creator official integrity does not match recorded official baseline")
    baseline_integrity = system_skill_integrity(skill_root)
    if baseline_integrity != record["effective_integrity"]:
        raise InstallError("skill-creator active integrity does not match recorded effective baseline")
    source_path = _base.ensure_file(skill_root / "SOURCE.md", label="skill-creator baseline SOURCE.md")
    source_before = source_path.read_bytes()
    if hashlib.sha256(source_before).hexdigest() != record.get("source_md_sha256"):
        raise InstallError("skill-creator baseline SOURCE.md does not match ledger")
    prior_overlay = record.get("overlay")
    projection = skill_creator_overlay_ledger_projection(overlay)
    if prior_overlay == {"kind": "none"}:
        if baseline_integrity != record["official_integrity"]:
            raise InstallError("skill-creator unmodified baseline differs from official integrity")
    elif isinstance(prior_overlay, dict) and prior_overlay.get("kind") == "display-only":
        hashes = prior_overlay.get("baseline_file_sha256")
        if (
            set(prior_overlay) != {"kind", "base_overlay", "baseline_file_sha256"}
            or prior_overlay.get("base_overlay") != {"kind": "none"}
            or not isinstance(hashes, dict)
            or "SKILL.md" not in hashes
            or not set(hashes).issubset({"SKILL.md", "agents/openai.yaml"})
            or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes.values())
        ):
            raise InstallError("skill-creator prior display overlay provenance is invalid")
        projection["base_overlay"] = json.loads(json.dumps(prior_overlay))
        projection["baseline_integrity"] = json.loads(json.dumps(baseline_integrity))
    else:
        raise InstallError("skill-creator prior overlay is not a supported compatibility baseline")
    baseline_inventory = system_skill_payload_inventory(skill_root)
    return {
        "overlay": overlay,
        "overlay_projection": projection,
        "baseline_integrity": baseline_integrity,
        "source_before": source_before,
        "source_index": source_index,
        "source_entry_id": entry.get("id"),
        "package": observed_package,
        "provider": provider,
        "provider_bytes": provider_bytes,
        "provider_identity": system_path_identity(provider),
        "interpreter": interpreter,
        "marker_path": marker_path,
        "marker_identity": system_path_identity(marker_path),
        "marker_bytes": marker_path.read_bytes(),
        "baseline_skill_root": skill_root,
        "baseline_skill_identity": _tree.directory_identity(skill_root, label="skill-creator active root"),
        "baseline_inventory": baseline_inventory,
        "source_bytes": None,
    }


def assert_system_overlay_baseline(
    *,
    overlay_context: dict[str, Any],
    active_root: Path,
    ledger_path: Path | None = None,
) -> None:
    skill_root = _base.d_path(active_root / ".system" / "skill-creator", label="skill-creator active root", must_exist=True)
    if _tree.directory_identity(skill_root, label="skill-creator active root") != overlay_context["baseline_skill_identity"]:
        raise InstallError("skill-creator active directory identity changed during transaction")
    if system_skill_integrity(skill_root) != overlay_context["baseline_integrity"]:
        raise InstallError("skill-creator active payload changed during transaction")
    if (skill_root / "SOURCE.md").read_bytes() != overlay_context["source_before"]:
        raise InstallError("skill-creator baseline SOURCE.md changed during transaction")
    if system_skill_payload_inventory(skill_root) != overlay_context["baseline_inventory"]:
        raise InstallError("skill-creator active payload topology changed during transaction")
    marker_path = overlay_context["marker_path"]
    if (
        system_path_identity(marker_path) != overlay_context["marker_identity"]
        or marker_path.read_bytes() != overlay_context["marker_bytes"]
    ):
        raise InstallError("system marker changed during transaction")
    provider = overlay_context["provider"]
    if (
        system_path_identity(provider) != overlay_context["provider_identity"]
        or provider.read_bytes() != overlay_context["provider_bytes"]
    ):
        raise InstallError("Store package identity provider changed during transaction")


def validate_staged_system_overlay(
    *,
    staged_root: Path,
    overlay_context: dict[str, Any],
    interpreter: Path,
    evidence_dir: Path,
) -> bytes:
    """Validate candidate payload topology, hashes, and durable SOURCE bytes."""
    overlay = overlay_context["overlay"]
    target = _base.d_path(staged_root / "skill-creator", label="staged skill-creator", must_exist=True)
    actual = system_skill_integrity(target)
    if actual != overlay["effective_integrity"]:
        raise InstallError("skill-creator effective integrity does not match overlay")
    candidate_inventory = system_skill_payload_inventory(target)
    overlay_context["effective_inventory"] = candidate_inventory
    baseline_inventory = overlay_context["baseline_inventory"]
    if candidate_inventory["directories"] != baseline_inventory["directories"]:
        raise InstallError("skill-creator overlay changed directory topology outside the managed payload")
    changed = {
        relative
        for relative in set(baseline_inventory["files"]) | set(candidate_inventory["files"])
        if baseline_inventory["files"].get(relative) != candidate_inventory["files"].get(relative)
    }
    if changed != set(SKILL_CREATOR_CRITICAL_FILES):
        raise InstallError(
            "skill-creator overlay changed files outside the exact quick_validate payload: "
            + ", ".join(sorted(changed))
        )
    for relative in SKILL_CREATOR_CRITICAL_FILES:
        path = target / Path(*relative.split("/"))
        if not path.is_file() or _base.sha256_file(path) != overlay["critical_files"][relative]:
            raise InstallError(f"skill-creator critical payload hash mismatch: {relative}")
    source_path = target / "SOURCE.md"
    if not source_path.is_file():
        raise InstallError("skill-creator staged SOURCE.md is missing")
    return source_path.read_bytes()


def verify_system_provenance_overlay_postcondition(
    *,
    active_root: Path,
    ledger: dict[str, Any],
    catalog_path: Path,
    overlay_context: dict[str, Any],
) -> dict[str, Any]:
    overlay = overlay_context["overlay"]
    try:
        query_system_package_identity(
            interpreter=overlay_context["interpreter"],
            provider=overlay_context["provider"],
            expected=overlay_context["package"],
            evidence_dir=None,
            label="system-overlay-package-postcheck",
        )
    except SystemProvenanceRepairError as exc:
        raise InstallError(str(exc)) from exc
    marker_path = overlay_context["marker_path"]
    if (
        system_path_identity(marker_path) != overlay_context["marker_identity"]
        or marker_path.read_bytes() != overlay_context["marker_bytes"]
    ):
        raise InstallError("system marker changed during system overlay postcheck")
    provider = overlay_context["provider"]
    if (
        system_path_identity(provider) != overlay_context["provider_identity"]
        or provider.read_bytes() != overlay_context["provider_bytes"]
    ):
        raise InstallError("Store package identity provider changed during system overlay postcheck")
    active_skill = _base.d_path(
        active_root / ".system" / "skill-creator",
        label="active skill-creator",
        must_exist=True,
    )
    if system_skill_integrity(active_skill) != overlay["effective_integrity"]:
        raise InstallError("active skill-creator effective integrity postcheck failed")
    if system_skill_payload_inventory(active_skill) != overlay_context["effective_inventory"]:
        raise InstallError("active skill-creator payload topology postcheck failed")
    for relative in SKILL_CREATOR_CRITICAL_FILES:
        path = active_skill / Path(*relative.split("/"))
        if _base.sha256_file(path) != overlay["critical_files"][relative]:
            raise InstallError(f"active skill-creator critical payload drifted: {relative}")
    source_path = active_skill / "SOURCE.md"
    if source_path.read_bytes() != overlay_context["source_bytes"]:
        raise InstallError("skill-creator SOURCE.md provenance postcheck failed")
    source_hash = _base.sha256_file(source_path)
    entry, _ = _system_source_entry(ledger=ledger, active_root=active_root)
    record = next(item for item in entry["system_provenance"]["skills"] if item.get("name") == "skill-creator")
    if (
        record.get("official_integrity") != overlay["official_integrity"]
        or record.get("effective_integrity") != overlay["effective_integrity"]
        or record.get("critical_files") != overlay["critical_files"]
        or record.get("overlay") != overlay_context["overlay_projection"]
        or record.get("source_md_sha256") != source_hash
    ):
        raise InstallError("system provenance ledger overlay postcheck failed")
    catalog = _base.load_json(catalog_path, label="skill catalog")
    matches = [
        item for item in catalog.get("artifacts", [])
        if isinstance(item, dict)
        and item.get("scope") == "system"
        and item.get("name") == "skill-creator"
        and item.get("relative_path") == ".system/skill-creator/SKILL.md"
    ]
    if len(matches) != 1:
        raise InstallError("catalog skill-creator system entry is not unique")
    artifact = matches[0]
    if artifact.get("integrity", {}).get("skill_md_sha256") != overlay["effective_integrity"]["skill_md_sha256"]:
        raise InstallError("catalog skill-creator effective SKILL.md hash drifted")
    if artifact.get("ledger_coverage") != "pass" or artifact.get("conflicts"):
        raise InstallError("catalog skill-creator ledger coverage is not pass")
    return {
        "skill_md_sha256": overlay["effective_integrity"]["skill_md_sha256"],
        "source_md_sha256": source_hash,
        "overlay": overlay_context["overlay_projection"],
    }


def apply_system_provenance_overlay_to_ledger(
    *,
    ledger: dict[str, Any],
    overlay_context: dict[str, Any],
    source_md_sha256: str,
) -> dict[str, Any]:
    updated = json.loads(json.dumps(ledger, ensure_ascii=False))
    entry = updated["sources"][overlay_context["source_index"]]
    provenance = entry["system_provenance"]
    overlay = overlay_context["overlay"]
    record = next(
        item for item in provenance["skills"] if item.get("name") == "skill-creator"
    )
    record["effective_integrity"] = json.loads(json.dumps(overlay["effective_integrity"]))
    record["critical_files"] = json.loads(json.dumps(overlay["critical_files"]))
    record["overlay"] = json.loads(json.dumps(overlay_context["overlay_projection"]))
    record["source_md_sha256"] = source_md_sha256
    changes = entry.setdefault("local_changes", [])
    if not isinstance(changes, list):
        raise InstallError("system source group local_changes must be an array")
    # Each successful apply is its own event: a replay after a Store refresh keeps its date in the history.
    changes.append({
        "skill": ".system/skill-creator",
        "date": _base.today(),
        "summary": (
            "guarded system provenance overlay: bound skill-creator quick_validate "
            "argument-hint/disable-model-invocation compatibility payload."
        ),
    })
    updated["updated_at"] = _base.today()
    return updated
