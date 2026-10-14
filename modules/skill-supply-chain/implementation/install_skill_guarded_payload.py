"""Candidate payload inventory, integrity binding and SKILL.md/openai.yaml display checks.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

import yaml

import install_skill_guarded_base as _base
from install_skill_guarded_base import SAFE_SKILL_NAME, SHA256_HEX, InstallError


ASCII_DISPLAY_NAME = re.compile(r"^[\x20-\x7e]+$")
CJK_TEXT = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
LATIN_TEXT = re.compile(r"[A-Za-z]")


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


def candidate_payload_inventory(root: Path) -> tuple[list[str], dict[str, str]]:
    """Inventory exactly the candidate topology eligible for activation."""
    directories_result: list[str] = []
    files_result: dict[str, str] = {}

    if _base.is_reparse(root) or not root.is_dir():
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
            if _base.is_reparse(child) or not child.is_dir():
                raise InstallError(f"candidate 安装载荷只允许普通目录：{child}")
            if name.casefold() in CANDIDATE_EXCLUDED_DIRECTORIES:
                continue
            retained_directories.append(name)
            directories_result.append(child.relative_to(root).as_posix())
        directories[:] = sorted(retained_directories, key=str.casefold)
        files.sort(key=str.casefold)
        for filename in files:
            source = current_path / filename
            if _base.is_reparse(source) or not source.is_file():
                raise InstallError(f"candidate 安装载荷只允许普通文件：{source}")
            if (
                filename.casefold() in CANDIDATE_EXCLUDED_DIRECTORIES
                or filename.casefold().endswith(".pyc")
            ):
                continue
            files_result[source.relative_to(root).as_posix()] = _base.sha256_file(source)
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
        "tree_sha256": _base.tree_manifest_sha256(files, directories),
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
    _base.ensure_tree_no_reparse(candidate, label="candidate")
    return {
        "candidate_integrity": candidate_integrity_payload(candidate),
        "excluded_files": candidate_excluded_file_summary(candidate),
    }


def strip_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"', "`"}:
        return value[1:-1].strip()
    return value


def read_skill_name(skill_md: Path) -> str:
    skill_md = _base.d_path(skill_md, label="SKILL.md", must_exist=True)
    if _base.is_reparse(skill_md) or not skill_md.is_file():
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
    path = _base.d_path(path, label=f"{label} agents/openai.yaml", must_exist=True)
    if _base.is_reparse(path) or not path.is_file():
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
    skill_md = _base.d_path(skill_dir / "SKILL.md", label=f"{label} SKILL.md", must_exist=True)
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
