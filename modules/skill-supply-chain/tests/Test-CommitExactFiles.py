"""Behaviour tests for commit_exact_files in throwaway repositories."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[3]
IMPLEMENTATION_ROOT = PROJECT_ROOT / "modules" / "skill-supply-chain" / "implementation"
HELPER_PATH = IMPLEMENTATION_ROOT / "commit_exact_files.py"
SPEC = importlib.util.spec_from_file_location("commit_exact_files", HELPER_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 helper：{HELPER_PATH}")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)
if str(IMPLEMENTATION_ROOT) not in sys.path:
    sys.path.insert(0, str(IMPLEMENTATION_ROOT))
from install_skill_guarded_tree import tree_content_seal  # noqa: E402  (the wrapper's own seal)
TEMP_PARENT = Path(r"D:\Codex\tmp")
LEDGER = ".downloaded-skills-source-state.json"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ledger_bytes(data: dict) -> bytes:
    return (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


class CommitExactFilesTests(unittest.TestCase):
    def setUp(self) -> None:
        TEMP_PARENT.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="commit-exact-files-test-", dir=TEMP_PARENT)
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.repo = self.temp / "repo"
        self.hooks = self.temp / "hooks"
        self.hooks.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        for key, value in (
            ("user.name", "Test"),
            ("user.email", "test@example.invalid"),
            ("commit.gpgsign", "false"),
            ("core.autocrlf", "false"),
            ("core.hooksPath", self.hooks.as_posix()),
        ):
            self.git("config", key, value)
        for name in ("a.txt", "b.txt", "c.txt"):
            self.write(name, f"{name[0]}1\n".encode())
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.base = self.head()
        self.message = self.temp / "message.txt"
        self.message.write_bytes(b"exact commit\n")

    def git(self, *args: str) -> str:
        result = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, check=True)
        return result.stdout.decode("utf-8")

    def head(self) -> str:
        return self.git("rev-parse", "HEAD").strip()

    def show(self, spec: str) -> bytes:
        return subprocess.run(["git", "-C", str(self.repo), "show", spec], capture_output=True, check=True).stdout

    def status(self) -> list[str]:
        return sorted(line for line in self.git("status", "--porcelain=v1").split("\n") if line)

    def write(self, name: str, data: bytes) -> None:
        (self.repo / name).write_bytes(data)

    def run_helper(self, *args: str, message: bool = True) -> tuple[int, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = HELPER.main(
                [
                    "--repo",
                    str(self.repo),
                    "--expected-head",
                    self.base,
                    *(["--message-file", str(self.message)] if message else []),
                    *args,
                ]
            )
        self.stdout = stdout.getvalue()
        return code, stderr.getvalue()

    def test_commits_only_named_path_and_keeps_other_sessions_work(self) -> None:
        self.write("a.txt", b"a2\n")
        self.write("b.txt", b"b2\n")
        self.write("c.txt", b"c2\n")
        self.git("add", "c.txt")
        code, error = self.run_helper("--file", "a.txt", sha256(b"a2\n"))
        self.assertEqual(code, 0, error)
        self.assertEqual(self.git("rev-parse", "HEAD^").strip(), self.base)
        self.assertEqual(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").split(), ["a.txt"])
        self.assertEqual(self.show("HEAD:a.txt"), b"a2\n")
        self.assertEqual(self.status(), [" M b.txt", "M  c.txt"])

    def test_commits_more_paths_than_one_windows_command_line_holds(self) -> None:
        # Windows caps a whole command line at 32,767 characters, and one skill update can name thousands of paths
        # (design-taste-frontend v2.5.1 named 1,633, about 91K characters). 220 paths of 180 characters overrun a
        # single command line by a fifth, so this commit only goes through when git gets its path lists in batches.
        folder = "d" * 50
        (self.repo / folder).mkdir()
        args: list[str] = []
        for index in range(220):
            name = f"{folder}/{index:04d}-{'f' * 120}.txt"
            data = f"{index}\n".encode()
            self.write(name, data)
            args += ["--file", name, sha256(data)]
        code, error = self.run_helper(*args)
        self.assertEqual(code, 0, error)
        self.assertEqual(len(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").split()), 220)
        self.assertEqual(self.status(), [])
        self.assertIn("committed paths status: clean", self.stdout)

    def test_rejects_bytes_that_differ_from_review(self) -> None:
        self.write("a.txt", b"a2\n")
        code, error = self.run_helper("--file", "a.txt", sha256(b"reviewed\n"))
        self.assertEqual(code, 1)
        self.assertIn("不是评审过的", error)
        self.assertEqual(self.head(), self.base)
        self.assertEqual(self.status(), [" M a.txt"])

    def test_rejects_when_head_moved(self) -> None:
        self.write("b.txt", b"b2\n")
        self.git("commit", "-q", "-am", "other session")
        moved = self.head()
        self.write("a.txt", b"a2\n")
        code, error = self.run_helper("--file", "a.txt", sha256(b"a2\n"))
        self.assertEqual(code, 1)
        self.assertIn("HEAD 已不是", error)
        self.assertEqual(self.head(), moved)

    def test_refuses_path_staged_by_another_session(self) -> None:
        self.write("a.txt", b"a2\n")
        self.git("add", "a.txt")
        self.write("a.txt", b"a3\n")
        code, error = self.run_helper("--file", "a.txt", sha256(b"a3\n"))
        self.assertEqual(code, 1)
        self.assertIn("已有暂存改动：a.txt（暂存版本写于 ", error)
        self.assertIn("--from-index PATH BLOB", error)
        self.assertEqual(self.head(), self.base)
        self.assertEqual(self.status(), ["MM a.txt"])

    def test_from_index_commits_the_reviewed_staged_entry_only(self) -> None:
        self.write("a.txt", b"a2\n")
        self.write("b.txt", b"b2\n")
        self.git("add", "a.txt", "b.txt")
        self.write("a.txt", b"a3\n")
        staged = self.git("rev-parse", ":a.txt").strip()
        code, error = self.run_helper("--from-index", "a.txt", "0" * 40)
        self.assertEqual(code, 1)
        self.assertIn(f"暂存的 blob 是 {staged}，不是评审过的", error)
        code, error = self.run_helper("--from-index", "a.txt", staged)
        self.assertEqual(code, 0, error)
        self.assertEqual(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").split(), ["a.txt"])
        self.assertEqual(self.show("HEAD:a.txt"), b"a2\n")
        self.assertEqual(self.status(), [" M a.txt", "M  b.txt"])

    def test_refuses_path_without_changes(self) -> None:
        code, error = self.run_helper("--file", "a.txt", sha256(b"a1\n"))
        self.assertEqual(code, 1)
        self.assertIn("内容与 HEAD 相同", error)
        self.assertEqual(self.head(), self.base)

    def test_file_from_commits_snapshot_while_live_file_keeps_later_edit(self) -> None:
        snapshot = self.temp / "source-state-after.json"
        snapshot.write_bytes(b"a-transaction\n")
        self.write("a.txt", b"a-transaction\nlater edit\n")
        code, error = self.run_helper("--file-from", "a.txt", str(snapshot), sha256(b"a-transaction\n"))
        self.assertEqual(code, 0, error)
        self.assertEqual(self.show("HEAD:a.txt"), b"a-transaction\n")
        self.assertEqual(self.status(), [" M a.txt"])
        self.assertIn("工作树里的 a.txt 已含本次提交的改动", self.stdout)

    def test_file_from_brings_untouched_work_tree_copies_to_the_commit(self) -> None:
        prepared = self.temp / "prepared"
        prepared.mkdir()
        (prepared / "a.txt").write_bytes(b"a2\n")
        (prepared / "new.txt").write_bytes(b"n1\n")
        code, error = self.run_helper(
            "--file-from", "a.txt", str(prepared / "a.txt"), sha256(b"a2\n"),
            "--file-from", "new.txt", str(prepared / "new.txt"), sha256(b"n1\n"),
        )
        self.assertEqual(code, 0, error)
        self.assertEqual((self.repo / "a.txt").read_bytes(), b"a2\n")
        self.assertEqual((self.repo / "new.txt").read_bytes(), b"n1\n")
        self.assertEqual(self.status(), [])
        self.assertIn("工作树已换成新提交的版本：a.txt", self.stdout)

    def clone_snapshot(self) -> Path:
        self.snapshot = self.temp / "snapshot"
        config = {
            "core.autocrlf": "false",
            "core.hooksPath": self.hooks.as_posix(),
            "user.name": "Test",
            "user.email": "test@example.invalid",
            "commit.gpgsign": "false",
        }
        options = [arg for key, value in config.items() for arg in ("-c", f"{key}={value}")]
        subprocess.run(["git", "clone", "-q", "--shared", *options, str(self.repo), str(self.snapshot)], check=True)
        return self.snapshot

    def snapshot_git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.snapshot), *args], capture_output=True, check=True).stdout.decode("utf-8")

    def snapshot_commit(
        self,
        changes: dict[str, bytes | None],
        *,
        message: tuple[str, ...] = ("snapshot change",),
        executable: tuple[str, ...] = (),
    ) -> str:
        for name, data in changes.items():
            target = self.snapshot / name
            if data is None:
                target.unlink()
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        self.snapshot_git("add", "-A")
        for name in executable:
            self.snapshot_git("update-index", "--chmod=+x", "--", name)
        self.snapshot_git("commit", "-q", *[arg for paragraph in message for arg in ("-m", paragraph)])
        return self.snapshot_git("rev-parse", "HEAD").strip()

    def test_from_commit_replays_snapshot_commit_and_its_message(self) -> None:
        snapshot = self.clone_snapshot()
        replayed = self.snapshot_commit(
            {"a.txt": b"a2\n", "b.txt": None, "dir/new.txt": b"n1\n", "tool.sh": b"#!/bin/sh\n"},
            message=("snapshot change", "body line"),
            executable=("tool.sh",),
        )
        self.write("a.txt", b"a1\nother session\n")
        self.write("c.txt", b"c2\n")
        code, error = self.run_helper("--from-commit", str(snapshot), replayed, message=False)
        self.assertEqual(code, 0, error)
        self.assertEqual(self.git("rev-parse", "HEAD^").strip(), self.base)
        self.assertEqual(self.git("rev-parse", "HEAD^{tree}"), self.snapshot_git("rev-parse", f"{replayed}^{{tree}}"))
        self.assertEqual(self.git("log", "-1", "--format=%B").strip(), "snapshot change\n\nbody line")
        self.assertEqual(self.git("ls-tree", "HEAD", "tool.sh").split()[0], "100755")
        self.assertFalse((self.repo / "b.txt").exists())
        self.assertEqual((self.repo / "dir" / "new.txt").read_bytes(), b"n1\n")
        self.assertEqual(self.status(), [" M a.txt", " M c.txt"])
        self.assertIn("工作树里的 a.txt 带着别的改动", self.stdout)

    def test_from_commit_tells_copies_holding_the_change_from_copies_lacking_it(self) -> None:
        self.commit_base("a.txt", b"x\ny\nz\n")
        snapshot = self.clone_snapshot()
        replayed = self.snapshot_commit({"a.txt": b"x\nz\n", "b.txt": b"b2\n", "new.txt": b"n1\n"})
        self.write("a.txt", b"x\ny\nz\nmore\n")
        self.write("b.txt", b"b2\nmore\n")
        self.write("new.txt", b"n1\nn2\n")
        code, error = self.run_helper("--from-commit", str(snapshot), replayed)
        self.assertEqual(code, 0, error)
        self.assertIn("工作树里的 b.txt 已含本次提交的改动", self.stdout)
        self.assertIn("工作树里的 new.txt 已含本次提交的改动", self.stdout)
        self.assertIn("工作树里的 a.txt 带着别的改动，没有动它，也可能缺本次提交的改动", self.stdout)
        self.assertEqual((self.repo / "a.txt").read_bytes(), b"x\ny\nz\nmore\n")
        self.assertEqual(self.status(), [" M a.txt", " M b.txt", " M new.txt"])

    def test_from_commit_refuses_a_path_committed_since_the_snapshot(self) -> None:
        snapshot = self.clone_snapshot()
        replayed = self.snapshot_commit({"a.txt": b"a-snapshot\n", "b.txt": b"b-snapshot\n"})
        self.commit_base("a.txt", b"a-other\n")
        code, error = self.run_helper("--from-commit", str(snapshot), replayed)
        self.assertEqual(code, 1)
        self.assertIn("重放会覆盖之后的提交：['a.txt']", error)
        self.assertEqual(self.head(), self.base)
        self.assertEqual(self.status(), [])

    def test_from_commit_replays_disjoint_paths_onto_a_moved_head(self) -> None:
        snapshot = self.clone_snapshot()
        replayed = self.snapshot_commit({"a.txt": b"a2\n"})
        self.commit_base("b.txt", b"b2\n")
        code, error = self.run_helper("--from-commit", str(snapshot), replayed)
        self.assertEqual(code, 0, error)
        self.assertEqual(self.git("rev-parse", "HEAD^").strip(), self.base)
        self.assertEqual((self.show("HEAD:a.txt"), self.show("HEAD:b.txt")), (b"a2\n", b"b2\n"))
        self.assertEqual(self.git("log", "-1", "--format=%B").strip(), "exact commit")
        self.assertEqual(self.status(), [])

    def test_executable_commits_only_named_new_file_as_100755(self) -> None:
        self.write("hook", b"#!/bin/sh\n")
        self.write("notes.txt", b"n1\n")
        self.write("a.txt", b"a2\n")
        code, error = self.run_helper(
            "--file", "hook", sha256(b"#!/bin/sh\n"),
            "--file", "notes.txt", sha256(b"n1\n"),
            "--file", "a.txt", sha256(b"a2\n"),
            "--executable", "hook",
        )
        self.assertEqual(code, 0, error)
        modes = {line.split()[3]: line.split()[0] for line in self.git("ls-tree", "HEAD").splitlines()}
        self.assertEqual((modes["hook"], modes["notes.txt"], modes["a.txt"]), ("100755", "100644", "100644"))

    def test_executable_must_name_a_committed_file(self) -> None:
        self.write("a.txt", b"a2\n")
        code, error = self.run_helper("--file", "a.txt", sha256(b"a2\n"), "--executable", "b.txt")
        self.assertEqual(code, 1)
        self.assertIn("--executable 只能指", error)
        self.assertEqual(self.head(), self.base)

    def test_delete_commits_only_removal_of_absent_file(self) -> None:
        code, error = self.run_helper("--delete", "b.txt")
        self.assertEqual(code, 1)
        self.assertIn("仍在工作树里", error)
        (self.repo / "b.txt").unlink()
        code, error = self.run_helper("--delete", "b.txt")
        self.assertEqual(code, 0, error)
        self.assertEqual(self.git("ls-tree", "--name-only", "HEAD").split(), ["a.txt", "c.txt"])
        self.assertEqual(self.status(), [])

    def test_failing_pre_commit_hook_blocks_and_leaves_shared_index(self) -> None:
        hook = self.hooks / "pre-commit"
        hook.write_bytes(b"#!/bin/sh\necho blocked-by-hook >&2\nexit 1\n")
        os.chmod(hook, 0o755)
        self.write("a.txt", b"a2\n")
        code, error = self.run_helper("--file", "a.txt", sha256(b"a2\n"))
        self.assertEqual(code, 1)
        self.assertIn("blocked-by-hook", error)
        self.assertEqual(self.head(), self.base)
        self.assertEqual(self.status(), [" M a.txt"])
        self.assertEqual(list((self.repo / ".git").glob("index.commit-exact-files.*")), [])

    def test_held_index_lock_reports_the_created_commit_and_how_to_refresh(self) -> None:
        self.write("a.txt", b"a2\n")
        lock = self.repo / ".git" / "index.lock"
        lock.write_bytes(b"")
        with mock.patch.object(HELPER, "INDEX_LOCK_WAIT_SECONDS", 0.5):
            code, error = self.run_helper("--file", "a.txt", sha256(b"a2\n"))
        created = self.head()
        self.assertEqual(code, 3, error)
        self.assertEqual(self.git("rev-parse", "HEAD^").strip(), self.base)
        self.assertEqual(self.show("HEAD:a.txt"), b"a2\n")
        self.assertIn(created, error)
        self.assertIn("reset -q -- a.txt", error)
        lock.unlink()
        self.assertEqual(self.status(), ["MM a.txt"])
        self.git("reset", "-q", "--", "a.txt")
        self.assertEqual(self.status(), [])

    def test_waits_out_an_index_lock_taken_right_after_the_commit(self) -> None:
        hook = self.hooks / "post-commit"
        hook.write_bytes(b"#!/bin/sh\n: > .git/index.lock\n")
        os.chmod(hook, 0o755)
        lock = self.repo / ".git" / "index.lock"
        released = threading.Event()

        def release_once_taken() -> None:
            deadline = time.monotonic() + 30
            while not lock.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            time.sleep(0.5)
            lock.unlink(missing_ok=True)
            released.set()

        threading.Thread(target=release_once_taken, daemon=True).start()
        self.write("a.txt", b"a2\n")
        code, error = self.run_helper("--file", "a.txt", sha256(b"a2\n"))
        self.assertTrue(released.wait(5), "post-commit hook never took the index lock")
        self.assertEqual(code, 0, error)
        self.assertEqual(self.show("HEAD:a.txt"), b"a2\n")
        self.assertEqual(self.status(), [])

    def test_applies_clean_filters_like_git_add(self) -> None:
        self.git("config", "core.autocrlf", "true")
        self.write("a.txt", b"a2\r\n")
        code, error = self.run_helper("--file", "a.txt", sha256(b"a2\r\n"))
        self.assertEqual(code, 0, error)
        self.assertEqual(self.show("HEAD:a.txt"), b"a2\n")
        self.assertEqual(self.status(), [])

    def list_hunks(self, path: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = HELPER.main(["--repo", str(self.repo), "--list-hunks", path])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_repo_defaults_to_the_work_tree_holding_the_current_directory(self) -> None:
        edited = b"a2\n"
        self.write("a.txt", edited)
        (self.repo / "sub").mkdir()
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.chdir(self.repo / "sub"), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = HELPER.main(["--list-hunks", "a.txt"])
        self.assertEqual(code, 0, stderr.getvalue())
        self.assertIn(f"a.txt sha256={sha256(edited)} hunks=1", stdout.getvalue())

    def test_without_repo_outside_a_work_tree_reports_the_git_error(self) -> None:
        stderr = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": str(TEMP_PARENT)}),
            contextlib.chdir(self.temp),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(stderr),
        ):
            code = HELPER.main(["--list-hunks", "a.txt"])
        self.assertEqual(code, 1)
        self.assertIn("rev-parse --show-toplevel", stderr.getvalue())

    def commit_base(self, name: str, data: bytes) -> None:
        self.write(name, data)
        self.git("commit", "-q", "-am", f"base {name}")
        self.base = self.head()

    def test_hunks_commit_selected_hunks_at_their_head_lines(self) -> None:
        lines = [f"line{number}\n".encode() for number in range(1, 21)]
        self.commit_base("a.txt", b"".join(lines))
        mine = lines[:10] + [b"mine after line10\n"] + lines[10:14] + [b"line15 mine\n"] + lines[15:]
        edited = b"".join(mine[:2] + [b"other session\n"] * 5 + mine[2:])
        self.write("a.txt", edited)
        code, listing, error = self.list_hunks("a.txt")
        self.assertEqual(code, 0, error)
        self.assertIn(f"sha256={sha256(edited)} hunks=3", listing)
        code, error = self.run_helper("--hunks", "a.txt", sha256(edited), "1", "2")
        self.assertEqual(code, 0, error)
        self.assertEqual(self.show("HEAD:a.txt"), b"".join(mine))
        self.assertEqual(self.status(), [" M a.txt"])
        left = [
            line
            for line in self.git("diff", "-U0", "HEAD", "--", "a.txt").split("\n")
            if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))
        ]
        self.assertEqual(left, ["+other session"] * 5)

    def test_list_hunks_warns_when_the_shared_index_stages_the_path(self) -> None:
        self.write("a.txt", b"a1\nmine\n")
        code, listing, error = self.list_hunks("a.txt")
        self.assertEqual(code, 0, error)
        self.assertNotIn("已有暂存改动", listing)
        self.git("add", "a.txt")
        self.write("a.txt", b"a1\nmine\nmore\n")
        code, listing, error = self.list_hunks("a.txt")
        self.assertEqual(code, 0, error)
        self.assertIn("hunks=1", listing)
        self.assertIn("现在提交这个路径会被拒绝。共享 index 里这些路径已有暂存改动：a.txt（暂存版本写于 ", listing)
        code, error = self.run_helper("--hunks", "a.txt", sha256(b"a1\nmine\nmore\n"), "0")
        self.assertEqual(code, 1)
        self.assertIn("已有暂存改动", error)
        self.assertEqual(self.head(), self.base)

    def test_hunks_refuse_changed_work_tree_and_unknown_hunk(self) -> None:
        self.write("a.txt", b"a1\nmine\n")
        code, error = self.run_helper("--hunks", "a.txt", sha256(b"a1\nreviewed\n"), "0")
        self.assertEqual(code, 1)
        self.assertIn("重新 --list-hunks", error)
        code, error = self.run_helper("--hunks", "a.txt", sha256(b"a1\nmine\n"), "1")
        self.assertEqual(code, 1)
        self.assertIn("没有第 1 个改动块", error)
        self.assertEqual(self.head(), self.base)
        self.assertEqual(self.status(), [" M a.txt"])

    def test_hunks_keep_a_missing_final_newline(self) -> None:
        self.commit_base("b.txt", b"x\ny")
        edited = b"w\nx\ny\nz"
        self.write("b.txt", edited)
        code, error = self.run_helper("--hunks", "b.txt", sha256(edited), "1")
        self.assertEqual(code, 0, error)
        self.assertEqual(self.show("HEAD:b.txt"), b"x\ny\nz")
        self.assertEqual(self.status(), [" M b.txt"])

    def guarded_transaction(self, *, other_status: str | None = None, our_status: str | None = None) -> Path:
        """A succeeded guarded update of skill-x, run after another session's still uncommitted transaction."""
        committed = {
            "updated_at": "2026-11-05",
            "notes": [],
            "sources": [
                {
                    "id": "group-a",
                    "status": "tracked",
                    "skills": ["skill-x", "skill-y"],
                    "local_changes": [{"skill": "skill-x", "date": "2026-11-01", "summary": "first"}],
                    "last_guarded_install": "2026-11-01T00:00:00Z",
                },
                {"id": "group-b", "skills": ["skill-z"], "local_changes": [], "last_guarded_install": "2026-11-01T00:00:00Z"},
            ],
            "unresolved": [],
            "deleted": [],
        }
        skill = self.repo / "skill-x"
        skill.mkdir()
        (skill / "SKILL.md").write_bytes(b"---\nname: skill-x\n---\nv1\n")
        (skill / "SOURCE.md").write_bytes(b"# Source\n")
        self.write(LEDGER, ledger_bytes(committed))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base skill-x")
        self.base = self.head()

        before = copy.deepcopy(committed)
        group_a, group_b = before["sources"]
        group_a["local_changes"].append({"skill": "skill-y", "date": "2026-11-06", "summary": "other session"})
        group_a["last_guarded_install"] = "2026-11-06T00:00:00Z"
        group_b["last_guarded_install"] = "2026-11-06T00:00:00Z"
        before["updated_at"] = "2026-11-06"
        if other_status:
            group_a["status"] = other_status
        after = copy.deepcopy(before)
        group_a = after["sources"][0]
        group_a["local_changes"].append({"skill": "skill-x", "date": "2026-11-07", "summary": "this transaction"})
        group_a["last_guarded_install"] = "2026-11-07T00:00:00Z"
        group_a["skills"] = ["skill-y", "skill-x"]
        after["updated_at"] = "2026-11-07"
        if our_status:
            group_a["status"] = our_status

        evidence = self.temp / "install-20261107T000000-tx"
        backups = evidence / "backups"
        backup = backups / "active-skills" / "skill-x"
        shutil.copytree(skill, backup)
        (skill / "SKILL.md").write_bytes(b"---\nname: skill-x\n---\nv2\n")
        (skill / "SOURCE.md").write_bytes(b"# Source\n\n---\n\n# Source Provenance\n\nSkill: `skill-x`\n")
        (backups / "source-state-before.json").write_bytes(ledger_bytes(before))
        (backups / "source-state-after.json").write_bytes(ledger_bytes(after))
        self.write(LEDGER, ledger_bytes(after))
        manifest = {
            "status": "succeeded",
            "target_scope": "active",
            "active_root": str(self.repo),
            "ledger": str(self.repo / LEDGER),
            "merge_retirement": None,
            "directory_records": [
                {
                    "name": "skill-x",
                    "active": str(skill),
                    "backup": str(backup),
                    "had_existing": True,
                    "activated": True,
                    "backup_seal": tree_content_seal(backup),
                    "activated_payload_seal": tree_content_seal(skill),
                }
            ],
            "source_state_after": {
                "path": str(backups / "source-state-after.json"),
                "sha256": sha256(ledger_bytes(after)),
            },
        }
        (evidence / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        return evidence

    def test_transaction_commits_its_own_ledger_delta_beside_another_sessions_uncommitted_one(self) -> None:
        evidence = self.guarded_transaction()

        code, error = self.run_helper("--transaction", str(evidence))

        self.assertEqual(code, 0, error)
        changed = self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").split()
        self.assertEqual(changed, [LEDGER, "skill-x/SKILL.md", "skill-x/SOURCE.md"])
        self.assertEqual(self.show("HEAD:skill-x/SKILL.md"), b"---\nname: skill-x\n---\nv2\n")
        expected = {
            "updated_at": "2026-11-07",
            "notes": [],
            "sources": [
                {
                    "id": "group-a",
                    "status": "tracked",
                    "skills": ["skill-y", "skill-x"],
                    "local_changes": [
                        {"skill": "skill-x", "date": "2026-11-01", "summary": "first"},
                        {"skill": "skill-x", "date": "2026-11-07", "summary": "this transaction"},
                    ],
                    "last_guarded_install": "2026-11-07T00:00:00Z",
                },
                {"id": "group-b", "skills": ["skill-z"], "local_changes": [], "last_guarded_install": "2026-11-01T00:00:00Z"},
            ],
            "unresolved": [],
            "deleted": [],
        }
        self.assertEqual(self.show(f"HEAD:{LEDGER}"), ledger_bytes(expected))
        self.assertEqual(self.status(), [f" M {LEDGER}"])

    def test_transaction_refuses_a_field_both_transactions_changed(self) -> None:
        evidence = self.guarded_transaction(other_status="retained-local", our_status="updated")

        code, error = self.run_helper("--transaction", str(evidence))

        self.assertEqual(code, 1)
        self.assertIn("$.sources[id=group-a].status", error)
        self.assertEqual(self.head(), self.base)

    def bulk_transaction(self, skill: str, changed: int) -> Path:
        """A succeeded guarded update of ``skill`` that modifies, deletes and adds ``changed`` files in all."""
        modified, deleted = changed // 2, changed // 4
        added = changed - modified - deleted
        ledger = {"updated_at": "2026-11-05", "sources": [{"id": skill, "skills": [skill], "local_changes": []}]}
        folder = self.repo / skill
        (folder / "refs").mkdir(parents=True)
        for index in range(modified + deleted):
            (folder / "refs" / f"{index:03d}.md").write_bytes(f"old {index}\n".encode())
        self.write(LEDGER, ledger_bytes(ledger))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", f"base {skill}")
        self.base = self.head()

        evidence = self.temp / f"install-{skill}"
        backups = evidence / "backups"
        backup = backups / "active-skills" / skill
        shutil.copytree(folder, backup)
        for index in range(modified):
            (folder / "refs" / f"{index:03d}.md").write_bytes(f"new {index}\n".encode())
        for index in range(modified, modified + deleted):
            (folder / "refs" / f"{index:03d}.md").unlink()
        for index in range(added):
            (folder / f"added-{index:03d}.md").write_bytes(f"added {index}\n".encode())
        after = {**ledger, "updated_at": "2026-11-07"}
        (backups / "source-state-before.json").write_bytes(ledger_bytes(ledger))
        (backups / "source-state-after.json").write_bytes(ledger_bytes(after))
        self.write(LEDGER, ledger_bytes(after))
        manifest = {
            "status": "succeeded",
            "active_root": str(self.repo),
            "ledger": str(self.repo / LEDGER),
            "directory_records": [
                {
                    "name": skill,
                    "active": str(folder),
                    "backup": str(backup),
                    "had_existing": True,
                    "activated": True,
                    "backup_seal": tree_content_seal(backup),
                    "activated_payload_seal": tree_content_seal(folder),
                }
            ],
            "source_state_after": {"path": str(backups / "source-state-after.json"), "sha256": sha256(ledger_bytes(after))},
        }
        (evidence / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return evidence

    def test_transaction_runs_as_many_git_processes_for_forty_files_as_for_four(self) -> None:
        # A git process costs about 0.1 s on Windows.  Started per file, they kept a 1,633-file update
        # committing for 771 s, so the count must not grow with the files a transaction changes.
        processes = []
        for skill, changed in (("skill-small", 4), ("skill-large", 40)):
            evidence = self.bulk_transaction(skill, changed)
            trace = self.temp / f"{skill}.trace"
            with mock.patch.dict(os.environ, {"GIT_TRACE": str(trace)}):
                code, error = self.run_helper("--transaction", str(evidence))
            self.assertEqual(code, 0, error)
            self.assertEqual(len(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").split()), changed + 1)
            self.assertEqual(self.status(), [])
            processes.append(trace.read_text(encoding="utf-8", errors="replace").count("trace: built-in: git "))
        self.assertEqual(processes[0], processes[1], f"git 进程数随文件数增长：{processes}")


if __name__ == "__main__":
    unittest.main()
