#!/usr/bin/env python3
"""Commit exactly the reviewed bytes of named paths in a shared work tree.

Other sessions may edit or stage files in the same work tree while a commit is
prepared.  This helper builds the commit in a private index seeded from the
expected HEAD, so only the named paths change: each file is read once, checked
against its reviewed SHA-256, and those same bytes become the blob (through the
repository's clean filters, as ``git add`` would apply them).  ``git commit``
runs with its normal hooks.  Afterwards only the committed paths are refreshed
in the shared index; other sessions' staged and unstaged work stays put.  The
refresh waits up to 30 seconds for another git process's ``index.lock``; if it
still cannot run, the commit stands, and the helper prints it and exits 3,
naming the ``git reset`` that finishes the refresh.  Until that runs, a commit
from the shared index would revert the committed paths.

When another session's edits share a file, ``--list-hunks PATH`` prints the
file's work-tree SHA-256 and numbers its zero-context hunks against HEAD (the
same hunks, in the same order, as ``git diff -U0 HEAD -- PATH``); ``--hunks
PATH SHA256 INDEX...`` commits HEAD's content plus only those hunks, each placed
by its HEAD line numbers, and the other hunks stay as unstaged edits.  ``git
apply --cached --unidiff-zero`` with a subset of hunks is no substitute: it
starts each zero-context hunk's search at its new-side line number, so after a
skipped hunk every pure insertion lands shifted and a replacement edits the
nearest copy of its old lines, the wrong one when that text repeats, while the
apply still succeeds.

``--file-from PATH SOURCE SHA256`` commits bytes prepared outside the work
tree.  When two sessions edit adjacent lines, ``git diff -U0`` merges the edits
into one hunk that ``--hunks`` cannot split; write HEAD's content plus only your
edit to SOURCE instead, and the other edit stays unstaged.  A guarded install
transaction's ledger can be committed the same way from its
``backups/source-state-after.json`` snapshot when the live ledger has changed
since; the transaction manifest's ``source_state_after`` records that
snapshot's path and SHA-256.

``--from-commit SNAPSHOT COMMIT`` replays one commit made in a snapshot of this
repository (``exact_snapshot.py create`` makes one): its paths, modes and
blobs, and its message unless ``--message-file`` is given.  Each of those paths
must be in HEAD exactly as in the commit's parent, so the replay never
overwrites a change committed since the snapshot was taken; when the parent's
tree equals HEAD's, the new commit's tree must equal the snapshot commit's.

After a ``--file-from`` or ``--from-commit`` commit, a work-tree copy that
still matches the parent commit (missing, for a new file) is brought to the
new version, or removed for a deleted file; a copy holding other edits is left
alone and named, since committing it as it stands would revert this commit.
If that update fails, the commit stands and the helper exits 3.

A committed path keeps its mode in HEAD, and a new one is a regular file
(100644); ``--executable PATH`` commits PATH, which ``--file`` or
``--file-from`` must also name, as 100755 instead (a new hook script, say).

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
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path


REGULAR_FILE_MODES = {"100644", "100755"}
HUNK_HEADER = re.compile(rb"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@")
INDEX_LOCK_WAIT_SECONDS = 30.0
INDEX_LOCK_POLL_SECONDS = 0.25


class CommitError(Exception):
    """A precondition or postcondition failed; the message names it."""


class IndexNotRefreshed(CommitError):
    """The commit exists, but the shared index still holds the committed paths' old entries."""

    def __init__(self, head: str, message: str) -> None:
        super().__init__(message)
        self.head = head


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


def tree_entry(repo: Path, commit: str, path: str) -> tuple[str, str] | None:
    """``path``'s (mode, blob) in ``commit``, or None when it is absent."""
    output = git(repo, "ls-tree", "-z", commit, "--", path).stdout
    if not output:
        return None
    mode, kind, blob = output.split(b"\t", 1)[0].decode("ascii").split(" ")
    if kind != "blob":
        raise CommitError(f"{path} 在 {commit} 里是 {kind}，不是文件")
    return mode, blob


