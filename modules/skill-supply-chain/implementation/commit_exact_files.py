#!/usr/bin/env python3
"""Commit exactly the reviewed bytes of named paths in a shared work tree.

Other sessions may edit or stage files in the same work tree while a commit is
prepared.  This helper builds the commit in a private index seeded from the
expected HEAD, so only the named paths change: each file is read once, checked
against its reviewed SHA-256, and those same bytes become the blob (through the
repository's clean filters, as ``git add`` would apply them).  ``git commit``
runs with its normal hooks.  Afterwards only the committed paths are refreshed
in the shared index; other sessions' staged and unstaged work stays put.

A guarded install transaction's ledger can be committed from its
``backups/source-state-after.json`` snapshot with ``--file-from`` when the live
ledger has changed since; the transaction manifest's ``source_state_after``
records that snapshot's path and SHA-256.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import uuid
from pathlib import Path


REGULAR_FILE_MODES = {"100644", "100755"}


class CommitError(Exception):
    """A precondition or postcondition failed; the message names it."""


def git(
    repo: Path,
    *args: str,
    data: bytes | None = None,
    index: Path | None = None,
    allowed: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[bytes]:
    env = dict(os.environ, GIT_LITERAL_PATHSPECS="1")
    env.pop("GIT_INDEX_FILE", None)
    if index is not None:
        env["GIT_INDEX_FILE"] = str(index)
    result = subprocess.run(["git", "-C", str(repo), *args], input=data, capture_output=True, env=env)
    if result.returncode not in allowed:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise CommitError(f"git {' '.join(args)} 失败（exit {result.returncode}）：{detail}")
    return result


def git_text(repo: Path, *args: str, data: bytes | None = None, index: Path | None = None) -> str:
    return git(repo, *args, data=data, index=index).stdout.decode("utf-8").strip()


def path_list(output: bytes) -> list[str]:
    return sorted(item.decode("utf-8") for item in output.split(b"\0") if item)


def tree_entry_mode(repo: Path, commit: str, path: str) -> str | None:
    output = git(repo, "ls-tree", "-z", commit, "--", path).stdout
    if not output:
        return None
    mode, kind, _ = output.split(b"\t", 1)[0].decode("ascii").split(" ")
    if kind != "blob":
        raise CommitError(f"{path} 在 {commit} 里是 {kind}，不是文件")
    return mode


def commit_exact(
    *,
    repo: Path,
    expected_head: str,
    message_file: Path,
    files: list[tuple[str, Path, str]],
    deletes: list[str],
) -> str:
    """Commit ``files`` (path, content source, reviewed SHA-256) and ``deletes`` on ``expected_head``."""

    paths = [path for path, _, _ in files] + deletes
    duplicates = sorted({path for path in paths if paths.count(path) > 1})
    if duplicates:
        raise CommitError(f"同一路径出现多次：{duplicates}")
    expected = git_text(repo, "rev-parse", "--verify", f"{expected_head}^{{commit}}")
    if git_text(repo, "rev-parse", "--verify", "HEAD") != expected:
        raise CommitError(f"HEAD 已不是 {expected}，重新核对后再提交")
    if git(repo, "diff", "--cached", "--quiet", expected, "--", *paths, allowed=(0, 1)).returncode:
        raise CommitError("共享 index 里这些路径已有暂存改动；先确认它们属于哪个会话")
    entries: list[tuple[str, str, str]] = []
    for path, source, reviewed in files:
        data = source.read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != reviewed.lower():
            raise CommitError(f"{path}：内容 sha256 是 {actual}，不是评审过的 {reviewed}")
        mode = tree_entry_mode(repo, expected, path) or "100644"
        if mode not in REGULAR_FILE_MODES:
            raise CommitError(f"{path}：不支持 mode {mode}")
        blob = git_text(repo, "hash-object", "-w", f"--path={path}", "--stdin", data=data)
        entries.append((mode, blob, path))
    for path in deletes:
        if tree_entry_mode(repo, expected, path) is None:
            raise CommitError(f"{path} 不在 {expected} 里，无从删除")
        if os.path.lexists(repo / path):
            raise CommitError(f"{path} 仍在工作树里；--delete 只提交已经不在的文件")
    git_dir = Path(git_text(repo, "rev-parse", "--absolute-git-dir"))
    index = git_dir / f"index.commit-exact-files.{uuid.uuid4().hex}"
    try:
        git(repo, "read-tree", expected, index=index)
        for mode, blob, path in entries:
            git(repo, "update-index", "--add", "--cacheinfo", mode, blob, path, index=index)
        for path in deletes:
            git(repo, "update-index", "--force-remove", "--", path, index=index)
        changed = path_list(
            git(repo, "diff", "--cached", "--name-only", "-z", "--no-renames", expected, index=index).stdout
        )
        if changed != sorted(paths):
            raise CommitError(f"私有 index 的改动是 {changed}，不是请求的 {sorted(paths)}（内容与 HEAD 相同的路径不能提交）")
        tree = git_text(repo, "write-tree", index=index)
        if git_text(repo, "rev-parse", "--verify", "HEAD") != expected:
            raise CommitError(f"HEAD 在准备期间离开了 {expected}，没有提交")
        git(repo, "commit", "-q", "-F", str(message_file.resolve()), index=index)
    finally:
        index.unlink(missing_ok=True)
    head = git_text(repo, "rev-parse", "--verify", "HEAD")
    parent = git_text(repo, "rev-parse", "--verify", "HEAD^")
    if parent != expected:
        raise CommitError(f"新提交 {head} 的父提交是 {parent}，不是 {expected}；推送前人工核对")
    if git_text(repo, "rev-parse", "--verify", "HEAD^{tree}") != tree:
        raise CommitError(f"新提交 {head} 的 tree 与私有 index 不一致（hook 改了暂存内容？）；推送前人工核对")
    git(repo, "reset", "-q", "--", *paths)
    return head


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, type=Path, help="work tree root")
    parser.add_argument("--expected-head", required=True, help="commit HEAD points to now; it becomes the parent")
    parser.add_argument("--message-file", required=True, type=Path)
    parser.add_argument(
        "--file",
        action="append",
        nargs=2,
        default=[],
        metavar=("PATH", "SHA256"),
        help="commit PATH's work-tree bytes, which must hash to SHA256",
    )
    parser.add_argument(
        "--file-from",
        action="append",
        nargs=3,
        default=[],
        metavar=("PATH", "SOURCE", "SHA256"),
        help="commit SOURCE's bytes as PATH; they must hash to SHA256",
    )
    parser.add_argument(
        "--delete",
        action="append",
        default=[],
        metavar="PATH",
        help="commit PATH's removal; PATH must be in HEAD and absent from the work tree",
    )
    args = parser.parse_args(argv)
    if not (args.file or args.file_from or args.delete):
        parser.error("至少给一个 --file、--file-from 或 --delete")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = args.repo.resolve()
    files = [(Path(path).as_posix(), repo / path, sha) for path, sha in args.file]
    files += [(Path(path).as_posix(), Path(source), sha) for path, source, sha in args.file_from]
    deletes = [Path(path).as_posix() for path in args.delete]
    try:
        head = commit_exact(
            repo=repo,
            expected_head=args.expected_head,
            message_file=args.message_file,
            files=files,
            deletes=deletes,
        )
    except (CommitError, OSError) as exc:
        print(f"commit_exact_files: {exc}", file=sys.stderr)
        return 1
    paths = [path for path, _, _ in files] + deletes
    print(git_text(repo, "show", "--stat", "--format=%H%n%an <%ae> | %s", head))
    status = git(repo, "status", "--porcelain=v1", "--", *paths).stdout.decode("utf-8").rstrip()
    print("committed paths status:", status or "clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
