"""Generate a read-only, local catalog of the installed Codex skills.

The catalog is a derived host fact.  It does not install, update, enable, or
invoke a skill, and it never contacts a remote service.  The plugin cache is
scanned as read-only reference material; the active root and the existing
resource-closure checker are the authoritative local inputs.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


sys.dont_write_bytecode = True
_SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(_SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIRECTORY))

from skill_source_record import parse_current_source_record

SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


DEFAULT_ACTIVE_ROOT = Path(r"D:\agents\skills-manager\skills")
DEFAULT_PLUGIN_CACHE_ROOT = Path(r"D:\Codex\.codex\plugins\cache")
DEFAULT_LEDGER_PATH = Path(
    r"D:\agents\skills-manager\skills\.downloaded-skills-source-state.json"
)
DEFAULT_CLOSURE_SCRIPT = Path(
    r"D:\agents\skills-manager\skills\skill-install-guard\scripts\skill_resource_closure.py"
)
DEFAULT_OUTPUT = Path(r"D:\Codex\.codex\skill-catalog\catalog.json")

_FRONTMATTER_END = {"---", "..."}
_KEY_VALUE = re.compile(r"^(?P<key>[^:#\s][^:]*?)\s*:\s*(?P<value>.*)$")
_VERSION = re.compile(r"^v?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$", re.IGNORECASE)
_EXCLUDED_DIRS = {
    ".agents",
    "_disabled-duplicates",
    "backup",
    "backups",
    "tmp",
    "run-evidence",
}
_CLOSURE_SUMMARY_KEYS = (
    "root",
    "active_skill_count",
    "finding_count",
    "missing_resource_count",
    "missing_source_count",
    "missing_ledger_count",
    "duplicate_ledger_count",
    "stale_ledger_count",
)


def _assert_local_d_path(path: Path, *, label: str) -> None:
    """Keep diagnostic inputs and outputs on this host's local D drive."""

    raw = str(path)
    if raw.startswith("\\\\") or raw.startswith("//"):
        raise CatalogError(f"{label}不能是 UNC 或远程共享路径：{path}")
    if any(part.casefold() == ".agents" for part in path.parts):
        raise CatalogError(f"{label}不能位于已停用的 .agents 路径：{path}")
    if os.name == "nt" and path.drive.casefold() != "d:":
        raise CatalogError(f"{label}必须位于本机 D 盘：{path}")


class CatalogError(RuntimeError):
    """Raised when the local catalog cannot make a safe, explicit claim."""


# --- Scoped closure gate (shared by install_skill_guarded and the system
# provenance repair).  A finding is identified by these fields; ``line`` and
# ``resolved`` are excluded because they drift on unrelated edits and differ
# between staging and active roots.
CLOSURE_FINDING_KEY_FIELDS = ("kind", "skill", "source", "reference")


def parse_closure_output(stdout: str, returncode: int, *, label: str) -> dict[str, Any]:
    """Validate strict closure output; exit 0/1 are results, anything else crashes."""

    if returncode not in (0, 1):
        raise CatalogError(f"{label} 异常退出，退出码 {returncode}")
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise CatalogError(f"{label} 未返回合法 JSON：{exc}") from exc
    summary = payload.get("summary") if isinstance(payload, dict) else None
    findings = payload.get("findings") if isinstance(payload, dict) else None
    if not isinstance(summary, dict) or not isinstance(findings, list):
        raise CatalogError(f"{label} 结果缺少 summary 或 findings")
    if summary.get("finding_count") != len(findings):
        raise CatalogError(f"{label} finding_count 与 findings 数量不一致")
    validate_closure_findings(findings, label=label)
    if (returncode == 0) != (not findings):
        raise CatalogError(
            f"{label} 退出码 {returncode} 与 finding 数量 {len(findings)} 不一致"
        )
    return payload


def validate_closure_findings(findings: Any, *, label: str) -> list[dict[str, Any]]:
    if not isinstance(findings, list):
        raise CatalogError(f"{label} findings 不是数组")
    for finding in findings:
        if not isinstance(finding, dict) or any(
            not isinstance(finding.get(field), str) for field in CLOSURE_FINDING_KEY_FIELDS
        ):
            raise CatalogError(f"{label} finding 结构无效：{finding!r}")
    return findings


def closure_finding_key(finding: dict[str, Any]) -> tuple[str, ...]:
    return tuple(str(finding[field]) for field in CLOSURE_FINDING_KEY_FIELDS)


def finding_hits_targets(finding: dict[str, Any], targets: Iterable[str]) -> bool:
    skill = str(finding.get("skill", ""))
    return any(skill == target or skill.startswith(target + "/") for target in targets)


def classify_closure_findings(
    findings: list[dict[str, Any]],
    *,
    baseline_findings: list[dict[str, Any]] | None,
    targets: Iterable[str],
) -> dict[str, Any]:
    """Split findings into new / target / preexisting (non-blocking) buckets.

    ``baseline_findings=None`` means there is no baseline: every finding is new.
    Blocking = any new finding or any finding on a target (pre-existing or not).
    """

    target_list = list(targets)
    baseline_keys = {closure_finding_key(item) for item in baseline_findings or []}
    new_findings: list[dict[str, Any]] = []
    target_findings: list[dict[str, Any]] = []
    preexisting_findings: list[dict[str, Any]] = []
    for finding in findings:
        is_new = closure_finding_key(finding) not in baseline_keys
        on_target = finding_hits_targets(finding, target_list)
        if is_new:
            new_findings.append(finding)
        if on_target:
            target_findings.append(finding)
        if not is_new and not on_target:
            preexisting_findings.append(finding)
    return {
        "status": "fail" if new_findings or target_findings else "pass",
        "key_fields": list(CLOSURE_FINDING_KEY_FIELDS),
        "targets": target_list,
        "baseline_finding_count": None if baseline_findings is None else len(baseline_findings),
        "finding_count": len(findings),
        "new_findings": new_findings,
        "target_findings": target_findings,
        "preexisting_findings": preexisting_findings,
    }