def tree_entry_mode(repo: Path, commit: str, path: str) -> str | None:
    entry = tree_entry(repo, commit, path)
    return entry[0] if entry else None


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


def refresh_shared_index(repo: Path, git_dir: Path, head: str, paths: list[str]) -> None:
    """Point the shared index entries of ``paths`` at the new commit ``head``.

    Another git process (a status refresh, another session's commit) may hold
    ``index.lock`` for a moment; wait up to ``INDEX_LOCK_WAIT_SECONDS`` for it.
    """
    lock = git_dir / "index.lock"
    deadline = time.monotonic() + INDEX_LOCK_WAIT_SECONDS
    while True:
        try:
            git(repo, "reset", "-q", "--", *paths)
            return
        except CommitError as exc:
            if ("index.lock" in str(exc) or lock.exists()) and time.monotonic() < deadline:
                time.sleep(INDEX_LOCK_POLL_SECONDS)
                continue
            command = shlex.join(["git", "-C", str(repo), "reset", "-q", "--", *paths])
            raise IndexNotRefreshed(
                head,
                f"提交 {head} 已生成，但共享 index 没有刷新（{exc}）。处理掉原因（通常是别的 git 进程持有 index.lock）"
                f"后运行 {command}；在此之前用共享 index 提交，会把这次提交的改动回退",
            ) from exc


def replay_entries(
    repo: Path, expected: str, source: Path, commit: str
) -> tuple[list[tuple[str, str, str]], list[str], bytes, str | None]:
    """The (mode, blob, path) entries and the deletions that replay ``commit`` of the snapshot ``source`` on ``expected``.

    Also returns the commit's message, and its tree when its parent's tree equals ``expected``'s, for the replayed
    commit to reproduce.  A path that ``expected`` holds differently from the parent stops the replay, since writing
    the snapshot's version would overwrite whatever changed it.
    """
    snapshot = git_text(source, "rev-parse", "--verify", f"{commit}^{{commit}}")
    parents = git_text(source, "rev-list", "--parents", "-n", "1", snapshot).split()[1:]
    if len(parents) != 1:
        raise CommitError(f"{snapshot} 有 {len(parents)} 个父提交；--from-commit 只重放单个父提交的提交")
    raw = git(source, "diff-tree", "-r", "-z", "--no-renames", "--no-abbrev", parents[0], snapshot).stdout.split(b"\0")
    changes: list[tuple[str, str, str]] = []
    moved: list[str] = []
    for meta, name in zip(raw[0:-1:2], raw[1::2]):
        old_mode, new_mode, old_blob, new_blob, _ = meta.decode("ascii").lstrip(":").split(" ")
        path = name.decode("utf-8")
        for mode in (old_mode, new_mode):
            if mode != "000000" and mode not in REGULAR_FILE_MODES:
                raise CommitError(f"{path}：不支持 mode {mode}")
        if tree_entry(repo, expected, path) != (None if old_mode == "000000" else (old_mode, old_blob)):
            moved.append(path)
        changes.append((new_mode, new_blob, path))
    if moved:
        raise CommitError(
            f"这些路径在 {expected} 里和快照基底 {parents[0]} 不同，重放会覆盖之后的提交：{moved}；"
            "先用 exact_snapshot.py onto 把快照跟上 HEAD"
        )
    if not changes:
        raise CommitError(f"{snapshot} 没有改动")
    entries: list[tuple[str, str, str]] = []
    deletes: list[str] = []
    for new_mode, new_blob, path in changes:
        if new_mode == "000000":
            deletes.append(path)
            continue
        data = git(source, "cat-file", "blob", new_blob).stdout
        if git_text(repo, "hash-object", "-w", "--no-filters", "--stdin", data=data) != new_blob:
            raise CommitError(f"{path}：写进本仓库的 blob 与快照的 {new_blob} 不同")
        entries.append((new_mode, new_blob, path))
    message = git(source, "log", "-1", "--format=%B", snapshot).stdout
    same_base = git_text(source, "rev-parse", f"{parents[0]}^{{tree}}") == git_text(repo, "rev-parse", f"{expected}^{{tree}}")
    return entries, deletes, message, git_text(source, "rev-parse", f"{snapshot}^{{tree}}") if same_base else None


