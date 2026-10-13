#!/usr/bin/env python3
"""Install a Codex skill and atomically reconcile its local governance state.

The model-facing ``skill-install-guard`` skill decides whether a candidate may
be installed.  This wrapper is the operational boundary: it stages the
candidate, writes provenance and the unified ledger, runs resource closure,
regenerates the local catalog, verifies the postcondition, and rolls back on
failure.  The bundled system installer remains an upstream helper and is not
modified.

Source: ``D:/agents/projects/统一环境/modules/skill-supply-chain/implementation``.
Edit it there, then run that repo's ``scripts/Deploy-SkillInstallGuarded.ps1``
to copy it into ``D:/Codex/.codex/scripts``.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as _datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Iterator, NamedTuple, Sequence
from urllib.parse import unquote, urlparse

import yaml


sys.dont_write_bytecode = True

_SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(_SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIRECTORY))

from skill_source_record import CurrentSourceRecord, parse_current_source_record
from generate_skill_catalog import (
    CLOSURE_FINDING_KEY_FIELDS,
    CatalogError,
    classify_closure_findings,
    closure_finding_key,
    finding_hits_targets,
    verify_catalog_closure_check,
)
from system_skill_provenance_repair import (
    SKILL_CREATOR_CRITICAL_FILES,
    SKILL_CREATOR_OVERLAY_KIND,
    SystemProvenanceRepairError,
    _identity as system_path_identity,
    _query_package_identity as query_system_package_identity,
    _source_record as system_source_record,
    skill_creator_overlay_ledger_projection,
    system_skill_payload_inventory,
    system_skill_integrity,
    validate_skill_creator_compatibility_overlay,
)


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

SAFE_SKILL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
TARGET_SCOPES = frozenset({"active", "system"})
REPO_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$")
SHA256_HEX = re.compile(r"^[0-9a-fA-F]{64}$")
ASCII_DISPLAY_NAME = re.compile(r"^[\x20-\x7e]+$")
CJK_TEXT = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
LATIN_TEXT = re.compile(r"[A-Za-z]")
# C0 controls except tab/LF/CR; e.g. a non-raw "D:\agents" literal yields BEL.
SOURCE_RECORD_FORBIDDEN_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
DRIVE_ABSOLUTE_PATH = re.compile(r"^[A-Za-z]:[\\/]")


class UniqueSafeLoader(yaml.SafeLoader):
    pass


def _unique_mapping(loader: yaml.SafeLoader, node: yaml.nodes.MappingNode, deep: bool = False) -> dict:
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise yaml.YAMLError(f"duplicate key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueSafeLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_mapping)
CANDIDATE_TREE_HASH_ALGORITHM = (
    "sha256(utf8(concat(sorted_unicode_codepoint("
    "D + tab + relative_posix_directory + lf, or "
    "F + tab + relative_posix_file + tab + file_sha256 + lf)))); "
    "excludes any path segment named .git or __pycache__, and files ending in .pyc"
)
CANDIDATE_EXCLUDED_DIRECTORIES = frozenset({".git", "__pycache__"})
CANDIDATE_EXCLUDED_PATTERNS = [
    "**/.git",
    "**/.git/**",
    "**/__pycache__",
    "**/__pycache__/**",
    "**/*.pyc",
]


class InstallError(RuntimeError):
    """A fail-closed wrapper error."""


class RecoveryRequiredError(InstallError):
    """The wrapper could not prove that pre-transaction active state was restored."""


class BundledSkillProof(NamedTuple):
    """The bound identity and staged provenance of one bundled skill."""

    top_level_name: str
    path: str
    name: str
    skill_md_sha256: str | None = None
    source_md_sha256: str | None = None

    @property
    def ledger_key(self) -> str:
        return f"{self.top_level_name}/{self.path}"

    def with_staged_integrity(
        self,
        *,
        skill_md_sha256: str,
        source_md_sha256: str,
    ) -> "BundledSkillProof":
        return self._replace(
            skill_md_sha256=skill_md_sha256,
            source_md_sha256=source_md_sha256,
        )

    def require_staged_integrity(self) -> tuple[str, str]:
        if (
            not isinstance(self.skill_md_sha256, str)
            or not isinstance(self.source_md_sha256, str)
            or not SHA256_HEX.fullmatch(self.skill_md_sha256)
            or not SHA256_HEX.fullmatch(self.source_md_sha256)
        ):
            raise InstallError("bundled skill 缺少暂存期 provenance 哈希")
        return self.skill_md_sha256, self.source_md_sha256

    def ledger_projection(self) -> dict[str, str]:
        return {"path": self.ledger_key, "name": self.name}

    def staged_projection(self) -> dict[str, str]:
        skill_md_sha256, source_md_sha256 = self.require_staged_integrity()
        return {
            "path": self.path,
            "name": self.name,
            "ledger_key": self.ledger_key,
            "skill_md_sha256": skill_md_sha256,
            "source_md_sha256": source_md_sha256,
        }

    @classmethod
    def from_staged_projection(cls, value: Any) -> "BundledSkillProof":
        expected_fields = {
            "path",
            "name",
            "ledger_key",
            "skill_md_sha256",
            "source_md_sha256",
        }
        if not isinstance(value, dict) or set(value) != expected_fields:
            raise InstallError("bundled skill 暂存期证明对象不合法")
        path = value.get("path")
        name = value.get("name")
        ledger_key = value.get("ledger_key")
        if (
            not isinstance(path, str)
            or not isinstance(name, str)
            or not isinstance(ledger_key, str)
            or not ledger_key.endswith(f"/{path}")
        ):
            raise InstallError("bundled skill 暂存期证明对象不合法")
        top_level_name = ledger_key[: -(len(path) + 1)]
        if (
            not top_level_name
            or not SAFE_SKILL_NAME.fullmatch(top_level_name)
            or not SAFE_SKILL_NAME.fullmatch(name)
            or not path
            or "\\" in path
            or any(not part or part in {".", ".."} for part in path.split("/"))
        ):
            raise InstallError("bundled skill 暂存期证明对象不合法")
        proof = cls(
            top_level_name=top_level_name,
            path=path,
            name=name,
            skill_md_sha256=value.get("skill_md_sha256"),
            source_md_sha256=value.get("source_md_sha256"),
        )
        proof.require_staged_integrity()
        return proof


def utc_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def today() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).date().isoformat()


def is_reparse(path: Path) -> bool:
    if path.is_symlink():
        return True
    try:
        stat_result = path.lstat()
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise InstallError(f"无法读取路径属性：{path}：{exc}") from exc
    return bool(getattr(stat_result, "st_file_attributes", 0) & 0x400)


def ensure_no_reparse_ancestors(path: Path, *, label: str) -> None:
    for current in (*reversed(path.parents), path):
        if is_reparse(current):
            raise InstallError(
                f"{label}不能位于符号链接、junction 或其他 reparse point 之下：{current}"
            )


def d_path(value: Path | str, *, label: str, must_exist: bool = False) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    path = path.absolute()
    if path.drive.casefold() != "d:":
        raise InstallError(f"{label}必须位于本机 D 盘：{path}")
    ensure_no_reparse_ancestors(path, label=label)
    if must_exist and not path.exists():
        raise InstallError(f"{label}不存在：{path}")
    return path


def ensure_dir(path: Path, *, label: str) -> Path:
    path = d_path(path, label=label)
    if path.exists() and not path.is_dir():
        raise InstallError(f"{label}不是目录：{path}")
    path.mkdir(parents=True, exist_ok=True)
    ensure_no_reparse_ancestors(path, label=label)
    return path


def ensure_file(path: Path, *, label: str) -> Path:
    path = d_path(path, label=label, must_exist=True)
    if not path.is_file():
        raise InstallError(f"{label}不是普通文件：{path}")
    return path


def ensure_tree_no_reparse(root: Path, *, label: str) -> None:
    """Reject links/junctions anywhere in a candidate before copying it."""
    if is_reparse(root):
        raise InstallError(f"{label}不能包含 reparse point：{root}")

    def onerror(error: OSError) -> None:
        raise InstallError(f"无法遍历{label}：{error}") from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        current_path = Path(current)
        for child_name in [*directories, *files]:
            child = current_path / child_name
            if is_reparse(child):
                raise InstallError(f"{label}不能包含 reparse point：{child}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_manifest_sha256(
    files: dict[str, str],
    directories: list[str],
) -> str:
    records = [f"D\t{relative}\n" for relative in directories]
    records.extend(f"F\t{relative}\t{digest}\n" for relative, digest in files.items())
    canonical = "".join(sorted(records))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def candidate_payload_inventory(root: Path) -> tuple[list[str], dict[str, str]]:
    """Inventory exactly the candidate topology eligible for activation."""
    directories_result: list[str] = []
    files_result: dict[str, str] = {}

    if is_reparse(root) or not root.is_dir():
        raise InstallError(f"candidate 安装载荷根必须是普通目录：{root}")

    def onerror(error: OSError) -> None:
        raise InstallError(f"无法遍历 candidate 安装载荷：{root}：{error}") from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        current_path = Path(current)
        retained_directories: list[str] = []
        for name in directories:
            child = current_path / name
            if is_reparse(child) or not child.is_dir():
                raise InstallError(f"candidate 安装载荷只允许普通目录：{child}")
            if name.casefold() in CANDIDATE_EXCLUDED_DIRECTORIES:
                continue
            retained_directories.append(name)
            directories_result.append(child.relative_to(root).as_posix())
        directories[:] = sorted(retained_directories, key=str.casefold)
        files.sort(key=str.casefold)
        for filename in files:
            source = current_path / filename
            if is_reparse(source) or not source.is_file():
                raise InstallError(f"candidate 安装载荷只允许普通文件：{source}")
            if (
                filename.casefold() in CANDIDATE_EXCLUDED_DIRECTORIES
                or filename.casefold().endswith(".pyc")
            ):
                continue
            files_result[source.relative_to(root).as_posix()] = sha256_file(source)
    return sorted(directories_result), files_result


def candidate_payload_file_hashes(root: Path) -> dict[str, str]:
    """Compatibility helper for callers that only need eligible file hashes."""
    return candidate_payload_inventory(root)[1]


def candidate_copy_ignore(directory: str, names: list[str]) -> set[str]:
    ignored: set[str] = set()
    for name in names:
        if name.casefold() in CANDIDATE_EXCLUDED_DIRECTORIES:
            ignored.add(name)
        elif name.casefold().endswith(".pyc") and not (Path(directory) / name).is_dir():
            ignored.add(name)
    return ignored


def candidate_excluded_file_summary(root: Path) -> dict[str, int]:
    included = set(candidate_payload_file_hashes(root))
    excluded_files = 0
    excluded_bytes = 0
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if relative in included:
            continue
        excluded_files += 1
        excluded_bytes += path.stat().st_size
    return {"file_count": excluded_files, "byte_count": excluded_bytes}


def candidate_integrity_payload(candidate: Path) -> dict[str, Any]:
    directories, files = candidate_payload_inventory(candidate)
    skill_md_sha256 = files.get("SKILL.md")
    if skill_md_sha256 is None:
        raise InstallError("candidate 安装载荷缺少 SKILL.md")
    return {
        "algorithm": CANDIDATE_TREE_HASH_ALGORITHM,
        "excluded": CANDIDATE_EXCLUDED_PATTERNS,
        "directory_count": len(directories),
        "file_count": len(files),
        "tree_sha256": tree_manifest_sha256(files, directories),
        "skill_md_sha256": skill_md_sha256,
    }


def validate_candidate_integrity(
    candidate: Path,
    decision: dict[str, Any],
) -> dict[str, Any]:
    integrity = decision.get("candidate_integrity")
    if not isinstance(integrity, dict):
        raise InstallError(
            "本地 --candidate 必须在 decision manifest 中包含 candidate_integrity"
        )
    expected_fields = {
        "algorithm",
        "excluded",
        "directory_count",
        "file_count",
        "tree_sha256",
        "skill_md_sha256",
    }
    if set(integrity) != expected_fields:
        raise InstallError(
            "candidate_integrity 字段必须精确为：" + ", ".join(sorted(expected_fields))
        )
    if integrity.get("algorithm") != CANDIDATE_TREE_HASH_ALGORITHM:
        raise InstallError("candidate_integrity.algorithm 与受管安装载荷算法不一致")
    if integrity.get("excluded") != CANDIDATE_EXCLUDED_PATTERNS:
        raise InstallError("candidate_integrity.excluded 与受管排除规则不一致")
    for field, minimum in (("directory_count", 0), ("file_count", 1)):
        value = integrity.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
            qualifier = "非负整数" if minimum == 0 else "正整数"
            raise InstallError(f"candidate_integrity.{field} 必须是{qualifier}")
    for field in ("tree_sha256", "skill_md_sha256"):
        value = integrity.get(field)
        if not isinstance(value, str) or not SHA256_HEX.fullmatch(value):
            raise InstallError(f"candidate_integrity.{field} 必须是 SHA-256")

    actual = candidate_integrity_payload(candidate)
    normalized_expected = {
        **integrity,
        "tree_sha256": integrity["tree_sha256"].casefold(),
        "skill_md_sha256": integrity["skill_md_sha256"].casefold(),
    }
    if actual != normalized_expected:
        raise InstallError(
            "candidate_integrity 与当前候选安装载荷不一致："
            + json.dumps({"expected": normalized_expected, "actual": actual}, ensure_ascii=False)
        )
    return {
        **actual,
        "excluded_files": candidate_excluded_file_summary(candidate),
    }


def inspect_candidate_integrity(candidate: Path) -> dict[str, Any]:
    ensure_tree_no_reparse(candidate, label="candidate")
    return {
        "candidate_integrity": candidate_integrity_payload(candidate),
        "excluded_files": candidate_excluded_file_summary(candidate),
    }


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path = d_path(path, label="原子写入目标")
    parent = ensure_dir(path.parent, label="原子写入目录")
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=parent,
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def json_document_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_bytes(path, json_document_bytes(value))


def load_json(path: Path, *, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise InstallError(f"{label}不是可读取的合法 UTF-8 JSON：{path}：{exc}") from exc


def strip_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"', "`"}:
        return value[1:-1].strip()
    return value


def read_skill_name(skill_md: Path) -> str:
    skill_md = d_path(skill_md, label="SKILL.md", must_exist=True)
    if is_reparse(skill_md) or not skill_md.is_file():
        raise InstallError(f"SKILL.md 必须是安全的普通文件：{skill_md}")
    try:
        lines = skill_md.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError) as exc:
        raise InstallError(f"无法读取 SKILL.md：{skill_md}：{exc}") from exc
    if not lines or lines[0].strip() != "---":
        raise InstallError(f"SKILL.md 缺少 frontmatter：{skill_md}")
    for line in lines[1:]:
        if line.strip() in {"---", "..."}:
            break
        match = re.match(r"^\s*name\s*:\s*(.+?)\s*$", line)
        if match:
            name = strip_scalar(match.group(1))
            if not name or not SAFE_SKILL_NAME.fullmatch(name):
                raise InstallError(f"SKILL.md 的 name 非法：{skill_md}：{name!r}")
            return name
    raise InstallError(f"SKILL.md frontmatter 缺少 name：{skill_md}")


def validate_openai_display_name(skill_dir: Path, *, label: str) -> None:
    path = skill_dir / "agents" / "openai.yaml"
    if not path.exists():
        return
    path = d_path(path, label=f"{label} agents/openai.yaml", must_exist=True)
    if is_reparse(path) or not path.is_file():
        raise InstallError(f"{label} agents/openai.yaml 必须是安全的普通文件：{path}")
    try:
        data = yaml.load(path.read_text(encoding="utf-8-sig"), Loader=UniqueSafeLoader)
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        raise InstallError(f"{label} agents/openai.yaml 不是合法 YAML：{path}：{exc}") from exc
    if data is None:
        return
    if not isinstance(data, dict):
        raise InstallError(f"{label} agents/openai.yaml 顶层必须是对象：{path}")
    interface = data.get("interface")
    if interface is None:
        return
    if not isinstance(interface, dict):
        raise InstallError(f"{label} agents/openai.yaml interface 必须是对象：{path}")
    display_name = interface.get("display_name")
    if display_name is None:
        return
    if not isinstance(display_name, str) or not display_name.strip():
        raise InstallError(
            f"{label} agents/openai.yaml interface.display_name 必须是非空字符串：{path}"
        )
    if not ASCII_DISPLAY_NAME.fullmatch(display_name):
        raise InstallError(
            f"{label} agents/openai.yaml interface.display_name 必须保留英文，"
            f"只能中文化 short_description 和 default_prompt：{path}：{display_name!r}"
        )


def _chinese_dominant(value: str) -> bool:
    text = value.strip()
    cjk = len(CJK_TEXT.findall(text))
    latin = len(LATIN_TEXT.findall(text))
    return cjk >= 2 and (latin == 0 or cjk / (cjk + latin) >= 0.20) and bool(text and CJK_TEXT.match(text[0]))


def _frontmatter_value(skill_md: Path, key: str) -> str | None:
    lines = skill_md.read_text(encoding="utf-8-sig").splitlines()
    in_frontmatter = bool(lines and lines[0].strip() == "---")
    if not in_frontmatter:
        return None
    index = 1
    while index < len(lines):
        line = lines[index]
        if line.strip() in {"---", "..."}:
            break
        match = re.match(rf"^\s*{re.escape(key)}\s*:\s*(.*?)\s*$", line)
        if match:
            raw = match.group(1).strip()
            if not raw or raw in {">", ">-", ">+", "|", "|-", "|+"}:
                parts = []
                index += 1
                while index < len(lines) and (lines[index].startswith(" ") or not lines[index].strip()):
                    parts.append(lines[index].strip())
                    index += 1
                raw = " ".join(parts)
            return strip_scalar(raw)
        index += 1
    return None


def validate_chinese_display_metadata(skill_dir: Path, *, label: str) -> None:
    """Require Chinese-first user-facing metadata while preserving ASCII identity."""
    skill_md = d_path(skill_dir / "SKILL.md", label=f"{label} SKILL.md", must_exist=True)
    description = _frontmatter_value(skill_md, "description")
    if not description or not _chinese_dominant(description):
        raise InstallError(f"{label} SKILL.md description 必须以中文为主体：{skill_md}")
    path = skill_dir / "agents" / "openai.yaml"
    if not path.exists():
        return
    data = yaml.load(path.read_text(encoding="utf-8-sig"), Loader=UniqueSafeLoader) or {}
    interface = data.get("interface") if isinstance(data, dict) else None
    if not isinstance(interface, dict):
        return
    for field in ("short_description", "default_prompt"):
        value = interface.get(field)
        if value is not None and (not isinstance(value, str) or not _chinese_dominant(value)):
            raise InstallError(f"{label} agents/openai.yaml interface.{field} 必须以中文为主体：{path}")


def read_source_text(path: Path) -> str:
    path = d_path(path, label="SOURCE.md", must_exist=True)
    if is_reparse(path) or not path.is_file():
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
    expected_repo = normalize_repo(repository)
    recorded_repos = source_record_values(path, "Source repository")
    normalized_repos = [normalize_repo(value) for value in recorded_repos]
    if (
        expected_repo is None
        or not normalized_repos
        or any(value != expected_repo for value in normalized_repos)
    ):
        raise InstallError(
            f"{label} SOURCE.md 的 source repository 与 canonical source 不一致"
        )


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


def normalize_repo(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    value = value.strip().rstrip("/")
    if REPO_NAME.fullmatch(value):
        value = f"https://github.com/{value}"
    if value.endswith(".git"):
        value = value[:-4]
    return value.casefold().rstrip("/")


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
    data = load_json(path, label="guard decision manifest")
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
    target_root = d_path(
        active_root / ".system",
        label="system skill root",
        must_exist=True,
    )
    if is_reparse(target_root) or not target_root.is_dir():
        raise InstallError(f"system skill root 必须是安全目录：{target_root}")
    return scope, target_root, [f".system/{name}" for name in names]


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
    provider = ensure_file(args.system_package_provider, label="Store package identity provider")
    interpreter = ensure_file(args.interpreter, label="Python interpreter")
    provider_bytes = provider.read_bytes()
    if sha256_file(provider) != overlay["package_identity_provider_sha256"]:
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
    marker_path = d_path(
        active_root / Path(*str(marker["relative_path"]).split("/")),
        label="system skill marker",
        must_exist=True,
    )
    if sha256_file(marker_path) != marker.get("sha256"):
        raise InstallError("system skill marker hash does not match ledger")
    skill_root = d_path(active_root / ".system" / "skill-creator", label="skill-creator active root", must_exist=True)
    record = next(item for item in provenance["skills"] if item["name"] == "skill-creator")
    if record["official_integrity"] != overlay["official_integrity"]:
        raise InstallError("skill-creator official integrity does not match recorded official baseline")
    baseline_integrity = system_skill_integrity(skill_root)
    if baseline_integrity != record["effective_integrity"]:
        raise InstallError("skill-creator active integrity does not match recorded effective baseline")
    source_path = ensure_file(skill_root / "SOURCE.md", label="skill-creator baseline SOURCE.md")
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
        "baseline_skill_identity": directory_identity(skill_root, label="skill-creator active root"),
        "baseline_inventory": baseline_inventory,
        "source_bytes": None,
    }


def _assert_system_overlay_baseline(
    *,
    overlay_context: dict[str, Any],
    active_root: Path,
    ledger_path: Path | None = None,
) -> None:
    skill_root = d_path(active_root / ".system" / "skill-creator", label="skill-creator active root", must_exist=True)
    if directory_identity(skill_root, label="skill-creator active root") != overlay_context["baseline_skill_identity"]:
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
    target = d_path(staged_root / "skill-creator", label="staged skill-creator", must_exist=True)
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
        if not path.is_file() or sha256_file(path) != overlay["critical_files"][relative]:
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
    active_skill = d_path(
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
        if sha256_file(path) != overlay["critical_files"][relative]:
            raise InstallError(f"active skill-creator critical payload drifted: {relative}")
    source_path = active_skill / "SOURCE.md"
    if source_path.read_bytes() != overlay_context["source_bytes"]:
        raise InstallError("skill-creator SOURCE.md provenance postcheck failed")
    source_hash = sha256_file(source_path)
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
    catalog = load_json(catalog_path, label="skill catalog")
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
    summary = (
        "guarded system provenance overlay: bound skill-creator quick_validate "
        "argument-hint/disable-model-invocation compatibility payload."
    )
    if not any(
        isinstance(item, dict)
        and item.get("skill") == ".system/skill-creator"
        and item.get("summary") == summary
        for item in changes
    ):
        changes.append({"skill": ".system/skill-creator", "date": today(), "summary": summary})
    updated["updated_at"] = today()
    return updated


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


def target_specs(args: argparse.Namespace) -> list[tuple[str, str]]:
    specs: list[tuple[str, str]] = []
    if args.candidate:
        candidate = d_path(args.candidate, label="candidate", must_exist=True)
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

    candidate = d_path(args.candidate, label="canonical rename candidate", must_exist=True)
    ensure_tree_no_reparse(candidate, label="canonical rename candidate")
    candidate_name = read_skill_name(candidate / "SKILL.md")
    if candidate_name != new_name:
        raise InstallError(
            f"canonical rename candidate name 不一致：{candidate_name!r} != {new_name!r}"
        )
    validate_source_record_identity(
        candidate / "SOURCE.md",
        skill_name=new_name,
        repository=repository,
        label="candidate",
    )
    candidate_source = candidate / "SOURCE.md"
    candidate_predecessor = source_record_unique_value(
        candidate_source,
        ("Canonical predecessor",),
        label="candidate",
    )
    candidate_source_id = source_record_unique_value(
        candidate_source,
        ("Source identity",),
        label="candidate",
    )
    candidate_upstream_path = source_record_unique_value(
        candidate_source,
        ("Upstream path",),
        label="candidate",
    )
    candidate_ref = source_record_unique_value(
        candidate_source,
        ("Ref",),
        label="candidate",
    )
    candidate_commit = source_record_unique_value(
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

    old_active = d_path(
        active_root / old_name,
        label="canonical rename 旧 active skill",
        must_exist=True,
    )
    new_active = d_path(active_root / new_name, label="canonical rename 新 active skill")
    if not path_exists_strict(old_active, label="canonical rename 旧 active skill"):
        raise InstallError(f"canonical rename 旧 active skill 不存在：{old_active}")
    if is_reparse(old_active) or not old_active.is_dir():
        raise InstallError(f"canonical rename 旧 active skill 不是安全目录：{old_active}")
    ensure_tree_no_reparse(old_active, label="canonical rename 旧 active skill")
    if path_exists_strict(new_active, label="canonical rename 新 active skill"):
        raise InstallError(f"canonical rename 新 active skill 已存在：{new_active}")
    actual_old_name = read_skill_name(old_active / "SKILL.md")
    if actual_old_name != old_name:
        raise InstallError(
            f"canonical rename 旧 active name 不一致：{actual_old_name!r} != {old_name!r}"
        )
    validate_source_record_identity(
        old_active / "SOURCE.md",
        skill_name=old_name,
        repository=repository,
        label="旧 active skill",
    )
    old_source = old_active / "SOURCE.md"
    old_upstream_path = source_record_unique_value(
        old_source,
        ("Upstream path",),
        label="旧 active skill",
    )
    old_ref = source_record_unique_value(
        old_source,
        ("Ref",),
        label="旧 active skill",
    )
    old_commit = source_record_unique_value(
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
            if ledger_entry_covers(entry, old_name):
                if not isinstance(entry, dict):
                    raise InstallError("canonical rename 旧名 ledger coverage 不合法")
                live_matches.append((section, entry))
            if ledger_entry_covers(entry, new_name):
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
    if normalize_repo(source_entry.get("repo")) != normalize_repo(repository):
        raise InstallError("canonical rename 旧名 ledger source repo 不一致")
    if source_entry.get("ref") != predecessor_source["ref"]:
        raise InstallError("canonical rename 旧名 ledger source ref 不一致")


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
    retired_active = d_path(
        active_root / retired_name,
        label="merge retirement 退役 active skill",
        must_exist=True,
    )
    if is_reparse(retired_active) or not retired_active.is_dir():
        raise InstallError("merge retirement 退役 active skill 不是安全目录")
    ensure_tree_no_reparse(retired_active, label="merge retirement 退役 active skill")
    actual_retired_name = read_skill_name(retired_active / "SKILL.md")
    if actual_retired_name != retired_name:
        raise InstallError("merge retirement 退役 active frontmatter name 不一致")
    actual_retired_sha256 = sha256_file(retired_active / "SKILL.md")
    if actual_retired_sha256 != retired["skill_md_sha256"]:
        raise InstallError("merge retirement 退役 active SKILL.md 哈希漂移")
    verify_tree_seal(
        retired_active,
        seal=retired["tree_seal"],
        label="merge retirement 退役 active skill",
    )
    source_md = retired_active / "SOURCE.md"
    if not source_md.is_file() or is_reparse(source_md):
        raise InstallError("merge retirement 退役 active skill 缺少安全 SOURCE.md")
    recorded_skill = source_record_unique_value(
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
            if ledger_entry_covers(entry, retired_name):
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
            if ledger_entry_covers(entry, target_name):
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

    candidate = d_path(
        args.candidate,
        label="merge retirement survivor candidate",
        must_exist=True,
    )
    target_active = d_path(
        active_root / target_name,
        label="merge retirement update 目标",
        must_exist=True,
    )
    if is_reparse(target_active) or not target_active.is_dir():
        raise InstallError("merge retirement update 目标不是安全 active skill")
    for survivor in retirement["survivors"]:
        survivor_name = survivor["name"]
        if survivor_name == target_name:
            survivor_root = candidate
            label = "merge retirement survivor candidate"
        else:
            survivor_root = d_path(
                active_root / survivor_name,
                label=f"merge retirement survivor {survivor_name}",
                must_exist=True,
            )
            label = f"merge retirement survivor {survivor_name}"
        if is_reparse(survivor_root) or not survivor_root.is_dir():
            raise InstallError(f"{label} 不是安全目录")
        ensure_tree_no_reparse(survivor_root, label=label)
        if read_skill_name(survivor_root / "SKILL.md") != survivor_name:
            raise InstallError(f"{label} frontmatter name 不一致")
        if sha256_file(survivor_root / "SKILL.md") != survivor["skill_md_sha256"]:
            raise InstallError(f"{label} SKILL.md 哈希漂移")


def guarded_retrieval(args: argparse.Namespace) -> str:
    if args.candidate:
        return "guarded wrapper local candidate verified by candidate_integrity"
    if args.url:
        return f"guarded wrapper --url {args.url}"
    return f"guarded wrapper --repo {args.repo} --path {' '.join(args.paths)}"


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
        f"Recorded: {today()}",
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
    atomic_write_bytes(path, (content.rstrip() + "\n").encode("utf-8"))


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
            value = normalize_path(Path(strip_scalar(match.group("value"))))
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
            if isinstance(entry, dict) and normalize_repo(entry.get("repo")) == normalize_repo(repo):
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
    target_source["last_guarded_install"] = utc_now()
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
                    "date": today(),
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
                "date": today(),
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
            changes.append({"skill": name, "date": today(), "summary": marker})
    data["updated_at"] = today()
    return data


def run_process(
    command: list[str],
    *,
    evidence_dir: Path,
    label: str,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        env=env,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    atomic_write_bytes(
        evidence_dir / f"{label}.stdout.txt",
        result.stdout.encode("utf-8", errors="replace"),
    )
    atomic_write_bytes(
        evidence_dir / f"{label}.stderr.txt",
        result.stderr.encode("utf-8", errors="replace"),
    )
    if check and result.returncode != 0:
        raise InstallError(
            f"{label} 失败，退出码 {result.returncode}；详见 {evidence_dir}"
        )
    return result


def run_closure(
    *,
    root: Path,
    closure_script: Path,
    interpreter: Path,
    evidence_dir: Path,
    label: str,
) -> dict[str, Any]:
    """Run strict closure and return a structurally validated JSON payload.

    Exit 0 (clean) and 1 (strict findings) are normal outcomes; findings are
    judged by ``evaluate_closure_gate``.  Any other exit code, invalid JSON or
    an inconsistent payload is a hard failure.
    """
    result = run_process(
        [
            str(interpreter),
            str(closure_script),
            "--root",
            str(root),
            "--strict",
            "--format",
            "json",
        ],
        evidence_dir=evidence_dir,
        label=label,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise InstallError(
            f"{label} 异常退出，退出码 {result.returncode}；详见 {evidence_dir}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise InstallError(f"{label} 未返回合法 JSON：{exc}") from exc
    summary = payload.get("summary") if isinstance(payload, dict) else None
    findings = payload.get("findings") if isinstance(payload, dict) else None
    if not isinstance(summary, dict) or not isinstance(findings, list):
        raise InstallError(f"{label} 结果缺少 summary 或 findings")
    if summary.get("finding_count") != len(findings):
        raise InstallError(f"{label} finding_count 与 findings 数量不一致")
    for finding in findings:
        if not isinstance(finding, dict) or any(
            not isinstance(finding.get(field), str) for field in CLOSURE_FINDING_KEY_FIELDS
        ):
            raise InstallError(f"{label} finding 结构无效：{finding!r}")
    if (result.returncode == 0) != (not findings):
        raise InstallError(
            f"{label} 退出码 {result.returncode} 与 finding 数量 {len(findings)} 不一致"
        )
    return payload


def evaluate_closure_gate(
    *,
    payload: dict[str, Any],
    baseline: dict[str, Any] | None,
    targets: Sequence[str],
    label: str,
) -> dict[str, Any]:
    """Baseline-diff + target-scoped closure gate.

    Blocks on findings absent from the pre-transaction baseline and on every
    finding attributed to a transaction target (pre-existing or not).
    Pre-existing findings outside the targets are reported, not blocking.
    ``baseline=None`` means no baseline exists, so every finding is new.
    """
    gate = {
        "label": label,
        **classify_closure_findings(
            payload["findings"],
            baseline_findings=None if baseline is None else baseline["findings"],
            targets=targets,
        ),
    }
    new_findings = gate["new_findings"]
    target_findings = gate["target_findings"]
    preexisting_findings = gate["preexisting_findings"]
    if gate["status"] != "pass":
        raise InstallError(
            f"{label} 门禁失败：新增 finding {len(new_findings)} 条，"
            f"target finding {len(target_findings)} 条："
            + json.dumps(
                {"new_findings": new_findings, "target_findings": target_findings},
                ensure_ascii=False,
            )
        )
    if preexisting_findings:
        print(
            f"[{label}] 既有非 target closure finding {len(preexisting_findings)} 条"
            "（不阻塞本事务，全根 strict 仍为红，见返回 payload 的 preexisting_findings）",
            file=sys.stderr,
        )
    return gate


def transaction_closure_targets(
    *,
    ledger_names: Sequence[str],
    rename: dict[str, Any] | None,
    merge_retirement: dict[str, Any] | None,
) -> list[str]:
    targets = list(ledger_names)
    if rename is not None:
        targets.append(str(rename["old_name"]))
    if merge_retirement is not None:
        targets.append(str(merge_retirement["retired"]["name"]))
    return targets


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


def bundled_skill_specs(
    *,
    args: argparse.Namespace,
    decision: dict[str, Any],
    names: list[str],
) -> tuple[BundledSkillProof, ...]:
    raw = decision.get("bundled_skills")
    if raw is None:
        return ()
    if not args.candidate:
        raise InstallError("bundled_skills 只允许绑定本地 --candidate 安装载荷")
    if len(names) != 1:
        raise InstallError("bundled_skills 只支持单个顶层安装目标")
    if not isinstance(raw, list) or not raw:
        raise InstallError("bundled_skills 必须是非空数组")

    result: list[BundledSkillProof] = []
    seen_paths: set[str] = set()
    seen_names: set[str] = set()
    top_level_name_keys = {name.casefold() for name in names}
    for index, item in enumerate(raw):
        if not isinstance(item, dict) or set(item) != {"path", "name"}:
            raise InstallError(
                f"bundled_skills[{index}] 字段必须精确为 path、name"
            )
        relative_path = item.get("path")
        skill_name = item.get("name")
        if not isinstance(relative_path, str) or not relative_path.strip():
            raise InstallError(f"bundled_skills[{index}].path 必须是非空字符串")
        if relative_path != relative_path.strip() or any(
            not character.isprintable() for character in relative_path
        ):
            raise InstallError(
                f"bundled_skills[{index}].path 必须是规范的可打印相对路径"
            )
        parts = relative_path.split("/")
        if (
            "\\" in relative_path
            or "`" in relative_path
            or relative_path.startswith("/")
            or re.match(r"^[A-Za-z]:", relative_path)
            or any(
                not part
                or part in {".", ".."}
                or part.casefold() in CANDIDATE_EXCLUDED_DIRECTORIES
                for part in parts
            )
        ):
            raise InstallError(
                f"bundled_skills[{index}].path 必须是 candidate 内安全的 POSIX 相对路径"
            )
        if not isinstance(skill_name, str) or not SAFE_SKILL_NAME.fullmatch(skill_name):
            raise InstallError(f"bundled_skills[{index}].name 不是合法 skill name")
        path_key = relative_path.casefold()
        name_key = skill_name.casefold()
        if path_key in seen_paths:
            raise InstallError(f"bundled_skills[{index}].path 重复：{relative_path}")
        if name_key in seen_names or name_key in top_level_name_keys:
            raise InstallError(f"bundled_skills[{index}].name 重复：{skill_name}")
        seen_paths.add(path_key)
        seen_names.add(name_key)
        result.append(
            BundledSkillProof(
                top_level_name=names[0],
                path=relative_path,
                name=skill_name,
            )
        )
    return tuple(result)


def validate_staged_bundled_skills(
    *,
    stage_root: Path,
    active_root: Path,
    top_level_name: str,
    bundled_proofs: Sequence[BundledSkillProof],
    args: argparse.Namespace,
) -> tuple[BundledSkillProof, ...]:
    verified: list[BundledSkillProof] = []
    for proof in bundled_proofs:
        if proof.top_level_name != top_level_name:
            raise InstallError("bundled skill 证明对象的顶层名称不一致")
        target = stage_root / top_level_name / Path(*proof.path.split("/"))
        if not target.is_dir() or is_reparse(target):
            raise InstallError(f"bundled skill 路径不是安全目录：{target}")
        ensure_tree_no_reparse(target, label=f"bundled skill {proof.name}")
        skill_md = target / "SKILL.md"
        if not skill_md.is_file() or is_reparse(skill_md):
            raise InstallError(f"bundled skill 缺少安全的 SKILL.md：{skill_md}")
        actual_name = read_skill_name(skill_md)
        if actual_name != proof.name:
            raise InstallError(
                "bundled skill name 与 manifest 不一致："
                f"{actual_name!r} != {proof.name!r}"
            )
        validate_openai_display_name(target, label=f"bundled skill {proof.name}")
        validate_chinese_display_metadata(target, label=f"bundled skill {proof.name}")
        source_md = target / "SOURCE.md"
        if not source_md.is_file() or is_reparse(source_md):
            raise InstallError(f"bundled skill 缺少安全的 SOURCE.md：{source_md}")
        source_label = f"bundled skill {proof.name} SOURCE.md"
        reject_source_control_characters(read_source_text(source_md), label=source_label)
        # No wrapper record is appended here, so this record stays current.
        validate_source_record_paths(
            current_source_record(source_md),
            label=source_label,
            local_path=active_root / top_level_name / Path(*proof.path.split("/")),
            active_root=active_root,
        )
        recorded_names = source_record_values(source_md, "Skill")
        if not recorded_names or any(value != proof.name for value in recorded_names):
            raise InstallError(
                f"bundled skill SOURCE.md identity 不一致：{recorded_names!r}"
            )
        source_repo = source_record_unique_value(
            source_md,
            ("Source repository",),
            label=f"bundled skill {proof.name}",
        )
        parsed_repo = urlparse(source_repo)
        if (
            parsed_repo.scheme != "https"
            or not parsed_repo.hostname
            or not parsed_repo.path.strip("/")
            or parsed_repo.username
            or parsed_repo.password
            or parsed_repo.query
            or parsed_repo.fragment
        ):
            raise InstallError(
                f"bundled skill {proof.name} SOURCE.md 必须记录不含凭据的 HTTPS source repository"
            )
        source_record_unique_value(
            source_md,
            ("Upstream path",),
            label=f"bundled skill {proof.name}",
        )
        source_record_unique_value(
            source_md,
            ("Ref",),
            label=f"bundled skill {proof.name}",
        )
        source_record_unique_value(
            source_md,
            ("Commit or revision", "Commit"),
            label=f"bundled skill {proof.name}",
        )
        validate_durable_source_record(
            source_md,
            durable_fields={},
            transient_paths=[Path(args.candidate), Path(args.decision_manifest)],
        )
        verified.append(
            proof.with_staged_integrity(
                skill_md_sha256=sha256_file(skill_md),
                source_md_sha256=sha256_file(source_md),
            )
        )
    return tuple(verified)


def make_staging_ledger(names: list[str], context: dict[str, Any]) -> dict[str, Any]:
    return update_ledger(
        {"updated_at": today(), "notes": [], "sources": [], "unresolved": [], "deleted": []},
        names=names,
        context=context,
    )


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
    ensure_dir(stage_root, label="staging root")
    stage_target_root = (
        stage_root
        if target_scope == "active"
        else ensure_dir(stage_root / ".system", label="system staging root")
    )
    ledger_names = [
        name if target_scope == "active" else f".system/{name}"
        for name, _ in specs
    ]
    candidate_integrity: dict[str, Any] | None = None
    if args.candidate:
        candidate = d_path(args.candidate, label="candidate", must_exist=True)
        ensure_tree_no_reparse(candidate, label="candidate")
        candidate_integrity = validate_candidate_integrity(candidate, decision)
        name = specs[0][0]
        shutil.copytree(candidate, stage_target_root / name, ignore=candidate_copy_ignore)
        copied_seal = tree_content_seal(stage_target_root / name)
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
        run_process(command, evidence_dir=evidence_dir, label="upstream-installer")

    names = [name for name, _ in specs]
    for name, upstream_path in specs:
        target = stage_target_root / name
        if not target.is_dir() or is_reparse(target):
            raise InstallError(f"staging 缺少安全的 skill 目录：{target}")
        ensure_tree_no_reparse(target, label=f"staging skill {name}")
        skill_md = target / "SKILL.md"
        if not skill_md.is_file() or is_reparse(skill_md):
            raise InstallError(f"staging 缺少安全的 SKILL.md：{skill_md}")
        actual_name = read_skill_name(skill_md)
        if actual_name != name:
            raise InstallError(f"SKILL.md name 与目标目录不一致：{actual_name!r} != {name!r}")
        validate_openai_display_name(target, label=f"staging skill {name}")
        validate_chinese_display_metadata(target, label=f"staging skill {name}")
        system_overlay_context = context.get("system_provenance_overlay")
        if (
            isinstance(system_overlay_context, dict)
            and target_scope == "system"
            and name == "skill-creator"
        ):
            source_bytes = system_overlay_context.get("source_bytes")
            if not isinstance(source_bytes, bytes):
                raise InstallError("skill-creator system provenance SOURCE bytes are missing")
            atomic_write_bytes(target / "SOURCE.md", source_bytes)
            if (target / "SOURCE.md").read_bytes() != source_bytes:
                raise InstallError("skill-creator system provenance SOURCE staging hash mismatch")
        else:
            append_source_record(
                target / "SOURCE.md",
                skill_name=(name if target_scope == "active" else f".system/{name}"),
                active_root=active_root,
                upstream_path=upstream_path,
                context=context,
                command=guarded_retrieval(args),
            )
            if args.candidate:
                validate_durable_source_record(
                    target / "SOURCE.md",
                    durable_fields={
                        "Local path": active_root / ledger_names[names.index(name)],
                        "Active root": active_root,
                        "Guarded transaction evidence": Path(context["evidence_path"]),
                        "Decision manifest": Path(context["manifest_path"]),
                    },
                    transient_paths=[Path(args.candidate), Path(args.decision_manifest)],
                )
    bundled_validation = validate_staged_bundled_skills(
        stage_root=stage_target_root,
        active_root=active_root,
        top_level_name=names[0],
        bundled_proofs=context.get("bundled_skill_proofs", ()),
        args=args,
    )
    atomic_write_json(
        stage_root / ".downloaded-skills-source-state.json",
        make_staging_ledger(ledger_names, context),
    )
    closure = run_closure(
        root=stage_root,
        closure_script=closure_script,
        interpreter=interpreter,
        evidence_dir=evidence_dir,
        label="staged-resource-closure",
    )
    # The staging root only holds this transaction's skills: no baseline, so
    # every staged finding blocks (equivalent to zero-finding strict).
    staged_gate = evaluate_closure_gate(
        payload=closure,
        baseline=None,
        targets=ledger_names,
        label="staged-resource-closure",
    )
    staged_payloads = {
        name: tree_content_seal(stage_target_root / name) for name in names
    }
    system_overlay_context = context.get("system_provenance_overlay")
    if isinstance(system_overlay_context, dict):
        source_bytes = validate_staged_system_overlay(
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


def safe_remove(path: Path) -> None:
    if not path.exists():
        return
    if is_reparse(path):
        raise InstallError(f"拒绝删除 reparse point：{path}")
    if path.is_dir():
        make_tree_writable(path)
        shutil.rmtree(path)
    else:
        path.chmod(path.stat().st_mode | stat.S_IWRITE)
        path.unlink()


def path_exists_strict(path: Path, *, label: str) -> bool:
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise InstallError(f"无法确认{label}是否存在：{path}：{exc}") from exc


def directory_identity(path: Path, *, label: str) -> dict[str, int]:
    path = d_path(path, label=label, must_exist=True)
    if is_reparse(path) or not path.is_dir():
        raise InstallError(f"{label}必须是安全目录：{path}")
    try:
        stat_result = path.stat(follow_symlinks=False)
    except OSError as exc:
        raise InstallError(f"无法读取{label}目录 identity：{path}：{exc}") from exc
    return {
        "device": int(stat_result.st_dev),
        "inode": int(stat_result.st_ino),
    }


def verify_directory_identity(
    path: Path,
    *,
    expected: dict[str, int],
    label: str,
) -> None:
    if set(expected) != {"device", "inode"} or any(
        isinstance(value, bool) or not isinstance(value, int) or value < 0
        for value in expected.values()
    ):
        raise InstallError(f"{label}预期目录 identity 不合法")
    actual = directory_identity(path, label=label)
    if actual != expected:
        raise InstallError(
            f"{label}目录 identity 漂移："
            + json.dumps({"expected": expected, "actual": actual}, ensure_ascii=False)
        )


def make_tree_writable(root: Path) -> None:
    """Clear read-only bits so Windows copy-delete fallbacks can finish."""
    ensure_tree_no_reparse(root, label="待移动目录")
    for current, directories, files in os.walk(root, topdown=False, followlinks=False):
        current_path = Path(current)
        for name in [*files, *directories]:
            child = current_path / name
            child.chmod(child.stat().st_mode | stat.S_IWRITE)
    root.chmod(root.stat().st_mode | stat.S_IWRITE)


def read_only_relative_paths(root: Path) -> list[str]:
    """Capture the write-bit state that make_tree_writable intentionally changes."""
    ensure_tree_no_reparse(root, label="只读属性盘点目录")
    result: list[str] = []
    if not (root.stat().st_mode & stat.S_IWRITE):
        result.append(".")
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in [*directories, *files]:
            child = current_path / name
            if not (child.stat().st_mode & stat.S_IWRITE):
                result.append(child.relative_to(root).as_posix())
    return sorted(result)


def restore_read_only_paths(root: Path, relative_paths: list[str]) -> None:
    """Restore only the read-only bits cleared for a guarded tree move."""
    for relative in sorted(relative_paths, key=lambda value: value.count("/"), reverse=True):
        target = root if relative == "." else root / Path(relative)
        if not path_exists_strict(target, label="只读属性恢复目标"):
            raise InstallError(f"只读属性恢复目标不存在：{target}")
        target.chmod(target.stat().st_mode & ~stat.S_IWRITE)


def merge_tree_contents(source: Path, destination: Path) -> None:
    """Merge a backup fragment into a source fragment without deleting either side."""
    ensure_tree_no_reparse(source, label="恢复来源目录")
    if path_exists_strict(destination, label="恢复目标目录"):
        if is_reparse(destination) or not destination.is_dir():
            raise InstallError(f"恢复目标必须是普通目录：{destination}")
        make_tree_writable(destination)
    else:
        destination.mkdir(parents=True)
    for current, directories, files in os.walk(source, topdown=True, followlinks=False):
        directories.sort(key=str.casefold)
        files.sort(key=str.casefold)
        current_path = Path(current)
        relative = current_path.relative_to(source)
        target_directory = destination / relative
        target_directory.mkdir(exist_ok=True)
        for directory in directories:
            (target_directory / directory).mkdir(exist_ok=True)
        for filename in files:
            shutil.copyfile(current_path / filename, target_directory / filename)


def restore_move_union(
    *,
    source: Path,
    destination: Path,
    seal: dict[str, Any],
    label: str,
) -> None:
    """Reconstruct a tree after shutil.move partially copied or removed it."""
    if path_exists_strict(source, label=f"{label}来源"):
        merge_tree_contents(source, destination)
    verify_tree_seal(destination, seal=seal, label=label)


def move_active_to_backup(active: Path, backup: Path) -> tuple[dict[str, Any], list[str]]:
    """Move active state while guaranteeing restoration after a partial fallback."""
    seal = tree_content_seal(active)
    read_only_paths = read_only_relative_paths(active)
    try:
        make_tree_writable(active)
        shutil.move(str(active), str(backup))
        verify_tree_seal(backup, seal=seal, label="active skill 事务备份")
        restore_read_only_paths(backup, read_only_paths)
    except Exception as move_error:
        try:
            restore_move_union(
                source=backup,
                destination=active,
                seal=seal,
                label="备份移动失败后的 active skill",
            )
            restore_read_only_paths(active, read_only_paths)
        except Exception as restore_error:
            raise RecoveryRequiredError(
                f"active skill 备份移动失败且无法证明恢复：{move_error}；恢复错误：{restore_error}"
            ) from restore_error
        raise InstallError(
            f"active skill 备份移动失败；原 active 已按内容 seal 恢复：{move_error}"
        ) from move_error
    return seal, read_only_paths


def tree_content_seal(root: Path) -> dict[str, Any]:
    directories_result: list[str] = []
    files_result: dict[str, str] = {}

    if is_reparse(root) or not root.is_dir():
        raise InstallError(f"skill 内容树根必须是普通目录：{root}")

    def onerror(error: OSError) -> None:
        raise InstallError(f"无法遍历 skill 内容树：{root}：{error}") from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        current_path = Path(current)
        if is_reparse(current_path) or not current_path.is_dir():
            raise InstallError(f"skill 内容树只允许普通目录：{current_path}")
        for directory in directories:
            child = current_path / directory
            if is_reparse(child) or not child.is_dir():
                raise InstallError(f"skill 内容树只允许普通目录：{child}")
            directories_result.append(child.relative_to(root).as_posix())
        directories.sort(key=str.casefold)
        files.sort(key=str.casefold)
        for filename in files:
            source = current_path / filename
            if is_reparse(source) or not source.is_file():
                raise InstallError(f"skill 内容树只允许普通文件：{source}")
            relative = source.relative_to(root).as_posix()
            files_result[relative] = sha256_file(source)
    return {
        "directory_count": len(directories_result),
        "file_count": len(files_result),
        "tree_sha256": tree_manifest_sha256(files_result, directories_result),
    }


def verify_tree_seal(root: Path, *, seal: dict[str, Any], label: str) -> None:
    expected_fields = {"directory_count", "file_count", "tree_sha256"}
    if set(seal) != expected_fields:
        raise InstallError(f"{label} seal 字段不合法")
    expected_directory_count = seal.get("directory_count")
    expected_file_count = seal.get("file_count")
    expected_hash = seal.get("tree_sha256")
    if (
        isinstance(expected_directory_count, bool)
        or not isinstance(expected_directory_count, int)
        or expected_directory_count < 0
        or isinstance(expected_file_count, bool)
        or not isinstance(expected_file_count, int)
        or expected_file_count < 1
        or not isinstance(expected_hash, str)
        or not SHA256_HEX.fullmatch(expected_hash)
    ):
        raise InstallError(f"{label} seal 值不合法")
    expected = {
        "directory_count": expected_directory_count,
        "file_count": expected_file_count,
        "tree_sha256": expected_hash.casefold(),
    }
    actual = tree_content_seal(root)
    if actual != expected:
        raise InstallError(
            f"{label} 内容 seal 漂移："
            + json.dumps(
                {
                    "expected": expected,
                    "actual": actual,
                },
                ensure_ascii=False,
            )
        )


def copy_tree_without_security_metadata(source: Path, destination: Path) -> None:
    """Copy skill content while letting every target inherit active-root ACLs."""
    ensure_tree_no_reparse(source, label="待激活 skill")
    if path_exists_strict(destination, label="激活临时目录"):
        raise InstallError(f"激活临时目录已存在：{destination}")
    destination.mkdir()
    try:
        root_skill_md = source / "SKILL.md"
        for current, directories, files in os.walk(
            source,
            topdown=True,
            followlinks=False,
        ):
            directories.sort(key=str.casefold)
            files.sort(key=str.casefold)
            current_path = Path(current)
            relative = current_path.relative_to(source)
            target_directory = destination / relative
            target_directory.mkdir(exist_ok=True)
            for directory in directories:
                child = current_path / directory
                if is_reparse(child):
                    raise InstallError(f"待激活 skill 不能包含 reparse point：{child}")
                (target_directory / directory).mkdir(exist_ok=True)
            for filename in files:
                child = current_path / filename
                if child == root_skill_md:
                    continue
                if is_reparse(child) or not child.is_file():
                    raise InstallError(f"待激活 skill 只允许普通文件：{child}")
                shutil.copyfile(child, target_directory / filename)
        if not root_skill_md.is_file() or is_reparse(root_skill_md):
            raise InstallError(f"待激活 skill 缺少安全的 SKILL.md：{root_skill_md}")
        shutil.copyfile(root_skill_md, destination / "SKILL.md")
        if tree_content_seal(source) != tree_content_seal(destination):
            raise InstallError(f"激活临时目录内容指纹不一致：{destination}")
    except Exception:
        if path_exists_strict(destination, label="失败的激活临时目录"):
            safe_remove(destination)
        raise


def verify_activation_readability(
    *,
    active_root: Path,
    names: list[str],
    interpreter: Path,
    evidence_dir: Path,
) -> dict[str, Any]:
    roots = [str(active_root / name) for name in names]
    probe_environment = dict(os.environ)
    probe_environment["CODEX_SKILL_READ_ROOTS"] = json.dumps(roots, ensure_ascii=False)
    probe_code = """
