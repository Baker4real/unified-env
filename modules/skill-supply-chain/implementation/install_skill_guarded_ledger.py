"""Unified source ledger updates, the staging ledger and the group checkpoint guard.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import re
from typing import Any, Sequence

import install_skill_guarded_base as _base
from install_skill_guarded_base import InstallError
from install_skill_guarded_bundled import BundledSkillProof


def entry_name(entry: Any) -> str | None:
    if isinstance(entry, dict):
        values = [
            value
            for key in ("name", "skill")
            if isinstance((value := entry.get(key)), str) and value
        ]
        if len(set(values)) > 1:
            raise InstallError(f"source ledger direct coverage 字段冲突：{values!r}")
        return values[0] if values else None
    if isinstance(entry, str):
        return entry
    return None


def ledger_entry_covers(entry: Any, name: str) -> bool:
    if not isinstance(entry, dict):
        return False
    expected_name = name.casefold()
    direct_name = entry_name(entry)
    if isinstance(direct_name, str) and direct_name.casefold() == expected_name:
        return True
    skills = entry.get("skills")
    return isinstance(skills, list) and any(
        isinstance(skill, str) and skill.casefold() == expected_name
        for skill in skills
    )


GIT_COMMIT_PREFIX = re.compile(r"^[0-9a-f]{7,40}$")


def checkpoint_matches(recorded: Any, commit: str) -> bool:
    """Treat ledger checkpoints as equal by exact text or a shared hex-hash prefix.

    Older ledger values keep 10-character short hashes, so a full hash and its
    prefix name the same upstream commit.
    """
    if not isinstance(recorded, str) or not recorded.strip():
        return False
    left = recorded.strip().casefold()
    right = commit.strip().casefold()
    if left == right:
        return True
    return bool(
        GIT_COMMIT_PREFIX.fullmatch(left)
        and GIT_COMMIT_PREFIX.fullmatch(right)
        and (left.startswith(right) or right.startswith(left))
    )


def find_ledger_source(
    sources: Sequence[Any],
    *,
    source_id: str,
    repo: str | None,
    match_repo: bool,
) -> dict[str, Any] | None:
    """Return the ledger source entry a transaction writes to: by id, else by repo."""
    for entry in sources:
        if isinstance(entry, dict) and entry.get("id") == source_id:
            return entry
    if match_repo and repo:
        for entry in sources:
            if isinstance(entry, dict) and _base.normalize_repo(entry.get("repo")) == _base.normalize_repo(repo):
                return entry
    return None


def validate_group_checkpoint_advance(
    ledger: Any,
    *,
    names: Sequence[str],
    context: dict[str, Any],
) -> None:
    """Fail closed before a partial-group transaction moves the group checkpoint.

    ``last_checked_commit``/``catalog_ref`` record that the whole source group is
    aligned with upstream at that commit.  A transaction may move them only when
    it covers every skill in the group, or when the decision sets
    ``source.advance_group_checkpoint`` after checking the whole group.
    """
    commit = context.get("commit")
    if not commit or context.get("advance_group_checkpoint"):
        return
    if not isinstance(ledger, dict) or not isinstance(ledger.get("sources"), list):
        raise InstallError("source ledger 的 sources 不是数组，无法核对组级检查点")
    merge_retirement = context.get("merge_retirement")
    group = find_ledger_source(
        ledger["sources"],
        source_id=str(context["source_id"]),
        repo=context.get("repo"),
        match_repo=not isinstance(merge_retirement, dict),
    )
    if group is None:
        return
    managed_roots = {name.casefold() for name in names}
    rename = context.get("canonical_rename")
    if isinstance(rename, dict) and isinstance(rename.get("old_name"), str):
        managed_roots.add(rename["old_name"].casefold())
    if isinstance(merge_retirement, dict):
        retired = merge_retirement.get("retired")
        if isinstance(retired, dict) and isinstance(retired.get("name"), str):
            managed_roots.add(retired["name"].casefold())
    group_skills = group.get("skills")
    others = sorted(
        skill
        for skill in (group_skills if isinstance(group_skills, list) else [])
        if isinstance(skill, str)
        and not any(
            skill.casefold() == root or skill.casefold().startswith(f"{root}/")
            for root in managed_roots
        )
    )
    if not others:
        return
    recorded = group.get("last_checked_commit") or group.get("catalog_ref")
    if checkpoint_matches(recorded, str(commit)):
        return
    shown = "、".join(others[:5]) + (" 等" if len(others) > 5 else "")
    if isinstance(rename, dict):
        remedy = (
            "canonical rename 必须带 commit：先按这个 commit 核对整组，"
            '再在 source 里写 "advance_group_checkpoint": true。'
        )
    else:
        remedy = (
            "只改本机 overlay 时从 source 删掉 commit、catalog_ref 和 revision；"
            '已按这个 commit 核对过整组时，在 source 里写 "advance_group_checkpoint": true。'
        )
    raise InstallError(
        f"source.commit {commit} 会把来源组 {group.get('id') or context['source_id']} 的上游检查点"
        f"从 {recorded or '（未记录）'} 推进过去，但组内另有 {len(others)} 个 skill 不在本事务里"
        f"（{shown}）。{remedy}"
    )


def update_ledger(
    data: dict[str, Any],
    *,
    names: list[str],
    context: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise InstallError("source ledger 顶层必须是 JSON 对象")
    for key in ("sources", "unresolved", "deleted"):
        if key not in data:
            data[key] = []
        if not isinstance(data[key], list):
            raise InstallError(f"source ledger 的 {key} 必须是数组")

    rename = context.get("canonical_rename")
    merge_retirement = context.get("merge_retirement")
    if isinstance(rename, dict) and isinstance(merge_retirement, dict):
        raise InstallError("ledger context 不能同时包含 canonical rename 和 merge retirement")
    retired_names: list[str] = []
    if isinstance(rename, dict):
        old_name = rename.get("old_name")
        new_name = rename.get("new_name")
        source_id = rename.get("source_id")
        if (
            not isinstance(old_name, str)
            or not isinstance(new_name, str)
            or not isinstance(source_id, str)
            or names != [new_name]
        ):
            raise InstallError("canonical rename ledger context 不合法")
        retired_names.append(old_name)
    if isinstance(merge_retirement, dict):
        retired = merge_retirement.get("retired")
        survivors = merge_retirement.get("survivors")
        if (
            not isinstance(retired, dict)
            or not isinstance(retired.get("name"), str)
            or not isinstance(retired.get("source_id"), str)
            or not isinstance(survivors, list)
            or not all(
                isinstance(item, dict)
                and isinstance(item.get("name"), str)
                and isinstance(item.get("skill_md_sha256"), str)
                for item in survivors
            )
            or names[0] not in [item["name"] for item in survivors]
        ):
            raise InstallError("merge retirement ledger context 不合法")
        retired_names.append(retired["name"])

    bundled_proofs = context.get("bundled_skill_proofs", ())
    if (
        not isinstance(bundled_proofs, tuple)
        or not all(isinstance(proof, BundledSkillProof) for proof in bundled_proofs)
    ):
        raise InstallError("bundled skill ledger context 不合法")
    bundled_names = [proof.ledger_key for proof in bundled_proofs]

    managed_roots = set([*names, *retired_names])
    coverage_names = [*names, *bundled_names]

    def is_managed_name(value: Any) -> bool:
        if not isinstance(value, str):
            return False
        normalized_value = value.casefold()
        return any(
            normalized_value == root.casefold()
            or normalized_value.startswith(f"{root.casefold()}/")
            for root in managed_roots
        )

    for key in ("unresolved", "deleted"):
        data[key] = [entry for entry in data[key] if not is_managed_name(entry_name(entry))]
    for entry in data["sources"]:
        if not isinstance(entry, dict):
            continue
        direct_name = entry_name(entry)
        if is_managed_name(direct_name):
            for direct_key in ("name", "skill"):
                if entry.get(direct_key) == direct_name:
                    entry.pop(direct_key)
            entry.setdefault("skills", [])
        skills = entry.get("skills")
        if isinstance(skills, list):
            entry["skills"] = [skill for skill in skills if not is_managed_name(skill)]
        existing_bundled = entry.get("bundled_skills")
        if existing_bundled is not None:
            if not isinstance(existing_bundled, list):
                raise InstallError("source ledger bundled_skills 不是数组")
            retained_bundled = [
                item
                for item in existing_bundled
                if not (
                    isinstance(item, dict)
                    and is_managed_name(item.get("path"))
                )
            ]
            if retained_bundled:
                entry["bundled_skills"] = retained_bundled
            else:
                entry.pop("bundled_skills", None)

    source_id = str(context["source_id"])
    source_repo = context["repo"]
    target_source = find_ledger_source(
        data["sources"],
        source_id=source_id,
        repo=source_repo,
        match_repo=not isinstance(merge_retirement, dict),
    )

    if target_source is None:
        target_source = {
            "id": source_id,
            "type": context["source_type"],
            "repo": source_repo or "local candidate",
            "ref": context["ref"],
            "skills": [],
            "status": "installed-by-guarded-wrapper",
            "local_changes": [],
        }
        data["sources"].append(target_source)
    target_source.setdefault("id", source_id)
    target_source.setdefault("type", context["source_type"])
    if source_repo:
        target_source["repo"] = source_repo
    if context["ref"]:
        target_source["ref"] = context["ref"]
    if context["commit"]:
        target_source["last_checked_commit"] = context["commit"]
        target_source["catalog_ref"] = context["commit"]
    target_source["last_guarded_install"] = _base.utc_now()
    target_source.setdefault("status", "installed-by-guarded-wrapper")
    for field, value in context.get("ledger_updates", {}).items():
        target_source[field] = value
    skills = target_source.setdefault("skills", [])
    if not isinstance(skills, list):
        raise InstallError(f"source ledger source.skills 不是数组：{source_id}")
    for name in coverage_names:
        if name not in skills:
            skills.append(name)
    existing_bundled = target_source.get("bundled_skills", [])
    if not isinstance(existing_bundled, list):
        raise InstallError(f"source ledger bundled_skills 不是数组：{source_id}")
    retained_bundled = [
        item
        for item in existing_bundled
        if not (
            isinstance(item, dict)
            and is_managed_name(item.get("path"))
        )
    ]
    retained_bundled.extend(proof.ledger_projection() for proof in bundled_proofs)
    if retained_bundled:
        target_source["bundled_skills"] = retained_bundled
    else:
        target_source.pop("bundled_skills", None)
    if retired_names:
        if isinstance(rename, dict):
            data["deleted"].append(
                {
                    "name": retired_names[0],
                    "status": "moved",
                    "reason": "canonical rename",
                    "new_name": names[0],
                    "source_id": context["source_id"],
                    "date": _base.today(),
                }
            )
        else:
            assert isinstance(merge_retirement, dict)
            retired = merge_retirement["retired"]
            survivor_names = [item["name"] for item in merge_retirement["survivors"]]
            deleted_record = {
                "name": retired["name"],
                "status": "deleted-by-user",
                "reason": merge_retirement["reason"],
                "survivors": survivor_names,
                "source": retired["source_id"],
                "source_id": retired["source_id"],
                "skill_md_sha256": retired["skill_md_sha256"],
                "tree_seal": retired["tree_seal"],
                "date": _base.today(),
            }
            data["deleted"].append(deleted_record)
            retired_source_matches = [
                entry
                for entry in data["sources"]
                if isinstance(entry, dict) and entry.get("id") == retired["source_id"]
            ]
            if len(retired_source_matches) > 1:
                raise InstallError("merge retirement 退役 source id 在 ledger 中不唯一")
            if retired_source_matches:
                retired_source = retired_source_matches[0]
                deleted_skills = retired_source.setdefault("deleted_skills", [])
                if not isinstance(deleted_skills, list):
                    raise InstallError("merge retirement source.deleted_skills 不是数组")
                deleted_skills.append(dict(deleted_record))
                remaining_skills = retired_source.get("skills")
                if not isinstance(remaining_skills, list):
                    raise InstallError("merge retirement source.skills 不是数组")
                if not remaining_skills:
                    retired_source["status"] = "deleted-by-user"
                    retired_source["retirement_scope"] = [retired["name"]]
    if context["overlay_status"].casefold() not in {"none", "no-change", ""}:
        changes = target_source.setdefault("local_changes", [])
        if not isinstance(changes, list):
            raise InstallError(f"source ledger local_changes 不是数组：{source_id}")
        summary = context["overlay_summary"] or context["overlay_status"]
        marker = f"guarded wrapper: {summary}"
        for name in names:
            if any(
                isinstance(item, dict)
                and item.get("skill") == name
                and item.get("summary") == marker
                for item in changes
            ):
                continue
            legacy_record = next(
                (
                    item
                    for item in changes
                    if isinstance(item, dict)
                    and "skill" not in item
                    and item.get("summary") == marker
                ),
                None,
            )
            if legacy_record is not None:
                legacy_record["skill"] = name
                continue
            changes.append({"skill": name, "date": _base.today(), "summary": marker})
    data["updated_at"] = _base.today()
    return data


def make_staging_ledger(names: list[str], context: dict[str, Any]) -> dict[str, Any]:
    return update_ledger(
        {"updated_at": _base.today(), "notes": [], "sources": [], "unresolved": [], "deleted": []},
        names=names,
        context=context,
    )
