#!/usr/bin/env python3
"""Regression coverage for deleting the retired CC Switch evidence setting."""

from __future__ import annotations

import json
import importlib.util
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import uuid


PROJECT_ROOT = Path(r"D:\agents\projects\统一环境")
REPORTS_ROOT = PROJECT_ROOT / "reports"
SCRIPT_PATH = PROJECT_ROOT / "scripts" / "Invoke-RetiredProjectUsageEvidenceConfigPurger.py"
RETIRED_ID = "codex-gsd-codex-c-skill"
MARKER_NAME = ".retired-project-usage-evidence-purger-fixture"
MARKER_VALUE = "retired-project-usage-evidence-purger-fixture-v1\n"
PREFIX = "retired-project-usage-evidence-purger-tests-"
TARGET_KEY = "common_config_codex"
SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def fixture_home() -> Path:
    home = REPORTS_ROOT / f"{PREFIX}{uuid.uuid4().hex}" / ".codex"
    home.mkdir(parents=True)
    (home / MARKER_NAME).write_text(MARKER_VALUE, encoding="utf-8")
    return home


def database_path(home: Path) -> Path:
    return home / "usage_evidence" / "ccswitch" / "cc-switch-latest.db"


def create_database(home: Path, *, extra_marker: bool = False, missing_schema: bool = False) -> None:
    path = database_path(home)
    path.parent.mkdir(parents=True)
    connection = sqlite3.connect(path)
    try:
        if missing_schema:
            connection.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, other TEXT)")
            connection.execute("INSERT INTO settings (key,other) VALUES (?,?)", (TARGET_KEY, RETIRED_ID))
        else:
            connection.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)")
            retired_toml = f'service_tier = "default"\n[projects."D:\\\\Codex\\\\projects\\\\{RETIRED_ID}"]\ntrust_level = "trusted"\n'
            connection.execute("INSERT INTO settings (key,value) VALUES (?,?)", (TARGET_KEY, retired_toml))
            connection.execute("INSERT INTO settings (key,value) VALUES (?,?)", ("safe_config", "[feature]\nvalue = true\n"))
            if extra_marker:
                connection.execute("INSERT INTO settings (key,value) VALUES (?,?)", ("other_config", RETIRED_ID))
        connection.commit()
    finally:
        connection.close()


def run_purger(home: Path, *arguments: str, expected_status: int) -> dict:
    completed = subprocess.run(
        [sys.executable, "-B", str(SCRIPT_PATH), "--fixture-root", str(home), "--json", *arguments],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        creationflags=SUBPROCESS_CREATION_FLAGS,
    )
    assert_true(completed.returncode == expected_status, f"purger exit code 不符：{completed.stdout}\n{completed.stderr}")
    assert_true(completed.stderr == "", f"purger 不应向 stderr 输出：{completed.stderr}")
    return json.loads(completed.stdout)


def load_purger_module():
    module_name = f"retired_project_usage_evidence_purger_test_{uuid.uuid4().hex}"
    specification = importlib.util.spec_from_file_location(module_name, SCRIPT_PATH)
    assert_true(specification is not None and specification.loader is not None, "无法加载 usage evidence purger 模块")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def read_rows(home: Path) -> list[tuple[str, str]]:
    connection = sqlite3.connect(database_path(home))
    try:
        return list(connection.execute("SELECT key,value FROM settings ORDER BY key"))
    finally:
        connection.close()


def assert_no_payload_backup(home: Path) -> None:
    unexpected = [item for item in home.rglob("*") if item.is_file() and item.name != MARKER_NAME and (item.name.endswith(".bak") or ".retired-project-usage-evidence" in item.name)]
    assert_true(not unexpected, "usage evidence purger 创建了 payload backup 或临时文件")


def cleanup(home: Path) -> None:
    reports = REPORTS_ROOT.resolve(strict=True)
    candidate = home.resolve(strict=True) if home.exists() else home
    assert_true(str(candidate).casefold().startswith(str(reports).casefold() + "\\"), "测试路径越出 reports")
    assert_true(candidate.parent.name.startswith(PREFIX), "测试前缀不匹配")
    if home.parent.exists():
        shutil.rmtree(home.parent)


