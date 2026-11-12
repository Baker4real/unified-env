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
by its HEAD line numbers, and the other hunks stay as unstaged edits.  When the
shared index already stages PATH, the listing ends with the refusal that such a
commit would meet (see the staged-change paragraph below).  ``git apply
--cached --unidiff-zero`` with a subset of hunks is no substitute: it
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

``--transaction EVIDENCE`` commits what one succeeded guarded install transaction
changed, read from its evidence directory: each skill directory as the work tree
holds it, once the tree matches the transaction's ``activated_payload_seal`` and
HEAD holds the version the transaction backed up, plus only that transaction's
ledger change.  That change is the transaction's ``backups/source-state-before.json``
to ``source-state-after.json`` delta applied to HEAD's ledger: source groups match by
``id``, appended ``local_changes`` stay appended, ``updated_at`` and
``last_guarded_install`` keep the later time, and anything else that both HEAD and
the transaction changed stops the commit.  Another session's uncommitted
transaction in the live ledger stays out of the commit and in the work tree.

``--from-commit SNAPSHOT COMMIT`` replays one commit made in a snapshot of this
repository (``exact_snapshot.py create`` makes one): its paths, modes and
blobs, and its message unless ``--message-file`` is given.  Each of those paths
must be in HEAD exactly as in the commit's parent, so the replay never
overwrites a change committed since the snapshot was taken; when the parent's
tree equals HEAD's, the new commit's tree must equal the snapshot commit's.

After a ``--file-from`` or ``--from-commit`` commit, a work-tree copy that
still matches the parent commit (missing, for a new file) is brought to the
new version, or removed for a deleted file.  A copy holding other edits is left
alone and named.  It already holds this commit's change when its edits on top
of the new version delete none of the lines the commit added and put none of
the lines it removed back in their place; otherwise, or when that cannot be
told (binary content, a file the commit deletes), the helper says the copy may
lack the change, and committing the copy as it stands would revert this commit
wherever it does.  If that update fails, the commit stands and the helper exits 3.

A named path that already holds a staged change in the shared index stops
the commit, since that change belongs to whichever session staged it; the
refusal names each such path and when its staged version was written, for
finding the owner in session transcripts and closeout records.  Once the owner
is confirmed and the commit authorized, ``--from-index PATH BLOB`` commits that
staged entry as it is: its blob must be BLOB (``git ls-files -s PATH`` prints
it) and its mode is kept.

A committed path keeps its mode in HEAD, and a new one is a regular file
(100644); ``--executable PATH`` commits PATH, which ``--file`` or
``--file-from`` must also name, as 100755 instead (a new hook script, say).

A pre-commit hook that checks the whole work tree still sees other sessions'
unstaged edits and untracked files.  The knowledge base's hook instead checks
only the staged content.  Use its ``scripts/kb_stage.py`` with selected record
files to stage those records, their owned changes and the derived index;
unrelated work-tree changes stay uncommitted and do not block that commit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path

if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from install_skill_guarded_base import tree_manifest_sha256  # noqa: E402  (the wrapper's tree seal)