import json, os
from pathlib import Path

roots = [Path(item) for item in json.loads(os.environ["CODEX_SKILL_READ_ROOTS"])]
directory_count = 0
file_count = 0

def is_reparse(path):
    attributes = getattr(path.lstat(), "st_file_attributes", 0)
    return path.is_symlink() or bool(attributes & 0x400)

for root in roots:
    root.lstat()
    if is_reparse(root) or not root.is_dir():
        raise RuntimeError(f"reparse/non-directory root: {root}")
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directory_count += 1
        current_path = Path(current)
        if is_reparse(current_path) or not current_path.is_dir():
            raise RuntimeError(f"reparse/non-directory path: {current_path}")
        for directory in directories:
            child = current_path / directory
            if is_reparse(child) or not child.is_dir():
                raise RuntimeError(f"reparse/non-directory child: {child}")
        for filename in files:
            child = current_path / filename
            if is_reparse(child) or not child.is_file():
                raise RuntimeError(f"non-regular file: {child}")
            with child.open("rb") as stream:
                while stream.read(1024 * 1024):
                    pass
            file_count += 1
print(json.dumps({"directory_count": directory_count, "file_count": file_count}))
"""
    runtime_result = run_process(
        [str(interpreter), "-c", probe_code],
        evidence_dir=evidence_dir,
        label="activation-readability-process",
        env=probe_environment,
    )
    try:
        runtime_payload = json.loads(runtime_result.stdout)
    except json.JSONDecodeError as exc:
        raise InstallError(f"activation readability 子进程未返回合法 JSON：{exc}") from exc

    powershell = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
    if not powershell:
        raise InstallError("无法找到 PowerShell，不能验证 Windows ACL 继承")
    acl_script = r"""
