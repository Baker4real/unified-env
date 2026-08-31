"""Journaled, SOURCE-only migration for legacy skill provenance records.

The migration appends one normalized current record to each conflicted
``SOURCE.md``. Existing bytes remain an immutable history. Runtime scripts,
the ledger, and the generated catalog are included in the rollback set, but
this tool never changes ``SKILL.md`` or plugin-cache content.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import locale
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Iterable

from skill_source_record import normalize_field_name, parse_current_source_record, strip_scalar


DEFAULT_ACTIVE_ROOT = Path(r"D:\Codex\.codex\skills")
DEFAULT_PLUGIN_CACHE_ROOT = Path(r"D:\Codex\.codex\plugins\cache")
DEFAULT_LEDGER = DEFAULT_ACTIVE_ROOT / ".downloaded-skills-source-state.json"
DEFAULT_CATALOG = Path(r"D:\Codex\.codex\skill-catalog\catalog.json")
DEFAULT_RUNTIME_ROOT = Path(r"D:\Codex\.codex\scripts")
LEGACY_ADOPTED_SCHEMA1_BACKUP_ROOT = Path(
    r"D:\Codex\.codex\backups_state\skill-source-schema\20260804-084701-authorized-followup-strict-catalog-v2"
)
LEGACY_ADOPTED_SCHEMA1_MANIFEST_SHA256 = (
    "DB5EA290F4D009393E246CDA563CE0C9F404E85E22DD81AB2205D2870562EC6C"
)
DEFAULT_BACKUP_PARENT = Path(r"D:\Codex\.codex\backups_state\skill-source-schema")
DEFAULT_EVIDENCE_PARENT = Path(
    r"D:\agents\run-evidence\daily-codex-ecosystem-update"
)
RUNTIME_FILES = (
    "skill_source_record.py",
    "generate_skill_catalog.py",
    "system_skill_provenance_repair.py",
    "system_package_identity.py",
    "install_skill_guarded.py",
    "install-skill-guarded.cmd",
)
_SEPARATOR = re.compile(r"\s*---\s*")
_PLAIN_FIELD = re.compile(
    r"^\s*(?P<key>[A-Za-z][A-Za-z0-9 _-]*)\s*:\s*(?P<value>.*?)\s*$"
)
_BULLET_FIELD = re.compile(
    r"^-\s+(?P<key>[A-Za-z][A-Za-z0-9 _-]*)\s*:\s*(?P<value>.*?)\s*$"
)


class MigrationError(RuntimeError):
    """Raised when a batch cannot be proved safe and complete."""


@dataclass(frozen=True)
class PlannedChange:
    name: str
    scope: str
    relative_source: str
    before_sha256: str
    after_sha256: str
    before_size: int
    after_size: int
    source_section_index: int
    normalized_fields: tuple[str, ...]
    narrative_fields: tuple[str, ...]
    after_bytes: bytes

    def evidence(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "scope": self.scope,
            "relative_source": self.relative_source,
            "before_sha256": self.before_sha256,
            "after_sha256": self.after_sha256,
            "before_size": self.before_size,
            "after_size": self.after_size,
            "source_section_index": self.source_section_index,
            "normalized_fields": list(self.normalized_fields),
            "narrative_fields": list(self.narrative_fields),
        }


def _utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _is_reparse(path: Path) -> bool:
    stat_result = path.stat(follow_symlinks=False)
    return path.is_symlink() or bool(getattr(stat_result, "st_file_attributes", 0) & 0x400)


def _assert_safe_file(path: Path, *, label: str, required: bool = True) -> None:
    if not path.exists():
        if required:
            raise MigrationError(f"{label} 不存在：{path}")
        return
    if not path.is_file() or _is_reparse(path):
        raise MigrationError(f"{label} 不是安全普通文件：{path}")


def _read_stable(path: Path, *, label: str) -> bytes:
    _assert_safe_file(path, label=label)
    before = path.stat(follow_symlinks=False)
    data = path.read_bytes()
    after = path.stat(follow_symlinks=False)
    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if identity_before != identity_after:
        raise MigrationError(f"{label} 读取期间发生变化：{path}")
    return data


def _atomic_write(path: Path, data: bytes) -> None:
    if path.exists() and _is_reparse(path):
        raise MigrationError(f"拒绝替换 reparse point：{path}")
    temp = path.with_name(f".{path.name}.{os.getpid()}.{os.urandom(8).hex()}.tmp")
    try:
        with temp.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def _write_json(path: Path, value: dict[str, Any]) -> None:
    data = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    _atomic_write(path, data)


def _split_sections(text: str) -> list[list[str]]:
    sections: list[list[str]] = [[]]
    for line in text.splitlines():
        if _SEPARATOR.fullmatch(line):
            sections.append([])
        else:
            sections[-1].append(line)
    return sections


def _collapse_narrative(lines: Iterable[str]) -> str:
    parts: list[str] = []
    for line in lines:
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        value = re.sub(r"^[-*]\s+", "", value).strip()
        if value:
            parts.append(value)
    return " | ".join(parts)


def _extract_section_fields(
    lines: list[str],
) -> tuple[list[tuple[str, str]], set[str]]:
    plain = [(index, match) for index, line in enumerate(lines) if (match := _PLAIN_FIELD.match(line))]
    matches = plain
    if not matches:
        matches = [
            (index, match)
            for index, line in enumerate(lines)
            if (match := _BULLET_FIELD.match(line))
        ]
    if not matches:
        return [], set()

    values: list[tuple[str, str]] = []
    narrative_fields: set[str] = set()
    for position, (index, match) in enumerate(matches):
        end = matches[position + 1][0] if position + 1 < len(matches) else len(lines)
        key = match.group("key").strip()
        value = strip_scalar(match.group("value"))
        if not value:
            value = _collapse_narrative(lines[index + 1 : end])
            if value:
                narrative_fields.add(normalize_field_name(key))
        if value:
            values.append((key, value))
    return values, narrative_fields


def _canonical_record(
    text: str,
    *,
    expected_name: str,
    scope: str,
) -> tuple[str, int, tuple[str, ...], tuple[str, ...]]:
    sections = _split_sections(text)
    selected_index = -1
    extracted: list[tuple[str, str]] = []
    narrative_fields: set[str] = set()
    for index in range(len(sections) - 1, -1, -1):
        candidate, candidate_narrative = _extract_section_fields(sections[index])
        if candidate:
            selected_index = index
            extracted = candidate
            narrative_fields = candidate_narrative
            break
    if selected_index < 0:
        raise MigrationError(f"{expected_name} 的 SOURCE.md 没有可证明的 provenance 字段")

    grouped: dict[str, list[tuple[str, str]]] = {}
    order: list[str] = []
    for label, value in extracted:
        key = normalize_field_name(label)
        if key not in grouped:
            order.append(key)
            grouped[key] = []
        grouped[key].append((label, value))

    accepted_names = {expected_name}
    if scope == "system":
        accepted_names.add(f".system/{expected_name}")
    skill_values = {strip_scalar(value) for _, value in grouped.get("skill", [])}
    if skill_values and not skill_values.issubset(accepted_names):
        raise MigrationError(
            f"{expected_name} 的 SOURCE.md Skill identity 不一致：{sorted(skill_values)!r}"
        )
    if "skill" not in grouped:
        grouped["skill"] = [("Skill", f".system/{expected_name}" if scope == "system" else expected_name)]
        order.insert(0, "skill")

    rendered: list[tuple[str, str]] = []
    for key in order:
        entries = grouped[key]
        label = entries[0][0]
        unique = list(dict.fromkeys(value for _, value in entries))
        if len(unique) == 1:
            rendered.append((label, unique[0]))
            continue
        if key not in narrative_fields:
            raise MigrationError(
                f"{expected_name} 的标量字段 {label} 有多个不同值，拒绝猜测：{unique!r}"
            )
        rendered.append((label, " | ".join(unique)))

    record_lines = ["# Current Source Record", ""]
    record_lines.extend(f"{label}: {value}" for label, value in rendered)
    record = "\n".join(record_lines).rstrip() + "\n"
    after = text + ("" if text.endswith(("\r", "\n")) else "\n") + "\n---\n\n" + record
    parsed = parse_current_source_record(after)
    if parsed.conflicts:
        raise MigrationError(
            f"{expected_name} 的规范 current record 仍有冲突：{parsed.conflict_description()}"
        )
    final_skill_values = set(parsed.values_for("Skill"))
    if not final_skill_values or not final_skill_values.issubset(accepted_names):
        raise MigrationError(f"{expected_name} 的规范 current record 缺少一致 Skill identity")
    return after, selected_index, tuple(order), tuple(sorted(narrative_fields))


def _load_catalog_module(script_root: Path):
    resolved = str(script_root.resolve())
    if resolved not in sys.path:
        sys.path.insert(0, resolved)
    import generate_skill_catalog  # pylint: disable=import-outside-toplevel

    return generate_skill_catalog


def build_plan(
    *,
    active_root: Path,
    plugin_cache_root: Path,
    ledger: Path,
    script_root: Path,
    expected_count: int | None = None,
) -> tuple[dict[str, Any], list[PlannedChange]]:
    generator = _load_catalog_module(script_root)
    catalog = generator.build_catalog(active_root, plugin_cache_root, ledger)
    conflicts = catalog["checks"]["ledger"]["conflicts"]
    if expected_count is not None and len(conflicts) != expected_count:
        raise MigrationError(
            f"实时冲突数 {len(conflicts)} 与期望 {expected_count} 不一致"
        )

    changes: list[PlannedChange] = []
    for artifact in catalog["artifacts"]:
        if artifact["scope"] not in {"active", "system"} or not artifact["conflicts"]:
            continue
        if any(not conflict.startswith("SOURCE.md 当前记录的 ") for conflict in artifact["conflicts"]):
            raise MigrationError(
                f"{artifact['name']} 存在非 SOURCE schema 冲突：{artifact['conflicts']!r}"
            )
        source_path = Path(artifact["source"]["record_path"])
        before = _read_stable(source_path, label=f"{artifact['name']} SOURCE.md")
        try:
            text = before.decode("utf-8-sig")
        except UnicodeDecodeError as exc:
            raise MigrationError(f"SOURCE.md 不是合法 UTF-8：{source_path}") from exc
        after_text, section_index, fields, narrative = _canonical_record(
            text,
            expected_name=artifact["name"],
            scope=artifact["scope"],
        )
        if not after_text.startswith(text):
            raise MigrationError(f"{artifact['name']} 的 current record 未保持原文本前缀")
        after = before + after_text[len(text) :].encode("utf-8")
        changes.append(
            PlannedChange(
                name=artifact["name"],
                scope=artifact["scope"],
                relative_source=source_path.relative_to(active_root).as_posix(),
                before_sha256=_sha256(before),
                after_sha256=_sha256(after),
                before_size=len(before),
                after_size=len(after),
                source_section_index=section_index,
                normalized_fields=fields,
                narrative_fields=narrative,
                after_bytes=after,
            )
        )
    if len(changes) != len(conflicts):
        raise MigrationError(
            f"迁移计划 {len(changes)} 项与 strict 冲突 {len(conflicts)} 项不一致"
        )
    plan = {
        "schema_version": 1,
        "kind": "skill-source-current-record-migration",
        "generated_at": _utc_now(),
        "active_root": str(active_root),
        "plugin_cache_root": str(plugin_cache_root),
        "ledger": str(ledger),
        "conflict_count": len(conflicts),
        "scope_counts": {
            "active": sum(change.scope == "active" for change in changes),
            "system": sum(change.scope == "system" for change in changes),
        },
        "changes": [change.evidence() for change in changes],
        "skill_md_changes": 0,
        "plugin_cache_changes": 0,
    }
    return plan, changes


def validate_isolated(
    *,
    active_root: Path,
    plugin_cache_root: Path,
    ledger: Path,
    script_root: Path,
    changes: list[PlannedChange],
    scratch_parent: Path,
) -> dict[str, Any]:
    generator = _load_catalog_module(script_root)
    scratch_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="skill-source-shadow-", dir=scratch_parent) as temp:
        shadow = Path(temp) / "skills"
        shadow.mkdir()
        source_overrides = {change.relative_source: change.after_bytes for change in changes}
        live_catalog = generator.build_catalog(active_root, plugin_cache_root, ledger)
        for artifact in live_catalog["artifacts"]:
            if artifact["scope"] not in {"active", "system"}:
                continue
            skill_path = Path(artifact["skill_md_path"])
            relative_skill = skill_path.relative_to(active_root)
            target_skill = shadow / relative_skill
            target_skill.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(skill_path, target_skill)
            source_path = skill_path.parent / "SOURCE.md"
            relative_source = source_path.relative_to(active_root).as_posix()
            target_source = shadow / source_path.relative_to(active_root)
            if relative_source in source_overrides:
                target_source.write_bytes(source_overrides[relative_source])
            else:
                shutil.copyfile(source_path, target_source)
            openai = skill_path.parent / "agents" / "openai.yaml"
            if openai.is_file() and not _is_reparse(openai):
                target_openai = shadow / openai.relative_to(active_root)
                target_openai.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(openai, target_openai)
        isolated = generator.build_catalog(shadow, plugin_cache_root, ledger)
        remaining = isolated["checks"]["ledger"]["conflicts"]
        if remaining or isolated["checks"]["ledger"]["status"] != "pass":
            raise MigrationError(
                f"隔离镜像未达到 zero-conflict：{len(remaining)} 项，"
                f"status={isolated['checks']['ledger']['status']}"
            )
        live_skills = {
            (item["scope"], item["relative_path"], item["integrity"]["skill_md_sha256"])
            for item in live_catalog["artifacts"]
            if item["scope"] in {"active", "system"}
        }
        shadow_skills = {
            (item["scope"], item["relative_path"], item["integrity"]["skill_md_sha256"])
            for item in isolated["artifacts"]
            if item["scope"] in {"active", "system"}
        }
        if live_skills != shadow_skills:
            raise MigrationError("隔离镜像的 SKILL.md 闭包或哈希发生变化")
        return {
            "status": "pass",
            "conflict_count": 0,
            "ledger_status": "pass",
            "artifact_count": len(shadow_skills),
            "skill_md_hashes_unchanged": True,
        }


def _backup_entry(target: Path, backup_root: Path, backup_relative: Path) -> dict[str, Any]:
    exists = target.exists()
    entry: dict[str, Any] = {
        "target": str(target),
        "backup_relative": backup_relative.as_posix(),
        "before_exists": exists,
        "before_sha256": None,
        "before_size": None,
    }
    if not exists:
        return entry
    data = _read_stable(target, label="rollback target")
    backup = backup_root / backup_relative
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_bytes(data)
    if _sha256(backup.read_bytes()) != _sha256(data):
        raise MigrationError(f"回滚备份哈希不一致：{target}")
    entry["before_sha256"] = _sha256(data)
    entry["before_size"] = len(data)
    return entry


def _run_localized_tool(command: list[str]) -> subprocess.CompletedProcess[str]:
    """运行按活动代码页输出的本机 Windows 工具（icacls 等）。

    icacls 会用控制台代码页回显路径与本地化消息；zh-CN 主机上是 GBK，
    严格 UTF-8 解码在调用方检查退出码之前就抛 UnicodeDecodeError。
    先按 UTF-8 解码，失败后回退到本机首选编码。
    """
    raw = subprocess.run(command, capture_output=True, check=False)

    def _decode(data: bytes | str | None) -> str:
        if isinstance(data, str):
            return data
        if not data:
            return ""
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.decode(locale.getpreferredencoding(False), errors="replace")

    return subprocess.CompletedProcess(
        args=command,
        returncode=raw.returncode,
        stdout=_decode(raw.stdout),
        stderr=_decode(raw.stderr),
    )


def _protect_acl(path: Path) -> dict[str, Any]:
    whoami = subprocess.run(
        ["whoami.exe", "/user", "/fo", "csv", "/nh"],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    match = re.search(r'"(S-1-[0-9-]+)"\s*$', whoami.stdout.strip())
    if match is None:
        raise MigrationError("无法解析当前用户 SID，拒绝建立未保护回滚点")
    principals = (match.group(1), "S-1-5-18", "S-1-5-32-544")
    pwsh_path = shutil.which("pwsh.exe")
    if pwsh_path is None:
        raise MigrationError("找不到受管 pwsh.exe，拒绝建立未保护回滚点")
    acl_script = r"""
