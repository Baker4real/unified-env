#!/usr/bin/env python3
"""Pre-commit guard for the skills repository.

``check`` blocks a commit when a staged added or modified text blob contains a
C0 control character other than tab, LF and CR (the BEL-in-SOURCE.md class of
corruption), or when the staged source ledger is not the canonical form the
guarded installer writes: ``json.dumps(value, ensure_ascii=False, indent=2)``
plus a trailing newline, UTF-8 without BOM.  Blobs git would treat as binary
(a NUL in the first 8000 bytes) are skipped.

``install --repo PATH`` copies this file next to a ``pre-commit`` shim in that
repository's hooks directory.  Edit the source in
``D:/agents/projects/统一环境/modules/skill-supply-chain/implementation`` and
reinstall; the copy in the hooks directory is a deployment target.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


LEDGER = ".downloaded-skills-source-state.json"
# Same class as install_skill_guarded.SOURCE_RECORD_FORBIDDEN_CONTROL.
FORBIDDEN_CONTROL = re.compile(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]")
BINARY_SNIFF_BYTES = 8000
MAX_REPORTED = 20
SHIM_MARKER = "# skills_repo_pre_commit.py shim"
SHIM = f"""#!/bin/sh
{SHIM_MARKER}: reinstall with `skills_repo_pre_commit.py install` instead of editing.
exec "{{python}}" -X utf8 -I "$(dirname "$0")/skills_repo_pre_commit.py" check
"""


class GuardError(Exception):
    pass


def git(*args: str, repo: Path | None = None, data: bytes | None = None, allowed: tuple[int, ...] = (0,)) -> bytes:
    command = ["git", *(["-C", str(repo)] if repo is not None else []), *args]
    result = subprocess.run(command, input=data, capture_output=True)
    if result.returncode not in allowed:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise GuardError(f"git {' '.join(args)} 失败（exit {result.returncode}）：{detail}")
    return result.stdout


def staged_blobs() -> list[tuple[str, str]]:
    """Return (path, blob id) for staged added, modified and type-changed paths."""

    fields = git("diff-index", "--cached", "-z", "--no-renames", "--diff-filter=AMT", "HEAD").split(b"\0")
    blobs = []
    for meta, path in zip(fields[0::2], fields[1::2]):
        _, new_mode, _, new_oid, _ = meta.decode("ascii").lstrip(":").split(" ")
        if new_mode != "160000":
            blobs.append((path.decode("utf-8"), new_oid))
    return blobs


def read_blobs(oids: list[str]) -> list[bytes]:
    if not oids:
        return []
    output = git("cat-file", "--batch", data="".join(f"{oid}\n" for oid in oids).encode("ascii"))
    contents, offset = [], 0
    for _ in oids:
        header_end = output.index(b"\n", offset)
        size = int(output[offset:header_end].split(b" ")[2])
        start = header_end + 1
        contents.append(output[start : start + size])
        offset = start + size + 1
    return contents


def control_findings(path: str, data: bytes) -> list[str]:
    if b"\0" in data[:BINARY_SNIFF_BYTES]:
        return []
    findings = []
    for match in FORBIDDEN_CONTROL.finditer(data):
        line = data.count(b"\n", 0, match.start()) + 1
        findings.append(f"{path}:{line}: 控制字符 0x{match.group()[0]:02x}")
    return findings


def ledger_findings(data: bytes) -> list[str]:
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return [f"{LEDGER}: 不是有效的 UTF-8 JSON：{exc}"]
    if data != (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"):
        return [f"{LEDGER}: 不是 guarded installer 写出的规范 JSON（ensure_ascii=False、indent=2、末尾换行）"]
    return []


def check() -> int:
    blobs = staged_blobs()
    findings: list[str] = []
    for (path, _), data in zip(blobs, read_blobs([oid for _, oid in blobs])):
        findings += control_findings(path, data)
        if path == LEDGER:
            findings += ledger_findings(data)
    if not findings:
        return 0
    print("skills pre-commit: 拒绝提交，暂存内容有以下问题：", file=sys.stderr)
    for finding in findings[:MAX_REPORTED]:
        print(f"  {finding}", file=sys.stderr)
    if len(findings) > MAX_REPORTED:
        print(f"  ……另有 {len(findings) - MAX_REPORTED} 条", file=sys.stderr)
    return 1


def install(repo: Path, python: Path) -> int:
    hooks_path = git("config", "--get", "core.hooksPath", repo=repo, allowed=(0, 1)).decode("utf-8").strip()
    if hooks_path:
        raise GuardError(f"core.hooksPath 已设为 {hooks_path}，git 不会运行 hooks 目录里的 shim；先确认这个设置的归属")
    hooks_dir = repo / git("rev-parse", "--git-path", "hooks", repo=repo).decode("utf-8").strip()
    hooks_dir.mkdir(parents=True, exist_ok=True)
    shim = hooks_dir / "pre-commit"
    if shim.exists() and SHIM_MARKER not in shim.read_text(encoding="utf-8", errors="replace"):
        raise GuardError(f"{shim} 已是别的 pre-commit hook；先人工合并")
    source = Path(__file__).read_bytes()
    checker = hooks_dir / "skills_repo_pre_commit.py"
    checker.write_bytes(source)
    shim.write_bytes(SHIM.format(python=python.as_posix()).encode("utf-8"))
    os.chmod(shim, 0o755)
    if checker.read_bytes() != source:
        raise GuardError(f"{checker} 写入后与源文件不一致")
    print(f"installed {shim}")
    print(f"checker {checker} sha256 {hashlib.sha256(source).hexdigest()}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="check the staged changes of the current repository")
    install_parser = commands.add_parser("install", help="install the pre-commit shim and checker copy")
    install_parser.add_argument("--repo", required=True, type=Path)
    install_parser.add_argument("--python", type=Path, default=Path(sys.executable))
    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            return check()
        return install(args.repo.resolve(), args.python)
    except GuardError as exc:
        print(f"skills pre-commit: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
