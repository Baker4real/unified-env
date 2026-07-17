#!/usr/bin/env python3
"""Regression coverage for stale retired-process registry deletion."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
REPORTS_ROOT = PROJECT_ROOT / "reports"
SCRIPT_PATH = PROJECT_ROOT / "scripts" / "Invoke-RetiredProjectProcessRegistryPurger.py"
RETIRED_ID = "codex-gsd-codex-c-skill"
MARKER_NAME = ".retired-project-process-registry-purger-fixture"
MARKER_VALUE = "retired-project-process-registry-purger-fixture-v1\n"
PREFIX = "retired-project-process-registry-purger-tests-"


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def fixture_home() -> Path:
    home = REPORTS_ROOT / f"{PREFIX}{uuid.uuid4().hex}" / ".codex"
    home.mkdir(parents=True)
    (home / MARKER_NAME).write_text(MARKER_VALUE, encoding="utf-8")
    return home


def record(*, identifier: str, cwd: str, command: str, os_pid: int | None, process_id: int | None, title: str = "safe title") -> dict:
    return {
        "id": identifier,
        "itemId": identifier + "-item",
        "conversationId": identifier + "-conversation",
        "turnId": identifier + "-turn",
        "cwd": cwd,
        "command": command,
        "osPid": os_pid,
        "processId": process_id,
        "startedAtMs": 1,
        "updatedAtMs": 2,
        "chatTitle": title,
    }


def write_registry(home: Path, records: list[dict]) -> None:
    target = home / "process_manager" / "chat_processes.json"
    target.parent.mkdir(parents=True)
    target.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def read_registry(home: Path) -> list[dict]:
    return json.loads((home / "process_manager" / "chat_processes.json").read_text(encoding="utf-8"))


def run_purger(home: Path, *arguments: str, expected_status: int) -> dict:
    completed = subprocess.run(
        [sys.executable, "-B", str(SCRIPT_PATH), "--fixture-root", str(home), "--json", *arguments],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
    )
    assert_true(completed.returncode == expected_status, f"purger exit code 不符：{completed.stdout}\n{completed.stderr}")
    assert_true(completed.stderr == "", f"purger 不应向 stderr 输出：{completed.stderr}")
    return json.loads(completed.stdout)


def assert_no_payload_backup(home: Path) -> None:
    unexpected = [
        item
        for item in home.rglob("*")
        if item.is_file() and item.name != MARKER_NAME and (item.name.endswith(".bak") or ".retired-project-process-registry-" in item.name)
    ]
    assert_true(not unexpected, "process registry purger 创建了 payload backup 或临时文件")


def cleanup(home: Path) -> None:
    reports = REPORTS_ROOT.resolve(strict=True)
    candidate = home.resolve(strict=True) if home.exists() else home
    assert_true(str(candidate).casefold().startswith(str(reports).casefold() + "\\"), "测试路径越出 reports")
    assert_true(candidate.parent.name.startswith(PREFIX), "测试前缀不匹配")
    if home.parent.exists():
        shutil.rmtree(home.parent)


def retired_cwd() -> str:
    return r"\\?\D:\Codex\projects\codex-gsd-codex-c-skill"


def test_happy_path() -> None:
    home = fixture_home()
    try:
        records = [
            record(identifier="retired-both", cwd=retired_cwd(), command=f"codex --cwd {retired_cwd()}", os_pid=None, process_id=None),
            record(identifier="retired-cwd", cwd=retired_cwd(), command="codex resume", os_pid=0, process_id=None),
            record(identifier="safe", cwd=r"\\?\D:\Codex\projects\统一环境", command="codex", os_pid=None, process_id=None),
        ]
        write_registry(home, records)
        before = read_registry(home)
        audit = run_purger(home, "--mode", "Audit", expected_status=1)
        assert_true(audit["readyRecordCount"] == 2 and audit["blockedRecordCount"] == 0, "Audit 未识别全部陈旧记录")
        missing_confirm = run_purger(home, "--mode", "Apply", "--cold-maintenance", expected_status=1)
        assert_true("confirm" in missing_confirm["error"].casefold(), "缺少确认的 Apply 未被拒绝")
        assert_true(read_registry(home) == before, "缺少确认的 Apply 修改 registry")
        missing_cold = run_purger(home, "--mode", "Apply", "--confirm-retired-project", RETIRED_ID, expected_status=1)
        assert_true("cold-maintenance" in missing_cold["error"], "缺少 cold maintenance 的 Apply 未被拒绝")
        assert_true(read_registry(home) == before, "缺少 cold maintenance 的 Apply 修改 registry")
        applied = run_purger(home, "--mode", "Apply", "--cold-maintenance", "--confirm-retired-project", RETIRED_ID, expected_status=0)
        assert_true(applied["ok"] is True and applied["changed"] is True and applied["readyRecordCount"] == 0, "合法 Apply 未成功")
        remaining = read_registry(home)
        assert_true([entry["id"] for entry in remaining] == ["safe"], "Apply 删除了错误的 registry entry")
        assert_true(remaining[0] == records[-1], "保留 registry entry 被改写")
        post = run_purger(home, "--mode", "Audit", expected_status=0)
        assert_true(post["ok"] is True and post["findingCount"] == 0, "Apply 后 Audit 未归零")
        assert_no_payload_backup(home)
    finally:
        cleanup(home)


def test_large_replacement_uses_stdin_transport() -> None:
    """Apply must not put a replacement payload past the Windows command-line limit."""
    home = fixture_home()
    try:
        retained = record(
            identifier="large-safe",
            cwd=r"\\?\D:\Codex\projects\统一环境",
            command="codex " + ("x" * 40_000),
            os_pid=None,
            process_id=None,
        )
        write_registry(
            home,
            [
                record(identifier="retired", cwd=retired_cwd(), command="codex", os_pid=None, process_id=None),
                retained,
            ],
        )
        result = run_purger(
            home,
            "--mode",
            "Apply",
            "--cold-maintenance",
            "--confirm-retired-project",
            RETIRED_ID,
            expected_status=0,
        )
        target = home / "process_manager" / "chat_processes.json"
        assert_true(result["ok"] is True and result["changed"] is True, "大 replacement Apply 未成功")
        assert_true(target.stat().st_size > 32_768, "回归 fixture 未形成超过 32 KiB 的 replacement")
        assert_true(read_registry(home) == [retained], "大 replacement Apply 未精确保留安全记录")
        assert_no_payload_backup(home)
    finally:
        cleanup(home)


def test_fail_closed() -> None:
    for label, records in [
        (
            "active",
            [record(identifier="active", cwd=retired_cwd(), command="codex", os_pid=42, process_id=None)],
        ),
        (
            "user-title",
            [record(identifier="title", cwd=r"\\?\D:\Codex", command="codex", os_pid=None, process_id=None, title=f"user text {RETIRED_ID}")],
        ),
        (
            "command-only",
            [record(identifier="command", cwd=r"\\?\D:\Codex\projects\统一环境", command=f"codex --project {RETIRED_ID}", os_pid=None, process_id=None)],
        ),
    ]:
        home = fixture_home()
        try:
            write_registry(home, records)
            before = read_registry(home)
            result = run_purger(home, "--mode", "Apply", "--cold-maintenance", "--confirm-retired-project", RETIRED_ID, expected_status=1)
            assert_true(result["ok"] is False and "process registry" in result["error"], f"{label} 未失败关闭")
            assert_true(read_registry(home) == before, f"{label} 拒绝路径改写了 registry")
            assert_no_payload_backup(home)
        finally:
            cleanup(home)


def test_hardlink_refusal() -> None:
    home = fixture_home()
    external = REPORTS_ROOT / f"{PREFIX}{uuid.uuid4().hex}" / "external.json"
    try:
        write_registry(home, [record(identifier="retired", cwd=retired_cwd(), command="codex", os_pid=None, process_id=None)])
        external.parent.mkdir(parents=True)
        shutil.copyfile(home / "process_manager" / "chat_processes.json", external)
        (home / "process_manager" / "chat_processes.json").unlink()
        os.link(external, home / "process_manager" / "chat_processes.json")
        result = run_purger(home, "--mode", "Audit", expected_status=1)
        assert_true("hard link" in result["error"], "hard link registry 未失败关闭")
        assert_true(external.exists(), "hard link 拒绝误伤外部文件")
    finally:
        cleanup(home)
        if external.parent.exists():
            shutil.rmtree(external.parent)


def main() -> int:
    assert_true(SCRIPT_PATH.is_file(), "缺少 process registry purger")
    test_happy_path()
    test_large_replacement_uses_stdin_transport()
    test_fail_closed()
    test_hardlink_refusal()
    print("Retired project process registry purger: PASS (stale-only deletion, confirmation/cold gate, large stdin replacement, user-text and hardlink refusal)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