REGULAR_FILE_MODES = {"100644", "100755"}
LEDGER_TIMESTAMP_KEYS = frozenset({"updated_at", "last_guarded_install"})
_MISSING = object()
HUNK_HEADER = re.compile(rb"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
INDEX_LOCK_WAIT_SECONDS = 30.0
INDEX_LOCK_POLL_SECONDS = 0.25
TRANSCRIPTS = Path(__file__).resolve().parents[1] / "overlays" / "retro" / "scripts" / "transcripts.py"


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


# Windows caps a whole command line at 32,767 characters, and one skill update can name thousands of paths
# (design-taste-frontend v2.5.1: 1,633, about 91K characters), so path lists reach git in batches.
PATH_BATCH_CHARS = 16_000


def path_batches(paths: list[str]) -> list[list[str]]:
    """``paths`` in order, split so no batch's command line nears the Windows cap; an oversized path rides alone."""
    batches: list[list[str]] = []
    size = PATH_BATCH_CHARS
    for path in paths:
        if size + len(path) + 3 > PATH_BATCH_CHARS:
            batches.append([])
            size = 0
        batches[-1].append(path)
        size += len(path) + 3  # the separating space, and quotes around a path with a space in it
    return batches


# A git process costs about 0.1 s on Windows; started several times per file, they kept that 1,633-file update
# committing for 771 s.  So work over many files reaches git as path batches or one stdin list per step; a file
# gets a process of its own only when it needs a look of its own (a work-tree copy about to be overwritten, or bytes
# its clean filters change).


def tree_entries(repo: Path, commit: str, paths: list[str]) -> dict[str, tuple[str, str, str]]:
    """The (mode, type, object) ``commit`` holds at each of ``paths`` it has.

    ``-r -t`` lists a requested directory as a tree even when another requested path lies inside it; without them
    ls-tree descends into it silently, and the directory would read as absent.
    """
    entries: dict[str, tuple[str, str, str]] = {}
    for batch in path_batches(paths):
        for row in git(repo, "ls-tree", "-r", "-t", "-z", commit, "--", *batch).stdout.split(b"\0"):
            if row:
                meta, name = row.split(b"\t", 1)
                mode, kind, blob = meta.decode("ascii").split(" ")
                entries[name.decode("utf-8")] = (mode, kind, blob)
    return entries


def blob_entry(entries: dict[str, tuple[str, str, str]], commit: str, path: str) -> tuple[str, str] | None:
    """``path``'s (mode, blob) among ``commit``'s ``entries``, or None when it is absent."""
    if path not in entries:
        return None
    mode, kind, blob = entries[path]
    if kind != "blob":
        raise CommitError(f"{path} 在 {commit} 里是 {kind}，不是文件")
    return mode, blob


def tree_entry(repo: Path, commit: str, path: str) -> tuple[str, str] | None:
    """``path``'s (mode, blob) in ``commit``, or None when it is absent."""
    return blob_entry(tree_entries(repo, commit, [path]), commit, path)


def work_tree_blobs(repo: Path, paths: list[str], *, write: bool) -> list[str]:
    """Each work-tree file's blob through its clean filters, as ``git add`` stores it, from one git process.

    git opens these files itself, and without ``core.longpaths`` it cannot open a path of 260 characters or more.
    """
    if not paths:
        return []
    listing = "".join(f"{path}\n" for path in paths).encode("utf-8")
    flags = ["-w"] if write else []
    return git(repo, "-c", "core.longpaths=true", "hash-object", *flags, "--stdin-paths", data=listing).stdout.decode("ascii").split()


def copy_blobs(repo: Path, paths: list[str]) -> dict[str, str | None]:
    """Each path's work-tree copy: its blob (written), "" for something other than a regular file, None when absent."""
    files = [path for path in paths if (repo / path).is_file() and not (repo / path).is_symlink()]
    blobs = dict(zip(files, work_tree_blobs(repo, files, write=True), strict=True))
    return {path: blobs.get(path, "" if os.path.lexists(repo / path) else None) for path in paths}


def raw_blob_id(data: bytes, like: str) -> str:
    """The id of ``data`` stored unfiltered as a blob, in the object format of the id ``like``."""
    return hashlib.new("sha1" if len(like) == 40 else "sha256", b"blob %d\0" % len(data) + data).hexdigest()


def is_blob_of(repo: Path, path: str, data: bytes, blob: str) -> bool:
    """Whether ``data`` through ``path``'s clean filters is ``blob``; bytes that already are its content skip git."""
    return raw_blob_id(data, blob) == blob or git_text(repo, "hash-object", f"--path={path}", "--stdin", data=data) == blob


def file_blobs(repo: Path, rows: list[tuple[str, Path | bytes, bytes]], like: str) -> list[str]:
    """Write and return the blob each (path, source, bytes) row commits: the bytes through ``path``'s clean filters.

    Rows read from their own work-tree file go to git together; where git's blob of the file is those bytes
    unfiltered, the filters leave them alone and that blob is the row's.  Every other row gets its own hash-object.
    """
    own = [index for index, (path, source, _) in enumerate(rows) if source == repo / path]
    found = dict(zip(own, work_tree_blobs(repo, [rows[index][0] for index in own], write=True), strict=True))
    return [
        found[index]
        if found.get(index) == raw_blob_id(data, like)
        else git_text(repo, "hash-object", "-w", f"--path={path}", "--stdin", data=data)
        for index, (path, _, data) in enumerate(rows)
    ]


def tree_entry_mode(repo: Path, commit: str, path: str) -> str | None:
    entry = tree_entry(repo, commit, path)
    return entry[0] if entry else None


def lines_of(data: bytes) -> list[bytes]:
    """Split on LF only, keeping each LF, the way git counts diff lines."""
    parts = data.split(b"\n")
    return [part + b"\n" for part in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def blob_hunks(repo: Path, old_blob: str, new_blob: str) -> list[tuple[int, int, int, int, list[bytes], list[bytes], str]]:
    """The zero-context hunks turning ``old_blob`` into ``new_blob``; binary content has none.

    Each hunk is (old start, old length, new start, new length, removed lines, added lines, header); a side of
    length 0 sits after its start line.
    """
    diff = git(repo, "diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", old_blob, new_blob).stdout
    hunks: list[tuple[int, int, int, int, list[bytes], list[bytes], str]] = []
    last: list[bytes] | None = None
    for line in lines_of(diff):
        match = HUNK_HEADER.match(line)
        if match:
            header = line.decode("utf-8", errors="replace").rstrip("\n")
            old_length = 1 if match[2] is None else int(match[2])
            new_length = 1 if match[4] is None else int(match[4])
            hunks.append((int(match[1]), old_length, int(match[3]), new_length, [], [], header))
            last = None
        elif hunks and line[:1] in (b"-", b"+"):
            last = hunks[-1][4] if line[:1] == b"-" else hunks[-1][5]
            last.append(line[1:])
        elif hunks and line.startswith(b"\\") and last:
            last[-1] = last[-1].removesuffix(b"\n")
    return hunks


def hunks_against(repo: Path, commit: str, path: str, data: bytes) -> tuple[bytes, list[tuple[int, int, list[bytes], list[bytes], str]]]:
    """HEAD's blob of ``path`` and the zero-context hunks turning it into ``data`` after clean filters.

    Each hunk is (old start, old length, removed lines, added lines, header).
    """
    if tree_entry_mode(repo, commit, path) is None:
        raise CommitError(f"{path} 不在 {commit} 里；新文件用 --file")
    old_blob = git_text(repo, "rev-parse", "--verify", f"{commit}:{path}")
    new_blob = git_text(repo, "hash-object", "-w", f"--path={path}", "--stdin", data=data)
    hunks = [
        (start, length, removed, added, header)
        for start, length, _, _, removed, added, header in blob_hunks(repo, old_blob, new_blob)
    ]
    return git(repo, "cat-file", "blob", old_blob).stdout, hunks


def gap_span(start: int, length: int) -> tuple[int, int]:
    """The first and last line gaps a hunk side touches, gap g lying after line g."""
    return (start - 1, start + length - 1) if length else (start, start)


def holds_change(repo: Path, current: str, old: str, new: str) -> bool:
    """Whether blob ``current`` keeps the change from blob ``old`` to blob ``new`` beside other edits.

    It does when the edits turning ``new`` into ``current`` delete none of the lines the change added and put none
    of the lines it removed back where it removed them.  Binary content never counts as holding it.
    """
    change, edits = blob_hunks(repo, old, new), blob_hunks(repo, new, current)
    if not change or not edits:
        return False
    for _, _, start, length, removed, _, _ in change:
        first, last = gap_span(start, length)
        for edit_start, edit_length, _, _, _, inserted, _ in edits:
            if length and edit_length and edit_start < start + length and start < edit_start + edit_length:
                return False
            edit_first, edit_last = gap_span(edit_start, edit_length)
            if set(removed) & set(inserted) and edit_first <= last and first <= edit_last:
                return False
    return True


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
    if git(repo, "diff", "--cached", "--quiet", head, "--", path, allowed=(0, 1)).returncode:
        rows.append(f"注意：现在提交这个路径会被拒绝。{staged_refusal(repo, [path])}")
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
            for batch in path_batches(paths):
                git(repo, "reset", "-q", "--", *batch)
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


def sync_work_tree(repo: Path, head: str, paths: list[str]) -> tuple[list[str], list[str], list[str]]:
    """Bring each work-tree copy of ``paths`` that still matches ``head``'s parent to ``head``'s version.

    Returns the paths brought over, the paths whose copy holds other edits beside ``head``'s change, and the paths
    left alone because their copy holds other edits and may lack that change.
    """
    synced: list[str] = []
    held: list[str] = []
    left: list[str] = []
    parent_entries, head_entries = tree_entries(repo, f"{head}^", paths), tree_entries(repo, head, paths)
    copies = copy_blobs(repo, paths)
    for path in paths:
        old = blob_entry(parent_entries, f"{head}^", path)
        new = blob_entry(head_entries, head, path)
        old_blob, new_blob = (old[1] if old else None), (new[1] if new else None)
        current = copies[path]
        if current == old_blob != new_blob:
            # This copy is about to be replaced or removed.  Look at it again right before, as when each path was
            # hashed in turn, so an edit another session made since the batched hash above still keeps it.
            current = copy_blobs(repo, [path])[path]
        if current == "":
            left.append(path)
            continue
        if current == new_blob:
            continue
        if current != old_blob:
            base = old_blob or git_text(repo, "hash-object", "-w", "--stdin", data=b"")
            (held if current and new_blob and holds_change(repo, current, base, new_blob) else left).append(path)
        elif new_blob is None:
            (repo / path).unlink()
            synced.append(path)
        else:
            git(repo, "checkout-index", "-f", "--", path)
            synced.append(path)
    return synced, held, left


def _keyed_by_id(items: list[object]) -> bool:
    ids = [item.get("id") for item in items if isinstance(item, dict)]
    return len(ids) == len(items) and all(isinstance(value, str) for value in ids) and len(set(ids)) == len(ids)


def merge_ledger_value(base: object, theirs: object, ours: object, path: str) -> object:
    """Apply the transaction's change from ``base`` to ``theirs`` onto ``ours``; refuse what both changed."""
    if theirs == base:
        return ours
    if ours == base or ours == theirs:
        return theirs
    if isinstance(base, dict) and isinstance(theirs, dict) and isinstance(ours, dict):
        merged = {}
        for key in [*ours, *(key for key in theirs if key not in ours)]:
            value = merge_ledger_value(
                base.get(key, _MISSING), theirs.get(key, _MISSING), ours.get(key, _MISSING), f"{path}.{key}"
            )
            if value is not _MISSING:
                merged[key] = value
        return merged
    if path.rsplit(".", 1)[-1] in LEDGER_TIMESTAMP_KEYS and isinstance(theirs, str) and isinstance(ours, str):
        return max(ours, theirs)
    if isinstance(base, list) and isinstance(theirs, list) and isinstance(ours, list):
        if _keyed_by_id(base) and _keyed_by_id(theirs) and _keyed_by_id(ours):
            before = {item["id"]: item for item in base}
            after = {item["id"]: item for item in theirs}
            present = {item["id"] for item in ours}
            pairs = [(item["id"], item) for item in ours]
            pairs += [(item["id"], _MISSING) for item in theirs if item["id"] not in present]
            items = (
                merge_ledger_value(before.get(key, _MISSING), after.get(key, _MISSING), item, f"{path}[id={key}]")
                for key, item in pairs
            )
            return [item for item in items if item is not _MISSING]
        if theirs[: len(base)] == base:
            return [*ours, *(item for item in theirs[len(base):] if item not in ours)]
    raise CommitError(
        f"账本 {path} 在这次事务里和 HEAD 之后都改了，不能自动合并；手工合并后用 --file-from 提交"
    )


def merge_ledger(base: dict[str, object], theirs: dict[str, object], ours: dict[str, object]) -> dict[str, object]:
    merged = merge_ledger_value(base, theirs, ours, "$")
    if isinstance(merged.get("updated_at"), str) and isinstance(theirs.get("updated_at"), str):
        # The commit carries this transaction's change, so the ledger is at least as new as the transaction left it.
        merged["updated_at"] = max(merged["updated_at"], theirs["updated_at"])
    return merged


def _load_json(path: Path, label: str) -> object:
    try:
        return json.loads(path.read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CommitError(f"读不到{label}：{path}（{exc}）") from exc


def _tree_files(root: Path, *, skip_bytecode: bool) -> tuple[dict[str, str], list[str]]:
    """Every file's SHA-256 and every directory under ``root``, as the wrapper's tree seal counts them."""
    files: dict[str, str] = {}
    directories: list[str] = []
    for current, names, filenames in os.walk(root):
        current_path = Path(current)
        if skip_bytecode:
            names[:] = [name for name in names if name.casefold() != "__pycache__"]
        directories += [(current_path / name).relative_to(root).as_posix() for name in names]
        for filename in filenames:
            if not (skip_bytecode and filename.casefold().endswith(".pyc")):
                path = current_path / filename
                files[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return files, directories


def _seal(files: dict[str, str], directories: list[str]) -> dict[str, object]:
    return {
        "directory_count": len(directories),
        "file_count": len(files),
        "tree_sha256": tree_manifest_sha256(files, directories),
    }


def transaction_changes(repo: Path, expected: str, evidence: Path) -> tuple[list[tuple[str, Path | bytes, str]], list[str]]:
    """The files and deletions of one succeeded guarded install transaction, with its ledger change merged onto ``expected``."""
    manifest = _load_json(evidence / "manifest.json", "事务 manifest")
    records = manifest.get("directory_records") if isinstance(manifest, dict) else None
    if manifest.get("status") != "succeeded" or not isinstance(records, list) or not records:
        raise CommitError("--transaction 只提交 status=succeeded、带 directory_records 的安装/更新事务")
    if manifest.get("merge_retirement"):
        raise CommitError("--transaction 不处理 merge retirement 事务")
    if os.path.normcase(Path(str(manifest.get("active_root"))).resolve()) != os.path.normcase(repo):
        raise CommitError(f"事务的 active root 是 {manifest.get('active_root')}，不是 {repo}")
    files: list[tuple[str, Path | bytes, str]] = []
    deletes: list[str] = []
    for record in records:
        if not record.get("activated"):
            raise CommitError(f"事务没有激活 {record.get('name')}")
        active = Path(record["active"])
        relative = active.resolve().relative_to(repo).as_posix()
        listing = git(repo, "ls-tree", "-r", "-z", expected, "--", relative).stdout.split(b"\0")
        head = {
            name.decode("utf-8").removeprefix(relative + "/"): meta.decode("ascii").split(" ")[2]
            for meta, name in (row.split(b"\t", 1) for row in listing if row)
        }
        before: dict[str, Path] = {}
        if record.get("had_existing"):
            backup = Path(record["backup"])
            if _seal(*_tree_files(backup, skip_bytecode=False)) != record.get("backup_seal"):
                raise CommitError(f"事务备份 {backup} 与它的 backup_seal 不一致")
            before = {name: backup / name for name in _tree_files(backup, skip_bytecode=True)[0]}
        if set(head) != set(before) or not all(
            is_blob_of(repo, f"{relative}/{name}", source.read_bytes(), head[name]) for name, source in before.items()
        ):
            raise CommitError(f"HEAD 里的 {relative} 不是这次事务之前的版本：先提交更早改过它的事务")
        live, live_directories = _tree_files(active, skip_bytecode=True)
        if _seal(live, live_directories) != record.get("activated_payload_seal"):
            raise CommitError(f"{relative} 在这次事务之后又被改过，工作树已不是事务写下的版本")
        names = sorted(live)
        paths = [f"{relative}/{name}" for name in names]
        for name, path, blob in zip(names, paths, work_tree_blobs(repo, paths, write=False), strict=True):
            if blob != head.get(name):
                files.append((path, repo / path, live[name]))
        deletes += [f"{relative}/{name}" for name in sorted(head) if name not in live]
    after = manifest.get("source_state_after") or {}
    after_bytes = Path(str(after.get("path"))).read_bytes()
    if hashlib.sha256(after_bytes).hexdigest() != after.get("sha256"):
        raise CommitError("source-state-after.json 与事务 manifest 记录的 SHA-256 不一致")
    ledger = Path(str(manifest.get("ledger"))).resolve().relative_to(repo).as_posix()
    merged = merge_ledger(
        _load_json(evidence / "backups" / "source-state-before.json", "事务前的账本"),
        json.loads(after_bytes.decode("utf-8")),
        json.loads(git(repo, "cat-file", "blob", f"{expected}:{ledger}").stdout.decode("utf-8")),
    )
    data = (json.dumps(merged, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    files.append((ledger, data, hashlib.sha256(data).hexdigest()))
    return files, deletes


def staged_refusal(repo: Path, paths: list[str]) -> str:
    """The guard's refusal: ``paths`` hold staged changes; name them, when each staged version was written, and how to find the owner."""
    rows = []
    for path in paths:
        entry = git(repo, "ls-files", "--debug", "--", path).stdout
        match = re.search(rb"^\s*mtime: (\d+):", entry, re.MULTILINE)
        if not entry:
            rows.append(f"{path}（暂存的是删除）")
        elif match and int(match[1]):
            written = datetime.fromtimestamp(int(match[1])).astimezone().isoformat(timespec="minutes")
            rows.append(f"{path}（暂存版本写于 {written}）")
        else:
            rows.append(f"{path}（暂存版本的写入时间不明）")
    return (
        f"共享 index 里这些路径已有暂存改动：{'、'.join(rows)}。先确认它们属于哪个会话："
        f"python {TRANSCRIPTS} find <路径> --since <日期> 找提到过它们的会话，再看那段时间 run-evidence 里的收尾记录；"
        "归属确认、那个会话的用户也授权提交后，核对 git diff --cached -- PATH，"
        "再用 --from-index PATH BLOB 提交暂存的版本（BLOB 见 git ls-files -s PATH）"
    )


def commit_exact(
    *,
    repo: Path,
    expected_head: str,
    message_file: Path | None,
    files: list[tuple[str, Path | bytes, str]],
    deletes: list[str],
    hunks: list[tuple[str, str, list[int]]] = (),
    executables: list[str] = (),
    replay: tuple[Path, str] | None = None,
    staged: list[tuple[str, str]] = (),
) -> str:
    """Commit ``files`` (path, content source, reviewed SHA-256), ``hunks`` (path, reviewed work-tree SHA-256, hunk numbers), ``staged`` (path, reviewed blob of its shared index entry) and ``deletes`` on ``expected_head``; ``executables`` names files to commit as 100755.

    ``replay`` (snapshot repository, commit) commits that commit's changes instead, with its message unless
    ``message_file`` is given.
    """

    paths = [path for path, _, _ in files] + [path for path, _, _ in hunks] + [path for path, _ in staged] + deletes
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
    confirmed = {path for path, _ in staged}
    unconfirmed = [path for path in paths if path not in confirmed]
    already_staged = sorted(
        path
        for batch in path_batches(unconfirmed)
        for path in path_list(
            git(repo, "diff", "--cached", "--name-only", "-z", "--no-renames", expected, "--", *batch).stdout
        )
    )
    if already_staged:
        raise CommitError(staged_refusal(repo, already_staged))
    for path, reviewed in staged:
        rows = git(repo, "ls-files", "-s", "-z", "--", path).stdout.split(b"\0")[:-1]
        if len(rows) != 1:
            raise CommitError(f"{path}：共享 index 里有 {len(rows)} 个条目，--from-index 要正好一个暂存的文件")
        mode, blob, stage = rows[0].split(b"\t", 1)[0].decode("ascii").split(" ")
        if stage != "0" or mode not in REGULAR_FILE_MODES:
            raise CommitError(f"{path}：共享 index 里的条目是 stage {stage}、mode {mode}，不是暂存的普通文件")
        if blob != reviewed.lower():
            raise CommitError(f"{path}：共享 index 里暂存的 blob 是 {blob}，不是评审过的 {reviewed}")
        entries.append((mode, blob, path))
    removed = [] if replay else deletes
    in_head = tree_entries(repo, expected, [path for path, _, _ in files] + removed)
    rows: list[tuple[str, Path | bytes, bytes]] = []
    modes: list[str] = []
    for path, source, reviewed in files:
        data = source if isinstance(source, bytes) else source.read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != reviewed.lower():
            raise CommitError(f"{path}：内容 sha256 是 {actual}，不是评审过的 {reviewed}")
        entry = blob_entry(in_head, expected, path)
        mode = entry[0] if entry else "100644"
        if mode not in REGULAR_FILE_MODES:
            raise CommitError(f"{path}：不支持 mode {mode}")
        rows.append((path, source, data))
        modes.append("100755" if path in executables else mode)
    blobs = file_blobs(repo, rows, expected)
    entries += [(mode, blob, path) for mode, blob, (path, _, _) in zip(modes, blobs, rows, strict=True)]
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
    for path in removed:
        if blob_entry(in_head, expected, path) is None:
            raise CommitError(f"{path} 不在 {expected} 里，无从删除")
        if os.path.lexists(repo / path):
            raise CommitError(f"{path} 仍在工作树里；--delete 只提交已经不在的文件")
    git_dir = Path(git_text(repo, "rev-parse", "--absolute-git-dir"))
    index = git_dir / f"index.commit-exact-files.{uuid.uuid4().hex}"
    try:
        git(repo, "read-tree", expected, index=index)
        # --index-info would take every entry in one process, but it implies --replace: it quietly turns a file into
        # a directory or back, where --cacheinfo refuses.  So --cacheinfo it stays, many to a process; each item's
        # flag adds 12 characters, well inside the margin path_batches leaves under the command-line cap.
        for batch in path_batches([f"{mode},{blob},{path}" for mode, blob, path in entries]):
            git(repo, "update-index", "--add", *(arg for item in batch for arg in ("--cacheinfo", item)), index=index)
        for batch in path_batches(deletes):
            git(repo, "update-index", "--force-remove", "--", *batch, index=index)
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
    parser.add_argument("--repo", type=Path, help="work tree root; defaults to the one holding the current directory")
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
        "--from-index",
        action="append",
        nargs=2,
        default=[],
        metavar=("PATH", "BLOB"),
        help="commit the entry another session staged for PATH in the shared index, once its owner is confirmed; "
        "its blob must be BLOB (git ls-files -s PATH prints it), and its mode is kept",
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
        "--transaction",
        type=Path,
        metavar="EVIDENCE",
        help="commit what the succeeded guarded install transaction in evidence directory EVIDENCE changed: its "
        "skill directories as the work tree holds them, and only its own ledger change merged onto HEAD's ledger",
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
        help="print PATH's work-tree SHA-256 and its numbered hunks against HEAD, warning when the shared "
        "index already stages PATH, then exit",
    )
    args = parser.parse_args(argv)
    if args.list_hunks:
        if (
            args.file or args.file_from or args.from_index or args.delete or args.hunks or args.executable
            or args.from_commit or args.transaction
        ):
            parser.error("--list-hunks 只能单独使用")
        return args
    if args.transaction:
        if args.file or args.file_from or args.from_index or args.delete or args.hunks or args.executable or args.from_commit:
            parser.error("--transaction 不和 --file、--file-from、--from-index、--hunks、--delete、--executable、--from-commit 同用")
        if not (args.expected_head and args.message_file):
            parser.error("提交需要 --expected-head 和 --message-file")
        return args
    if args.from_commit:
        if args.file or args.file_from or args.from_index or args.delete or args.hunks or args.executable:
            parser.error("--from-commit 不和 --file、--file-from、--from-index、--hunks、--delete、--executable 同用")
        if not args.expected_head:
            parser.error("提交需要 --expected-head")
        return args
    if not (args.expected_head and args.message_file):
        parser.error("提交需要 --expected-head 和 --message-file")
    if not (args.file or args.file_from or args.from_index or args.delete or args.hunks):
        parser.error("至少给一个 --file、--file-from、--from-index、--hunks 或 --delete")
    for values in args.hunks:
        if len(values) < 3 or not all(value.isdigit() for value in values[2:]):
            parser.error("--hunks 的格式是 PATH SHA256 INDEX [INDEX ...]")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        repo = (args.repo or Path(git_text(Path.cwd(), "rev-parse", "--show-toplevel"))).resolve()
    except CommitError as exc:
        print(f"commit_exact_files: {exc}", file=sys.stderr)
        return 1
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
        if args.transaction:
            expected = git_text(repo, "rev-parse", "--verify", f"{args.expected_head}^{{commit}}")
            files, deletes = transaction_changes(repo, expected, args.transaction.resolve())
        head = commit_exact(
            repo=repo,
            expected_head=args.expected_head,
            message_file=args.message_file,
            files=files,
            deletes=deletes,
            hunks=hunks,
            executables=[Path(path).as_posix() for path in args.executable],
            replay=replay,
            staged=[(Path(path).as_posix(), blob) for path, blob in args.from_index],
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
        synced, held, left = sync_work_tree(
            repo,
            head,
            committed if replay or args.transaction else [Path(path).as_posix() for path, _, _ in args.file_from],
        )
    except (CommitError, OSError) as exc:
        print(f"commit_exact_files: 提交 {head} 已生成，但同步工作树失败：{exc}", file=sys.stderr)
        return 3
    for path in synced:
        print(f"工作树已换成新提交的版本：{path}")
    for path in held:
        print(f"工作树里的 {path} 已含本次提交的改动，另带别的改动，没有动它，不用补")
    for path in left:
        print(
            f"工作树里的 {path} 带着别的改动，没有动它，也可能缺本次提交的改动：用 git diff {head[:12]} -- {path} 核对，"
            "缺的先补进去，否则按它现在的样子提交会回退本次提交"
        )
    status = "\n".join(
        line
        for batch in path_batches(committed)
        for line in git(repo, "status", "--porcelain=v1", "--", *batch).stdout.decode("utf-8").splitlines()
    )
    print("committed paths status:", status or "clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
