"""Merge retirement: spec, active-state validation and postcondition.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import install_skill_guarded_base as _base
import install_skill_guarded_tree as _tree
import install_skill_guarded_payload as _payload
import install_skill_guarded_source_record as _source_record
import install_skill_guarded_ledger as _ledger
from install_skill_guarded_base import SAFE_SKILL_NAME, SHA256_HEX, InstallError


def normalize_tree_seal(value: Any, *, label: str) -> dict[str, Any]:
    expected_fields = {"directory_count", "file_count", "tree_sha256"}
    if not isinstance(value, dict) or set(value) != expected_fields:
        raise InstallError(f"{label} 必须精确包含 directory_count、file_count、tree_sha256")
    directory_count = value.get("directory_count")
    file_count = value.get("file_count")
    tree_sha256 = value.get("tree_sha256")
    if (
        isinstance(directory_count, bool)
        or not isinstance(directory_count, int)
        or directory_count < 0
        or isinstance(file_count, bool)
        or not isinstance(file_count, int)
        or file_count < 1
        or not isinstance(tree_sha256, str)
        or not SHA256_HEX.fullmatch(tree_sha256)
    ):
        raise InstallError(f"{label} 包含不合法的内容 seal")
    return {
        "directory_count": directory_count,
        "file_count": file_count,
        "tree_sha256": tree_sha256.casefold(),
    }


def merge_retirement_spec(
    *,
    args: argparse.Namespace,
    decision: dict[str, Any],
    names: list[str],
) -> dict[str, Any] | None:
    raw = decision.get("merge_retirement")
    if raw is None:
        return None
    if not isinstance(raw, dict) or set(raw) != {"retired", "survivors", "reason"}:
        raise InstallError(
            "merge_retirement 必须精确包含 retired、survivors、reason"
        )
    if decision.get("decision") != "update":
        raise InstallError("merge retirement 只允许 decision=update")
    if not args.candidate or len(names) != 1:
        raise InstallError("merge retirement 只支持单个本地 --candidate update")
    if decision.get("canonical_rename") is not None:
        raise InstallError("merge_retirement 不能与 canonical_rename 同时使用")

    retired = raw.get("retired")
    retired_fields = {
        "name",
        "source_id",
        "skill_md_sha256",
        "tree_seal",
    }
    if not isinstance(retired, dict) or set(retired) != retired_fields:
        raise InstallError(
            "merge_retirement.retired 必须精确包含 name、source_id、"
            "skill_md_sha256、tree_seal"
        )
    retired_name = retired.get("name")
    retired_source_id = retired.get("source_id")
    retired_skill_md_sha256 = retired.get("skill_md_sha256")
    if not isinstance(retired_name, str) or not SAFE_SKILL_NAME.fullmatch(retired_name):
        raise InstallError("merge_retirement.retired.name 不是合法 skill name")
    if (
        not isinstance(retired_source_id, str)
        or not retired_source_id.strip()
        or retired_source_id != retired_source_id.strip()
    ):
        raise InstallError("merge_retirement.retired.source_id 必须是规范非空字符串")
    if (
        not isinstance(retired_skill_md_sha256, str)
        or not SHA256_HEX.fullmatch(retired_skill_md_sha256)
    ):
        raise InstallError("merge_retirement.retired.skill_md_sha256 必须是 SHA-256")
    if retired_name.casefold() == names[0].casefold():
        raise InstallError("merge retirement 的退役 skill 不能是本次 update 目标")

    raw_survivors = raw.get("survivors")
    if not isinstance(raw_survivors, list) or not raw_survivors:
        raise InstallError("merge_retirement.survivors 必须是非空数组")
    survivors: list[dict[str, str]] = []
    seen_survivors: set[str] = set()
    for index, item in enumerate(raw_survivors):
        if not isinstance(item, dict) or set(item) != {"name", "skill_md_sha256"}:
            raise InstallError(
                f"merge_retirement.survivors[{index}] 必须精确包含 name、skill_md_sha256"
            )
        survivor_name = item.get("name")
        survivor_sha256 = item.get("skill_md_sha256")
        if not isinstance(survivor_name, str) or not SAFE_SKILL_NAME.fullmatch(
            survivor_name
        ):
            raise InstallError(
                f"merge_retirement.survivors[{index}].name 不是合法 skill name"
            )
        if (
            not isinstance(survivor_sha256, str)
            or not SHA256_HEX.fullmatch(survivor_sha256)
        ):
            raise InstallError(
                f"merge_retirement.survivors[{index}].skill_md_sha256 必须是 SHA-256"
            )
        survivor_key = survivor_name.casefold()
        if survivor_key in seen_survivors:
            raise InstallError(f"merge_retirement survivor 重复：{survivor_name}")
        if survivor_key == retired_name.casefold():
            raise InstallError("merge_retirement survivor 不能同时是退役 skill")
        seen_survivors.add(survivor_key)
        survivors.append(
            {
                "name": survivor_name,
                "skill_md_sha256": survivor_sha256.casefold(),
            }
        )
    if names[0].casefold() not in seen_survivors:
        raise InstallError("merge_retirement.survivors 必须包含本次 update 目标")

    reason = raw.get("reason")
    if (
        not isinstance(reason, str)
        or not reason.strip()
        or reason != reason.strip()
        or any(not character.isprintable() for character in reason)
    ):
        raise InstallError("merge_retirement.reason 必须是规范可打印非空字符串")
    source = decision.get("source")
    if (
        not isinstance(source, dict)
        or not isinstance(source.get("id"), str)
        or not source["id"].strip()
    ):
        raise InstallError("merge retirement 必须提供 survivor source.id")
    if source["id"] == retired_source_id:
        raise InstallError("merge retirement 必须绑定不同来源的 survivor 与 retired skill")
    return {
        "survivor_source_id": source["id"],
        "retired": {
            "name": retired_name,
            "source_id": retired_source_id,
            "skill_md_sha256": retired_skill_md_sha256.casefold(),
            "tree_seal": normalize_tree_seal(
                retired.get("tree_seal"),
                label="merge_retirement.retired.tree_seal",
            ),
        },
        "survivors": survivors,
        "reason": reason,
    }


def validate_merge_retirement_state(
    *,
    args: argparse.Namespace,
    active_root: Path,
    ledger: dict[str, Any],
    names: list[str],
    retirement: dict[str, Any],
) -> None:
    retired = retirement["retired"]
    retired_name = retired["name"]
    retired_active = _base.d_path(
        active_root / retired_name,
        label="merge retirement 退役 active skill",
        must_exist=True,
    )
    if _base.is_reparse(retired_active) or not retired_active.is_dir():
        raise InstallError("merge retirement 退役 active skill 不是安全目录")
    _base.ensure_tree_no_reparse(retired_active, label="merge retirement 退役 active skill")
    actual_retired_name = _payload.read_skill_name(retired_active / "SKILL.md")
    if actual_retired_name != retired_name:
        raise InstallError("merge retirement 退役 active frontmatter name 不一致")
    actual_retired_sha256 = _base.sha256_file(retired_active / "SKILL.md")
    if actual_retired_sha256 != retired["skill_md_sha256"]:
        raise InstallError("merge retirement 退役 active SKILL.md 哈希漂移")
    _tree.verify_tree_seal(
        retired_active,
        seal=retired["tree_seal"],
        label="merge retirement 退役 active skill",
    )
    source_md = retired_active / "SOURCE.md"
    if not source_md.is_file() or _base.is_reparse(source_md):
        raise InstallError("merge retirement 退役 active skill 缺少安全 SOURCE.md")
    recorded_skill = _source_record.source_record_unique_value(
        source_md,
        ("Skill",),
        label="merge retirement 退役 active skill",
    )
    if recorded_skill != retired_name:
        raise InstallError("merge retirement 退役 active SOURCE.md identity 不一致")

    if not isinstance(ledger, dict):
        raise InstallError("source ledger 顶层必须是 JSON 对象")
    live_matches: list[tuple[str, dict[str, Any]]] = []
    for section in ("sources", "unresolved"):
        entries = ledger.get(section)
        if not isinstance(entries, list):
            raise InstallError(f"source ledger 的 {section} 必须是数组")
        for entry in entries:
            if _ledger.ledger_entry_covers(entry, retired_name):
                if not isinstance(entry, dict):
                    raise InstallError("merge retirement ledger coverage 不合法")
                live_matches.append((section, entry))
    if len(live_matches) != 1 or live_matches[0][0] != "sources":
        raise InstallError(
            "merge retirement 退役 skill 必须由唯一 sources ledger entry 覆盖"
        )
    source_entry = live_matches[0][1]
    if source_entry.get("id") != retired["source_id"]:
        raise InstallError("merge retirement 退役 skill 的 ledger source id 不一致")
    source_id_matches = [
        entry
        for entry in ledger["sources"]
        if isinstance(entry, dict) and entry.get("id") == retired["source_id"]
    ]
    if len(source_id_matches) != 1 or source_id_matches[0] is not source_entry:
        raise InstallError("merge retirement 退役 source id 必须唯一")

    survivor_source_id = retirement.get("survivor_source_id")
    if not isinstance(survivor_source_id, str) or not survivor_source_id:
        raise InstallError("merge retirement 缺少 survivor source id")
    target_name = names[0]
    target_live_matches: list[tuple[str, dict[str, Any]]] = []
    for section in ("sources", "unresolved"):
        for entry in ledger[section]:
            if _ledger.ledger_entry_covers(entry, target_name):
                if not isinstance(entry, dict):
                    raise InstallError("merge retirement update 目标 ledger coverage 不合法")
                target_live_matches.append((section, entry))
    if len(target_live_matches) != 1 or target_live_matches[0][0] != "sources":
        raise InstallError(
            "merge retirement update 目标必须由唯一 sources ledger entry 覆盖"
        )
    target_source_entry = target_live_matches[0][1]
    if target_source_entry.get("id") != survivor_source_id:
        raise InstallError("merge retirement survivor ledger source id 不一致")
    survivor_source_id_matches = [
        entry
        for entry in ledger["sources"]
        if isinstance(entry, dict) and entry.get("id") == survivor_source_id
    ]
    if (
        len(survivor_source_id_matches) != 1
        or survivor_source_id_matches[0] is not target_source_entry
    ):
        raise InstallError("merge retirement survivor source id 必须唯一")

    candidate = _base.d_path(
        args.candidate,
        label="merge retirement survivor candidate",
        must_exist=True,
    )
    target_active = _base.d_path(
        active_root / target_name,
        label="merge retirement update 目标",
        must_exist=True,
    )
    if _base.is_reparse(target_active) or not target_active.is_dir():
        raise InstallError("merge retirement update 目标不是安全 active skill")
    for survivor in retirement["survivors"]:
        survivor_name = survivor["name"]
        if survivor_name == target_name:
            survivor_root = candidate
            label = "merge retirement survivor candidate"
        else:
            survivor_root = _base.d_path(
                active_root / survivor_name,
                label=f"merge retirement survivor {survivor_name}",
                must_exist=True,
            )
            label = f"merge retirement survivor {survivor_name}"
        if _base.is_reparse(survivor_root) or not survivor_root.is_dir():
            raise InstallError(f"{label} 不是安全目录")
        _base.ensure_tree_no_reparse(survivor_root, label=label)
        if _payload.read_skill_name(survivor_root / "SKILL.md") != survivor_name:
            raise InstallError(f"{label} frontmatter name 不一致")
        if _base.sha256_file(survivor_root / "SKILL.md") != survivor["skill_md_sha256"]:
            raise InstallError(f"{label} SKILL.md 哈希漂移")


def verify_merge_retirement_postcondition(
    *,
    active_root: Path,
    ledger: dict[str, Any],
    catalog_path: Path,
    retirement: dict[str, Any],
) -> dict[str, Any]:
    retired = retirement["retired"]
    retired_name = retired["name"]
    retired_active = _base.d_path(
        active_root / retired_name,
        label="merge retirement 退役 active skill",
    )
    if _base.path_exists_strict(retired_active, label="merge retirement 退役 active skill"):
        raise InstallError("merge retirement 后退役 active skill 仍然存在")

    live_coverage: list[str] = []
    for section in ("sources", "unresolved"):
        entries = ledger.get(section)
        if not isinstance(entries, list):
            raise InstallError(f"source ledger 的 {section} 必须是数组")
        for entry in entries:
            if _ledger.ledger_entry_covers(entry, retired_name):
                live_coverage.append(section)
    if live_coverage:
        raise InstallError(
            "merge retirement 后 ledger 仍有 live coverage："
            + ", ".join(live_coverage)
        )
    expected_survivors = [item["name"] for item in retirement["survivors"]]
    deleted_entries = ledger.get("deleted")
    if not isinstance(deleted_entries, list):
        raise InstallError("source ledger 的 deleted 必须是数组")
    deleted_matches = [
        entry
        for entry in deleted_entries
        if isinstance(entry, dict)
        and entry.get("name") == retired_name
        and entry.get("status") == "deleted-by-user"
        and entry.get("reason") == retirement["reason"]
        and entry.get("source_id") == retired["source_id"]
        and entry.get("survivors") == expected_survivors
        and entry.get("skill_md_sha256") == retired["skill_md_sha256"]
        and entry.get("tree_seal") == retired["tree_seal"]
    ]
    if len(deleted_matches) != 1:
        raise InstallError("merge retirement 后 ledger deleted 记录不唯一或不完整")

    retired_source_matches = [
        entry
        for entry in ledger["sources"]
        if isinstance(entry, dict) and entry.get("id") == retired["source_id"]
    ]
    if len(retired_source_matches) != 1:
        raise InstallError("merge retirement 后 retired source id 不唯一")
    retired_source = retired_source_matches[0]
    source_deleted_skills = retired_source.get("deleted_skills")
    if not isinstance(source_deleted_skills, list):
        raise InstallError("merge retirement 后 retired source 缺少 deleted_skills")
    source_deleted_matches = [
        entry
        for entry in source_deleted_skills
        if isinstance(entry, dict)
        and entry.get("name") == retired_name
        and entry.get("status") == "deleted-by-user"
        and entry.get("reason") == retirement["reason"]
        and entry.get("source_id") == retired["source_id"]
        and entry.get("survivors") == expected_survivors
        and entry.get("skill_md_sha256") == retired["skill_md_sha256"]
        and entry.get("tree_seal") == retired["tree_seal"]
    ]
    if len(source_deleted_matches) != 1:
        raise InstallError(
            "merge retirement 后 retired source.deleted_skills 记录不唯一或不完整"
        )

    survivor_results: list[dict[str, str]] = []
    for survivor in retirement["survivors"]:
        survivor_root = _base.d_path(
            active_root / survivor["name"],
            label=f"merge retirement survivor {survivor['name']}",
            must_exist=True,
        )
        if _base.is_reparse(survivor_root) or not survivor_root.is_dir():
            raise InstallError(
                f"merge retirement survivor 不是安全目录：{survivor['name']}"
            )
        actual = _base.sha256_file(survivor_root / "SKILL.md")
        if actual != survivor["skill_md_sha256"]:
            raise InstallError(
                f"merge retirement survivor SKILL.md 哈希漂移：{survivor['name']}"
            )
        survivor_results.append(
            {"name": survivor["name"], "skill_md_sha256": actual}
        )

    catalog = _base.load_json(catalog_path, label="skill catalog")
    artifacts = catalog.get("artifacts") if isinstance(catalog, dict) else None
    if not isinstance(artifacts, list):
        raise InstallError("skill catalog 缺少 artifacts 数组")
    retired_catalog_entries = [
        artifact
        for artifact in artifacts
        if isinstance(artifact, dict)
        and artifact.get("scope") == "active"
        and (
            artifact.get("name") == retired_name
            or artifact.get("relative_path") == f"{retired_name}/SKILL.md"
        )
    ]
    if retired_catalog_entries:
        raise InstallError("merge retirement 后 catalog 仍含退役 active skill")
    for survivor in survivor_results:
        survivor_entries = [
            artifact
            for artifact in artifacts
            if isinstance(artifact, dict)
            and artifact.get("scope") == "active"
            and artifact.get("name") == survivor["name"]
            and artifact.get("relative_path") == f"{survivor['name']}/SKILL.md"
        ]
        if len(survivor_entries) != 1:
            raise InstallError(
                f"merge retirement survivor catalog 条目数量不是 1：{survivor['name']}"
            )
        artifact = survivor_entries[0]
        if artifact.get("ledger_coverage") != "pass":
            raise InstallError(
                f"merge retirement survivor ledger coverage 不是 pass：{survivor['name']}"
            )
        if (
            artifact.get("integrity", {}).get("skill_md_sha256")
            != survivor["skill_md_sha256"]
        ):
            raise InstallError(
                f"merge retirement survivor catalog 哈希不一致：{survivor['name']}"
            )
    return {
        "retired": {
            "name": retired_name,
            "source_id": retired["source_id"],
            "skill_md_sha256": retired["skill_md_sha256"],
            "tree_seal": retired["tree_seal"],
            "active_absent": True,
            "catalog_absent": True,
            "ledger_live_coverage_absent": True,
            "source_deleted_skills_recorded": True,
        },
        "survivors": survivor_results,
        "backup_cleanup": "required-after-transaction-success",
    }
