"""Behaviour tests for the skills repository pre-commit guard, run through real git commits."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[3]
IMPLEMENTATION_ROOT = PROJECT_ROOT / "modules" / "skill-supply-chain" / "implementation"
TEMP_PARENT = Path(r"D:\Codex\tmp")


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, IMPLEMENTATION_ROOT / f"{name}.py")
    if spec is None or spec.loader is None:  # pragma: no cover
        raise RuntimeError(f"无法加载 {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GUARD = load("skills_repo_pre_commit")
HELPER = load("commit_exact_files")


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


class SkillsRepoPreCommitTests(unittest.TestCase):
    def setUp(self) -> None:
        TEMP_PARENT.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="skills-pre-commit-test-", dir=TEMP_PARENT)
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        (self.temp / "gitconfig").write_bytes(b"")
        environment = mock.patch.dict(
            os.environ,
            {"GIT_CONFIG_GLOBAL": str(self.temp / "gitconfig"), "GIT_CONFIG_NOSYSTEM": "1"},
        )
        environment.start()
        self.addCleanup(environment.stop)
        self.repo = self.temp / "repo"
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.write("legacy.txt", b"form\x0cfeed predates the guard\n")
        self.write(GUARD.LEDGER, canonical({"sources": []}))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.base = self.head()
        code, error = self.run_guard("install", "--repo", str(self.repo))
        self.assertEqual(code, 0, error)

    def git(self, *args: str) -> str:
        result = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, check=True)
        return result.stdout.decode("utf-8")

    def head(self) -> str:
        return self.git("rev-parse", "HEAD").strip()

    def write(self, name: str, data: bytes) -> None:
        (self.repo / name).write_bytes(data)

    def commit(self, *names: str) -> subprocess.CompletedProcess[bytes]:
        self.git("add", "--", *names)
        return subprocess.run(["git", "-C", str(self.repo), "commit", "-q", "-m", "change"], capture_output=True)

    def run_guard(self, *args: str) -> tuple[int, str]:
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            code = GUARD.main(list(args))
        return code, stderr.getvalue()

    def test_blocks_staged_text_with_control_character_and_names_its_line(self) -> None:
        self.write("SOURCE.md", b"# Source\nPath: D:\x07gents\n")
        result = self.commit("SOURCE.md")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SOURCE.md:2: 控制字符 0x07", result.stderr.decode("utf-8"))
        self.assertEqual(self.head(), self.base)

    def test_allows_text_binary_and_untouched_legacy_files(self) -> None:
        self.write("notes.md", b"tab\tand CRLF\r\n")
        self.write("image.bin", b"\x89PNG\0\x07\x1b binary")
        result = self.commit("notes.md", "image.bin")
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8"))

    def test_blocks_non_canonical_ledger_and_allows_canonical(self) -> None:
        value = {"sources": [{"id": "例子"}]}
        self.write(GUARD.LEDGER, json.dumps(value, indent=2).encode("utf-8") + b"\n")
        result = self.commit(GUARD.LEDGER)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("规范 JSON", result.stderr.decode("utf-8"))
        self.write(GUARD.LEDGER, canonical(value))
        result = self.commit(GUARD.LEDGER)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8"))

    def test_checks_the_exact_commit_helpers_private_index(self) -> None:
        self.write("other-session.md", b"bell \x07 staged elsewhere\n")
        self.git("add", "other-session.md")
        message = self.temp / "message.txt"
        message.write_bytes(b"exact commit\n")

        def run_helper(*args: str) -> int:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                return HELPER.main(
                    ["--repo", str(self.repo), "--expected-head", self.head(), "--message-file", str(message), *args]
                )

        self.write("bad.md", b"bell \x07\n")
        self.assertEqual(run_helper("--file", "bad.md", hashlib.sha256(b"bell \x07\n").hexdigest()), 1)
        self.assertEqual(self.head(), self.base)
        self.write("good.md", b"clean\n")
        self.assertEqual(run_helper("--file", "good.md", hashlib.sha256(b"clean\n").hexdigest()), 0)
        self.assertEqual(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").split(), ["good.md"])

    def test_install_reinstalls_own_shim_and_refuses_foreign_hook(self) -> None:
        code, error = self.run_guard("install", "--repo", str(self.repo))
        self.assertEqual(code, 0, error)
        (self.repo / ".git" / "hooks" / "pre-commit").write_bytes(b"#!/bin/sh\nexit 0\n")
        code, error = self.run_guard("install", "--repo", str(self.repo))
        self.assertEqual(code, 1)
        self.assertIn("别的 pre-commit hook", error)

    def test_install_refuses_when_hooks_path_is_set(self) -> None:
        self.git("config", "core.hooksPath", "elsewhere")
        code, error = self.run_guard("install", "--repo", str(self.repo))
        self.assertEqual(code, 1)
        self.assertIn("core.hooksPath", error)


if __name__ == "__main__":
    unittest.main()
