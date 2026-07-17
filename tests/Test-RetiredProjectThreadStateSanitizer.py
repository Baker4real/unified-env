#!/usr/bin/env python3
"""Regression coverage for the cold retired-project thread-state sanitizer."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import uuid


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
REPORTS_ROOT = PROJECT_ROOT / "reports"
SCRIPT_PATH = PROJECT_ROOT / "scripts" / "Invoke-RetiredProjectThreadStateSanitizer.py"
RETIRED_ID = "codex-gsd-codex-c-skill"
RETIRED_ROOT = rf"D:\Codex\projects\{RETIRED_ID}"
RETIRED_EXTENDED_ROOT = "\\\\?\\" + RETIRED_ROOT
RETIRED_ORIGIN = "https://github.com/Baker4real/codex-gsd-codex-c-skill.git"
MARKER_NAME = ".retired-project-thread-state-sanitizer-fixture"
MARKER_VALUE = "retired-project-thread-state-sanitizer-fixture-v1\n"
PREFIX = "retired-project-thread-state-sanitizer-tests-"


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def fixture_home(label: str) -> Path:
    root = REPORTS_ROOT / f"{PREFIX}{uuid.uuid4().hex}" / ".codex"
    root.mkdir(parents=True)
    (root / MARKER_NAME).write_text(MARKER_VALUE, encoding="utf-8")
    (root / "neutral-host").mkdir()
    return root


def create_database(home: Path, *, active_retired: bool = False, missing_column: bool = False) -> None:
    database = home / "state_5.sqlite"
    connection = sqlite3.connect(database)
    try:
        connection.execute("PRAGMA journal_mode = WAL")
        origin_column = "" if missing_column else ", git_origin_url TEXT"
        connection.execute(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                archived INTEGER NOT NULL,
                git_sha TEXT,
                git_branch TEXT
            """
            + origin_column
            + ", title TEXT, first_user_message TEXT, preview TEXT, sentinel TEXT)"
        )
        connection.execute("CREATE TABLE spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL)")
        if missing_column:
            connection.execute(
                "INSERT INTO threads (id,cwd,archived,git_sha,git_branch,title,first_user_message,preview,sentinel) VALUES (?,?,?,?,?,?,?,?,?)",
                ("safe", r"\\?\D:\Codex", 1, None, None, "safe", "safe", "safe", "safe"),
            )
            connection.commit()
            return
        rows = [
            ("retired-root", RETIRED_EXTENDED_ROOT, 1, "sha-root", "main", RETIRED_ORIGIN, "retired title must survive", "retired first user message must survive", "retired preview must survive", "retired-root-sentinel"),
            ("retired-descendant", RETIRED_EXTENDED_ROOT + r"\child", 1, "sha-desc", "feature", None, "descendant title", "descendant message", "descendant preview", "retired-desc-sentinel"),
            ("retired-forward-slash", RETIRED_ROOT.replace("\\", "/"), 1, None, None, RETIRED_ORIGIN, "forward title", "forward message", "forward preview", "retired-forward-sentinel"),
            ("safe-user-text", r"\\?\D:\Codex\projects\统一环境", 1, "safe-sha", "safe-branch", "https://github.com/Baker4real/unified-env.git", f"title mentions {RETIRED_ID}", f"prompt mentions {RETIRED_ROOT}", f"preview mentions {RETIRED_ID}", "safe-user-text-sentinel"),
            ("safe", r"\\?\D:\Codex\projects\统一环境", 1, "safe-sha-2", "safe-branch-2", None, "safe", "safe", "safe", "safe-sentinel"),
        ]
        if active_retired:
            rows.append(("retired-active", RETIRED_EXTENDED_ROOT, 0, "active-sha", "main", RETIRED_ORIGIN, "active title", "active message", "active preview", "active-sentinel"))
        connection.executemany(
            """
            INSERT INTO threads (id,cwd,archived,git_sha,git_branch,git_origin_url,title,first_user_message,preview,sentinel)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            rows,
        )
        connection.executemany(
            "INSERT INTO spawn_edges (parent_thread_id,child_thread_id) VALUES (?,?)",
            [("retired-root", "retired-descendant"), ("retired-descendant", "safe-user-text")],
        )
        connection.commit()
    finally:
        connection.close()


def run_sanitizer(home: Path, *arguments: str, expected_status: int) -> dict:
    completed = subprocess.run(
        [sys.executable, "-B", str(SCRIPT_PATH), "--fixture-root", str(home), "--json", *arguments],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
    )
    assert_true(completed.returncode == expected_status, f"sanitizer exit code 不符：{completed.stdout}\n{completed.stderr}")
    assert_true(completed.stderr == "", f"sanitizer 不应向 stderr 输出：{completed.stderr}")
    return json.loads(completed.stdout)


def logical_rows(home: Path) -> list[tuple]:
    connection = sqlite3.connect(home / "state_5.sqlite")
    try:
        return list(connection.execute("SELECT id,cwd,git_sha,git_branch,git_origin_url,title,first_user_message,preview,sentinel FROM threads ORDER BY id"))
    finally:
        connection.close()


def assert_no_payload_backup(home: Path) -> None:
    payload_backups = [
        item
        for item in home.rglob("*")
        if item.is_file()
        and item.name != MARKER_NAME
        and (item.name.endswith(".bak") or ".retired-project-thread-state" in item.name)
    ]
    assert_true(not payload_backups, "sanitizer 创建了 payload backup 或临时副本")


def safe_cleanup(root: Path) -> None:
    reports_root = REPORTS_ROOT.resolve(strict=True)
    candidate = root.resolve(strict=True) if root.exists() else root
    assert_true(str(candidate).casefold().startswith(str(reports_root).casefold() + "\\"), "测试根越出 reports")
    assert_true(candidate.parent.name.startswith(PREFIX), "测试根前缀不匹配")
    if root.exists():
        shutil.rmtree(root.parent)


def test_valid_apply() -> None:
    home = fixture_home("valid")
    try:
        create_database(home)
        before_rows = logical_rows(home)
        audit = run_sanitizer(home, "--mode", "Audit", expected_status=1)
        assert_true(audit["ok"] is False and audit["findingCount"] == 5, "Audit 未计出 cwd/origin 结构引用")
        assert_true(audit["details"]["counts"]["retiredCwd"] == 3, "Audit cwd 数量不符")
        assert_true(audit["details"]["counts"]["retiredOrigin"] == 2, "Audit origin 数量不符")

        no_confirmation = run_sanitizer(home, "--mode", "Apply", "--cold-maintenance", expected_status=1)
        assert_true("confirm" in no_confirmation["error"].casefold(), "缺少确认的 Apply 未被拒绝")
        assert_true(logical_rows(home) == before_rows, "缺少确认的 Apply 修改了线程")

        no_cold = run_sanitizer(home, "--mode", "Apply", "--confirm-retired-project", RETIRED_ID, expected_status=1)
        assert_true("cold-maintenance" in no_cold["error"], "缺少 cold-maintenance 的 Apply 未被拒绝")
        assert_true(logical_rows(home) == before_rows, "无 cold-maintenance 的 Apply 修改了线程")

        applied = run_sanitizer(
            home,
            "--mode", "Apply",
            "--cold-maintenance",
            "--confirm-retired-project", RETIRED_ID,
            expected_status=0,
        )
        assert_true(applied["ok"] is True and applied["changed"] is True, "合法 Apply 未成功")
        assert_true(applied["details"]["changedRows"] == 3, "Apply 更新行数不符")
        assert_true(applied["payloadBackupCreated"] is False and applied["backupPath"] is None, "Apply 不得保留 payload backup")

        connection = sqlite3.connect(home / "state_5.sqlite")
        try:
            neutral = applied["neutralCwd"]
            retired_rows = list(connection.execute("SELECT id,cwd,git_sha,git_branch,git_origin_url FROM threads WHERE id LIKE 'retired-%' ORDER BY id"))
            assert_true(len(retired_rows) == 3, "退休 thread 行数意外变化")
            assert_true(all(row[1] == neutral for row in retired_rows), "退休 cwd 未转为中性 cwd")
            assert_true(all(row[2] is None and row[3] is None and row[4] is None for row in retired_rows), "退休 git 元数据未完全清除")
            user_text = connection.execute("SELECT cwd,git_sha,git_branch,git_origin_url,title,first_user_message,preview,sentinel FROM threads WHERE id='safe-user-text'").fetchone()
            assert_true(user_text[0] == r"\\?\D:\Codex\projects\统一环境", "安全 thread cwd 被误改")
            assert_true(user_text[1:4] == ("safe-sha", "safe-branch", "https://github.com/Baker4real/unified-env.git"), "安全 git 元数据被误改")
            assert_true(RETIRED_ID in user_text[4] and RETIRED_ROOT in user_text[5] and RETIRED_ID in user_text[6], "用户 title/prompt/preview 被误删")
            assert_true(user_text[7] == "safe-user-text-sentinel", "无关列被误改")
            assert_true(connection.execute("SELECT COUNT(*) FROM spawn_edges").fetchone()[0] == 2, "spawn edges 被误删")
            assert_true(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "Apply 后 integrity_check 失败")
            assert_true(not list(connection.execute("PRAGMA foreign_key_check")), "Apply 后 foreign_key_check 失败")
        finally:
            connection.close()
        post_audit = run_sanitizer(home, "--mode", "Audit", expected_status=0)
        assert_true(post_audit["ok"] is True and post_audit["findingCount"] == 0, "Apply 后 Audit 未归零")
        assert_no_payload_backup(home)
    finally:
        safe_cleanup(home)


def test_active_retired_refusal() -> None:
    home = fixture_home("active")
    try:
        create_database(home, active_retired=True)
        before_rows = logical_rows(home)
        result = run_sanitizer(
            home,
            "--mode", "Apply",
            "--cold-maintenance",
            "--confirm-retired-project", RETIRED_ID,
            expected_status=1,
        )
        assert_true("非 archived" in result["error"], "active retired thread 未失败关闭")
        assert_true(logical_rows(home) == before_rows, "active retired 拒绝路径修改了线程")
        assert_no_payload_backup(home)
    finally:
        safe_cleanup(home)


def test_schema_refusal() -> None:
    home = fixture_home("schema")
    try:
        create_database(home, missing_column=True)
        result = run_sanitizer(home, "--mode", "Audit", expected_status=1)
        assert_true("schema" in result["error"], "缺失受控列未失败关闭")
        assert_no_payload_backup(home)
    finally:
        safe_cleanup(home)


def test_hardlink_refusal() -> None:
    home = fixture_home("hardlink")
    outside = REPORTS_ROOT / f"{PREFIX}{uuid.uuid4().hex}" / "outside.sqlite"
    try:
        create_database(home)
        outside.parent.mkdir(parents=True)
        shutil.copyfile(home / "state_5.sqlite", outside)
        (home / "state_5.sqlite").unlink()
        os_link = getattr(__import__("os"), "link")
        os_link(outside, home / "state_5.sqlite")
        result = run_sanitizer(home, "--mode", "Audit", expected_status=1)
        assert_true("hard link" in result["error"], "hard link target 未失败关闭")
        assert_true(outside.exists(), "hard link 拒绝不得影响外部文件")
    finally:
        safe_cleanup(home)
        if outside.parent.exists():
            shutil.rmtree(outside.parent)


def main() -> int:
    assert_true(SCRIPT_PATH.is_file(), "缺少 thread-state sanitizer 脚本")
    test_valid_apply()
    test_active_retired_refusal()
    test_schema_refusal()
    test_hardlink_refusal()
    print("Retired project thread-state sanitizer: PASS (cold transaction, extended cwd, metadata-only cleanup, user-text/edge preservation, schema/hardlink refusal)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