def verify_catalog_closure_check(
    check: Any,
    *,
    targets: Iterable[str],
    baseline_findings: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Accept ``pass`` or ``preexisting-findings`` that block nothing for ``targets``.

    Used by install_skill_guarded.verify_catalog and the system provenance
    repair; it re-derives the verdict instead of trusting the recorded gate.
    """

    if not isinstance(check, dict):
        raise CatalogError("catalog checks.resource_closure 缺失")
    status = check.get("status")
    if status == "pass":
        if check.get("finding_count") != 0:
            raise CatalogError("catalog resource_closure=pass 但 finding_count 不为 0")
        return {"status": "pass", "finding_count": 0, "preexisting_findings": []}
    if status != "preexisting-findings":
        raise CatalogError(f"catalog resource_closure 状态不可接受：{status!r}")
    gate = check.get("gate")
    if not isinstance(gate, dict):
        raise CatalogError("catalog resource_closure 缺少 gate 判定")
    if gate.get("new_findings") != [] or gate.get("target_findings") != []:
        raise CatalogError("catalog resource_closure gate 含新增或 target finding")
    preexisting = validate_closure_findings(
        gate.get("preexisting_findings"), label="catalog resource_closure"
    )
    if not preexisting or check.get("finding_count") != len(preexisting):
        raise CatalogError("catalog resource_closure finding_count 与既有 finding 不一致")
    target_list = list(targets)
    gate_targets = gate.get("targets")
    if not isinstance(gate_targets, list) or not set(target_list) <= set(gate_targets):
        raise CatalogError("catalog resource_closure gate 未覆盖本事务 targets")
    on_target = [item for item in preexisting if finding_hits_targets(item, target_list)]
    if on_target:
        raise CatalogError(
            "catalog resource_closure 有落在 target 上的 finding："
            + json.dumps(on_target, ensure_ascii=False)
        )
    if baseline_findings is not None:
        baseline_keys = {closure_finding_key(item) for item in baseline_findings}
        new = [item for item in preexisting if closure_finding_key(item) not in baseline_keys]
        if new:
            raise CatalogError(
                "catalog resource_closure 有 baseline 外的新 finding："
                + json.dumps(new, ensure_ascii=False)
            )
    return {
        "status": "preexisting-findings",
        "finding_count": len(preexisting),
        "preexisting_findings": preexisting,
    }


def _utc_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def _timestamp(value: float) -> str:
    return _datetime.datetime.fromtimestamp(
        value, tz=_datetime.timezone.utc
    ).isoformat().replace("+00:00", "Z")


def _is_reparse(path: Path) -> bool:
    """Return whether a path is a symlink/junction/reparse point."""

    try:
        if path.is_symlink():
            return True
        is_junction = getattr(path, "is_junction", None)
        if callable(is_junction) and is_junction():
            return True
        stat_result = path.stat()
    except OSError as exc:
        raise CatalogError(f"无法读取路径属性：{path}：{exc}") from exc
    # FILE_ATTRIBUTE_REPARSE_POINT.  The attribute is present on Windows
    # Python stat results and harmlessly absent on other platforms.
    return bool(getattr(stat_result, "st_file_attributes", 0) & 0x400)


def _normalize_root(value: Path | str, *, required: bool, label: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    _assert_local_d_path(path, label=label)
    if not path.exists():
        if required:
            raise CatalogError(f"{label}不存在：{path}")
        return path.absolute()
    if not path.is_dir():
        raise CatalogError(f"{label}不是目录：{path}")
    if _is_reparse(path):
        raise CatalogError(f"{label}不能是符号链接、junction 或其他 reparse point：{path}")
    return path.resolve()


def _normalize_file(value: Path | str, *, label: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    _assert_local_d_path(path, label=label)
    if not path.exists():
        raise CatalogError(f"{label}不存在：{path}")
    if not path.is_file():
        raise CatalogError(f"{label}不是文件：{path}")
    if _is_reparse(path):
        raise CatalogError(f"{label}不能是符号链接、junction 或其他 reparse point：{path}")
    return path.resolve()


def _path_key(path: Path) -> str:
    return str(path.resolve()).replace("\\", "/").casefold()


def _is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _is_lexically_under(path: Path, root: Path) -> bool:
    try:
        path.absolute().relative_to(root.absolute())
        return True
    except ValueError:
        return False


def _read_stable(path: Path, *, label: str) -> tuple[bytes, os.stat_result]:
    """Read one file and reject a replacement while it is being read."""

    try:
        before = path.stat()
        data = path.read_bytes()
        after = path.stat()
    except (OSError, ValueError) as exc:
        raise CatalogError(f"无法稳定读取{label}：{path}：{exc}") from exc

    before_key = (
        before.st_size,
        before.st_mtime_ns,
        getattr(before, "st_ino", None),
    )
    after_key = (
        after.st_size,
        after.st_mtime_ns,
        getattr(after, "st_ino", None),
    )
    if before_key != after_key:
        raise CatalogError(f"{label}在读取期间发生变化：{path}")
    return data, after


def _strip_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"', "`"}:
        return value[1:-1]
    return value


def _parse_bool(value: Any, *, label: str) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    normalized = _strip_scalar(str(value)).casefold()
    if normalized in {"true", "yes", "on", "1"}:
        return True
    if normalized in {"false", "no", "off", "0"}:
        return False
    raise CatalogError(f"{label}不是受支持的布尔值：{value!r}")


def _openai_invocation_policy(skill_dir: Path) -> dict[str, Any]:
    """Read only the invocation policy from agents/openai.yaml.

    Display fields intentionally remain outside the catalog's authority: they
    may carry a local Chinese presentation overlay.  Invocation policy is
    behavioral and must agree with SKILL.md.
    """

    path = skill_dir / "agents" / "openai.yaml"
    if not path.exists():
        return {"path": None, "allow_implicit_invocation": None}
    if not path.is_file() or _is_reparse(path):
        raise CatalogError(f"agents/openai.yaml 不是安全的普通文件：{path}")
    data, _ = _read_stable(path, label="agents/openai.yaml")
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise CatalogError(f"agents/openai.yaml 不是合法 UTF-8：{path}") from exc
    matches = re.findall(
        r"(?m)^\s*allow_implicit_invocation\s*:\s*([^#\r\n]+)", text
    )
    if len(matches) > 1:
        raise CatalogError(f"agents/openai.yaml 重复声明 allow_implicit_invocation：{path}")
    value = (
        _parse_bool(matches[0].strip(), label=f"{path} 的 allow_implicit_invocation")
        if matches
        else None
    )
    return {"path": str(path), "allow_implicit_invocation": value}


def _fold_block(lines: list[str], *, literal: bool) -> str:
    nonempty = [len(line) - len(line.lstrip(" \t")) for line in lines if line.strip()]
    indent = min(nonempty) if nonempty else 0
    content = [line[indent:] if line.strip() else "" for line in lines]
    if literal:
        return "\n".join(content).rstrip("\n") + ("\n" if content else "")

    result: list[str] = []
    previous_blank = False
    for line in content:
        if not line:
            result.append("\n")
            previous_blank = True
        elif previous_blank:
            result.append(line)
            previous_blank = False
        else:
            if result:
                result.append(" ")
            result.append(line)
    return "".join(result).rstrip() + ("\n" if content else "")


def _parse_frontmatter(data: bytes, *, path: Path) -> dict[str, Any]:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise CatalogError(f"SKILL.md 不是合法 UTF-8：{path}") from exc

    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise CatalogError(f"SKILL.md 缺少 YAML frontmatter 起始标记：{path}")
    try:
        end = next(index for index, line in enumerate(lines[1:], start=1) if line.strip() in _FRONTMATTER_END)
    except StopIteration as exc:
        raise CatalogError(f"SKILL.md 缺少 YAML frontmatter 结束标记：{path}") from exc

    values: dict[str, Any] = {}
    index = 1
    while index < end:
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            index += 1
            continue
        if line[0].isspace():
            # Nested metadata is valid YAML but is not part of the small set
            # of catalog facts.  It is deliberately skipped, not guessed.
            index += 1
            continue
        match = _KEY_VALUE.match(line)
        if match is None:
            raise CatalogError(f"无法解析 SKILL.md frontmatter 行：{path}:{index + 1}")
        key = match.group("key").casefold().replace("-", "_")
        raw_value = match.group("value").strip()
        if raw_value in {"|", "|-", "|+", ">", ">-", ">+"}:
            block: list[str] = []
            index += 1
            while index < end:
                candidate = lines[index]
                if candidate and not candidate[0].isspace():
                    break
                block.append(candidate)
                index += 1
            values[key] = _fold_block(block, literal=raw_value.startswith("|"))
            continue
        values[key] = _strip_scalar(raw_value)
        index += 1

    name = values.get("name")
    if not isinstance(name, str) or not name.strip():
        raise CatalogError(f"SKILL.md frontmatter 缺少有效 name：{path}")
    if "disable_model_invocation" in values:
        values["disable_model_invocation"] = _parse_bool(
            values["disable_model_invocation"],
            label=f"{path} 的 disable-model-invocation",
        )
    return values


def _parse_source(
    data: bytes,
    *,
    path: Path,
    skill_name: str,
    accepted_skill_names: set[str] | None = None,
) -> dict[str, Any]:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise CatalogError(f"SOURCE.md 不是合法 UTF-8：{path}") from exc

    record = parse_current_source_record(text)
    fields = dict(record.fields)
    conflicts = [
        "SOURCE.md 当前记录的 "
        f"{record.labels.get(key, key)} 存在冲突：{list(values)!r}"
        for key, values in record.conflicts.items()
    ]
    accepted_names = {skill_name, *(accepted_skill_names or set())}
    for source_skill in dict.fromkeys(record.values_for("Skill")):
        if source_skill not in accepted_names and "," not in source_skill:
            conflicts.append(f"SOURCE.md Skill={source_skill!r} 与 name={skill_name!r} 不一致")
    return {
        "record_path": str(path),
        "status": fields.get("status", "unknown"),
        "fields": fields,
        "conflicts": conflicts,
    }


def _source_for(
    skill_md: Path,
    *,
    skill_name: str,
    accepted_skill_names: set[str] | None = None,
) -> dict[str, Any]:
    source_path = skill_md.parent / "SOURCE.md"
    if not source_path.exists():
        return {
            "record_path": None,
            "status": "missing",
            "fields": {},
            "conflicts": [],
        }
    if not source_path.is_file() or _is_reparse(source_path):
        raise CatalogError(f"SOURCE.md 不是安全的普通文件：{source_path}")
    data, stat_result = _read_stable(source_path, label="SOURCE.md")
    result = _parse_source(
        data,
        path=source_path,
        skill_name=skill_name,
        accepted_skill_names=accepted_skill_names,
    )
    result["integrity"] = {
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": stat_result.st_size,
        "modified_at": _timestamp(stat_result.st_mtime),
        "read_consistency": "stable",
    }
    return result


def _scan_skill_files(
    root: Path,
    *,
    scope: str,
) -> tuple[list[Path], list[str], dict[str, dict[str, Any]]]:
    found: list[Path] = []
    skipped_reparse: list[str] = []
    visited_directories: dict[str, dict[str, Any]] = {}
    root_key = root.resolve()

    def onerror(error: OSError) -> None:
        raise CatalogError(f"无法完整扫描 {scope} 根目录：{error}") from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        current_path = Path(current)
        visited_directories[_path_key(current_path)] = {
            "path": str(current_path.absolute()),
            "identity": _stat_identity(current_path.lstat()),
            "scanned": True,
        }
        safe_directories: list[str] = []
        for directory in directories:
            child = current_path / directory
            if _is_reparse(child):
                skipped_reparse.append(str(child))
                continue
            if directory.casefold() in _EXCLUDED_DIRS or directory.casefold().startswith("_disabled-"):
                visited_directories[_path_key(child)] = {
                    "path": str(child.absolute()),
                    "identity": _stat_identity(child.lstat()),
                    "scanned": False,
                }
                continue
            safe_directories.append(directory)
        directories[:] = safe_directories

        for filename in files:
            candidate = current_path / filename
            if _is_reparse(candidate):
                skipped_reparse.append(str(candidate))
                continue
            if filename != "SKILL.md":
                continue
            try:
                resolved = candidate.resolve()
                resolved.relative_to(root_key)
            except (OSError, ValueError) as exc:
                raise CatalogError(f"发现越过 {scope} 根目录的 SKILL.md：{candidate}") from exc
            found.append(candidate)
    return (
        sorted(found, key=lambda item: _path_key(item)),
        sorted(set(skipped_reparse), key=str.casefold),
        visited_directories,
    )


def _stat_identity(stat_result: os.stat_result) -> tuple[Any, ...]:
    return (
        getattr(stat_result, "st_dev", None),
        getattr(stat_result, "st_ino", None),
        stat_result.st_size,
        stat_result.st_mtime_ns,
        getattr(stat_result, "st_ctime_ns", None),
        getattr(stat_result, "st_file_attributes", None),
        getattr(stat_result, "st_reparse_tag", None),
    )


def _direct_reparse_target(alias: Path, raw: str | None = None) -> Path:
    raw = os.readlink(alias) if raw is None else raw
    if os.name == "nt" and raw.startswith("\\\\?\\"):
        raw = raw[4:]
    target = Path(raw)
    if not target.is_absolute():
        target = alias.parent / target
    return target.absolute()


def _verify_plugin_cache_aliases(
    *,
    root: Path,
    reparse_paths: list[str],
    visited_directories: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[str], list[dict[str, str]]]:
    """Accept only stable cache-local ``latest`` aliases to scanned physical trees."""

    root_resolved = root.resolve()
    root_lexical = root.absolute()
    visited = dict(visited_directories)
    reparse = [Path(path).absolute() for path in reparse_paths]
    verified: list[dict[str, Any]] = []
    unsafe: list[str] = []
    failures: list[dict[str, str]] = []

    def reject(alias: Path, reason: str) -> None:
        unsafe.append(str(alias))
        failures.append({"path": str(alias), "reason": reason})

    for raw_alias in sorted(reparse_paths, key=str.casefold):
        alias = Path(raw_alias).absolute()
        try:
            alias_before = alias.lstat()
            if alias.name.casefold() != "latest":
                reject(alias, "unsupported-reparse-name")
                continue

            raw_target_before = os.readlink(alias)
            direct_target = _direct_reparse_target(alias, raw_target_before)
            raw_direct = str(direct_target)
            if raw_direct.startswith(("\\\\", "//")):
                reject(alias, "target-outside-plugin-cache")
                continue
            if os.name == "nt" and direct_target.drive.casefold() != root_lexical.drive.casefold():
                reject(alias, "target-outside-plugin-cache")
                continue
            try:
                direct_target.relative_to(root_lexical)
            except ValueError:
                reject(alias, "target-outside-plugin-cache")
                continue

            relative_target = direct_target.relative_to(root_lexical)
            cursor = root_lexical
            target_chain_unsafe = False
            for part in relative_target.parts:
                cursor = cursor / part
                if _is_reparse(cursor):
                    reject(alias, "reparse-chain")
                    target_chain_unsafe = True
                    break
            if target_chain_unsafe:
                continue
            if not direct_target.is_dir():
                reject(alias, "target-not-physical-directory")
                continue

            target = direct_target.resolve(strict=True)
            if target == root_resolved:
                reject(alias, "target-is-plugin-cache-root")
                continue
            if _is_lexically_under(alias, target):
                reject(alias, "target-contains-alias")
                continue

            target_key = _path_key(target)
            scanned_target = visited.get(target_key)
            if scanned_target is None or scanned_target.get("scanned") is not True:
                reject(alias, "target-tree-not-scanned")
                continue
            target_before = direct_target.lstat()
            if _stat_identity(target_before) != scanned_target["identity"]:
                reject(alias, "target-changed-after-scan")
                continue

            scanned_target_tree = [
                item
                for item in visited.values()
                if _is_lexically_under(Path(item["path"]), target)
            ]
            target_tree_failure: str | None = None
            for item in scanned_target_tree:
                if item.get("scanned") is not True:
                    target_tree_failure = "target-tree-not-scanned"
                    break
                scanned_path = Path(item["path"])
                try:
                    current_identity = _stat_identity(scanned_path.lstat())
                except OSError:
                    target_tree_failure = "target-tree-changed-after-scan"
                    break
                if _is_reparse(scanned_path) or current_identity != item["identity"]:
                    target_tree_failure = "target-tree-changed-after-scan"
                    break
            if target_tree_failure:
                reject(alias, target_tree_failure)
                continue

            nested_reparse = [
                path
                for path in reparse
                if str(path).casefold() != str(alias).casefold()
                and _is_lexically_under(path, target)
            ]
            if nested_reparse:
                reject(alias, "target-tree-contains-reparse")
                continue

            alias_target = alias.resolve(strict=True)
            if _path_key(alias_target) != _path_key(target):
                reject(alias, "direct-target-resolution-mismatch")
                continue

            alias_after = alias.lstat()
            target_after = direct_target.lstat()
            raw_target_after = os.readlink(alias)
            if raw_target_before != raw_target_after:
                reject(alias, "alias-target-changed-during-scan")
                continue
            if _stat_identity(alias_before) != _stat_identity(alias_after):
                reject(alias, "alias-changed-during-scan")
                continue
            if _stat_identity(target_before) != _stat_identity(target_after):
                reject(alias, "target-changed-during-scan")
                continue

            verified.append(
                {
                    "alias": str(alias),
                    "target": str(target),
                    "verification": "physical-target-already-scanned",
                }
            )
        except (OSError, RuntimeError, ValueError) as exc:
            reject(alias, f"alias-verification-failed:{type(exc).__name__}")

    return verified, sorted(set(unsafe), key=str.casefold), failures


def _ledger_state(data: Any) -> dict[str, list[dict[str, str]]]:
    if not isinstance(data, dict):
        raise CatalogError("source-state ledger 顶层必须是 JSON 对象")
    states: dict[str, list[dict[str, str]]] = {}

    def add(name: Any, state: str, source: Any = None) -> None:
        if not isinstance(name, str) or not name.strip():
            return
        normalized = name.strip()
        states.setdefault(normalized, []).append(
            {"state": state, "source": str(source) if source else ""}
        )

    for entry in data.get("sources", []):
        if not isinstance(entry, dict):
            continue
        source_id = entry.get("id") or entry.get("repo") or "source"
        skills = entry.get("skills", [])
        if isinstance(skills, list):
            for skill in skills:
                add(skill, "source", source_id)
    for entry in data.get("unresolved", []):
        if isinstance(entry, dict):
            add(entry.get("name"), "unresolved", "unresolved")
        else:
            add(entry, "unresolved", "unresolved")
    for entry in data.get("deleted", []):
        if isinstance(entry, dict):
            add(entry.get("name"), "deleted", "deleted")
        else:
            add(entry, "deleted", "deleted")
    return states


def _load_ledger(path: Path) -> tuple[dict[str, Any], dict[str, list[dict[str, str]]], dict[str, Any]]:
    data_bytes, stat_result = _read_stable(path, label="source-state ledger")
    try:
        data = json.loads(data_bytes.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CatalogError(f"source-state ledger 不是合法 UTF-8 JSON：{path}") from exc
    states = _ledger_state(data)
    fingerprint = {
        "sha256": hashlib.sha256(data_bytes).hexdigest(),
        "size": stat_result.st_size,
        "modified_at": _timestamp(stat_result.st_mtime),
        "read_consistency": "stable",
    }
    return data, states, fingerprint


def _validate_closure(
    result: dict[str, Any],
    *,
    active_root: Path,
    active_count: int,
    closure_gate: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate closure; strict (zero findings) unless ``closure_gate`` is given.

    ``closure_gate`` = {"baseline_findings": [...], "targets": [...]} enables the
    baseline-diff + target-scoped rule: new or target findings still fail,
    pre-existing non-target findings yield status ``preexisting-findings``.
    """
    if not isinstance(result, dict):
        raise CatalogError("资源闭包结果必须是 JSON 对象")
    summary = result.get("summary")
    findings = result.get("findings")
    if not isinstance(summary, dict) or not isinstance(findings, list):
        raise CatalogError("资源闭包结果缺少 summary 或 findings")
    missing = [key for key in _CLOSURE_SUMMARY_KEYS if key not in summary]
    if missing:
        raise CatalogError(f"资源闭包结果缺少字段：{', '.join(missing)}")
    if _path_key(Path(str(summary["root"]))) != _path_key(active_root):
        raise CatalogError("资源闭包结果的 root 与 active root 不一致")
    for key in _CLOSURE_SUMMARY_KEYS[1:]:
        if not isinstance(summary[key], int) or summary[key] < 0:
            raise CatalogError(f"资源闭包结果字段无效：{key}")
    if summary["active_skill_count"] != active_count:
        raise CatalogError(
            "资源闭包 active_skill_count 与目录扫描不一致："
            f"{summary['active_skill_count']} != {active_count}"
        )
    if summary["finding_count"] != len(findings):
        raise CatalogError("资源闭包 finding_count 与 findings 数量不一致")
    if closure_gate is not None:
        validate_closure_findings(findings, label="资源闭包结果")
        gate = classify_closure_findings(
            findings,
            baseline_findings=closure_gate["baseline_findings"],
            targets=closure_gate["targets"],
        )
        if gate["status"] != "pass":
            raise CatalogError(
                "资源闭包门禁未通过："
                + json.dumps(
                    {
                        "new_findings": gate["new_findings"],
                        "target_findings": gate["target_findings"],
                    },
                    ensure_ascii=False,
                )
            )
        return {
            "status": "preexisting-findings" if findings else "pass",
            "coverage": "heuristic",
            "summary": summary,
            "finding_count": len(findings),
            "gate": gate,
        }
    failure_fields = [key for key in _CLOSURE_SUMMARY_KEYS[3:] if summary[key] != 0]
    if summary["finding_count"] or failure_fields:
        raise CatalogError(
            "资源闭包检查未通过："
            + json.dumps(
                {"finding_count": summary["finding_count"], "failed_fields": failure_fields},
                ensure_ascii=False,
            )
        )
    return {
        "status": "pass",
        "coverage": "heuristic",
        "summary": summary,
        "finding_count": len(findings),
    }


def _run_resource_closure(active_root: Path) -> dict[str, Any]:
    script = _normalize_file(DEFAULT_CLOSURE_SCRIPT, label="资源闭包脚本")
    interpreter = Path(sys.executable).resolve()
    if not interpreter.is_file():
        raise CatalogError(f"当前 Python 解释器不是普通文件：{interpreter}")
    command = [
        str(interpreter),
        str(script),
        "--root",
        str(active_root),
        "--strict",
        "--format",
        "json",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            shell=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env={"PYTHONDONTWRITEBYTECODE": "1"},
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
    except OSError as exc:
        raise CatalogError(f"无法运行本地资源闭包脚本：{exc}") from exc
    if completed.returncode not in (0, 1):
        detail = (completed.stderr or completed.stdout).strip()
        raise CatalogError(f"资源闭包脚本失败（exit {completed.returncode}）：{detail}")
    # exit 1 = strict findings; whether they block is decided by _validate_closure.
    return parse_closure_output(completed.stdout, completed.returncode, label="资源闭包脚本")


def _identity_fields(
    *,
    skill_path: Path,
    root: Path,
    scope: str,
    name: str,
    content_sha256: str,
    source: dict[str, Any],
) -> dict[str, Any]:
    relative = skill_path.relative_to(root)
    parts = relative.parts
    provider = "local" if scope in {"active", "system"} else (parts[0] if parts else "cache")
    version = next((part for part in parts if _VERSION.match(part)), None)
    package = "/".join(parts[:-1]) or "."
    source_fields = source.get("fields", {})
    source_identity = ":".join(
        value
        for value in (
            source_fields.get("repository", ""),
            source_fields.get("ref", ""),
            source_fields.get("stable_catalog_ref", ""),
            source_fields.get("upstream_path", ""),
        )
        if value
    )
    identity_payload = {
        "scope": scope,
        "provider": provider,
        "package": package,
        "version": version or "unspecified",
        "name": name,
        "content_sha256": content_sha256,
        "source_identity": source_identity,
    }
    artifact_id = "artifact:" + hashlib.sha256(
        json.dumps(identity_payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()[:32]
    location_id = "location:" + hashlib.sha256(
        _path_key(skill_path).encode("utf-8")
    ).hexdigest()[:32]
    return {
        "artifact_id": artifact_id,
        "location_id": location_id,
        "provider": provider,
        "package": package,
        "version": version,
        "source_identity": source_identity or None,
    }


def _artifact(
    *,
    skill_path: Path,
    root: Path,
    scope: str,
    read_only: bool,
    ledger_states: dict[str, list[dict[str, str]]],
    closure_status: str,
    closure_finding_skills: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    data, stat_result = _read_stable(skill_path, label="SKILL.md")
    frontmatter = _parse_frontmatter(data, path=skill_path)
    name = str(frontmatter["name"]).strip()
    content_sha256 = hashlib.sha256(data).hexdigest()
    source = _source_for(
        skill_path,
        skill_name=name,
        accepted_skill_names={f".system/{name}"} if scope == "system" else None,
    ) if scope != "plugin-cache" else {
        "record_path": None,
        "status": "not-applicable",
        "fields": {},
        "conflicts": [],
    }
    identity = _identity_fields(
        skill_path=skill_path,
        root=root,
        scope=scope,
        name=name,
        content_sha256=content_sha256,
        source=source,
    )
    ledger_keys = [skill_path.parent.relative_to(root).as_posix()]
    ledger_entries = (
        [entry for key in ledger_keys for entry in ledger_states.get(key, [])]
        if scope != "plugin-cache"
        else []
    )
    active_entries = [entry for entry in ledger_entries if entry["state"] in {"source", "unresolved"}]
    has_deleted = any(entry["state"] == "deleted" for entry in ledger_entries)
    conflicts = list(source.get("conflicts", []))
    if len(active_entries) != 1 or has_deleted:
        if len(active_entries) == 0:
            ledger_coverage = "deleted" if has_deleted else "missing"
        else:
            ledger_coverage = "conflict"
        if has_deleted:
            conflicts.append("ledger 同时把该 skill 标为 deleted")
        if len(active_entries) > 1:
            conflicts.append("ledger 对该 skill 存在多个 active 记录")
    else:
        ledger_coverage = "pass"
    ledger_state = sorted({entry["state"] for entry in ledger_entries})
    ledger_records = sorted(
        {entry["source"] for entry in ledger_entries if entry["source"]}
    )

    disable_value = frontmatter.get("disable_model_invocation")
    openai_policy = _openai_invocation_policy(skill_path.parent)
    allow_implicit = openai_policy["allow_implicit_invocation"]
    effective_disabled = disable_value is True
    if allow_implicit is not None and allow_implicit == effective_disabled:
        conflicts.append(
            "SKILL.md disable-model-invocation 与 agents/openai.yaml "
            "allow_implicit_invocation 语义冲突"
        )
    mode = "user-invoked" if disable_value is True else "model-invoked"
    relative = skill_path.relative_to(root).as_posix()
    return {
        "artifact_id": identity["artifact_id"],
        "location_id": identity["location_id"],
        "name": name,
        "scope": scope,
        "read_only": read_only,
        "root": str(root),
        "skill_path": str(skill_path.parent),
        "skill_md_path": str(skill_path),
        "relative_path": relative,
        "identity": {
            "provider": identity["provider"],
            "package": identity["package"],
            "version": identity["version"],
            "source_identity": identity["source_identity"],
        },
        "invocation": {
            "mode": mode,
            "description_present": bool(str(frontmatter.get("description", "")).strip()),
            "disable_model_invocation": disable_value,
            "openai_yaml_path": openai_policy["path"],
            "allow_implicit_invocation": allow_implicit,
        },
        "source": source,
        "ledger": {
            "coverage": ledger_coverage,
            "states": ledger_state,
            "records": ledger_records,
        },
        "ledger_coverage": ledger_coverage,
        "conflicts": conflicts,
        "integrity": {
            "skill_md_sha256": content_sha256,
            "size": stat_result.st_size,
            "modified_at": _timestamp(stat_result.st_mtime),
            "read_consistency": "stable",
        },
        "resource_closure": (
            "not-run"
            if scope == "plugin-cache" or closure_status not in {"pass", "preexisting-findings"}
            else "preexisting-findings"
            if skill_path.parent.relative_to(root).as_posix() in closure_finding_skills
            else "validated"
        ),
        "runtime_verification": "unverified",
    }


def _root_summary(
    *,
    scope: str,
    root: Path,
    artifacts: Iterable[dict[str, Any]],
    read_only: bool,
    skipped_reparse: list[str],
    verified_reparse_aliases: list[dict[str, Any]] | None = None,
    reparse_failures: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    return {
        "scope": scope,
        "root": str(root),
        "read_only": read_only,
        "artifact_count": sum(1 for item in artifacts if item["scope"] == scope),
        "skipped_reparse": skipped_reparse,
        "verified_reparse_aliases": verified_reparse_aliases or [],
        "reparse_failures": reparse_failures or [],
        "scan_status": "partial" if skipped_reparse else "complete",
    }


def build_catalog(
    active_root: Path,
    plugin_cache_root: Path,
    ledger_path: Path,
    resource_closure: dict[str, Any] | None = None,
    generated_at: str | None = None,
    closure_gate: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a catalog without writing any file or contacting a remote service."""

    active = _normalize_root(active_root, required=True, label="active root")
    cache = _normalize_root(plugin_cache_root, required=True, label="plugin cache root")
    ledger = _normalize_file(ledger_path, label="source-state ledger")

    active_paths, active_reparse, _ = _scan_skill_files(active, scope="active")
    if active_reparse:
        raise CatalogError(
            "active root 内存在未扫描的 reparse point，拒绝生成不完整目录："
            + ", ".join(active_reparse)
        )
    cache_paths: list[Path] = []
    cache_reparse: list[str] = []
    cache_reparse_candidates: list[str] = []
    cache_visited: dict[str, dict[str, Any]] = {}
    cache_verified_aliases: list[dict[str, Any]] = []
    cache_reparse_failures: list[dict[str, str]] = []
    if cache.exists():
        cache_paths, cache_reparse, cache_visited = _scan_skill_files(
            cache,
            scope="plugin-cache",
        )
        cache_reparse_candidates = list(cache_reparse)
        (
            cache_verified_aliases,
            cache_reparse,
            cache_reparse_failures,
        ) = _verify_plugin_cache_aliases(
            root=cache,
            reparse_paths=cache_reparse_candidates,
            visited_directories=cache_visited,
        )

    _, ledger_states, ledger_fingerprint = _load_ledger(ledger)
    active_count = len(active_paths)
    if resource_closure is None:
        closure_info = {"status": "not-run", "coverage": "heuristic", "summary": None, "finding_count": None}
    else:
        closure_info = _validate_closure(
            resource_closure,
            active_root=active,
            active_count=active_count,
            closure_gate=closure_gate,
        )
    closure_finding_skills = frozenset(
        str(item.get("skill"))
        for item in (resource_closure or {}).get("findings", [])
        if isinstance(item, dict)
    )

    artifacts: list[dict[str, Any]] = []
    for path in active_paths:
        scope = "system" if ".system" in path.relative_to(active).parts else "active"
        artifacts.append(
            _artifact(
                skill_path=path,
                root=active,
                scope=scope,
                read_only=False,
                ledger_states=ledger_states,
                closure_status=closure_info["status"],
                closure_finding_skills=closure_finding_skills,
            )
        )
    for path in cache_paths:
        artifacts.append(
            _artifact(
                skill_path=path,
                root=cache,
                scope="plugin-cache",
                read_only=True,
                ledger_states=ledger_states,
                closure_status=closure_info["status"],
            )
        )
    artifacts.sort(key=lambda item: (item["scope"], item["name"].casefold(), item["relative_path"].casefold()))

    if cache_reparse_candidates:
        (
            cache_verified_aliases,
            cache_reparse,
            cache_reparse_failures,
        ) = _verify_plugin_cache_aliases(
            root=cache,
            reparse_paths=cache_reparse_candidates,
            visited_directories=cache_visited,
        )

    ledger_conflicts = [
        {
            "name": item["name"],
            "scope": item["scope"],
            "conflicts": item["conflicts"],
        }
        for item in artifacts
        if item["scope"] != "plugin-cache" and item["conflicts"]
    ]
    active_coverage = [
        item["ledger_coverage"]
        for item in artifacts
        if item["scope"] in {"active", "system"}
    ]
    if ledger_conflicts:
        ledger_status = "conflict"
    elif active_coverage and all(value == "pass" for value in active_coverage):
        ledger_status = "pass"
    else:
        ledger_status = "partial"

    return {
        "schema_version": 1,
        "generated_at": generated_at or _utc_now(),
        "authority": str(ledger),
        "snapshot": {
            "status": "per-file-stable-not-atomic",
            "ledger": ledger_fingerprint,
            "remote_access": "none",
            "runtime_verification": "unverified",
        },
        "roots": [
            _root_summary(
                scope="active",
                root=active,
                artifacts=artifacts,
                read_only=False,
                skipped_reparse=[],
            ),
            _root_summary(
                scope="system",
                root=active / ".system",
                artifacts=artifacts,
                read_only=False,
                skipped_reparse=[],
            ),
            _root_summary(
                scope="plugin-cache",
                root=cache,
                artifacts=artifacts,
                read_only=True,
                skipped_reparse=cache_reparse,
                verified_reparse_aliases=cache_verified_aliases,
                reparse_failures=cache_reparse_failures,
            ),
        ],
        "checks": {
            "scan_complete": not cache_reparse,
            "ledger": {
                "status": ledger_status,
                "active_artifact_count": len(active_coverage),
                "covered_count": sum(value == "pass" for value in active_coverage),
                "conflicts": ledger_conflicts,
            },
            "resource_closure": closure_info,
        },
        "artifacts": artifacts,
    }


def _safe_output_path(output_path: Path | str, *, active_root: Path, cache_root: Path) -> Path:
    path = Path(output_path).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    path = path.absolute()
    _assert_local_d_path(path, label="输出路径")
    existing_parent = path.parent
    while not existing_parent.exists() and existing_parent != existing_parent.parent:
        existing_parent = existing_parent.parent
    if existing_parent.exists() and _is_reparse(existing_parent):
        raise CatalogError(f"输出目录不能是 reparse point：{existing_parent}")
    resolved = path.resolve(strict=False)
    if _is_under(resolved, active_root) or _is_under(resolved, cache_root):
        raise CatalogError("输出路径不能位于 active root 或 plugin cache 内")
    return path


def write_catalog(catalog: dict[str, Any], output_path: Path) -> None:
    """Write UTF-8 JSON atomically; retain the old target if replacement fails."""

    if not isinstance(catalog, dict):
        raise CatalogError("catalog 必须是 JSON 对象")
    output = Path(output_path).expanduser()
    if not output.is_absolute():
        output = Path.cwd() / output
    output = output.absolute()
    _assert_local_d_path(output, label="输出路径")
    parent = output.parent
    temp_path: Path | None = None
    try:
        parent.mkdir(parents=True, exist_ok=True)
        if _is_reparse(parent):
            raise CatalogError(f"输出目录不能是 reparse point：{parent}")
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            prefix=f".{output.name}.",
            suffix=".tmp",
            dir=parent,
            delete=False,
        ) as handle:
            temp_path = Path(handle.name)
            json.dump(catalog, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, output)
        temp_path = None
    except CatalogError:
        raise
    except (OSError, TypeError, ValueError) as exc:
        raise CatalogError(f"无法原子写入 catalog：{output}：{exc}") from exc
    finally:
        if temp_path is not None:
            try:
                temp_path.unlink(missing_ok=True)
            except OSError:
                pass


def _summary(catalog: dict[str, Any], *, mode: str, output: Path) -> dict[str, Any]:
    artifacts = catalog["artifacts"]
    counts: dict[str, int] = {}
    for item in artifacts:
        counts[item["scope"]] = counts.get(item["scope"], 0) + 1
    return {
        "mode": mode,
        "write": mode == "write",
        "output": str(output),
        "artifact_count": len(artifacts),
        "scope_counts": counts,
        "checks": catalog["checks"],
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="生成本机 Codex skill 派生目录")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="只扫描并输出摘要（默认）")
    mode.add_argument("--write", action="store_true", help="通过原子替换写入 catalog")
    parser.add_argument("--active-root", type=Path, default=DEFAULT_ACTIVE_ROOT)
    parser.add_argument("--plugin-cache-root", type=Path, default=DEFAULT_PLUGIN_CACHE_ROOT)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER_PATH)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--closure-baseline",
        type=Path,
        help="事务写入前的 strict closure JSON；提供后按基线差分 + target 作用域判定",
    )
    parser.add_argument(
        "--closure-target",
        action="append",
        default=[],
        help="本事务 target skill（相对 active root，如 .system/imagegen），可重复",
    )
    return parser


def _load_closure_gate(baseline_path: Path | None, targets: list[str]) -> dict[str, Any] | None:
    if baseline_path is None:
        if targets:
            raise CatalogError("--closure-target 必须与 --closure-baseline 一起使用")
        return None
    path = _normalize_file(baseline_path, label="closure baseline")
    try:
        payload = json.loads(path.read_bytes().decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CatalogError(f"closure baseline 不是合法 UTF-8 JSON：{path}") from exc
    if not isinstance(payload, dict):
        raise CatalogError("closure baseline 必须是 JSON 对象")
    findings = validate_closure_findings(payload.get("findings"), label="closure baseline")
    return {"baseline_findings": findings, "targets": list(targets)}


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    mode = "write" if args.write else "dry-run"
    try:
        active = _normalize_root(args.active_root, required=True, label="active root")
        cache = _normalize_root(args.plugin_cache_root, required=True, label="plugin cache root")
        ledger = _normalize_file(args.ledger, label="source-state ledger")
        output = _safe_output_path(args.output, active_root=active, cache_root=cache)
        closure_gate = _load_closure_gate(args.closure_baseline, args.closure_target)
        closure = _run_resource_closure(active)
        catalog = build_catalog(
            active_root=active,
            plugin_cache_root=cache,
            ledger_path=ledger,
            resource_closure=closure,
            closure_gate=closure_gate,
        )
        if catalog["checks"]["ledger"]["status"] == "conflict":
            raise CatalogError("ledger 与 SOURCE.md 存在冲突，拒绝写入")
        if mode == "write":
            write_catalog(catalog, output)
        print(json.dumps(_summary(catalog, mode=mode, output=output), ensure_ascii=False, indent=2))
        return 0
    except CatalogError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