def test_happy_path() -> None:
    home = fixture_home()
    try:
        create_database(home)
        before = read_rows(home)
        audit = run_purger(home, "--mode", "Audit", expected_status=1)
        assert_true(audit["findingCount"] == 1 and audit["details"]["blockedCount"] == 0, "Audit 未识别受控 config blob")
        missing_confirm = run_purger(home, "--mode", "Apply", expected_status=1)
        assert_true("confirm" in missing_confirm["error"].casefold(), "缺少确认的 Apply 未被拒绝")
        assert_true(read_rows(home) == before, "缺少确认的 Apply 修改了 DB")
        missing_cold = run_purger(home, "--mode", "Apply", "--confirm-retired-project", RETIRED_ID, expected_status=1)
        assert_true("cold-maintenance" in missing_cold["error"], "缺少 cold-maintenance 的 Apply 未被拒绝")
        assert_true(read_rows(home) == before, "无 cold-maintenance 的 Apply 修改了 DB")
        applied = run_purger(home, "--mode", "Apply", "--cold-maintenance", "--confirm-retired-project", RETIRED_ID, expected_status=0)
        assert_true(applied["ok"] is True and applied["changed"] is True and applied["details"]["changedRows"] == 1, "合法 Apply 未成功")
        assert_true(read_rows(home) == [("safe_config", "[feature]\nvalue = true\n")], "Apply 未精确删除受控 setting")
        post = run_purger(home, "--mode", "Audit", expected_status=0)
        assert_true(post["ok"] is True and post["findingCount"] == 0, "Apply 后 Audit 未归零")
        assert_no_payload_backup(home)
    finally:
        cleanup(home)


def test_fail_closed() -> None:
    for extra_marker, missing_schema in ((True, False), (False, True)):
        home = fixture_home()
        try:
            create_database(home, extra_marker=extra_marker, missing_schema=missing_schema)
            if missing_schema:
                result = run_purger(home, "--mode", "Audit", expected_status=1)
            else:
                before = read_rows(home)
                result = run_purger(home, "--mode", "Apply", "--cold-maintenance", "--confirm-retired-project", RETIRED_ID, expected_status=1)
                assert_true(read_rows(home) == before, "blocked Apply 修改了 DB")
            assert_true(result["ok"] is False, "不安全 schema/marker 未失败关闭")
            assert_no_payload_backup(home)
        finally:
            cleanup(home)


def test_hardlink_refusal() -> None:
    home = fixture_home()
    external = REPORTS_ROOT / f"{PREFIX}{uuid.uuid4().hex}" / "external.db"
    try:
        create_database(home)
        external.parent.mkdir(parents=True)
        shutil.copyfile(database_path(home), external)
        database_path(home).unlink()
        os.link(external, database_path(home))
        result = run_purger(home, "--mode", "Audit", expected_status=1)
        assert_true("普通文件" in result["error"], "hard link DB 未失败关闭")
        assert_true(external.exists(), "hard link 拒绝误伤外部 DB")
    finally:
        cleanup(home)
        if external.parent.exists():
            shutil.rmtree(external.parent)


def test_commit_time_cold_maintenance_recheck() -> None:
    home = fixture_home()
    try:
        create_database(home)
        before = read_rows(home)
        module = load_purger_module()
        calls = 0

        def reject_cold_maintenance() -> None:
            nonlocal calls
            calls += 1
            raise module.PurgerError("fixture simulated official Codex process")

        original = module.check_live_cold_maintenance
        module.check_live_cold_maintenance = reject_cold_maintenance
        try:
            try:
                module.apply(database_path(home), (RETIRED_ID,), require_live_cold_maintenance=True)
            except module.PurgerError as exc:
                assert_true("simulated" in str(exc), "提交前冷维护复核未传播拒绝")
            else:
                raise AssertionError("提交前冷维护复核应拒绝并回滚")
        finally:
            module.check_live_cold_maintenance = original
        assert_true(calls == 1, "提交前没有再次执行 cold-maintenance 进程核验")
        assert_true(read_rows(home) == before, "提交前 cold-maintenance 拒绝没有回滚 DB")
        assert_no_payload_backup(home)
    finally:
        cleanup(home)


def test_cold_maintenance_output_refusal() -> None:
    module = load_purger_module()
    original_assert_file = module.assert_ordinary_file
    original_run = module.subprocess.run

    class Completed:
        returncode = 0
        stdout = '"unexpected"'

    try:
        module.assert_ordinary_file = lambda path, _label: path
        module.subprocess.run = lambda *_args, **_kwargs: Completed()
        try:
            module.check_live_cold_maintenance()
        except module.PurgerError as exc:
            assert_true("输出无效" in str(exc), "非法 cold-maintenance 输出未失败关闭")
        else:
            raise AssertionError("非法 cold-maintenance 输出必须失败关闭")
    finally:
        module.assert_ordinary_file = original_assert_file
        module.subprocess.run = original_run


def main() -> int:
    assert_true(SCRIPT_PATH.is_file(), "缺少 usage evidence config purger")
    test_happy_path()
    test_fail_closed()
    test_hardlink_refusal()
    test_commit_time_cold_maintenance_recheck()
    test_cold_maintenance_output_refusal()
    print("Retired project usage-evidence config purger: PASS (exact setting deletion, cold transaction, confirmation, schema/foreign-marker/hardlink refusal)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
