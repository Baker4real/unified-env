#!/usr/bin/env python3
"""Commit exactly the reviewed bytes of named paths in a shared work tree.

Other sessions may edit or stage files in the same work tree while a commit is
prepared.  This helper builds the commit in a private index seeded from the
expected HEAD, so only the named paths change: each file is read once, checked
against its reviewed SHA-256, and those same bytes become the blob (through the
repository's clean filters, as ``git add`` would apply them).  ``git commit``
runs with its normal hooks.  Afterwards only the committed paths are refreshed
in the shared index; other sessions' staged and unstaged work stays put.

When another session's edits share a file, ``--list-hunks PATH`` prints the
file's work-tree SHA-256 and numbers its zero-context hunks against HEAD (the
same hunks, in the same order, as ``git diff -U0 HEAD -- PATH``); ``--hunks
PATH SHA256 INDEX...`` commits HEAD's content plus only those hunks, each placed
by its HEAD line numbers, and the other hunks stay as unstaged edits.  ``git
apply --cached --unidiff-zero`` with a subset of hunks is no substitute: it
places zero-context hunks by their new-side numbers, so every hunk after a
skipped one lands shifted while the apply still succeeds.

A guarded install transaction's ledger can be committed from its
``backups/source-state-after.json`` snapshot with ``--file-from`` when the live
ledger has changed since; the transaction manifest's ``source_state_after``
records that snapshot's path and SHA-256.

A pre-commit hook that checks the whole work tree still sees other sessions'
unstaged edits and untracked files.  The knowledge base's hook runs
``scripts/check.py --staged``, which requires the work tree to equal the index,
so there a partial commit fails until those edits are committed or included;
that repository has one owner commit every finished ingest together.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path


REGULAR_FILE_MODES = {"100644", "100755"}
HUNK_HEADER = re.compile(rb"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@")


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


def lines_of(data: bytes) -> list[bytes]:
    """Split on LF only, keeping each LF, the way git counts diff lines."""
    parts = data.split(b"\n")
    return [part + b"\n" for part in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def hunks_against(repo: Path, commit: str, path: str, data: bytes) -> tuple[bytes, list[tuple[int, int, list[bytes], list[bytes], str]]]:
    """HEAD's blob of ``path`` and the zero-context hunks turning it into ``data`` after clean filters.

    Each hunk is (old start, old length, removed lines, added lines, header).
    """
    if tree_entry_mode(repo, commit, path) is None:
        raise CommitError(f"{path} 不在 {commit} 里；新文件用 --file")
    old_blob = git_text(repo, "rev-parse", "--verify", f"{commit}:{path}")
    new_blob = git_text(repo, "hash-object", "-w", f"--path={path}", "--stdin", data=data)
    diff = git(repo, "diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", old_blob, new_blob).stdout
    hunks: list[tuple[int, int, list[bytes], list[bytes], str]] = []
    last: list[bytes] | None = None
    for line in lines_of(diff):
        match = HUNK_HEADER.match(line)
        if match:
            header = line.decode("utf-8", errors="replace").rstrip("\n")
            hunks.append((int(match[1]), 1 if match[2] is None else int(match[2]), [], [], header))
            last = None
        elif hunks and line[:1] in (b"-", b"+"):
            last = hunks[-1][2] if line[:1] == b"-" else hunks[-1][3]
            last.append(line[1:])
        elif hunks and line.startswith(b"\\") and last:
            last[-1] = last[-1].removesuffix(b"\n")
    return git(repo, "cat-file", "blob", old_blob).stdout, hunks


def splice_hunks(old: bytes, hunks: list[tuple[int, int, list[bytes], list[bytes], str]], keep: list[int], path: str) -> bytes:
    """``old`` with only the ``keep`` hunks applied, each at its old-side (HEAD) line numbers."""
    if len(set(keep)) != len(keep):
        raise CommitError(f"{path}：改动块编号重复 {keep}")
    lines, out, cursor = lines_of(old), [], 0
    for index in sorted(keep):
        if not 0 <= index < len(hunks):
            raise CommitError(f"{path}：没有第 {index} 个改动块（共 {len(hunks)} 个）")
        start, length, removed, added, header = hunks[index]
        begin = start if length == 0 else start - 1
        if lines[begin:begin + length] != removed:
            raise CommitError(f"{path}：第 {index} 个改动块 {header} 与 HEAD 的内容对不上")
        out += lines[cursor:begin] + added
        cursor = begin + length
    return b"".join(out + lines[cursor:])


def list_hunks(repo: Path, path: str) -> str:
    data = (repo / path).read_bytes()
    head = git_text(repo, "rev-parse", "--verify", "HEAD")
    _, hunks = hunks_against(repo, head, path, data)
    rows = [f"{path} sha256={hashlib.sha256(data).hexdigest()} hunks={len(hunks)} (against HEAD {head[:12]})"]
    for index, (_, _, removed, added, header) in enumerate(hunks):
        first = (added or removed or [b""])[0].decode("utf-8", errors="replace").rstrip("\r\n")[:80]
        rows.append(f"{index:3} {header} -{len(removed)} +{len(added)} | {first}")
    return "\n".join(rows)


def commit_exact(
    *,
    repo: Path,
    expected_head: str,
    message_file: Path,
    files: list[tuple[str, Path, str]],
    deletes: list[str],
    hunks: list[tuple[str, str, list[int]]] = (),
) -> str:
    """Commit ``files`` (path, content source, reviewed SHA-256), ``hunks`` (path, reviewed work-tree SHA-256, hunk numbers) and ``deletes`` on ``expected_head``."""

    paths = [path for path, _, _ in files] + [path for path, _, _ in hunks] + deletes
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
    for path, reviewed, keep in hunks:
        data = (repo / path).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != reviewed.lower():
            raise CommitError(f"{path}：工作树 sha256 是 {actual}，不是评审过的 {reviewed}；重新 --list-hunks")
        old, found = hunks_against(repo, expected, path, data)
        mode = tree_entry_mode(repo, expected, path)
        if mode not in REGULAR_FILE_MODES:
            raise CommitError(f"{path}：不支持 mode {mode}")
        content = splice_hunks(old, found, keep, path)
        blob = git_text(repo, "hash-object", "-w", "--no-filters", "--stdin", data=content)
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
    parser.add_argument("--expected-head", help="commit HEAD points to now; it becomes the parent")
    parser.add_argument("--message-file", type=Path)
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
    parser.add_argument(
        "--hunks",
        action="append",
        nargs="+",
        default=[],
        metavar="ITEM",
        help="PATH SHA256 INDEX [INDEX ...]: commit HEAD's PATH plus only hunks INDEX..., numbered as "
        "--list-hunks prints them for work-tree bytes hashing to SHA256",
    )
    parser.add_argument(
        "--list-hunks",
        metavar="PATH",
        help="print PATH's work-tree SHA-256 and its numbered hunks against HEAD, then exit",
    )
    args = parser.parse_args(argv)
    if args.list_hunks:
        if args.file or args.file_from or args.delete or args.hunks:
            parser.error("--list-hunks 只能单独使用")
        return args
    if not (args.expected_head and args.message_file):
        parser.error("提交需要 --expected-head 和 --message-file")
    if not (args.file or args.file_from or args.delete or args.hunks):
        parser.error("至少给一个 --file、--file-from、--hunks 或 --delete")
    for values in args.hunks:
        if len(values) < 3 or not all(value.isdigit() for value in values[2:]):
            parser.error("--hunks 的格式是 PATH SHA256 INDEX [INDEX ...]")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = args.repo.resolve()
    if args.list_hunks:
        try:
            print(list_hunks(repo, Path(args.list_hunks).as_posix()))
        except (CommitError, OSError) as exc:
            print(f"commit_exact_files: {exc}", file=sys.stderr)
            return 1
        return 0
    files = [(Path(path).as_posix(), repo / path, sha) for path, sha in args.file]
    files += [(Path(path).as_posix(), Path(source), sha) for path, source, sha in args.file_from]
    hunks = [(Path(values[0]).as_posix(), values[1], [int(index) for index in values[2:]]) for values in args.hunks]
    deletes = [Path(path).as_posix() for path in args.delete]
    try:
        head = commit_exact(
            repo=repo,
            expected_head=args.expected_head,
            message_file=args.message_file,
            files=files,
            deletes=deletes,
            hunks=hunks,
        )
    except (CommitError, OSError) as exc:
        print(f"commit_exact_files: {exc}", file=sys.stderr)
        return 1
    paths = [path for path, _, _ in files] + [path for path, _, _ in hunks] + deletes
    print(git_text(repo, "show", "--stat", "--format=%H%n%an <%ae> | %s", head))
    status = git(repo, "status", "--porcelain=v1", "--", *paths).stdout.decode("utf-8").rstrip()
    print("committed paths status:", status or "clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
