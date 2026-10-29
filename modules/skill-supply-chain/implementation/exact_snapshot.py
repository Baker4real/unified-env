#!/usr/bin/env python3
"""Make and refresh an exact snapshot of a shared work tree's repository.

Other sessions edit the shared work tree while a change is prepared, so the
change is built and tested in a snapshot instead: a clone of one commit that
shares the source's object store (``git clone --shared``), so it copies no
objects and every later source commit is readable in it without a fetch.  The
clone takes the source's effective line-ending, hook and identity settings and
checks the commit out with long paths on, so its work tree holds every tracked
file, ignored-but-tracked ones and executable modes included, as the source
would.

``create --repo SOURCE --dest DIR [--commit REV]`` clones REV (default HEAD) of
SOURCE into the new or empty DIR on branch ``snapshot``.  Commit there, then
replay each commit into SOURCE with ``commit_exact_files.py --from-commit DIR
COMMIT``, which carries its exact paths, modes and blobs.

``onto --dest DIR [--commit REV]`` rebases the snapshot's commits onto REV
(default HEAD) of the source after other sessions committed there, so the
replay applies to the current HEAD.  A conflict stops the rebase in DIR and the
helper exits 3: resolve the listed files, ``git add`` them, run ``git -c
core.editor=true rebase --continue`` in DIR, then rerun ``onto``.

Both print JSON naming the snapshot, its base commit in the source and the
snapshot commits to replay, oldest first.  The snapshot borrows the source's
objects, so keep it only while the change is prepared: once the source's
history is rewritten, a ``git gc`` there can drop objects the snapshot needs.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


BRANCH = "snapshot"
COPIED_KEYS = ("core.autocrlf", "core.eol", "core.hooksPath", "user.name", "user.email")


class SnapshotError(Exception):
    """A precondition failed; the message names it."""


class RebaseStopped(SnapshotError):
    """The rebase stopped on a conflict that has to be resolved in the snapshot."""


def git(repo: Path, *args: str, allowed: tuple[int, ...] = (0,)) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True)
    if result.returncode not in allowed:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise SnapshotError(f"git {' '.join(args)} 失败（exit {result.returncode}）：{detail}")
    return result


def git_text(repo: Path, *args: str) -> str:
    return git(repo, *args).stdout.decode("utf-8").strip()


def config_value(repo: Path, key: str) -> str | None:
    result = git(repo, "config", "--get", key, allowed=(0, 1))
    return result.stdout.decode("utf-8").strip() if result.returncode == 0 else None


def resolve(repo: Path, revision: str) -> str:
    return git_text(repo, "rev-parse", "--verify", f"{revision}^{{commit}}")


def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    return git(repo, "merge-base", "--is-ancestor", ancestor, descendant, allowed=(0, 1)).returncode == 0


def rebase_in_progress(dest: Path) -> bool:
    return any(
        Path(git_text(dest, "rev-parse", "--path-format=absolute", "--git-path", name)).exists()
        for name in ("rebase-merge", "rebase-apply")
    )


def report(dest: Path) -> dict[str, object]:
    base = config_value(dest, "snapshot.base")
    return {
        "snapshot": str(dest),
        "source": config_value(dest, "snapshot.source"),
        "base": base,
        "head": resolve(dest, BRANCH),
        "commits": git_text(dest, "rev-list", "--reverse", f"{base}..{BRANCH}").split(),
    }


def create(source: Path, dest: Path, revision: str) -> dict[str, object]:
    if dest.exists() and any(dest.iterdir()):
        raise SnapshotError(f"{dest} 已存在且不是空目录")
    source = Path(git_text(source, "rev-parse", "--show-toplevel"))
    commit = resolve(source, revision)
    options = ["-c", "core.longpaths=true"]
    for key in COPIED_KEYS:
        value = config_value(source, key)
        if value is not None:
            options += ["-c", f"{key}={value}"]
    git(source, "clone", "-q", "--shared", "--no-checkout", *options, str(source), str(dest))
    git(dest, "switch", "-q", "-c", BRANCH, commit)
    git(dest, "config", "snapshot.source", str(source))
    git(dest, "config", "snapshot.base", commit)
    dirty = git(dest, "status", "--porcelain=v1").stdout.decode("utf-8").splitlines()
    if dirty:
        raise SnapshotError(f"快照工作树检出后与 {commit} 不一致（前 10 项）：{dirty[:10]}")
    return report(dest)


def onto(dest: Path, revision: str) -> dict[str, object]:
    if rebase_in_progress(dest):
        raise SnapshotError(
            f"{dest} 里的 rebase 还没完成：解决冲突、git add 后运行 git -c core.editor=true rebase --continue，再重跑 onto"
        )
    source, base = config_value(dest, "snapshot.source"), config_value(dest, "snapshot.base")
    if not (source and base):
        raise SnapshotError(f"{dest} 缺 snapshot.source 或 snapshot.base，不是 exact_snapshot.py create 建的快照")
    target = resolve(Path(source), revision)
    if not is_ancestor(dest, base, target):
        raise SnapshotError(f"快照基底 {base} 不是 {target} 的祖先（源仓库的历史改写过？），不 rebase")
    if not is_ancestor(dest, target, BRANCH):
        result = git(dest, "rebase", "-q", target, BRANCH, allowed=(0, 1))
        if result.returncode:
            if not rebase_in_progress(dest):
                detail = result.stderr.decode("utf-8", errors="replace").strip()
                raise SnapshotError(f"rebase 到 {target} 失败：{detail}")
            conflicts = git_text(dest, "diff", "--name-only", "--diff-filter=U").splitlines()
            raise RebaseStopped(
                f"rebase 到 {target} 在冲突处停下：{conflicts}。在 {dest} 里解决这些文件、git add 后运行 "
                "git -c core.editor=true rebase --continue，再重跑 onto"
            )
    git(dest, "config", "snapshot.base", target)
    return report(dest)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    create_parser = commands.add_parser("create", help="clone a commit of a repository into a new snapshot")
    create_parser.add_argument("--repo", required=True, type=Path, help="source work tree")
    create_parser.add_argument("--dest", required=True, type=Path, help="new or empty snapshot directory")
    create_parser.add_argument("--commit", default="HEAD", help="source commit to snapshot (default HEAD)")
    onto_parser = commands.add_parser("onto", help="rebase the snapshot's commits onto a newer source commit")
    onto_parser.add_argument("--dest", required=True, type=Path, help="snapshot directory")
    onto_parser.add_argument("--commit", default="HEAD", help="source commit to rebase onto (default HEAD)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "create":
            result = create(args.repo.resolve(), args.dest.resolve(), args.commit)
        else:
            result = onto(args.dest.resolve(), args.commit)
    except RebaseStopped as exc:
        print(f"exact_snapshot: {exc}", file=sys.stderr)
        return 3
    except (SnapshotError, OSError) as exc:
        print(f"exact_snapshot: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
