"""Directory identity, content seals, safe removal and metadata-free tree copies.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
from pathlib import Path
from typing import Any

import install_skill_guarded_base as _base
from install_skill_guarded_base import SHA256_HEX, InstallError


def safe_remove(path: Path) -> None:
    if not path.exists():
        return
    if _base.is_reparse(path):
        raise InstallError(f"拒绝删除 reparse point：{path}")
    if path.is_dir():
        make_tree_writable(path)
        shutil.rmtree(path)
    else:
        path.chmod(path.stat().st_mode | stat.S_IWRITE)
        path.unlink()


def directory_identity(path: Path, *, label: str) -> dict[str, int]:
    path = _base.d_path(path, label=label, must_exist=True)
    if _base.is_reparse(path) or not path.is_dir():
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
    _base.ensure_tree_no_reparse(root, label="待移动目录")
    for current, directories, files in os.walk(root, topdown=False, followlinks=False):
        current_path = Path(current)
        for name in [*files, *directories]:
            child = current_path / name
            child.chmod(child.stat().st_mode | stat.S_IWRITE)
    root.chmod(root.stat().st_mode | stat.S_IWRITE)


def tree_content_seal(root: Path) -> dict[str, Any]:
    directories_result: list[str] = []
    files_result: dict[str, str] = {}

    if _base.is_reparse(root) or not root.is_dir():
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
        if _base.is_reparse(current_path) or not current_path.is_dir():
            raise InstallError(f"skill 内容树只允许普通目录：{current_path}")
        for directory in directories:
            child = current_path / directory
            if _base.is_reparse(child) or not child.is_dir():
                raise InstallError(f"skill 内容树只允许普通目录：{child}")
            directories_result.append(child.relative_to(root).as_posix())
        directories.sort(key=str.casefold)
        files.sort(key=str.casefold)
        for filename in files:
            source = current_path / filename
            if _base.is_reparse(source) or not source.is_file():
                raise InstallError(f"skill 内容树只允许普通文件：{source}")
            relative = source.relative_to(root).as_posix()
            files_result[relative] = _base.sha256_file(source)
    return {
        "directory_count": len(directories_result),
        "file_count": len(files_result),
        "tree_sha256": _base.tree_manifest_sha256(files_result, directories_result),
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
    _base.ensure_tree_no_reparse(source, label="待激活 skill")
    if _base.path_exists_strict(destination, label="激活临时目录"):
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
                if _base.is_reparse(child):
                    raise InstallError(f"待激活 skill 不能包含 reparse point：{child}")
                (target_directory / directory).mkdir(exist_ok=True)
            for filename in files:
                child = current_path / filename
                if child == root_skill_md:
                    continue
                if _base.is_reparse(child) or not child.is_file():
                    raise InstallError(f"待激活 skill 只允许普通文件：{child}")
                shutil.copyfile(child, target_directory / filename)
        if not root_skill_md.is_file() or _base.is_reparse(root_skill_md):
            raise InstallError(f"待激活 skill 缺少安全的 SKILL.md：{root_skill_md}")
        shutil.copyfile(root_skill_md, destination / "SKILL.md")
        if tree_content_seal(source) != tree_content_seal(destination):
            raise InstallError(f"激活临时目录内容指纹不一致：{destination}")
    except Exception:
        if _base.path_exists_strict(destination, label="失败的激活临时目录"):
            safe_remove(destination)
        raise
