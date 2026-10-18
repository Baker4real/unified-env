"""Decision manifest validation, target layout, ledger updates and source context.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import re
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

from system_skill_provenance_repair import (
    SystemProvenanceRepairError,
    validate_skill_creator_compatibility_overlay,
)
import install_skill_guarded_base as _base
from install_skill_guarded_base import REPO_NAME, SAFE_SKILL_NAME, InstallError


TARGET_SCOPES = frozenset({"active", "system"})


def github_repo_url(value: str | None) -> str | None:
    if not value:
        return None
    if REPO_NAME.fullmatch(value):
        return f"https://github.com/{value.removesuffix('.git')}"
    parsed = urlparse(value)
    if parsed.netloc.casefold() != "github.com":
        raise InstallError(f"source repository 必须是 GitHub 或 owner/repo：{value}")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise InstallError("source repository URL 不得包含用户信息、query 或 fragment")
    path = parsed.path.strip("/")
    if not path or path.count("/") != 1:
        raise InstallError(f"无法解析 GitHub repository：{value}")
    return f"https://github.com/{path.removesuffix('.git')}"


def parse_github_url(url: str) -> tuple[str, str]:
    parsed = urlparse(url)
    if parsed.netloc.casefold() != "github.com":
        raise InstallError(f"安装 URL 必须来自 github.com：{url}")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise InstallError("安装 URL 不得包含用户信息、query 或 fragment")
    parts = [unquote(part) for part in parsed.path.strip("/").split("/") if part]
    for marker in ("tree", "blob"):
        if marker in parts:
            index = parts.index(marker)
            if index + 2 >= len(parts):
                break
            path = "/".join(parts[index + 2 :])
            if path:
                return path, parts[index + 1]
    raise InstallError(f"URL 未包含可安装的 GitHub skill path：{url}")


def validate_decision_manifest(path: Path) -> dict[str, Any]:
    data = _base.load_json(path, label="guard decision manifest")
    if not isinstance(data, dict):
        raise InstallError("guard decision manifest 顶层必须是 JSON 对象")
    decision = data.get("decision")
    if decision not in {"install", "update"}:
        raise InstallError("guard decision manifest 的 decision 必须是 install 或 update")
    source_status = data.get("source_status")
    if source_status is None and isinstance(data.get("source"), dict):
        source_status = data["source"].get("status")
    if source_status not in {"source-pass", "source-review"}:
        raise InstallError(
            "guard decision manifest 必须包含 source-pass 或 source-review；"
            f"当前为 {source_status!r}"
        )
    if "writing_great_skills" in data:
        raise InstallError(
            "guard decision manifest 不得使用已退役的 writing_great_skills 字段；"
            "请改用 writing_for_agents（writing-for-agents gate）"
        )
    writing_gate = data.get("writing_for_agents")
    if isinstance(writing_gate, dict):
        gate_status = writing_gate.get("status")
    else:
        gate_status = writing_gate
    if gate_status not in {"pass", "passed", "no-change", "compliant"}:
        raise InstallError(
            "guard decision manifest 必须证明 writing-for-agents 已通过或无需修改"
        )
    target_scope = data.get("target_scope", "active")
    if target_scope not in TARGET_SCOPES:
        raise InstallError(
            "guard decision manifest 的 target_scope 必须是 active 或 system"
        )
    overlay = data.get("system_provenance_overlay")
    if overlay is not None:
        if target_scope != "system" or decision != "update":
            raise InstallError(
                "system_provenance_overlay 只允许绑定 system scope 的 skill-creator update"
            )
        source = data.get("source")
        if not isinstance(source, dict) or source.get("id") != "codex-bundled-system-skills":
            raise InstallError(
                "system_provenance_overlay 必须绑定 codex-bundled-system-skills source"
            )
        try:
            validate_skill_creator_compatibility_overlay(overlay)
        except SystemProvenanceRepairError as exc:
            raise InstallError(str(exc)) from exc
    return data


def target_layout(
    active_root: Path,
    *,
    names: list[str],
    decision: dict[str, Any],
) -> tuple[str, Path, list[str]]:
    scope = str(decision.get("target_scope", "active"))
    if scope == "active":
        return scope, active_root, list(names)
    target_root = _base.d_path(
        active_root / ".system",
        label="system skill root",
        must_exist=True,
    )
    if _base.is_reparse(target_root) or not target_root.is_dir():
        raise InstallError(f"system skill root 必须是安全目录：{target_root}")
    return scope, target_root, [f".system/{name}" for name in names]


def target_specs(args: argparse.Namespace) -> list[tuple[str, str]]:
    specs: list[tuple[str, str]] = []
    if args.candidate:
        candidate = _base.d_path(args.candidate, label="candidate", must_exist=True)
        if not candidate.is_dir():
            raise InstallError(f"candidate 必须是目录：{candidate}")
        name = args.name or candidate.name
        specs.append((name, candidate.name))
    elif args.url:
        upstream_path, _ = parse_github_url(args.url)
        specs.append((args.name or Path(upstream_path).name, upstream_path))
    else:
        if not args.repo or not args.paths:
            raise InstallError("远端安装必须同时提供 --repo 和 --path，或使用 --url/--candidate")
        for path in args.paths:
            path = path.strip("/")
            if not path:
                raise InstallError("--path 不能为空")
            specs.append((Path(path).name, path))
        if args.name:
            if len(specs) != 1:
                raise InstallError("多个 --path 不能同时使用 --name")
            specs[0] = (args.name, specs[0][1])

    names = [name for name, _ in specs]
    for name in names:
        if not SAFE_SKILL_NAME.fullmatch(name):
            raise InstallError(f"skill name 非法：{name!r}")
    if len(set(names)) != len(names):
        raise InstallError(f"本次安装包含重复 skill name：{names}")
    return specs


def apply_candidate_upstream_path(
    args: argparse.Namespace,
    decision: dict[str, Any],
    specs: list[tuple[str, str]],
) -> list[tuple[str, str]]:
    if not args.candidate:
        return specs
    source = decision.get("source")
    if not isinstance(source, dict) or source.get("upstream_path") is None:
        return specs
    upstream_path = source["upstream_path"]
    if not isinstance(upstream_path, str) or not upstream_path.strip():
        raise InstallError("source.upstream_path 必须是非空字符串")
    if any(not character.isprintable() for character in upstream_path):
        raise InstallError("source.upstream_path 不能包含不可打印字符")
    upstream_path = upstream_path.strip()
    if upstream_path == ".":
        return [(specs[0][0], upstream_path)]
    parts = upstream_path.split("/")
    if (
        "\\" in upstream_path
        or "`" in upstream_path
        or upstream_path.startswith("/")
        or re.match(r"^[A-Za-z]:", upstream_path)
        or any(not part or part in {".", ".."} for part in parts)
    ):
        raise InstallError("source.upstream_path 必须是仓库内的 POSIX 相对路径")
    return [(specs[0][0], upstream_path)]


LEDGER_UPDATE_FIELDS = {
    "action",
    "installed_version",
    "path",
    "repo_stars",
    "repo_stars_checked_at",
    "resource_paths",
    "status",
    "tag",
}


def is_canonical_ledger_string(value: Any) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and value == value.strip()
        and value.isprintable()
    )


def ledger_updates(source: dict[str, Any]) -> dict[str, Any]:
    """Validate optional source-ledger facts supplied by an update decision."""
    if "ledger_updates" not in source:
        return {}
    raw = source["ledger_updates"]
    if not isinstance(raw, dict):
        raise InstallError("source.ledger_updates 必须是对象")

    unexpected = sorted(set(raw) - LEDGER_UPDATE_FIELDS)
    if unexpected:
        raise InstallError(
            "source.ledger_updates 包含不允许的字段：" + ", ".join(unexpected)
        )

    if ("repo_stars" in raw) != ("repo_stars_checked_at" in raw):
        raise InstallError(
            "source.ledger_updates.repo_stars 与 repo_stars_checked_at 必须成对提供"
        )

    normalized: dict[str, Any] = {}
    for field, value in raw.items():
        if field == "resource_paths":
            if not isinstance(value, list) or not value or not all(
                is_canonical_ledger_string(item) for item in value
            ):
                raise InstallError(
                    "source.ledger_updates.resource_paths 必须是规范的非空字符串数组"
                )
            normalized[field] = list(value)
            continue
        if field == "repo_stars":
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise InstallError(
                    "source.ledger_updates.repo_stars 必须是非负整数"
                )
            normalized[field] = value
            continue
        if field == "repo_stars_checked_at":
            if not isinstance(value, str):
                raise InstallError(
                    "source.ledger_updates.repo_stars_checked_at 必须是 ISO 日期"
                )
            try:
                parsed_date = _datetime.date.fromisoformat(value)
            except ValueError as exc:
                raise InstallError(
                    "source.ledger_updates.repo_stars_checked_at 必须是 ISO 日期"
                ) from exc
            if value != parsed_date.isoformat():
                raise InstallError(
                    "source.ledger_updates.repo_stars_checked_at 必须是 ISO 日期"
                )
            normalized[field] = value
            continue
        if not is_canonical_ledger_string(value):
            raise InstallError(
                f"source.ledger_updates.{field} 必须是规范的非空字符串"
            )
        normalized[field] = value
    return normalized


def source_context(
    args: argparse.Namespace,
    decision: dict[str, Any],
    specs: list[tuple[str, str]],
) -> dict[str, Any]:
    source = decision.get("source") if isinstance(decision.get("source"), dict) else {}
    ledger_update_values = ledger_updates(source)
    repo_value = source.get("repo") or args.repo
    repo_url = None
    if repo_value:
        if REPO_NAME.fullmatch(str(repo_value)) or urlparse(str(repo_value)).netloc:
            repo_url = github_repo_url(str(repo_value))
        elif not args.candidate:
            raise InstallError(f"无法解析 source repository：{repo_value}")
    if args.url and not repo_url:
        parsed = urlparse(args.url)
        repo_parts = [part for part in parsed.path.strip("/").split("/") if part]
        if len(repo_parts) >= 2:
            repo_url = f"https://github.com/{repo_parts[0]}/{repo_parts[1]}"
    source_type = "github" if repo_url else "local-candidate"
    source_id = source.get("id")
    if not isinstance(source_id, str) or not source_id.strip():
        if repo_url:
            source_id = repo_url.removeprefix("https://github.com/").replace("/", "-")
        else:
            source_id = f"local-candidate-{specs[0][0]}"
    ref = source.get("ref") or args.ref or "main"
    commit = source.get("commit") or source.get("catalog_ref") or source.get("revision")
    advance_group_checkpoint = source.get("advance_group_checkpoint", False)
    if not isinstance(advance_group_checkpoint, bool):
        raise InstallError("source.advance_group_checkpoint 必须是布尔值")
    if advance_group_checkpoint and not commit:
        raise InstallError(
            "source.advance_group_checkpoint 需要同时提供 source.commit、catalog_ref 或 revision"
        )
    writing_gate = decision.get("writing_for_agents")
    if isinstance(writing_gate, dict):
        writing_revision = writing_gate.get("revision") or "no-change"
    else:
        writing_revision = "no-change"
    overlay = decision.get("local_overlay")
    if isinstance(overlay, dict):
        overlay_status = overlay.get("status") or "none"
        overlay_summary = overlay.get("summary") or ""
    elif isinstance(overlay, list):
        overlay_status = "replayed"
        overlay_summary = "; ".join(str(item) for item in overlay)
    else:
        overlay_status = "none"
        overlay_summary = ""
    return {
        "decision": decision["decision"],
        "source_status": decision.get("source_status") or source.get("status"),
        "source_id": source_id,
        "source_type": source_type,
        "repo": repo_url,
        "ref": str(ref),
        "commit": str(commit) if commit else None,
        "advance_group_checkpoint": advance_group_checkpoint,
        "writing_revision": str(writing_revision),
        "overlay_status": str(overlay_status),
        "overlay_summary": str(overlay_summary),
        "ledger_updates": ledger_update_values,
        "manifest_path": str(args.decision_manifest),
        "source_paths": [path for _, path in specs],
    }


def load_and_validate_manifest(path: Path, *, names: list[str]) -> dict[str, Any]:
    data = validate_decision_manifest(path)
    if "system_provenance_overlay" in data and names != ["skill-creator"]:
        raise InstallError(
            "system_provenance_overlay 只允许绑定 system scope 的 skill-creator update"
        )
    declared = data.get("skills")
    if declared is not None:
        if not isinstance(declared, list) or sorted(str(item) for item in declared) != sorted(names):
            raise InstallError("guard decision manifest 的 skills 与本次安装目标不一致")
    return data
