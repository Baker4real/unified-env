"""Behaviour tests for commit_exact_files in throwaway repositories."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


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

    def run_helper(self, *args: str) -> tuple[int, str]:
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = HELPER.main(
                [
                    "--repo",
                    str(self.repo),
                    "--expected-head",
                    self.base,
                    "--message-file",
                    str(self.message),
                    *args,
                ]
            )
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
