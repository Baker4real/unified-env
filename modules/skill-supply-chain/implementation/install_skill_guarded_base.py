"""Shared errors, path guards, hashing, subprocess and atomic JSON helpers.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import datetime as _datetime
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any


SAFE_SKILL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
REPO_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$")
SHA256_HEX = re.compile(r"^[0-9a-fA-F]{64}$")


class InstallError(RuntimeError):
    """A fail-closed wrapper error."""


class RecoveryRequiredError(InstallError):
    """The wrapper could not prove that pre-transaction active state was restored."""


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


def normalize_repo(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    value = value.strip().rstrip("/")
    if REPO_NAME.fullmatch(value):
        value = f"https://github.com/{value}"
    if value.endswith(".git"):
        value = value[:-4]
    return value.casefold().rstrip("/")


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


def path_exists_strict(path: Path, *, label: str) -> bool:
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise InstallError(f"无法确认{label}是否存在：{path}：{exc}") from exc
