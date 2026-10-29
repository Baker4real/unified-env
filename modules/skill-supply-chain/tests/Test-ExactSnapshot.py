"""Behaviour tests for exact_snapshot in throwaway repositories."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[3]
IMPLEMENTATION = PROJECT_ROOT / "modules" / "skill-supply-chain" / "implementation"
TEMP_PARENT = Path(r"D:\Codex\tmp")


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, IMPLEMENTATION / f"{name}.py")
    if spec is None or spec.loader is None:  # pragma: no cover
        raise RuntimeError(f"无法加载 helper：{name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SNAPSHOT = load("exact_snapshot")
COMMIT = load("commit_exact_files")


class ExactSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        TEMP_PARENT.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="exact-snapshot-test-", dir=TEMP_PARENT)
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.repo = self.temp / "repo"
        self.dest = self.temp / "snapshot"
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
            self.git(self.repo, "config", key, value)
        (self.repo / ".gitignore").write_bytes(b"ignored.txt\n")
        (self.repo / "ignored.txt").write_bytes(b"kept\n")
        (self.repo / "tool.sh").write_bytes(b"#!/bin/sh\n")
        self.commit(self.repo, {"a.txt": b"a1\n", "b.txt": b"b1\n"}, "base")
        self.git(self.repo, "add", "-f", "ignored.txt")
        self.git(self.repo, "update-index", "--chmod=+x", "tool.sh")
        self.git(self.repo, "commit", "-q", "--amend", "-m", "base")
        self.base = self.head(self.repo)

    def git(self, repo: Path, *args: str) -> str:
        result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True)
        return result.stdout.decode("utf-8")

    def head(self, repo: Path) -> str:
        return self.git(repo, "rev-parse", "HEAD").strip()

    def commit(self, repo: Path, changes: dict[str, bytes], message: str) -> str:
        for name, data in changes.items():
            (repo / name).write_bytes(data)
        self.git(repo, "add", "-A")
        self.git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", message)
        return self.head(repo)

    def run_snapshot(self, *args: str) -> tuple[int, dict | None, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = SNAPSHOT.main(list(args))
        return code, json.loads(stdout.getvalue()) if code == 0 else None, stderr.getvalue()

    def create(self) -> dict:
        code, result, error = self.run_snapshot("create", "--repo", str(self.repo), "--dest", str(self.dest))
        self.assertEqual(code, 0, error)
        return result

    def onto(self) -> tuple[int, dict | None, str]:
        return self.run_snapshot("onto", "--dest", str(self.dest))

    def test_create_checks_out_every_tracked_file_with_the_source_settings(self) -> None:
        result = self.create()
        self.assertEqual((result["base"], result["head"], result["commits"]), (self.base, self.base, []))
        self.assertEqual(Path(result["source"]), self.repo.resolve())
        self.assertEqual((self.dest / "ignored.txt").read_bytes(), b"kept\n")
        self.assertTrue(self.git(self.dest, "ls-files", "-s", "tool.sh").startswith("100755 "))
        self.assertEqual(self.git(self.dest, "status", "--porcelain=v1"), "")
        self.assertEqual(self.git(self.dest, "rev-parse", "--abbrev-ref", "HEAD").strip(), "snapshot")
        settings = {
            key: self.git(self.dest, "config", "--local", "--get", key).strip()
            for key in ("core.autocrlf", "core.hooksPath", "core.longpaths", "user.name")
        }
        self.assertEqual(
            settings,
            {"core.autocrlf": "false", "core.hooksPath": self.hooks.as_posix(), "core.longpaths": "true", "user.name": "Test"},
        )

    def test_create_refuses_a_non_empty_destination(self) -> None:
        self.dest.mkdir()
        (self.dest / "keep.txt").write_bytes(b"x")
        code, _, error = self.run_snapshot("create", "--repo", str(self.repo), "--dest", str(self.dest))
        self.assertEqual(code, 1)
        self.assertIn("不是空目录", error)
        self.assertEqual([path.name for path in self.dest.iterdir()], ["keep.txt"])

    def test_onto_rebases_snapshot_commits_onto_new_source_commits(self) -> None:
        self.create()
        mine = self.commit(self.dest, {"a.txt": b"a-snapshot\n"}, "snapshot change")
        moved = self.commit(self.repo, {"b.txt": b"b2\n"}, "other session")
        code, result, error = self.onto()
        self.assertEqual(code, 0, error)
        self.assertEqual(result["base"], moved)
        self.assertEqual(len(result["commits"]), 1)
        self.assertNotEqual(result["commits"][0], mine)
        self.assertEqual(self.git(self.dest, "rev-parse", f"{result['commits'][0]}^").strip(), moved)
        self.assertEqual(
            ((self.dest / "a.txt").read_bytes(), (self.dest / "b.txt").read_bytes()), (b"a-snapshot\n", b"b2\n")
        )
        code, again, error = self.onto()
        self.assertEqual(code, 0, error)
        self.assertEqual(again, result)

    def test_onto_stops_on_a_conflict_and_resumes_after_continue(self) -> None:
        self.create()
        self.commit(self.dest, {"a.txt": b"a-snapshot\n"}, "snapshot change")
        moved = self.commit(self.repo, {"a.txt": b"a-other\n"}, "other session")
        code, _, error = self.onto()
        self.assertEqual(code, 3)
        self.assertIn("['a.txt']", error)
        self.assertIn("rebase --continue", error)
        code, _, error = self.onto()
        self.assertEqual(code, 1)
        self.assertIn("rebase 还没完成", error)
        (self.dest / "a.txt").write_bytes(b"a-merged\n")
        self.git(self.dest, "add", "a.txt")
        self.git(self.dest, "-c", "core.editor=true", "-c", "commit.gpgsign=false", "rebase", "--continue")
        code, result, error = self.onto()
        self.assertEqual(code, 0, error)
        self.assertEqual(result["base"], moved)
        self.assertEqual(len(result["commits"]), 1)
        self.assertEqual(self.git(self.dest, "show", f"{result['head']}:a.txt"), "a-merged\n")

    def test_onto_refuses_rewritten_source_history(self) -> None:
        self.create()
        self.git(self.repo, "-c", "commit.gpgsign=false", "commit", "-q", "--amend", "-m", "base rewritten")
        code, _, error = self.onto()
        self.assertEqual(code, 1)
        self.assertIn(f"快照基底 {self.base} 不是", error)

    def test_snapshot_commits_replay_into_the_moved_source_with_their_trees(self) -> None:
        self.create()
        self.commit(self.dest, {"a.txt": b"a2\n"}, "first")
        self.commit(self.dest, {"c.txt": b"c1\n"}, "second")
        self.commit(self.repo, {"b.txt": b"b2\n"}, "other session")
        code, result, error = self.onto()
        self.assertEqual(code, 0, error)
        for replayed in result["commits"]:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as stderr:
                code = COMMIT.main(
                    ["--repo", str(self.repo), "--expected-head", self.head(self.repo), "--from-commit", str(self.dest), replayed]
                )
            self.assertEqual(code, 0, stderr.getvalue())
            self.assertEqual(
                self.git(self.repo, "rev-parse", "HEAD^{tree}"), self.git(self.dest, "rev-parse", f"{replayed}^{{tree}}")
            )
        self.assertEqual(self.git(self.repo, "log", "--format=%s", "-3").split("\n")[:3], ["second", "first", "other session"])
        self.assertEqual(self.git(self.repo, "status", "--porcelain=v1"), "")


if __name__ == "__main__":
    unittest.main()