$ErrorActionPreference = 'Stop'
$rootPath = [Environment]::GetEnvironmentVariable('CODEX_SKILL_ACL_ROOT')
$userSid = [Environment]::GetEnvironmentVariable('CODEX_SKILL_ACL_USER_SID')
$root = Get-Item -LiteralPath $rootPath -Force
$items = @($root) + @(Get-ChildItem -LiteralPath $root.FullName -Force -Recurse)
$sidTexts = @($userSid, 'S-1-5-18', 'S-1-5-32-544')
$processed = 0
foreach ($item in $items) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "ACL closure contains a reparse point: $($item.FullName)"
    }
    $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl(
        $item,
        [System.Security.AccessControl.AccessControlSections]::Access
    )
    $acl.SetAccessRuleProtection($true, $false)
    $seen = @{}
    foreach ($existing in $acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    )) {
        $key = $existing.IdentityReference.Value
        if (-not $seen.ContainsKey($key)) {
            $acl.PurgeAccessRules($existing.IdentityReference)
            $seen[$key] = $true
        }
    }
    foreach ($sidText in $sidTexts) {
        $identity = [System.Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    [System.IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
    $processed += 1
}
[pscustomobject]@{ status = 'pass'; processed = $processed } | ConvertTo-Json -Compress
"""
    acl_environment = os.environ.copy()
    acl_environment["CODEX_SKILL_ACL_ROOT"] = str(path)
    acl_environment["CODEX_SKILL_ACL_USER_SID"] = principals[0]
    acl_result = subprocess.run(
        [pwsh_path, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", acl_script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=acl_environment,
    )
    if acl_result.returncode != 0:
        raise MigrationError(f"回滚点 ACL exact-DACL 保护失败，exit={acl_result.returncode}")
    try:
        acl_summary = json.loads(acl_result.stdout)
    except json.JSONDecodeError as exc:
        raise MigrationError("回滚点 ACL exact-DACL 输出不是有效 JSON") from exc
    verify_result = _run_localized_tool(
        ["icacls.exe", str(path), "/verify", "/T", "/C"],
    )
    if verify_result.returncode != 0:
        raise MigrationError(f"回滚点 ACL verify 失败，exit={verify_result.returncode}")
    return {
        "status": "pass",
        "inheritance": "removed-recursively",
        "mode": "exact-three-principal-dacl",
        "principal_count": len(principals),
        "processed_item_count": int(acl_summary["processed"]),
        "verify_exit_code": verify_result.returncode,
    }


def create_backup(
    *,
    backup_root: Path,
    active_root: Path,
    ledger: Path,
    catalog: Path,
    runtime_root: Path,
    changes: list[PlannedChange],
    tool_path: Path,
) -> Path:
    if backup_root.exists():
        raise MigrationError(f"回滚点已存在：{backup_root}")
    backup_root.mkdir(parents=True)
    entries: list[dict[str, Any]] = []
    for change in changes:
        target = active_root / Path(change.relative_source)
        entries.append(
            _backup_entry(target, backup_root, Path("sources") / Path(change.relative_source))
        )
    entries.append(_backup_entry(ledger, backup_root, Path("state/ledger.json")))
    entries.append(_backup_entry(catalog, backup_root, Path("state/catalog.json")))
    for name in RUNTIME_FILES:
        entries.append(
            _backup_entry(runtime_root / name, backup_root, Path("runtime") / name)
        )
    tool_copy = backup_root / "tools" / tool_path.name
    tool_copy.parent.mkdir(parents=True)
    tool_copy.write_bytes(_read_stable(tool_path, label="migration tool"))
    parser_source = tool_path.with_name("skill_source_record.py")
    parser_copy = tool_copy.with_name(parser_source.name)
    parser_copy.write_bytes(_read_stable(parser_source, label="shared SOURCE parser"))
    recovery_tools = []
    for recovery_tool in (tool_copy, parser_copy):
        payload = _read_stable(recovery_tool, label="recovery tool")
        recovery_tools.append(
            {
                "backup_relative": recovery_tool.relative_to(backup_root).as_posix(),
                "sha256": _sha256(payload),
                "size": len(payload),
            }
        )
    manifest = {
        "schema_version": 2,
        "kind": "skill-source-current-record-rollback",
        "created_at": _utc_now(),
        "backup_root": str(backup_root),
        "allowed_targets": {
            "active_root": str(active_root.resolve()),
            "ledger": str(ledger.resolve()),
            "catalog": str(catalog.resolve()),
            "runtime_root": str(runtime_root.resolve()),
        },
        "entries": entries,
        "recovery_tools": recovery_tools,
        "restore_command": [
            sys.executable,
            "-B",
            str(tool_copy),
            "--restore",
            "--manifest",
            str(backup_root / "manifest.json"),
        ],
    }
    manifest_path = backup_root / "manifest.json"
    _write_json(manifest_path, manifest)
    for entry in entries:
        if entry["before_exists"]:
            backup = backup_root / entry["backup_relative"]
            if _sha256(backup.read_bytes()) != entry["before_sha256"]:
                raise MigrationError(f"回滚点校验失败：{backup}")
    manifest["acl"] = _protect_acl(backup_root)
    manifest["verified_entry_count"] = len(entries)
    _write_json(manifest_path, manifest)
    final_acl = _protect_acl(backup_root)
    if final_acl != manifest["acl"]:
        raise MigrationError("回滚点最终 ACL 结果与 manifest 记录不一致")
    _verify_acl(backup_root)
    return manifest_path


def _target_policy(data: dict[str, Any], manifest_path: Path) -> dict[str, Path]:
    schema_version = data.get("schema_version")
    if schema_version == 2:
        allowed = data.get("allowed_targets")
        if not isinstance(allowed, dict) or set(allowed) != {
            "active_root",
            "ledger",
            "catalog",
            "runtime_root",
        }:
            raise MigrationError("schema 2 rollback manifest 缺少精确 allowed_targets")
        policy = {key: Path(value) for key, value in allowed.items()}
        if any(not value.is_absolute() for value in policy.values()):
            raise MigrationError("rollback allowed_targets 必须全部是绝对路径")
        return {key: value.resolve() for key, value in policy.items()}
    if schema_version == 1:
        expected_manifest = LEGACY_ADOPTED_SCHEMA1_BACKUP_ROOT / "manifest.json"
        if manifest_path.resolve() != expected_manifest.resolve():
            raise MigrationError("schema 1 仅兼容已采用的精确 v2 本机回滚点")
        return {
            "active_root": DEFAULT_ACTIVE_ROOT.resolve(),
            "ledger": DEFAULT_LEDGER.resolve(),
            "catalog": DEFAULT_CATALOG.resolve(),
            "runtime_root": DEFAULT_RUNTIME_ROOT.resolve(),
        }
    raise MigrationError("不支持的 rollback manifest schema")


def _expected_target(backup_relative: Path, policy: dict[str, Path]) -> Path:
    parts = backup_relative.parts
    if len(parts) >= 3 and parts[0] == "sources" and parts[-1] == "SOURCE.md":
        relative_source = Path(*parts[1:])
        expected = (policy["active_root"] / relative_source).resolve()
        try:
            expected.relative_to(policy["active_root"])
        except ValueError as exc:
            raise MigrationError(f"SOURCE restore target 越界：{expected}") from exc
        return expected
    if backup_relative.as_posix() == "state/ledger.json":
        return policy["ledger"]
    if backup_relative.as_posix() == "state/catalog.json":
        return policy["catalog"]
    if len(parts) == 2 and parts[0] == "runtime" and parts[1] in RUNTIME_FILES:
        return (policy["runtime_root"] / parts[1]).resolve()
    raise MigrationError(f"rollback backup_relative 不属于受管闭包：{backup_relative}")


def verify_backup(manifest_path: Path) -> dict[str, Any]:
    data = json.loads(_read_stable(manifest_path, label="rollback manifest").decode("utf-8"))
    if data.get("kind") != "skill-source-current-record-rollback":
        raise MigrationError("不支持的 rollback manifest")
    policy = _target_policy(data, manifest_path)
    backup_root = Path(data["backup_root"]).resolve()
    if manifest_path.resolve().parent != backup_root:
        raise MigrationError("rollback manifest 不在其声明的 backup_root")
    entries = data.get("entries", [])
    targets = [str(Path(entry["target"]).resolve()) for entry in entries]
    relatives = [str(entry["backup_relative"]) for entry in entries]
    if len(targets) != len(set(targets)) or len(relatives) != len(set(relatives)):
        raise MigrationError("rollback manifest 存在重复 target 或 backup_relative")
    source_entries = [value for value in relatives if value.startswith("sources/")]
    required_state = {"state/ledger.json", "state/catalog.json"}
    required_runtime = {f"runtime/{name}" for name in RUNTIME_FILES}
    if (
        not source_entries
        or not required_state.issubset(relatives)
        or not required_runtime.issubset(relatives)
        or len(entries) != len(source_entries) + len(required_state) + len(required_runtime)
    ):
        raise MigrationError("rollback manifest 缺少 SOURCE、ledger、catalog 或六文件 runtime 闭包")
    verified = 0
    for entry in entries:
        target = Path(entry["target"])
        backup_relative = Path(entry["backup_relative"])
        if backup_relative.is_absolute() or ".." in backup_relative.parts:
            raise MigrationError(f"rollback backup_relative 越界：{backup_relative}")
        backup = (backup_root / backup_relative).resolve()
        try:
            backup.relative_to(backup_root)
        except ValueError as exc:
            raise MigrationError(f"rollback payload 越界：{backup}") from exc
        if entry["before_exists"]:
            payload = _read_stable(backup, label="rollback payload")
            if _sha256(payload) != entry["before_sha256"] or len(payload) != entry["before_size"]:
                raise MigrationError(f"rollback payload 校验失败：{backup}")
        if not target.is_absolute():
            raise MigrationError(f"rollback target 必须是绝对路径：{target}")
        expected_target = _expected_target(backup_relative, policy)
        if target.resolve() != expected_target:
            raise MigrationError(
                f"rollback target 映射不一致：{target.resolve()} != {expected_target}"
            )
        verified += 1
    if verified != len(entries) or verified == 0:
        raise MigrationError("rollback manifest entry 集合无效")
    recovery_tools = data.get("recovery_tools")
    if data.get("schema_version") == 2 or recovery_tools is not None:
        if not isinstance(recovery_tools, list) or len(recovery_tools) != 2:
            raise MigrationError("rollback recovery_tools 闭包无效")
        expected_tool_relatives = {
            "tools/reconcile_skill_source_records.py",
            "tools/skill_source_record.py",
        }
        actual_tool_relatives = {str(tool.get("backup_relative")) for tool in recovery_tools}
        if actual_tool_relatives != expected_tool_relatives:
            raise MigrationError("rollback recovery_tools 必须精确绑定两个恢复工具")
        for tool in recovery_tools:
            relative = Path(tool["backup_relative"])
            if relative.is_absolute() or ".." in relative.parts:
                raise MigrationError(f"recovery tool 路径越界：{relative}")
            payload_path = (backup_root / relative).resolve()
            try:
                payload_path.relative_to(backup_root)
            except ValueError as exc:
                raise MigrationError(f"recovery tool 路径越界：{payload_path}") from exc
            payload = _read_stable(payload_path, label="recovery tool")
            if _sha256(payload) != tool["sha256"] or len(payload) != tool["size"]:
                raise MigrationError(f"recovery tool 哈希漂移：{payload_path}")
        expected_tool_files = {
            (backup_root / Path(tool["backup_relative"])).resolve()
            for tool in recovery_tools
        }
        tools_root = backup_root / "tools"
        actual_tool_files: set[Path] = set()
        for candidate in tools_root.rglob("*"):
            if _is_reparse(candidate):
                raise MigrationError(f"recovery tools 闭包包含 reparse point：{candidate}")
            if candidate.is_file():
                actual_tool_files.add(candidate.resolve())
        if actual_tool_files != expected_tool_files:
            raise MigrationError("recovery tools 闭包包含未绑定或缺失文件")
    acl_verification = None
    if data.get("schema_version") == 2:
        acl_verification = _verify_acl(backup_root)
    return {
        "status": "pass",
        "schema_version": data["schema_version"],
        "entry_count": verified,
        "manifest": str(manifest_path),
        "restore_command_present": bool(data.get("restore_command")),
        "recovery_tools_verified": 0 if recovery_tools is None else len(recovery_tools),
        "acl": data.get("acl"),
        "acl_verification": acl_verification,
    }


def verify_backup_matches_plan(
    manifest_path: Path,
    *,
    active_root: Path,
    changes: list[PlannedChange],
) -> None:
    verify_backup(manifest_path)
    data = json.loads(_read_stable(manifest_path, label="rollback manifest").decode("utf-8"))
    entries = {str(Path(entry["target"]).resolve()): entry for entry in data["entries"]}
    for change in changes:
        target = (active_root / Path(change.relative_source)).resolve()
        entry = entries.get(str(target))
        if entry is None or entry.get("before_sha256") != change.before_sha256:
            raise MigrationError(f"回滚点未绑定当前迁移计划：{target}")


def restore_backup(manifest_path: Path) -> dict[str, Any]:
    manifest_bytes = _read_stable(manifest_path, label="rollback manifest")
    verify_backup(manifest_path)
    if _read_stable(manifest_path, label="rollback manifest") != manifest_bytes:
        raise MigrationError("rollback manifest 在验证后发生变化")
    data = json.loads(manifest_bytes.decode("utf-8"))
    backup_root = Path(data["backup_root"])
    restored = 0
    for entry in data["entries"]:
        target = Path(entry["target"])
        if entry["before_exists"]:
            backup = backup_root / entry["backup_relative"]
            payload = _read_stable(backup, label="rollback payload")
            if _sha256(payload) != entry["before_sha256"]:
                raise MigrationError(f"rollback payload 哈希漂移：{backup}")
            target.parent.mkdir(parents=True, exist_ok=True)
            _atomic_write(target, payload)
            if _sha256(_read_stable(target, label="restored target")) != entry["before_sha256"]:
                raise MigrationError(f"恢复后哈希不一致：{target}")
        elif target.exists():
            _assert_safe_file(target, label="rollback-created target")
            target.unlink()
        restored += 1
    return {"status": "restored", "entry_count": restored, "manifest": str(manifest_path)}


def _verify_acl(path: Path, *, recursive: bool = True) -> dict[str, Any]:
    verify = _run_localized_tool(
        ["icacls.exe", str(path), "/verify", "/T", "/C"],
    )
    if verify.returncode != 0:
        raise MigrationError(f"ACL verify 失败，exit={verify.returncode}：{path}")
    whoami = subprocess.run(
        ["whoami.exe"],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    ).stdout.strip()
    required = {whoami.casefold(), "nt authority\\system", "builtin\\administrators"}
    candidates = [path]
    if recursive:
        candidates.extend(sorted(path.rglob("*"), key=lambda value: str(value).casefold()))
    verified_items = 0
    for candidate in candidates:
        if _is_reparse(candidate):
            raise MigrationError(f"ACL 闭包包含 reparse point：{candidate}")
        listing_result = _run_localized_tool(
            ["icacls.exe", str(candidate)],
        )
        if listing_result.returncode != 0:
            raise MigrationError(f"ACL listing 失败，exit={listing_result.returncode}：{candidate}")
        lines = listing_result.stdout.splitlines()
        candidate_text = str(candidate)
        if not lines or not lines[0].casefold().startswith(candidate_text.casefold()):
            raise MigrationError(f"ACL listing 无法绑定目标：{candidate}")
        rule_lines = [
            lines[0][len(candidate_text) :].strip(),
            *[line.strip() for line in lines[1:]],
        ]
        rules: list[tuple[str, str]] = []
        for line in rule_lines:
            if not line or ":" not in line:
                continue
            principal, permissions = line.rsplit(":", 1)
            rules.append((principal.strip().casefold(), permissions.strip().casefold()))
        actual_principals = {principal for principal, _ in rules}
        if (
            len(rules) != 3
            or actual_principals != required
            or any(permissions != "(f)" for _, permissions in rules)
        ):
            raise MigrationError(
                f"ACL 不是预期的三主体 protected FullControl DACL：{candidate}"
            )
        verified_items += 1
    return {
        "status": "pass",
        "verify_exit_code": verify.returncode,
        "required_principal_count": len(required),
        "inheritance": "absent",
        "verified_item_count": verified_items,
        "scope": "recursive" if recursive else "root-only-legacy-compatibility",
    }


def _verify_exact_legacy_backup(manifest_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    expected = LEGACY_ADOPTED_SCHEMA1_BACKUP_ROOT / "manifest.json"
    if manifest_path.resolve() != expected.resolve():
        raise MigrationError("reharden 只接受精确 adopted v2 legacy manifest")
    manifest_bytes = _read_stable(manifest_path, label="legacy rollback manifest")
    if _sha256(manifest_bytes).upper() != LEGACY_ADOPTED_SCHEMA1_MANIFEST_SHA256:
        raise MigrationError("adopted v2 legacy manifest 哈希漂移")
    verified = verify_backup(manifest_path)
    data = json.loads(manifest_bytes.decode("utf-8"))
    entries = data["entries"]
    if len(entries) != 50 or sum(bool(entry["before_exists"]) for entry in entries) != 49:
        raise MigrationError("adopted v2 必须精确包含 50 entries、49 existing payloads")
    if [entry["backup_relative"] for entry in entries if not entry["before_exists"]] != [
        "runtime/skill_source_record.py"
    ]:
        raise MigrationError("adopted v2 absence marker 与预期不一致")
    verified["manifest_sha256"] = _sha256(manifest_bytes).upper()
    verified["acl"] = _verify_acl(LEGACY_ADOPTED_SCHEMA1_BACKUP_ROOT, recursive=False)
    return data, verified


def _copy_verified_payload(source: Path, target: Path, expected_sha256: str, expected_size: int) -> None:
    payload = _read_stable(source, label="legacy rollback payload")
    if _sha256(payload) != expected_sha256 or len(payload) != expected_size:
        raise MigrationError(f"legacy payload 哈希漂移：{source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(target, payload)
    copied = _read_stable(target, label="rehardened rollback payload")
    if copied != payload:
        raise MigrationError(f"rehardened payload 字节不一致：{target}")


def _sandbox_restore_validation(manifest_path: Path, embedded_tool: Path) -> dict[str, Any]:
    source_data = json.loads(_read_stable(manifest_path, label="hardened manifest").decode("utf-8"))
    scratch_parent = Path(r"D:\Codex\tmp\skill-source-record-migration")
    scratch_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rollback-restore-validation-", dir=scratch_parent) as temp:
        sandbox = Path(temp)
        sandbox_backup = sandbox / "backup"
        targets = sandbox / "targets"
        policy = {
            "active_root": targets / "skills",
            "ledger": targets / "skills" / ".downloaded-skills-source-state.json",
            "catalog": targets / "skill-catalog" / "catalog.json",
            "runtime_root": targets / "scripts",
        }
        sandbox_entries: list[dict[str, Any]] = []
        source_root = manifest_path.parent
        for entry in source_data["entries"]:
            relative = Path(entry["backup_relative"])
            copied_entry = dict(entry)
            copied_entry["target"] = str(_expected_target(relative, policy))
            sandbox_entries.append(copied_entry)
            if entry["before_exists"]:
                _copy_verified_payload(
                    source_root / relative,
                    sandbox_backup / relative,
                    entry["before_sha256"],
                    entry["before_size"],
                )
            target = Path(copied_entry["target"])
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"rollback-validation-mutated")
        recovery_tools: list[dict[str, Any]] = []
        for tool in source_data["recovery_tools"]:
            relative = Path(tool["backup_relative"])
            _copy_verified_payload(
                source_root / relative,
                sandbox_backup / relative,
                tool["sha256"],
                tool["size"],
            )
            recovery_tools.append(dict(tool))
        sandbox_manifest = {
            "schema_version": 2,
            "kind": source_data["kind"],
            "created_at": _utc_now(),
            "backup_root": str(sandbox_backup),
            "allowed_targets": {key: str(value) for key, value in policy.items()},
            "entries": sandbox_entries,
            "recovery_tools": recovery_tools,
            "restore_command": [
                sys.executable,
                "-B",
                str(embedded_tool),
                "--restore",
                "--manifest",
                str(sandbox_backup / "manifest.json"),
            ],
        }
        sandbox_backup.mkdir(parents=True, exist_ok=True)
        _write_json(sandbox_backup / "manifest.json", sandbox_manifest)
        sandbox_manifest["acl"] = _protect_acl(sandbox_backup)
        _write_json(sandbox_backup / "manifest.json", sandbox_manifest)
        _protect_acl(sandbox_backup)
        _verify_acl(sandbox_backup)
        restore = subprocess.run(
            sandbox_manifest["restore_command"],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if restore.returncode != 0:
            raise MigrationError(f"self-contained sandbox restore 失败，exit={restore.returncode}")
        for entry in sandbox_entries:
            target = Path(entry["target"])
            if entry["before_exists"]:
                payload = _read_stable(target, label="sandbox restored target")
                if _sha256(payload) != entry["before_sha256"]:
                    raise MigrationError(f"sandbox restore 哈希不一致：{target}")
            elif target.exists():
                raise MigrationError(f"sandbox restore 未清除 transaction-created target：{target}")
        return {
            "status": "pass",
            "entry_count": len(sandbox_entries),
            "existing_payload_count": sum(entry["before_exists"] for entry in sandbox_entries),
            "absence_marker_count": sum(not entry["before_exists"] for entry in sandbox_entries),
            "tool": str(embedded_tool),
        }


def reharden_legacy_backup(
    *,
    legacy_manifest: Path,
    destination: Path,
    tool_path: Path,
) -> dict[str, Any]:
    legacy_data, legacy_verification = _verify_exact_legacy_backup(legacy_manifest)
    destination = destination.resolve()
    if destination.parent != DEFAULT_BACKUP_PARENT.resolve() or not destination.name.endswith(
        "-v3-hardened"
    ):
        raise MigrationError("hardened backup 必须位于受管 backup parent 且以 -v3-hardened 结尾")
    if destination.exists():
        raise MigrationError(f"hardened backup 已存在：{destination}")
    stage = destination.parent / f".{destination.name}.not-adoptable-{os.urandom(8).hex()}"
    stage.mkdir(parents=True)
    published = False
    try:
        entries = [dict(entry) for entry in legacy_data["entries"]]
        for entry in entries:
            if not entry["before_exists"]:
                continue
            relative = Path(entry["backup_relative"])
            _copy_verified_payload(
                legacy_manifest.parent / relative,
                stage / relative,
                entry["before_sha256"],
                entry["before_size"],
            )
        embedded_tool = stage / "tools" / tool_path.name
        embedded_parser = stage / "tools" / "skill_source_record.py"
        _copy_verified_payload(
            tool_path,
            embedded_tool,
            _sha256(_read_stable(tool_path, label="hardened reconciler")),
            tool_path.stat().st_size,
        )
        parser_source = tool_path.with_name("skill_source_record.py")
        parser_payload = _read_stable(parser_source, label="repo shared parser")
        runtime_parser = _read_stable(
            DEFAULT_RUNTIME_ROOT / "skill_source_record.py", label="runtime shared parser"
        )
        if parser_payload != runtime_parser:
            raise MigrationError("repo/runtime shared parser 哈希不一致")
        _copy_verified_payload(
            parser_source,
            embedded_parser,
            _sha256(parser_payload),
            len(parser_payload),
        )
        recovery_tools = []
        for path in (embedded_tool, embedded_parser):
            payload = _read_stable(path, label="embedded recovery tool")
            recovery_tools.append(
                {
                    "backup_relative": path.relative_to(stage).as_posix(),
                    "sha256": _sha256(payload),
                    "size": len(payload),
                }
            )
        manifest = {
            "schema_version": 2,
            "kind": "skill-source-current-record-rollback",
            "created_at": _utc_now(),
            "backup_root": str(destination),
            "allowed_targets": {
                "active_root": str(DEFAULT_ACTIVE_ROOT.resolve()),
                "ledger": str(DEFAULT_LEDGER.resolve()),
                "catalog": str(DEFAULT_CATALOG.resolve()),
                "runtime_root": str(DEFAULT_RUNTIME_ROOT.resolve()),
            },
            "entries": entries,
            "recovery_tools": recovery_tools,
            "source_legacy": {
                "manifest": str(legacy_manifest.resolve()),
                "manifest_sha256": LEGACY_ADOPTED_SCHEMA1_MANIFEST_SHA256,
                "entry_count": 50,
            },
            "restore_command": [
                sys.executable,
                "-B",
                str(destination / "tools" / tool_path.name),
                "--restore",
                "--manifest",
                str(destination / "manifest.json"),
            ],
        }
        _write_json(stage / "manifest.json", manifest)
        manifest["acl"] = _protect_acl(stage)
        manifest["verified_entry_count"] = len(entries)
        _write_json(stage / "manifest.json", manifest)
        final_acl = _protect_acl(stage)
        if final_acl != manifest["acl"]:
            raise MigrationError("hardened 回滚点最终 ACL 结果与 manifest 记录不一致")
        stage_acl_verification = _verify_acl(stage)
        stage.rename(destination)
        published = True
        published_acl_verification = _verify_acl(destination)
        project_verification = verify_backup(destination / "manifest.json")
        embedded_result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(destination / "tools" / tool_path.name),
                "--verify-rollback",
                "--manifest",
                str(destination / "manifest.json"),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if embedded_result.returncode != 0:
            raise MigrationError(f"embedded verifier 失败，exit={embedded_result.returncode}")
        embedded_verification = json.loads(embedded_result.stdout)
        restore_validation = _sandbox_restore_validation(
            destination / "manifest.json", destination / "tools" / tool_path.name
        )
        payload_parity = sum(
            _read_stable(destination / entry["backup_relative"], label="hardened payload")
            == _read_stable(legacy_manifest.parent / entry["backup_relative"], label="legacy payload")
            for entry in entries
            if entry["before_exists"]
        )
        if payload_parity != 49:
            raise MigrationError("hardened payload parity 未达到 49/49 existing payloads")
        manifest_path = destination / "manifest.json"
        return {
            "status": "succeeded",
            "destination": str(destination),
            "manifest": str(manifest_path),
            "manifest_sha256": _sha256(_read_stable(manifest_path, label="hardened manifest")),
            "entry_count": 50,
            "existing_payload_parity_count": payload_parity,
            "absence_marker_count": 1,
            "legacy_verification": legacy_verification,
            "project_verification": project_verification,
            "embedded_verification": embedded_verification,
            "restore_validation": restore_validation,
            "stage_acl_verification": stage_acl_verification,
            "published_acl_verification": published_acl_verification,
            "recovery_tools": recovery_tools,
        }
    except Exception:
        if published and destination.exists():
            destination.rename(
                destination.parent / f".{destination.name}.failed-not-adoptable-{os.urandom(8).hex()}"
            )
        raise


def apply_sources(
    *,
    active_root: Path,
    changes: list[PlannedChange],
    backup_manifest: Path,
    journal_path: Path,
    generator,
    plugin_cache_root: Path,
    ledger: Path,
) -> dict[str, Any]:
    journal = {
        "schema_version": 1,
        "kind": "skill-source-current-record-transaction",
        "status": "prepared",
        "started_at": _utc_now(),
        "backup_manifest": str(backup_manifest),
        "changes": [change.evidence() for change in changes],
        "applied": [],
    }
    journal_path.parent.mkdir(parents=True, exist_ok=True)
    _write_json(journal_path, journal)
    try:
        for change in changes:
            target = active_root / Path(change.relative_source)
            current = _read_stable(target, label=f"{change.name} live SOURCE.md")
            if _sha256(current) != change.before_sha256:
                raise MigrationError(f"应用前 SOURCE.md 漂移：{target}")
        for change in changes:
            target = active_root / Path(change.relative_source)
            _atomic_write(target, change.after_bytes)
            if _sha256(_read_stable(target, label="migrated SOURCE.md")) != change.after_sha256:
                raise MigrationError(f"迁移后 SOURCE.md 哈希不一致：{target}")
            journal["applied"].append(change.relative_source)
            journal["status"] = "applying"
            _write_json(journal_path, journal)
        catalog = generator.build_catalog(active_root, plugin_cache_root, ledger)
        conflicts = catalog["checks"]["ledger"]["conflicts"]
        if conflicts or catalog["checks"]["ledger"]["status"] != "pass":
            raise MigrationError(f"live SOURCE 迁移后仍有 {len(conflicts)} 项冲突")
        journal["status"] = "source-applied"
        journal["completed_at"] = _utc_now()
        journal["live_conflict_count"] = 0
        journal["ledger_status"] = "pass"
        _write_json(journal_path, journal)
        return journal
    except Exception as exc:
        try:
            restored = restore_backup(backup_manifest)
            journal["status"] = "rolled-back"
            journal["rollback"] = restored
        except Exception as rollback_exc:  # pragma: no cover - live recovery path
            journal["status"] = "recovery-required"
            journal["rollback_error"] = str(rollback_exc)
        journal["error"] = str(exc)
        journal["completed_at"] = _utc_now()
        _write_json(journal_path, journal)
        raise


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="迁移 legacy skill SOURCE current record")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--verify-rollback", action="store_true")
    mode.add_argument("--restore", action="store_true")
    mode.add_argument("--reharden-legacy-backup", action="store_true")
    parser.add_argument("--active-root", type=Path, default=DEFAULT_ACTIVE_ROOT)
    parser.add_argument("--plugin-cache-root", type=Path, default=DEFAULT_PLUGIN_CACHE_ROOT)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--runtime-root", type=Path, default=DEFAULT_RUNTIME_ROOT)
    parser.add_argument("--script-root", type=Path, default=Path(__file__).absolute().parent)
    parser.add_argument("--expected-count", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--backup-root", type=Path)
    parser.add_argument("--journal", type=Path)
    parser.add_argument("--manifest", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.reharden_legacy_backup:
            if args.manifest is None or args.backup_root is None:
                raise MigrationError(
                    "--reharden-legacy-backup 需要 --manifest 和 --backup-root"
                )
            result = reharden_legacy_backup(
                legacy_manifest=args.manifest,
                destination=args.backup_root,
                tool_path=Path(__file__).absolute(),
            )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.verify_rollback:
            if args.manifest is None:
                raise MigrationError("--verify-rollback 需要 --manifest")
            print(json.dumps(verify_backup(args.manifest), ensure_ascii=False, indent=2))
            return 0
        if args.restore:
            if args.manifest is None:
                raise MigrationError("--restore 需要 --manifest")
            print(json.dumps(restore_backup(args.manifest), ensure_ascii=False, indent=2))
            return 0
        plan, changes = build_plan(
            active_root=args.active_root,
            plugin_cache_root=args.plugin_cache_root,
            ledger=args.ledger,
            script_root=args.script_root,
            expected_count=args.expected_count,
        )
        isolated = validate_isolated(
            active_root=args.active_root,
            plugin_cache_root=args.plugin_cache_root,
            ledger=args.ledger,
            script_root=args.script_root,
            changes=changes,
            scratch_parent=Path(r"D:\Codex\tmp\skill-source-record-migration"),
        )
        plan["isolated_validation"] = isolated
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            _write_json(args.output, plan)
        if args.plan:
            print(json.dumps(plan, ensure_ascii=False, indent=2))
            return 0
        if args.prepare:
            if args.backup_root is None:
                raise MigrationError("--prepare 需要 --backup-root")
            backup_manifest = create_backup(
                backup_root=args.backup_root,
                active_root=args.active_root,
                ledger=args.ledger,
                catalog=args.catalog,
                runtime_root=args.runtime_root,
                changes=changes,
                tool_path=Path(__file__).absolute(),
            )
            result = verify_backup(backup_manifest)
            result["status"] = "prepared"
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.manifest is None or args.journal is None:
            raise MigrationError("--apply 需要 --manifest 和 --journal")
        verify_backup_matches_plan(
            args.manifest,
            active_root=args.active_root,
            changes=changes,
        )
        generator = _load_catalog_module(args.script_root)
        result = apply_sources(
            active_root=args.active_root,
            changes=changes,
            backup_manifest=args.manifest,
            journal_path=args.journal,
            generator=generator,
            plugin_cache_root=args.plugin_cache_root,
            ledger=args.ledger,
        )
        result["backup_manifest"] = str(args.manifest)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (MigrationError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
