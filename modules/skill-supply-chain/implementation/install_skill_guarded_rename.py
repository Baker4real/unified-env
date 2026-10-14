"""Canonical rename: spec and active-state validation.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import install_skill_guarded_base as _base
import install_skill_guarded_payload as _payload
import install_skill_guarded_source_record as _source_record
import install_skill_guarded_ledger as _ledger
from install_skill_guarded_base import SAFE_SKILL_NAME, InstallError


def canonical_rename_spec(
    *,
    args: argparse.Namespace,
    decision: dict[str, Any],
    names: list[str],
) -> dict[str, Any] | None:
    raw = decision.get("canonical_rename")
    if raw is None:
        return None
    required_fields = {
        "old_name",
        "new_name",
        "source_id",
        "predecessor_source",
        "successor_source",
    }
    if not isinstance(raw, dict) or set(raw) != required_fields:
        raise InstallError(
            "canonical_rename 字段必须精确为 old_name、new_name、source_id、"
            "predecessor_source、successor_source"
        )
    if decision.get("decision") != "update":
        raise InstallError("canonical rename 只允许 decision=update")
    if not args.candidate or len(names) != 1:
        raise InstallError("canonical rename 只支持单个本地 --candidate")
    normalized: dict[str, Any] = {}
    for field in ("old_name", "new_name", "source_id"):
        value = raw.get(field)
        if not isinstance(value, str) or not value.strip():
            raise InstallError(f"canonical_rename.{field} 必须是非空字符串")
        normalized[field] = value.strip()
    for field in ("old_name", "new_name"):
        if not SAFE_SKILL_NAME.fullmatch(normalized[field]):
            raise InstallError(f"canonical_rename.{field} 不是合法 skill name")
    if normalized["old_name"] == normalized["new_name"]:
        raise InstallError("canonical rename 的旧名与新名不能相同")
    if normalized["new_name"] != names[0]:
        raise InstallError("canonical_rename.new_name 与候选目标名不一致")
    if decision.get("skills") != [normalized["new_name"]]:
        raise InstallError(
            "canonical rename manifest.skills 必须显式且唯一包含 successor"
        )
    source = decision.get("source")
    if not isinstance(source, dict):
        raise InstallError("canonical rename 必须提供 source identity")
    if source.get("id") != normalized["source_id"]:
        raise InstallError("canonical_rename.source_id 与 source.id 不一致")
    for field in ("repo", "ref", "commit", "upstream_path"):
        if not isinstance(source.get(field), str) or not source[field].strip():
            raise InstallError(f"canonical rename 必须提供 source.{field}")

    for identity_name in ("predecessor_source", "successor_source"):
        identity = raw.get(identity_name)
        if not isinstance(identity, dict) or set(identity) != {
            "upstream_path",
            "ref",
            "commit",
        }:
            raise InstallError(
                f"canonical_rename.{identity_name} 必须精确包含 "
                "upstream_path、ref、commit"
            )
        normalized_identity: dict[str, str] = {}
        for field in ("upstream_path", "ref", "commit"):
            value = identity.get(field)
            if not isinstance(value, str) or not value.strip():
                raise InstallError(
                    f"canonical_rename.{identity_name}.{field} 必须是非空字符串"
                )
            normalized_identity[field] = value.strip()
        normalized[identity_name] = normalized_identity

    expected_successor = {
        "upstream_path": source["upstream_path"].strip(),
        "ref": source["ref"].strip(),
        "commit": source["commit"].strip(),
    }
    if normalized["successor_source"] != expected_successor:
        raise InstallError(
            "canonical_rename.successor_source 必须与顶层 source 的 path/ref/commit 一致"
        )
    return normalized


def validate_canonical_rename_state(
    *,
    args: argparse.Namespace,
    active_root: Path,
    ledger: dict[str, Any],
    context: dict[str, Any],
    rename: dict[str, Any],
) -> None:
    old_name = rename["old_name"]
    new_name = rename["new_name"]
    repository = context.get("repo")
    if not isinstance(repository, str) or not repository:
        raise InstallError("canonical rename 缺少可验证的 GitHub source repository")
    if context.get("source_id") != rename["source_id"]:
        raise InstallError("canonical rename 的 source identity 与事务 context 不一致")
    source_paths = context.get("source_paths")
    if (
        not isinstance(source_paths, list)
        or len(source_paths) != 1
        or not isinstance(source_paths[0], str)
    ):
        raise InstallError("canonical rename 必须绑定唯一 upstream path")
    successor_source = rename.get("successor_source")
    predecessor_source = rename.get("predecessor_source")
    if not isinstance(successor_source, dict) or not isinstance(
        predecessor_source, dict
    ):
        raise InstallError("canonical rename 缺少 predecessor/successor source identity")
    expected_successor_path = source_paths[0]
    expected_successor_ref = context.get("ref")
    expected_successor_commit = context.get("commit")
    if not isinstance(expected_successor_ref, str) or not expected_successor_ref:
        raise InstallError("canonical rename 缺少 source ref")
    if not isinstance(expected_successor_commit, str) or not expected_successor_commit:
        raise InstallError("canonical rename 缺少 source commit")
    context_successor = {
        "upstream_path": expected_successor_path,
        "ref": expected_successor_ref,
        "commit": expected_successor_commit,
    }
    if successor_source != context_successor:
        raise InstallError(
            "canonical rename successor identity 与事务 source context 不一致"
        )

    candidate = _base.d_path(args.candidate, label="canonical rename candidate", must_exist=True)
    _base.ensure_tree_no_reparse(candidate, label="canonical rename candidate")
    candidate_name = _payload.read_skill_name(candidate / "SKILL.md")
    if candidate_name != new_name:
        raise InstallError(
            f"canonical rename candidate name 不一致：{candidate_name!r} != {new_name!r}"
        )
    _source_record.validate_source_record_identity(
        candidate / "SOURCE.md",
        skill_name=new_name,
        repository=repository,
        label="candidate",
    )
    candidate_source = candidate / "SOURCE.md"
    candidate_predecessor = _source_record.source_record_unique_value(
        candidate_source,
        ("Canonical predecessor",),
        label="candidate",
    )
    candidate_source_id = _source_record.source_record_unique_value(
        candidate_source,
        ("Source identity",),
        label="candidate",
    )
    candidate_upstream_path = _source_record.source_record_unique_value(
        candidate_source,
        ("Upstream path",),
        label="candidate",
    )
    candidate_ref = _source_record.source_record_unique_value(
        candidate_source,
        ("Ref",),
        label="candidate",
    )
    candidate_commit = _source_record.source_record_unique_value(
        candidate_source,
        ("Commit or revision", "Reference commit"),
        label="candidate",
    )
    expected_candidate_identity = {
        "canonical_predecessor": old_name,
        "source_identity": rename["source_id"],
        "upstream_path": successor_source["upstream_path"],
        "ref": successor_source["ref"],
        "commit": successor_source["commit"],
    }
    actual_candidate_identity = {
        "canonical_predecessor": candidate_predecessor,
        "source_identity": candidate_source_id,
        "upstream_path": candidate_upstream_path,
        "ref": candidate_ref,
        "commit": candidate_commit,
    }
    if actual_candidate_identity != expected_candidate_identity:
        raise InstallError(
            "candidate SOURCE.md 的 canonical source identity 不一致："
            + json.dumps(
                {
                    "expected": expected_candidate_identity,
                    "actual": actual_candidate_identity,
                },
                ensure_ascii=False,
            )
        )

    old_active = _base.d_path(
        active_root / old_name,
        label="canonical rename 旧 active skill",
        must_exist=True,
    )
    new_active = _base.d_path(active_root / new_name, label="canonical rename 新 active skill")
    if not _base.path_exists_strict(old_active, label="canonical rename 旧 active skill"):
        raise InstallError(f"canonical rename 旧 active skill 不存在：{old_active}")
    if _base.is_reparse(old_active) or not old_active.is_dir():
        raise InstallError(f"canonical rename 旧 active skill 不是安全目录：{old_active}")
    _base.ensure_tree_no_reparse(old_active, label="canonical rename 旧 active skill")
    if _base.path_exists_strict(new_active, label="canonical rename 新 active skill"):
        raise InstallError(f"canonical rename 新 active skill 已存在：{new_active}")
    actual_old_name = _payload.read_skill_name(old_active / "SKILL.md")
    if actual_old_name != old_name:
        raise InstallError(
            f"canonical rename 旧 active name 不一致：{actual_old_name!r} != {old_name!r}"
        )
    _source_record.validate_source_record_identity(
        old_active / "SOURCE.md",
        skill_name=old_name,
        repository=repository,
        label="旧 active skill",
    )
    old_source = old_active / "SOURCE.md"
    old_upstream_path = _source_record.source_record_unique_value(
        old_source,
        ("Upstream path",),
        label="旧 active skill",
    )
    old_ref = _source_record.source_record_unique_value(
        old_source,
        ("Ref",),
        label="旧 active skill",
    )
    old_commit = _source_record.source_record_unique_value(
        old_source,
        ("Commit or revision", "Reference commit"),
        label="旧 active skill",
    )
    if (
        old_upstream_path != predecessor_source["upstream_path"]
        or old_ref != predecessor_source["ref"]
        or old_commit != predecessor_source["commit"]
    ):
        raise InstallError(
            "旧 active SOURCE.md 与 canonical predecessor source identity 不一致"
        )

    if not isinstance(ledger, dict):
        raise InstallError("source ledger 顶层必须是 JSON 对象")
    live_matches: list[tuple[str, dict[str, Any]]] = []
    for section in ("sources", "unresolved"):
        entries = ledger.get(section, [])
        if not isinstance(entries, list):
            raise InstallError(f"source ledger 的 {section} 必须是数组")
        for entry in entries:
            if _ledger.ledger_entry_covers(entry, old_name):
                if not isinstance(entry, dict):
                    raise InstallError("canonical rename 旧名 ledger coverage 不合法")
                live_matches.append((section, entry))
            if _ledger.ledger_entry_covers(entry, new_name):
                raise InstallError("canonical rename 新名已存在 live ledger coverage")
    if len(live_matches) != 1 or live_matches[0][0] != "sources":
        raise InstallError("canonical rename 旧名必须由唯一 sources ledger entry 覆盖")
    source_entry = live_matches[0][1]
    if source_entry.get("id") != rename["source_id"]:
        raise InstallError("canonical rename 旧名 ledger source id 不一致")
    source_id_matches = [
        entry
        for entry in ledger["sources"]
        if isinstance(entry, dict) and entry.get("id") == rename["source_id"]
    ]
    if len(source_id_matches) != 1 or source_id_matches[0] is not source_entry:
        raise InstallError(
            "canonical rename source id 必须唯一绑定旧名 ledger source entry"
        )
    if _base.normalize_repo(source_entry.get("repo")) != _base.normalize_repo(repository):
        raise InstallError("canonical rename 旧名 ledger source repo 不一致")
    if source_entry.get("ref") != predecessor_source["ref"]:
        raise InstallError("canonical rename 旧名 ledger source ref 不一致")