$ErrorActionPreference = 'Stop'
$roots = ConvertFrom-Json ([Environment]::GetEnvironmentVariable('CODEX_SKILL_READ_ROOTS', 'Process'))
$normalRuntimeSids = @('S-1-5-11', 'S-1-5-32-545')
$itemCount = 0
foreach ($root in $roots) {
    $items = @((Get-Item -LiteralPath $root -Force -ErrorAction Stop)) + @(
        Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop
    )
    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        if ($acl.AreAccessRulesProtected) {
            throw "受保护 ACL 未从 active root 继承：$($item.FullName)"
        }
        $inheritedAllowSids = @(
            $acl.Access |
                Where-Object { $_.IsInherited -and $_.AccessControlType -eq 'Allow' } |
                ForEach-Object {
                    try {
                        $_.IdentityReference.Translate(
                            [System.Security.Principal.SecurityIdentifier]
                        ).Value
                    } catch {}
                }
        )
        if (@($inheritedAllowSids | Where-Object { $normalRuntimeSids -contains $_ }).Count -eq 0) {
            throw "active skill 缺少普通运行身份的继承读取权限：$($item.FullName)"
        }
        $itemCount++
    }
}
[ordered]@{ item_count = $itemCount } | ConvertTo-Json -Compress
"""
    acl_result = run_process(
        [
            powershell,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            acl_script,
        ],
        evidence_dir=evidence_dir,
        label="activation-acl-inheritance",
        env=probe_environment,
    )
    try:
        acl_payload = json.loads(acl_result.stdout.lstrip("\ufeff"))
    except json.JSONDecodeError as exc:
        raise InstallError(f"ACL 继承检查未返回合法 JSON：{exc}") from exc
    return {
        "status": "passed",
        "process": "new-child-process",
        "directory_count": int(runtime_payload["directory_count"]),
        "file_count": int(runtime_payload["file_count"]),
        "acl_item_count": int(acl_payload["item_count"]),
    }


def backup_file(path: Path, backup_root: Path, label: str) -> Path | None:
    if not path.exists():
        return None
    backup = backup_root / label
    ensure_dir(backup.parent, label="backup 目录")
    shutil.copy2(path, backup)
    if sha256_file(path) != sha256_file(backup):
        raise InstallError(f"backup 指纹不一致：{path}")
    return backup


def retire_directories(
    *,
    active_root: Path,
    names: list[str],
    backup_root: Path,
    records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    ensure_dir(backup_root, label="retired skill backup 目录")
    ensure_no_reparse_ancestors(active_root, label="active root")
    ensure_no_reparse_ancestors(backup_root, label="retired skill backup 目录")
    for name in names:
        active = d_path(active_root / name, label=f"待退场 active skill {name}")
        if not path_exists_strict(active, label=f"待退场 active skill {name}"):
            raise InstallError(f"待退场 active skill 不存在：{active}")
        if is_reparse(active) or not active.is_dir():
            raise InstallError(f"待退场 active skill 不是安全目录：{active}")
        record = {
            "name": name,
            "active": str(active),
            "backup": str(backup_root / name),
            "activation_temp": str(
                active_root / f"_disabled-guarded-retired-{name}-{uuid.uuid4().hex}"
            ),
            "had_existing": True,
            "backup_moved": False,
            "backup_seal": None,
            "backup_read_only_paths": [],
            "pre_activation_recovery_error": None,
            "activated": False,
            "retired": True,
        }
        records.append(record)
        try:
            backup_seal, backup_read_only_paths = move_active_to_backup(
                active,
                backup_root / name,
            )
            record["backup_seal"] = backup_seal
            record["backup_read_only_paths"] = backup_read_only_paths
            record["backup_moved"] = True
        except RecoveryRequiredError as exc:
            record["pre_activation_recovery_error"] = str(exc)
            raise
    return records


def activate_directories(
    *,
    stage_root: Path,
    active_root: Path,
    names: list[str],
    backup_root: Path,
    records: list[dict[str, Any]],
    payload_seals: dict[str, dict[str, Any]],
    must_not_exist: set[str] | None = None,
) -> list[dict[str, Any]]:
    ensure_dir(backup_root, label="skill backup 目录")
    ensure_no_reparse_ancestors(active_root, label="active root")
    ensure_no_reparse_ancestors(backup_root, label="skill backup 目录")
    protected_new_names = set(must_not_exist or ())
    unexpected_protected_names = protected_new_names - set(names)
    if unexpected_protected_names:
        raise InstallError(
            "must_not_exist 包含非目标 skill："
            + ", ".join(sorted(unexpected_protected_names))
        )
    for name in names:
        staged = stage_root / name
        seal = payload_seals.get(name)
        if not isinstance(seal, dict):
            raise InstallError(f"staging 缺少 skill 内容 seal：{name}")
        verify_tree_seal(staged, seal=seal, label=f"staging skill {name}")
        active = d_path(active_root / name, label=f"active skill {name}")
        active_exists = path_exists_strict(active, label=f"active skill {name}")
        if name in protected_new_names and active_exists:
            raise InstallError(f"canonical rename successor 已在换入前出现：{active}")
        if active_exists and is_reparse(active):
            raise InstallError(f"active skill 目标是 reparse point：{active}")
        if active_exists and not active.is_dir():
            raise InstallError(f"active skill 目标不是目录：{active}")
        activation_temp = d_path(
            active_root / f"_disabled-guarded-{name}-{uuid.uuid4().hex}",
            label=f"激活临时目录 {name}",
        )
        record = {
            "name": name,
            "active": str(active),
            "backup": str(backup_root / name),
            "activation_temp": str(activation_temp),
            "had_existing": active_exists,
            "backup_moved": False,
            "backup_seal": None,
            "backup_read_only_paths": [],
            "pre_activation_recovery_error": None,
            "activated": False,
            "activated_payload_seal": seal,
            "activated_payload_identity": None,
        }
        records.append(record)
        copy_tree_without_security_metadata(staged, activation_temp)
        verify_tree_seal(
            activation_temp,
            seal=seal,
            label=f"激活临时目录 {name}",
        )
        record["activated_payload_identity"] = directory_identity(
            activation_temp,
            label=f"激活临时目录 {name}",
        )
        if active_exists:
            try:
                backup_seal, backup_read_only_paths = move_active_to_backup(
                    active,
                    backup_root / name,
                )
                record["backup_seal"] = backup_seal
                record["backup_read_only_paths"] = backup_read_only_paths
                record["backup_moved"] = True
            except RecoveryRequiredError as exc:
                record["pre_activation_recovery_error"] = str(exc)
                raise
        try:
            verify_tree_seal(
                activation_temp,
                seal=seal,
                label=f"原子换入前临时目录 {name}",
            )
            ensure_no_reparse_ancestors(active_root, label="active root")
            if name in protected_new_names:
                if path_exists_strict(active, label=f"canonical rename successor {name}"):
                    raise InstallError(
                        f"canonical rename successor 已在原子换入前出现：{active}"
                    )
                try:
                    os.rename(activation_temp, active)
                except OSError as rename_error:
                    if path_exists_strict(
                        active, label=f"canonical rename successor {name}"
                    ):
                        raise InstallError(
                            f"canonical rename successor 在原子换入竞争中出现：{active}"
                        ) from rename_error
                    raise
            else:
                os.replace(activation_temp, active)
        except Exception as exc:
            raise InstallError(f"激活 skill 失败：{name}：{exc}") from exc
        record["activated"] = True
        activated_identity = record.get("activated_payload_identity")
        if not isinstance(activated_identity, dict):
            raise InstallError(f"已激活 skill 缺少目录 identity：{name}")
        verify_directory_identity(
            active,
            expected=activated_identity,
            label=f"已激活 skill {name}",
        )
        verify_tree_seal(active, seal=seal, label=f"已激活 skill {name}")
    return records


def rollback_directories(records: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    for record in reversed(records):
        active = Path(record["active"])
        backup = Path(record["backup"])
        activation_temp = Path(record["activation_temp"])
        try:
            if path_exists_strict(activation_temp, label="rollback 激活临时目录"):
                safe_remove(activation_temp)
            seal = record.get("backup_seal")
            if record["backup_moved"]:
                if not isinstance(seal, dict):
                    raise InstallError(f"rollback 缺少 active skill 内容 seal：{record['name']}")
                if not path_exists_strict(backup, label="rollback skill backup"):
                    raise InstallError(f"rollback active skill 事务备份不存在：{record['name']}")
                verify_tree_seal(
                    backup,
                    seal=seal,
                    label=f"rollback 删除 active 前事务备份 {record['name']}",
                )
            elif record["activated"] and record["had_existing"]:
                raise InstallError(f"rollback 已有 active skill 缺少事务备份：{record['name']}")
            if record["activated"]:
                if not path_exists_strict(active, label="rollback active skill"):
                    raise InstallError(
                        f"rollback 已激活 skill 路径已消失，无法证明事务 payload 已移除：{record['name']}"
                    )
                activated_seal = record.get("activated_payload_seal")
                if not isinstance(activated_seal, dict):
                    raise InstallError(
                        f"rollback 缺少已激活 skill 内容 seal：{record['name']}"
                    )
                activated_identity = record.get("activated_payload_identity")
                if not isinstance(activated_identity, dict):
                    raise InstallError(
                        f"rollback 缺少已激活 skill 目录 identity：{record['name']}"
                    )
                verify_directory_identity(
                    active,
                    expected=activated_identity,
                    label=f"rollback 删除前事务 payload {record['name']}",
                )
                verify_tree_seal(
                    active,
                    seal=activated_seal,
                    label=f"rollback 删除前事务 payload {record['name']}",
                )
                safe_remove(active)
            if record["backup_moved"]:
                if record.get("retired") and path_exists_strict(
                    active, label="rollback retired active skill"
                ):
                    raise InstallError(
                        f"rollback 待恢复旧名路径已被占用：{record['name']}"
                    )
                try:
                    make_tree_writable(backup)
                    shutil.move(str(backup), str(active))
                    verify_tree_seal(active, seal=seal, label=f"rollback active skill {record['name']}")
                except Exception:
                    restore_move_union(
                        source=backup,
                        destination=active,
                        seal=seal,
                        label=f"rollback active skill {record['name']}",
                    )
                read_only_paths = record.get("backup_read_only_paths")
                if not isinstance(read_only_paths, list) or any(
                    not isinstance(relative, str) for relative in read_only_paths
                ):
                    raise InstallError(f"rollback 只读属性记录不合法：{record['name']}")
                restore_read_only_paths(active, read_only_paths)
        except Exception as exc:  # pragma: no cover - exercised by injected host failures
            errors.append(f"{record['name']}: {exc}")
        if record.get("pre_activation_recovery_error"):
            errors.append(f"{record['name']}: {record['pre_activation_recovery_error']}")
    return errors


def restore_file(path: Path, backup: Path | None) -> None:
    if backup is None:
        if path.exists():
            safe_remove(path)
        return
    ensure_dir(path.parent, label="恢复文件目录")
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.restore")
    shutil.copy2(backup, temporary)
    os.replace(temporary, path)


def restore_file_cas(
    path: Path,
    *,
    before: bytes | None,
    before_identity: dict[str, int] | None,
    written: bytes | None,
    written_identity: dict[str, int] | None,
    backup: Path | None,
) -> None:
    if path.exists() and not path.is_file():
        raise InstallError(f"rollback CAS target is not a regular file: {path}")
    current = path.read_bytes() if path.exists() else None
    current_identity = system_path_identity(path) if current is not None else None
    if current == before and current_identity == before_identity:
        return
    if current != written or current_identity != written_identity:
        raise InstallError(f"rollback CAS refused to overwrite concurrent state: {path}")
    restore_file(path, backup)
    restored = path.read_bytes() if path.exists() and path.is_file() else None
    if restored != before:
        raise InstallError(f"rollback CAS could not verify original bytes: {path}")


def verify_catalog(
    *,
    catalog_path: Path,
    active_root: Path,
    names: list[str],
    bundled_proofs: Sequence[BundledSkillProof],
    target_scope: str = "active",
    closure_targets: Sequence[str] | None = None,
    baseline_findings: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    catalog = load_json(catalog_path, label="skill catalog")
    if not isinstance(catalog, dict) or not isinstance(catalog.get("artifacts"), list):
        raise InstallError("skill catalog 缺少 artifacts 数组")
    if closure_targets is None:
        closure_targets = [
            name if target_scope == "active" else f".system/{name}" for name in names
        ]
    try:
        closure_check = verify_catalog_closure_check(
            catalog.get("checks", {}).get("resource_closure"),
            targets=closure_targets,
            baseline_findings=baseline_findings,
        )
    except CatalogError as exc:
        raise InstallError(f"skill catalog 的资源闭包检查不可接受：{exc}") from exc
    verified: list[dict[str, Any]] = []

    def verify_target(
        *,
        path: str,
        name: str,
        proof: BundledSkillProof | None,
        scope: str = "active",
    ) -> None:
        matches = [
            artifact
            for artifact in catalog["artifacts"]
            if isinstance(artifact, dict)
            and artifact.get("scope") == scope
            and artifact.get("name") == name
            and artifact.get("relative_path") == f"{path}/SKILL.md"
        ]
        if len(matches) != 1:
            raise InstallError(f"skill catalog 对 {name} 的 active 条目数量不是 1：{len(matches)}")
        artifact = matches[0]
        if artifact.get("ledger_coverage") != "pass":
            raise InstallError(f"skill catalog 对 {name} 的 ledger coverage 不是 pass")
        source = artifact.get("source") if isinstance(artifact.get("source"), dict) else {}
        if (
            source.get("status") in {None, "missing"}
            or source.get("conflicts")
            or (proof is None and source.get("status") == "unknown")
        ):
            raise InstallError(f"skill catalog 对 {name} 的 SOURCE.md 存在冲突、未知或缺失")
        bundled_root: Path | None = None
        if proof is not None:
            bundled_root = d_path(
                active_root / Path(*path.split("/")),
                label=f"bundled skill {name}",
                must_exist=True,
            )
            if is_reparse(bundled_root) or not bundled_root.is_dir():
                raise InstallError(f"bundled skill {name} 不是安全目录")
            ensure_tree_no_reparse(bundled_root, label=f"bundled skill {name}")
        skill_md = d_path(
            (bundled_root or active_root / Path(*path.split("/"))) / "SKILL.md",
            label=f"skill {name} 的 SKILL.md",
            must_exist=True,
        )
        if is_reparse(skill_md) or not skill_md.is_file():
            raise InstallError(f"skill {name} 的 SKILL.md 不是安全普通文件")
        actual = sha256_file(skill_md)
        recorded = artifact.get("integrity", {}).get("skill_md_sha256")
        if actual != recorded:
            raise InstallError(f"skill catalog 对 {name} 的 SKILL.md 哈希不一致")
        verification = {"path": path, "name": name, "skill_md_sha256": actual}
        if proof is not None:
            expected_skill_md_sha256, expected_source_md_sha256 = proof.require_staged_integrity()
            if actual != expected_skill_md_sha256:
                raise InstallError(f"bundled skill {name} 的 SKILL.md 与暂存期哈希不一致")
            assert bundled_root is not None
            source_md = bundled_root / "SOURCE.md"
            if is_reparse(source_md) or not source_md.is_file():
                raise InstallError(f"bundled skill {name} 的 SOURCE.md 不是安全普通文件")
            source_md_sha256 = sha256_file(source_md)
            if source_md_sha256 != expected_source_md_sha256:
                raise InstallError(f"bundled skill {name} 的 SOURCE.md 与暂存期哈希不一致")
            verification["source_md_sha256"] = source_md_sha256
        verified.append(verification)

    for name in names:
        path = name if target_scope == "active" else f".system/{name}"
        expected_scope = "active" if target_scope == "active" else "system"
        verify_target(
            path=path,
            name=name,
            proof=None,
            scope=expected_scope,
        )
    for proof in bundled_proofs:
        verify_target(path=proof.ledger_key, name=proof.name, proof=proof)
    return {
        "generated_at": catalog.get("generated_at"),
        "skills": verified,
        "resource_closure": closure_check,
    }


def verify_merge_retirement_postcondition(
    *,
    active_root: Path,
    ledger: dict[str, Any],
    catalog_path: Path,
    retirement: dict[str, Any],
) -> dict[str, Any]:
    retired = retirement["retired"]
    retired_name = retired["name"]
    retired_active = d_path(
        active_root / retired_name,
        label="merge retirement 退役 active skill",
    )
    if path_exists_strict(retired_active, label="merge retirement 退役 active skill"):
        raise InstallError("merge retirement 后退役 active skill 仍然存在")

    live_coverage: list[str] = []
    for section in ("sources", "unresolved"):
        entries = ledger.get(section)
        if not isinstance(entries, list):
            raise InstallError(f"source ledger 的 {section} 必须是数组")
        for entry in entries:
            if ledger_entry_covers(entry, retired_name):
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
        survivor_root = d_path(
            active_root / survivor["name"],
            label=f"merge retirement survivor {survivor['name']}",
            must_exist=True,
        )
        if is_reparse(survivor_root) or not survivor_root.is_dir():
            raise InstallError(
                f"merge retirement survivor 不是安全目录：{survivor['name']}"
            )
        actual = sha256_file(survivor_root / "SKILL.md")
        if actual != survivor["skill_md_sha256"]:
            raise InstallError(
                f"merge retirement survivor SKILL.md 哈希漂移：{survivor['name']}"
            )
        survivor_results.append(
            {"name": survivor["name"], "skill_md_sha256": actual}
        )

    catalog = load_json(catalog_path, label="skill catalog")
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


@contextlib.contextmanager
def installation_lock(lock_path: Path) -> Iterator[None]:
    ensure_dir(lock_path.parent, label="skill 安装锁目录")
    try:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        raise InstallError(f"已有 skill 安装事务或遗留锁：{lock_path}；请先检查证据后再处理") from exc
    try:
        os.write(descriptor, f"pid={os.getpid()}\nutc={utc_now()}\n".encode("utf-8"))
        os.close(descriptor)
        descriptor = -1
        yield
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        lock_path.unlink(missing_ok=True)


def write_transaction_manifest(path: Path, payload: dict[str, Any]) -> None:
    atomic_write_json(path, payload)


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
    active_root = ensure_dir(args.active_root, label="active root")
    plugin_cache_root = ensure_dir(args.plugin_cache_root, label="plugin cache root")
    ledger_path = ensure_file(args.ledger, label="source ledger")
    generator = ensure_file(args.generator, label="catalog generator")
    closure_script = ensure_file(args.closure_script, label="resource closure script")
    interpreter = ensure_file(args.interpreter, label="Python interpreter")
    system_installer = d_path(args.system_installer, label="system installer")
    if not args.candidate:
        if not system_installer.exists() or not system_installer.is_file():
            raise InstallError(f"系统 skill installer 不存在：{system_installer}")
    catalog_path = d_path(args.catalog, label="catalog output")
    temp_root = ensure_dir(args.temp_root, label="skill staging temp root")
    evidence_root = ensure_dir(args.evidence_root, label="skill install evidence root")
    lock_root = ensure_dir(args.lock_root, label="skill install lock root")
    decision_path = d_path(args.decision_manifest, label="decision manifest", must_exist=True)
    specs = target_specs(args)
    names = [name for name, _ in specs]
    decision = load_and_validate_manifest(decision_path, names=names)
    target_scope, target_root, ledger_names = target_layout(
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
    rename = canonical_rename_spec(args=args, decision=decision, names=names)
    merge_retirement = merge_retirement_spec(
        args=args,
        decision=decision,
        names=names,
    )
    if target_scope == "system" and (rename is not None or merge_retirement is not None):
        raise InstallError("system scope 暂不支持 canonical rename 或 merge retirement")
    specs = apply_candidate_upstream_path(args, decision, specs)
    if args.update and decision["decision"] != "update":
        raise InstallError("--update 只能与 decision=update 的 manifest 一起使用")
    if decision["decision"] == "update" and not args.update:
        # The guard manifest is the authorization.  The explicit flag is an
        # extra compatibility signal, not a second approval gate.
        pass
    context = source_context(args, decision, specs)
    context["target_scope"] = target_scope
    initial_ledger_bytes = ledger_path.read_bytes()
    initial_ledger_identity = system_path_identity(ledger_path)
    initial_catalog_bytes = catalog_path.read_bytes() if catalog_path.exists() else None
    initial_catalog_identity = (
        system_path_identity(catalog_path) if catalog_path.exists() else None
    )
    initial_ledger = load_json(ledger_path, label="source ledger")
    system_overlay_context = prepare_system_provenance_overlay(
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
    context["bundled_skill_proofs"] = bundled_skill_specs(
        args=args,
        decision=decision,
        names=names,
    )
    if target_scope == "system" and context["bundled_skill_proofs"]:
        raise InstallError("system scope 暂不支持 bundled_skills")
    if rename is not None:
        context["canonical_rename"] = rename
        validate_canonical_rename_state(
            args=args,
            active_root=active_root,
            ledger=load_json(ledger_path, label="source ledger"),
            context=context,
            rename=rename,
        )
    if merge_retirement is not None:
        context["merge_retirement"] = merge_retirement
        validate_merge_retirement_state(
            args=args,
            active_root=active_root,
            ledger=load_json(ledger_path, label="source ledger"),
            names=names,
            retirement=merge_retirement,
        )
    validate_group_checkpoint_advance(
        load_json(ledger_path, label="source ledger"),
        names=ledger_names,
        context=context,
    )
    transaction_id = uuid.uuid4().hex
    evidence_dir = evidence_root / f"install-{_datetime.datetime.now().strftime('%Y%m%dT%H%M%S')}-{transaction_id}"
    ensure_dir(evidence_dir, label="transaction evidence directory")
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
        "started_at": utc_now(),
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
    closure_targets = transaction_closure_targets(
        ledger_names=ledger_names,
        rename=rename,
        merge_retirement=merge_retirement,
    )
    baseline_closure: dict[str, Any] | None = None
    try:
        # Baseline before any staging or active-root write; post-write closure
        # is judged against it (new findings + target findings block).
        baseline_closure = run_closure(
            root=active_root,
            closure_script=closure_script,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
            label="baseline-resource-closure",
        )
        baseline_closure_path = evidence_dir / "baseline-resource-closure.json"
        atomic_write_json(baseline_closure_path, baseline_closure)
        atomic_write_bytes(decision_snapshot_path, decision_snapshot_bytes)
        if sha256_file(decision_snapshot_path) != decision_snapshot["sha256"]:
            raise InstallError("decision manifest 事务快照指纹不一致")
        staged = stage_candidate(
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
                "completed_at": utc_now(),
                "baseline_resource_closure": baseline_closure,
                "staged": staged_result_projection(staged),
                "evidence": str(evidence_dir),
            }
            write_transaction_manifest(manifest_path, result)
            return result

        active_state = load_json(ledger_path, label="source ledger")
        system_overlay_context = context.get("system_provenance_overlay")
        if isinstance(system_overlay_context, dict):
            if (
                system_path_identity(ledger_path) != system_overlay_context["ledger_before_identity"]
                or ledger_path.read_bytes() != system_overlay_context["ledger_before_bytes"]
            ):
                raise InstallError("source ledger changed while staging system overlay")
            _assert_system_overlay_baseline(
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
            validate_canonical_rename_state(
                args=args,
                active_root=active_root,
                ledger=active_state,
                context=context,
                rename=rename,
            )
        if merge_retirement is not None:
            validate_merge_retirement_state(
                args=args,
                active_root=active_root,
                ledger=active_state,
                names=names,
                retirement=merge_retirement,
            )
        # Re-check against the ledger this transaction will write; writers
        # outside the install lock may have moved the checkpoint during staging.
        validate_group_checkpoint_advance(active_state, names=ledger_names, context=context)
        backup_root = evidence_dir / "backups"
        ensure_dir(backup_root, label="transaction backup root")
        ledger_backup = backup_file(ledger_path, backup_root, "source-state-before.json")
        catalog_backup = backup_file(catalog_path, backup_root, "catalog-before.json")
        state_backups_ready = True
        if rename is None and merge_retirement is None:
            for name in names:
                active = target_root / name
                if decision["decision"] == "install" and active.exists():
                    raise InstallError(f"install 分支不能覆盖已有 active skill：{active}")
                if decision["decision"] == "update" and not active.exists():
                    raise InstallError(f"update 分支要求已有 active skill：{active}")
        elif merge_retirement is not None:
            retire_directories(
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
            retire_directories(
                active_root=active_root,
                names=[rename["old_name"]],
                backup_root=backup_root / "active-skills",
                records=directory_records,
            )
        activate_directories(
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
        activation_readability = verify_activation_readability(
            active_root=target_root,
            names=names,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
        )
        updated_ledger = update_ledger(active_state, names=ledger_names, context=context)
        if isinstance(system_overlay_context, dict):
            source_md_sha256 = system_overlay_context.get("source_md_sha256")
            if not isinstance(source_md_sha256, str):
                raise InstallError("skill-creator system provenance SOURCE hash is missing")
            updated_ledger = apply_system_provenance_overlay_to_ledger(
                ledger=updated_ledger,
                overlay_context=system_overlay_context,
                source_md_sha256=source_md_sha256,
            )
            if ledger_path.read_bytes() != system_overlay_context["ledger_before_bytes"]:
                raise InstallError("source ledger changed before system overlay write")
        ledger_after_bytes = json_document_bytes(updated_ledger)
        atomic_write_bytes(ledger_path, ledger_after_bytes)
        if isinstance(system_overlay_context, dict):
            system_overlay_context["ledger_written_bytes"] = ledger_path.read_bytes()
            system_overlay_context["ledger_written_identity"] = system_path_identity(ledger_path)
        catalog_generation_output = (
            stage_dir / "system-overlay-catalog.json"
            if isinstance(system_overlay_context, dict)
            else catalog_path
        )
        run_process(
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
            atomic_write_bytes(catalog_path, generated_catalog_bytes)
            system_overlay_context["catalog_written_bytes"] = generated_catalog_bytes
            system_overlay_context["catalog_written_identity"] = system_path_identity(catalog_path)
        post_closure = run_closure(
            root=active_root,
            closure_script=closure_script,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
            label="post-resource-closure",
        )
        post_closure_gate = evaluate_closure_gate(
            payload=post_closure,
            baseline=baseline_closure,
            targets=closure_targets,
            label="post-resource-closure",
        )
        persisted_ledger = load_json(ledger_path, label="postcondition source ledger")
        if merge_retirement is not None and persisted_ledger != updated_ledger:
            raise InstallError("merge retirement 写入后的 source ledger 发生漂移")
        catalog_verification = verify_catalog(
            catalog_path=catalog_path,
            active_root=active_root,
            names=names,
            bundled_proofs=staged["bundled_skill_proofs"],
            target_scope=target_scope,
            closure_targets=closure_targets,
            baseline_findings=baseline_closure["findings"],
        )
        system_overlay_postcondition = (
            verify_system_provenance_overlay_postcondition(
                active_root=active_root,
                ledger=persisted_ledger,
                catalog_path=catalog_path,
                overlay_context=system_overlay_context,
            )
            if isinstance(system_overlay_context, dict)
            else None
        )
        merge_retirement_verification = (
            verify_merge_retirement_postcondition(
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
        atomic_write_bytes(source_state_after_path, ledger_after_bytes)
        result = {
            **plan,
            "status": "succeeded",
            "completed_at": utc_now(),
            "targets": names,
            "staged": staged_result_projection(staged),
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
            "catalog_sha256": sha256_file(catalog_path),
            "evidence": str(evidence_dir),
        }
        write_transaction_manifest(manifest_path, result)
        return result
    except Exception as exc:
        rollback_errors = rollback_directories(directory_records)
        if state_backups_ready:
            try:
                if isinstance(system_overlay_context, dict):
                    restore_file_cas(
                        ledger_path,
                        before=system_overlay_context["ledger_before_bytes"],
                        before_identity=system_overlay_context["ledger_before_identity"],
                        written=system_overlay_context.get("ledger_written_bytes"),
                        written_identity=system_overlay_context.get("ledger_written_identity"),
                        backup=ledger_backup,
                    )
                    restore_file_cas(
                        catalog_path,
                        before=system_overlay_context["catalog_before_bytes"],
                        before_identity=system_overlay_context["catalog_before_identity"],
                        written=system_overlay_context.get("catalog_written_bytes"),
                        written_identity=system_overlay_context.get("catalog_written_identity"),
                        backup=catalog_backup,
                    )
                else:
                    restore_file(ledger_path, ledger_backup)
                    restore_file(catalog_path, catalog_backup)
            except Exception as restore_exc:
                rollback_errors.append(f"state restore: {restore_exc}")
        failure = {
            **plan,
            "status": "rollback-failed" if rollback_errors else "rolled-back",
            "completed_at": utc_now(),
            "error": str(exc),
            "rollback_errors": rollback_errors,
            "baseline_resource_closure": baseline_closure,
            "staged": staged_result_projection(staged),
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
                    d_path(args.lock_root, label="skill install lock root")
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
            candidate = d_path(args.candidate, label="candidate", must_exist=True)
            if not candidate.is_dir():
                raise InstallError(f"candidate 必须是目录：{candidate}")
            result = inspect_candidate_integrity(candidate)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.decision_manifest is None:
            raise InstallError("安装事务必须提供 --decision-manifest")
        with installation_lock(d_path(args.lock_root, label="skill install lock root") / "install.lock"):
            result = execute(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except InstallError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