def sync_work_tree(repo: Path, head: str, paths: list[str]) -> tuple[list[str], list[str]]:
    """Bring each work-tree copy of ``paths`` that still matches ``head``'s parent to ``head``'s version.

    Returns the paths brought over and the paths left alone because their copy holds other edits.
    """
    synced: list[str] = []
    left: list[str] = []
    for path in paths:
        old = tree_entry(repo, f"{head}^", path)
        new = tree_entry(repo, head, path)
        target = repo / path
        if target.is_file() and not target.is_symlink():
            current = git_text(repo, "hash-object", f"--path={path}", "--stdin", data=target.read_bytes())
        elif os.path.lexists(target):
            left.append(path)
            continue
        else:
            current = None
        if current == (new[1] if new else None):
            continue
        if current != (old[1] if old else None):
            left.append(path)
        elif new is None:
            target.unlink()
            synced.append(path)
        else:
            git(repo, "checkout-index", "-f", "--", path)
            synced.append(path)
    return synced, left


def commit_exact(
    *,
    repo: Path,
    expected_head: str,
    message_file: Path | None,
    files: list[tuple[str, Path, str]],
    deletes: list[str],
    hunks: list[tuple[str, str, list[int]]] = (),
    executables: list[str] = (),
    replay: tuple[Path, str] | None = None,
) -> str:
    """Commit ``files`` (path, content source, reviewed SHA-256), ``hunks`` (path, reviewed work-tree SHA-256, hunk numbers) and ``deletes`` on ``expected_head``; ``executables`` names files to commit as 100755.

    ``replay`` (snapshot repository, commit) commits that commit's changes instead, with its message unless
    ``message_file`` is given.
    """

    paths = [path for path, _, _ in files] + [path for path, _, _ in hunks] + deletes
    duplicates = sorted({path for path in paths if paths.count(path) > 1})
    if duplicates:
        raise CommitError(f"同一路径出现多次：{duplicates}")
    stray_executables = sorted(set(executables) - {path for path, _, _ in files})
    if stray_executables:
        raise CommitError(f"--executable 只能指 --file 或 --file-from 提交的路径：{stray_executables}")
    expected = git_text(repo, "rev-parse", "--verify", f"{expected_head}^{{commit}}")
    if git_text(repo, "rev-parse", "--verify", "HEAD") != expected:
        raise CommitError(f"HEAD 已不是 {expected}，重新核对后再提交")
    entries: list[tuple[str, str, str]] = []
    message, snapshot_tree = b"", None
    if replay:
        entries, deletes, message, snapshot_tree = replay_entries(repo, expected, *replay)
        paths = [path for _, _, path in entries] + deletes
    if message_file:
        message = message_file.read_bytes()
    if git(repo, "diff", "--cached", "--quiet", expected, "--", *paths, allowed=(0, 1)).returncode:
        raise CommitError("共享 index 里这些路径已有暂存改动；先确认它们属于哪个会话")
    for path, source, reviewed in files:
        data = source.read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != reviewed.lower():
            raise CommitError(f"{path}：内容 sha256 是 {actual}，不是评审过的 {reviewed}")
        mode = tree_entry_mode(repo, expected, path) or "100644"
        if mode not in REGULAR_FILE_MODES:
            raise CommitError(f"{path}：不支持 mode {mode}")
        if path in executables:
            mode = "100755"
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
    for path in () if replay else deletes:
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
        if snapshot_tree and tree != snapshot_tree:
            raise CommitError(f"重放得到的 tree {tree} 不等于快照提交的 tree {snapshot_tree}，没有提交")
        if git_text(repo, "rev-parse", "--verify", "HEAD") != expected:
            raise CommitError(f"HEAD 在准备期间离开了 {expected}，没有提交")
        git(repo, "commit", "-q", "-F", "-", data=message, index=index)
    finally:
        index.unlink(missing_ok=True)
    head = git_text(repo, "rev-parse", "--verify", "HEAD")
    parent = git_text(repo, "rev-parse", "--verify", "HEAD^")
    if parent != expected:
        raise CommitError(f"新提交 {head} 的父提交是 {parent}，不是 {expected}；推送前人工核对")
    if git_text(repo, "rev-parse", "--verify", "HEAD^{tree}") != tree:
        raise CommitError(f"新提交 {head} 的 tree 与私有 index 不一致（hook 改了暂存内容？）；推送前人工核对")
    refresh_shared_index(repo, git_dir, head, paths)
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
        "--executable",
        action="append",
        default=[],
        metavar="PATH",
        help="commit PATH, which --file or --file-from also names, as an executable file (mode 100755)",
    )
    parser.add_argument(
        "--from-commit",
        nargs=2,
        metavar=("SNAPSHOT", "COMMIT"),
        help="replay COMMIT of the snapshot repository SNAPSHOT: its paths, modes and blobs, and its message "
        "unless --message-file is given",
    )
    parser.add_argument(
        "--hunks",
        action="append",
        nargs="+",
        default=[],
        metavar="ITEM",
        help="PATH SHA256 INDEX [INDEX ...]: commit HEAD's PATH plus only hunks INDEX..., numbered as "
        "--list-hunks prints them for work-tree bytes hashing to SHA256; a hunk that also holds another "
        "session's edit needs --file-from",
    )
    parser.add_argument(
        "--list-hunks",
        metavar="PATH",
        help="print PATH's work-tree SHA-256 and its numbered hunks against HEAD, then exit",
    )
    args = parser.parse_args(argv)
    if args.list_hunks:
        if args.file or args.file_from or args.delete or args.hunks or args.executable or args.from_commit:
            parser.error("--list-hunks 只能单独使用")
        return args
    if args.from_commit:
        if args.file or args.file_from or args.delete or args.hunks or args.executable:
            parser.error("--from-commit 不和 --file、--file-from、--hunks、--delete、--executable 同用")
        if not args.expected_head:
            parser.error("提交需要 --expected-head")
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
    replay = (Path(args.from_commit[0]).resolve(), args.from_commit[1]) if args.from_commit else None
    try:
        head = commit_exact(
            repo=repo,
            expected_head=args.expected_head,
            message_file=args.message_file,
            files=files,
            deletes=deletes,
            hunks=hunks,
            executables=[Path(path).as_posix() for path in args.executable],
            replay=replay,
        )
    except IndexNotRefreshed as exc:
        print(git_text(repo, "show", "--stat", "--format=%H%n%an <%ae> | %s", exc.head))
        print(f"commit_exact_files: {exc}", file=sys.stderr)
        return 3
    except (CommitError, OSError) as exc:
        print(f"commit_exact_files: {exc}", file=sys.stderr)
        return 1
    committed = path_list(git(repo, "diff-tree", "-r", "-z", "--name-only", "--no-renames", "--no-commit-id", head).stdout)
    print(git_text(repo, "show", "--stat", "--format=%H%n%an <%ae> | %s", head))
    try:
        synced, left = sync_work_tree(repo, head, committed if replay else [Path(path).as_posix() for path, _, _ in args.file_from])
    except (CommitError, OSError) as exc:
        print(f"commit_exact_files: 提交 {head} 已生成，但同步工作树失败：{exc}", file=sys.stderr)
        return 3
    for path in synced:
        print(f"工作树已换成新提交的版本：{path}")
    for path in left:
        print(f"工作树里的 {path} 带着别的改动，没有动它；按它现在的样子提交会回退本次提交，先把本次改动补进去")
    status = git(repo, "status", "--porcelain=v1", "--", *committed).stdout.decode("utf-8").rstrip()
    print("committed paths status:", status or "clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
