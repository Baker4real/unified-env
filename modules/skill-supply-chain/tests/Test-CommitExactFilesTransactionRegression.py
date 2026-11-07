#!/usr/bin/env python3
"""Host-live regression: ``--transaction`` remakes the skills root commit 1b07e9c from its real inputs.

The inputs are the skills root's own objects (parent b3128ec, commit 1b07e9c) and the c09434dd guarded
transaction evidence.  The commit is made in a throwaway repository; the skills root is only read.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
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

SKILLS_ROOT = Path(r"D:\agents\skills-manager\skills")
EVIDENCE = Path(
    r"D:\agents\run-evidence\skill-install-guarded\install-20261107T112931-c09434ddb3db4af1b0ba9b1293d2a0e8"
)
PARENT = "b3128ec"
COMMITTED = "1b07e9c"
SKILL = "implement-spec"
LEDGER = ".downloaded-skills-source-state.json"
# The ledger blob of 1b07e9c, which was assembled by hand on 2026-11-07.
COMMITTED_LEDGER_BLOB = "be04a0babed431f3407ee0f952dcfe81b7faa248"
TEMP_PARENT = Path(r"D:\Codex\tmp")


def skills_git(*args: str) -> bytes:
    return subprocess.run(["git", "-C", str(SKILLS_ROOT), *args], capture_output=True, check=True).stdout


def tree_files(commit: str, prefix: str) -> list[str]:
    listing = skills_git("ls-tree", "-r", "-z", "--name-only", commit, "--", prefix)
    return [name.decode("utf-8") for name in listing.split(b"\0") if name]


class TransactionRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        if not (EVIDENCE / "manifest.json").is_file():
            self.skipTest(f"回归输入不在了：{EVIDENCE}")
        for commit in (PARENT, COMMITTED):
            probe = subprocess.run(["git", "-C", str(SKILLS_ROOT), "cat-file", "-e", f"{commit}^{{commit}}"])
            if probe.returncode:
                self.skipTest(f"skills 根里没有提交 {commit}")
        TEMP_PARENT.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="commit-exact-files-regression-", dir=TEMP_PARENT)
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.repo = self.temp / "repo"

    def git(self, *args: str) -> str:
        result = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, check=True)
        return result.stdout.decode("utf-8")

    def write(self, relative: str, data: bytes) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_transaction_remakes_the_implement_spec_commit(self) -> None:
        hooks = self.temp / "hooks"
        hooks.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        for key, value in (
            ("user.name", "Test"),
            ("user.email", "test@example.invalid"),
            ("commit.gpgsign", "false"),
            ("core.autocrlf", "false"),
            ("core.hooksPath", hooks.as_posix()),
        ):
            self.git("config", key, value)
        # HEAD: the parent's ledger and skill directory, byte for byte.
        for relative in [LEDGER, *tree_files(PARENT, SKILL)]:
            self.write(relative, skills_git("cat-file", "blob", f"{PARENT}:{relative}"))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "parent")
        head = self.git("rev-parse", "HEAD").strip()

        # Work tree: the skill directory the transaction wrote, and the live ledger it left behind.
        shutil.rmtree(self.repo / SKILL)
        for relative in tree_files(COMMITTED, SKILL):
            self.write(relative, skills_git("cat-file", "blob", f"{COMMITTED}:{relative}"))
        evidence = self.temp / "evidence"
        backups = evidence / "backups"
        shutil.copytree(EVIDENCE / "backups" / "active-skills" / SKILL, backups / "active-skills" / SKILL)
        for name in ("source-state-before.json", "source-state-after.json"):
            shutil.copyfile(EVIDENCE / "backups" / name, backups / name)
        self.write(LEDGER, (backups / "source-state-after.json").read_bytes())

        # The transaction manifest, pointed at the copies.
        manifest = json.loads((EVIDENCE / "manifest.json").read_text(encoding="utf-8"))
        manifest["active_root"] = str(self.repo)
        manifest["ledger"] = str(self.repo / LEDGER)
        [record] = manifest["directory_records"]
        record["active"] = str(self.repo / SKILL)
        record["backup"] = str(backups / "active-skills" / SKILL)
        manifest["source_state_after"]["path"] = str(backups / "source-state-after.json")
        (evidence / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        message = self.temp / "message.txt"
        message.write_bytes(b"regression\n")

        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = HELPER.main(
                [
                    "--repo",
                    str(self.repo),
                    "--expected-head",
                    head,
                    "--message-file",
                    str(message),
                    "--transaction",
                    str(evidence),
                ]
            )

        self.assertEqual(code, 0, stderr.getvalue())
        self.assertEqual(self.git("rev-parse", f"HEAD:{LEDGER}").strip(), COMMITTED_LEDGER_BLOB)
        expected = skills_git("diff-tree", "--no-commit-id", "--name-only", "-r", COMMITTED).decode("utf-8").split()
        self.assertEqual(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").split(), expected)
        for relative in expected:
            committed = skills_git("rev-parse", f"{COMMITTED}:{relative}").decode("ascii").strip()
            self.assertEqual(self.git("rev-parse", f"HEAD:{relative}").strip(), committed, relative)


if __name__ == "__main__":
    unittest.main()
