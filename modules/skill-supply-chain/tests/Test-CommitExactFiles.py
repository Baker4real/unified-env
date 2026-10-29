"""Behaviour tests for commit_exact_files in throwaway repositories."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[3]
HELPER_PATH = PROJECT_ROOT / "modules" / "skill-supply-chain" / "implementation" / "commit_exact_files.py"
SPEC = importlib.util.spec_from_file_location("commit_exact_files", HELPER_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 helper：{HELPER_PATH}")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)
TEMP_PARENT = Path(r"D:\Codex\tmp")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
        self.assertIn("已有暂存改动", error)
        self.assertEqual(self.head(), self.base)
        self.assertEqual(self.status(), ["MM a.txt"])

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
        self.assertIn("工作树里的 a.txt 带着别的改动", self.stdout)

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


if __name__ == "__main__":
    unittest.main()
