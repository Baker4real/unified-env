"""SOURCE.md current-record parsing, path binding and durable source-record writes.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

from skill_source_record import CurrentSourceRecord, parse_current_source_record
import install_skill_guarded_base as _base
import install_skill_guarded_payload as _payload
from install_skill_guarded_base import InstallError


# C0 controls except tab/LF/CR; e.g. a non-raw "D:\agents" literal yields BEL.
SOURCE_RECORD_FORBIDDEN_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
DRIVE_ABSOLUTE_PATH = re.compile(r"^[A-Za-z]:[\\/]")


def read_source_text(path: Path) -> str:
    path = _base.d_path(path, label="SOURCE.md", must_exist=True)
    if _base.is_reparse(path) or not path.is_file():
        raise InstallError(f"SOURCE.md 必须是安全的普通文件：{path}")
    try:
        return path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError) as exc:
        raise InstallError(f"无法读取 SOURCE.md：{path}：{exc}") from exc


def reject_source_control_characters(text: str, *, label: str) -> None:
    locations = []
    for match in SOURCE_RECORD_FORBIDDEN_CONTROL.finditer(text):
        line_number = text.count("\n", 0, match.start()) + 1
        locations.append(f"第 {line_number} 行 U+{ord(match.group()):04X}")
    if locations:
        shown = "、".join(locations[:10])
        more = f" 等 {len(locations)} 处" if len(locations) > 10 else ""
        raise InstallError(
            f"{label} 含有 TAB/LF/CR 以外的 C0 控制字符：{shown}{more}"
        )


def same_filesystem_location(recorded: str, actual: Path) -> bool:
    expected = os.path.normcase(os.path.normpath(actual))
    if os.path.normcase(os.path.normpath(recorded)) == expected:
        return True
    # Resolve only local drive paths, so a junction alias such as the legacy
    # D:\Codex\.codex\skills root matches while UNC/device paths never trigger
    # a remote lookup.
    if not DRIVE_ABSOLUTE_PATH.match(recorded):
        return False
    try:
        return os.path.normcase(os.path.realpath(recorded)) == os.path.normcase(
            os.path.realpath(actual)
        )
    except OSError:
        return False


def validate_source_record_paths(
    record: CurrentSourceRecord,
    *,
    label: str,
    local_path: Path,
    active_root: Path,
) -> None:
    for field, actual in (("Local path", local_path), ("Active root", active_root)):
        for value in record.values_for(field):
            if not same_filesystem_location(value, actual):
                raise InstallError(
                    f"{label} 当前记录的 {field} 与实际路径不一致：`{value}` != `{actual}`"
                )


def current_source_record(path: Path) -> CurrentSourceRecord:
    record = parse_current_source_record(read_source_text(path))
    if record.conflicts:
        raise InstallError(
            "SOURCE.md 当前记录存在冲突：" + record.conflict_description()
        )
    return record


def source_record_values(path: Path, field: str) -> list[str]:
    return list(current_source_record(path).values_for(field))


def source_record_unique_value(
    path: Path,
    fields: tuple[str, ...],
    *,
    label: str,
) -> str:
    values = list(current_source_record(path).values_for(*fields))
    unique = set(values)
    if len(unique) == 1:
        return values[0]
    if values:
        raise InstallError(
            f"{label} SOURCE.md 当前记录的 {'/'.join(fields)} 存在冲突：{values!r}"
        )
    raise InstallError(f"{label} SOURCE.md 当前记录缺少 {'/'.join(fields)}")


def validate_source_record_identity(
    path: Path,
    *,
    skill_name: str,
    repository: str,
    label: str,
) -> None:
    recorded_names = source_record_values(path, "Skill")
    if not recorded_names or any(name != skill_name for name in recorded_names):
        raise InstallError(
            f"{label} SOURCE.md 的 Skill 与 canonical identity 不一致："
            f"{recorded_names!r} != {skill_name!r}"
        )
    expected_repo = _base.normalize_repo(repository)
    recorded_repos = source_record_values(path, "Source repository")
    normalized_repos = [_base.normalize_repo(value) for value in recorded_repos]
    if (
        expected_repo is None
        or not normalized_repos
        or any(value != expected_repo for value in normalized_repos)
    ):
        raise InstallError(
            f"{label} SOURCE.md 的 source repository 与 canonical source 不一致"
        )


def source_record_text(
    *,
    skill_name: str,
    active_root: Path,
    upstream_path: str,
    context: dict[str, Any],
    command: str,
) -> str:
    repository = context["repo"] or "local candidate supplied by the user"
    canonical_rename = context.get("canonical_rename")
    lines = [
        "# Source Provenance",
        "",
        f"Skill: `{skill_name}`",
        f"Local path: `{active_root / skill_name}`",
        f"Active root: `{active_root}`",
        f"Recorded: {_base.today()}",
        f"Status: {context['source_status']}",
        f"Decision: {context['decision']}",
        f"Source type: {context['source_type']}",
        f"Source repository: `{repository}`",
        f"Upstream path: `{upstream_path}`",
        f"Ref: `{context['ref']}`",
    ]
    if isinstance(canonical_rename, dict):
        predecessor = canonical_rename.get("old_name")
        source_id = canonical_rename.get("source_id")
        if not isinstance(predecessor, str) or not isinstance(source_id, str):
            raise InstallError("canonical rename source record context 不合法")
        lines.extend(
            [
                f"Canonical predecessor: `{predecessor}`",
                f"Source identity: `{source_id}`",
            ]
        )
    if context["commit"]:
        lines.append(f"Commit or revision: `{context['commit']}`")
    lines.extend(
        [
            f"Retrieval: `{command}`",
            f"writing-for-agents gate: {context['writing_revision']}",
            f"Local overlay: {context['overlay_status']}"
            + (f" ({context['overlay_summary']})" if context["overlay_summary"] else ""),
            "Guarded activation: complete only after ledger, closure, catalog, and hash postchecks pass.",
            f"Guarded transaction evidence: `{context['evidence_path']}`",
            f"Decision manifest: `{context['manifest_path']}`",
            "",
        ]
    )
    return "\n".join(lines)


def append_source_record(
    path: Path,
    *,
    skill_name: str,
    active_root: Path,
    upstream_path: str,
    context: dict[str, Any],
    command: str,
) -> None:
    generated = source_record_text(
        skill_name=skill_name,
        active_root=active_root,
        upstream_path=upstream_path,
        context=context,
        command=command,
    )
    if path.exists():
        existing = path.read_text(encoding="utf-8-sig")
        reject_source_control_characters(existing, label=f"候选 SOURCE.md（{path}）")
        record = parse_current_source_record(existing)
        if record.conflicts:
            raise InstallError(
                "候选 SOURCE.md 当前记录存在冲突：" + record.conflict_description()
            )
        recorded_names = record.values_for("Skill")
        if not recorded_names:
            raise InstallError(f"候选 SOURCE.md 当前记录缺少 Skill identity：{path}")
        if any(name != skill_name for name in recorded_names):
            raise InstallError(f"候选 SOURCE.md 的 Skill 与目录不一致：{path}")
        validate_source_record_paths(
            record,
            label="候选 SOURCE.md",
            local_path=active_root / skill_name,
            active_root=active_root,
        )
        content = existing.rstrip() + "\n\n---\n\n" + generated
    else:
        content = generated
    reject_source_control_characters(
        generated,
        label="受管追加的 SOURCE.md 记录（来自 decision manifest 或安装参数）",
    )
    _base.atomic_write_bytes(path, (content.rstrip() + "\n").encode("utf-8"))


def validate_durable_source_record(
    path: Path,
    *,
    durable_fields: dict[str, Path],
    transient_paths: list[Path],
) -> None:
    raw_text = path.read_text(encoding="utf-8-sig")
    normalized_text = raw_text.replace("\\", "/").casefold()

    def normalize_path(item: Path) -> str:
        return str(item).replace("\\", "/").rstrip("/").casefold()

    def contains_path(text: str, item: str) -> bool:
        if not item:
            return False
        pattern = re.compile(
            rf"(?<![a-z0-9._-]){re.escape(item)}(?=$|[/\s`'\"<>()\[\]{{}},;:])"
        )
        return pattern.search(text) is not None

    exact_transient = sorted(
        item
        for item in (normalize_path(path) for path in transient_paths)
        if contains_path(normalized_text, item)
    )
    if exact_transient:
        raise InstallError(
            "SOURCE.md 不得保留临时 provenance 路径："
            + ", ".join(exact_transient)
        )

    allowed_fields = {
        key.casefold(): normalize_path(value) for key, value in durable_fields.items()
    }
    sanitized_lines: list[str] = []
    field_pattern = re.compile(
        r"^\s*(?P<key>[A-Za-z][A-Za-z0-9 _-]*)\s*:\s*(?P<value>.+?)\s*$"
    )
    for line in raw_text.splitlines():
        match = field_pattern.match(line)
        if match is not None:
            key = match.group("key").strip().casefold()
            value = normalize_path(Path(_payload.strip_scalar(match.group("value"))))
            if key in allowed_fields and value == allowed_fields[key]:
                sanitized_lines.append(f"{key}: <durable-path>")
                continue
        sanitized_lines.append(line.replace("\\", "/").casefold())
    sanitized_text = "\n".join(sanitized_lines)
    transient_roots = (
        "d:/codex/tmp",
        "d:/codex/.tmp",
        "d:/codex/.codex/tmp",
    )
    matches = sorted(
        item for item in transient_roots if contains_path(sanitized_text, item)
    )
    if matches:
        raise InstallError(
            "SOURCE.md 不得保留临时 provenance 路径：" + ", ".join(matches)
        )
