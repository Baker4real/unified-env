#!/usr/bin/env python3
"""Delete the retired Codex configuration snapshot from CC Switch usage evidence.

Live writes require a confirmed cold-maintenance window and re-check the
official Codex process boundary immediately before committing the transaction.
"""

from __future__ import annotations

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import uuid
from typing import Any


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
LIVE_CODEX_HOME = Path(r"D:\Codex\.codex")
MANIFEST_PATH = PROJECT_ROOT / "managed" / "codex-hooks" / "host-preflight-manifest.json"
DATABASE_RELATIVE_PATH = Path("usage_evidence") / "ccswitch" / "cc-switch-latest.db"
SETTING_KEY = "common_config_codex"
FIXTURE_MARKER_NAME = ".retired-project-usage-evidence-purger-fixture"
FIXTURE_MARKER_VALUE = "retired-project-usage-evidence-purger-fixture-v1\n"
FIXTURE_PREFIX = "retired-project-usage-evidence-purger-tests-"


class PurgerError(RuntimeError):
    pass


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--mode", choices=("Audit", "Apply"), default="Audit")
    parser.add_argument("--confirm-retired-project", action="append", default=[])
    parser.add_argument("--fixture-root")
    parser.add_argument("--cold-maintenance", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--help", action="help")
    return parser.parse_args(argv)


def assert_ordinary_directory(path: Path, label: str) -> Path:
    try:
        stat = path.lstat()
    except FileNotFoundError as exc:
        raise PurgerError(f"{label} 不存在：{path}") from exc
    if path.is_symlink() or os.path.islink(path):
        raise PurgerError(f"{label} 是 reparse point 或 symlink：{path}")
    if not path.is_dir() or stat.st_nlink > 1:
        raise PurgerError(f"{label} 不是受支持的普通目录：{path}")
    return path.resolve(strict=True)


def assert_ordinary_file(path: Path, label: str) -> Path:
    try:
        stat = path.lstat()
    except FileNotFoundError as exc:
        raise PurgerError(f"{label} 不存在：{path}") from exc
    if path.is_symlink() or os.path.islink(path):
        raise PurgerError(f"{label} 是 reparse point 或 symlink：{path}")
    if not path.is_file() or stat.st_nlink > 1:
        raise PurgerError(f"{label} 不是受支持的普通文件：{path}")
    return path.resolve(strict=True)


def assert_physical_ancestry(path: Path, boundary: Path, label: str) -> None:
    current = path
    resolved_boundary = boundary.resolve(strict=True)
    while True:
        if not current.exists():
            raise PurgerError(f"{label} 的祖先不存在：{current}")
        if current.is_symlink() or os.path.islink(current):
            raise PurgerError(f"{label} 的祖先是 reparse point 或 symlink：{current}")
        if current.resolve(strict=True) == resolved_boundary:
            return
        if current.parent == current:
            raise PurgerError(f"{label} 越出受控根：{path}")
        current = current.parent


def resolve_scope(fixture_root: str | None) -> tuple[Path, Path, bool]:
    if fixture_root is None:
        root = assert_ordinary_directory(LIVE_CODEX_HOME, "live Codex home")
        database = root / DATABASE_RELATIVE_PATH
        assert_physical_ancestry(database.parent, root, "usage evidence database")
        return root, database, False
    reports = assert_ordinary_directory(PROJECT_ROOT / "reports", "项目 reports 根")
    root = assert_ordinary_directory(Path(fixture_root), "FixtureRoot")
    try:
        relative = root.relative_to(reports)
    except ValueError as exc:
        raise PurgerError("FixtureRoot 必须位于项目 reports 受控测试树。") from exc
    parts = relative.parts
    if len(parts) != 2 or not parts[0].startswith(FIXTURE_PREFIX) or parts[1] != ".codex":
        raise PurgerError("FixtureRoot 不在专用 usage evidence purger fixture 内。")
    suffix = parts[0][len(FIXTURE_PREFIX):]
    if len(suffix) != 32 or any(char not in "0123456789abcdef" for char in suffix):
        raise PurgerError("FixtureRoot fixture 标识不合法。")
    assert_physical_ancestry(root, reports, "FixtureRoot")
    marker = assert_ordinary_file(root / FIXTURE_MARKER_NAME, "Fixture marker")
    if marker.read_text(encoding="utf-8") != FIXTURE_MARKER_VALUE:
        raise PurgerError("Fixture marker 内容不匹配。")
    return root, root / DATABASE_RELATIVE_PATH, True


def load_retired_ids() -> tuple[str, ...]:
    manifest = json.loads(assert_ordinary_file(MANIFEST_PATH, "host preflight manifest").read_text(encoding="utf-8"))
    values = manifest.get("retiredProjectTrusts") if isinstance(manifest, dict) else None
    if not isinstance(values, list) or not values:
        raise PurgerError("host preflight manifest 的 retiredProjectTrusts 缺失或为空。")
    result: list[str] = []
    for value in values:
        if not isinstance(value, str):
            raise PurgerError("retiredProjectTrusts 含非字符串。")
        identifier = value.replace("/", "\\").rstrip("\\").rsplit("\\", 1)[-1].casefold()
        if not identifier or not identifier.replace("-", "").isalnum():
            raise PurgerError("retired project 标识不受支持。")
        result.append(identifier)
    if len(set(result)) != len(result):
        raise PurgerError("retired project 标识重复。")
    return tuple(result)


def check_live_cold_maintenance() -> None:
    """Reject a live write while any official Codex desktop process is running."""
    try:
        pwsh = assert_ordinary_file(Path(r"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe"), "固定 PowerShell runtime")
        command = (
            "$ErrorActionPreference='Stop';"
            "$root='C:\\Program Files\\WindowsApps\\OpenAI.Codex_';"
            "$items=@(Get-CimInstance Win32_Process | Where-Object { "
            "$_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) });"
            "$items | ForEach-Object { [int]$_.ProcessId } | ConvertTo-Json -Compress"
        )
        completed = subprocess.run(
            [str(pwsh), "-NoProfile", "-NonInteractive", "-Command", command],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, PurgerError) as exc:
        raise PurgerError("无法验证 Codex cold-maintenance 进程边界。") from exc
    if completed.returncode != 0:
        raise PurgerError("Codex cold-maintenance 进程核验失败。")
    text = completed.stdout.strip()
    if not text:
        return
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise PurgerError("Codex cold-maintenance 进程核验输出无效。") from exc
    pids = parsed if isinstance(parsed, list) else [parsed]
    if not isinstance(parsed, (int, list)) or any(isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0 for pid in pids):
        raise PurgerError("Codex cold-maintenance 进程核验输出无效。")
    if pids:
        raise PurgerError("仍有官方 Codex 进程，拒绝热修改 usage evidence。")


def open_database(path: Path, *, write: bool) -> sqlite3.Connection:
    database = assert_ordinary_file(path, "usage evidence database")
    if write:
        return sqlite3.connect(str(database), isolation_level=None, timeout=0)
    return sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True, isolation_level=None, timeout=0)


def assert_schema(connection: sqlite3.Connection) -> None:
    columns = {row[1]: row for row in connection.execute("PRAGMA table_info(settings)")}
    if not {"key", "value"}.issubset(columns):
        raise PurgerError("usage evidence settings schema 缺少 key/value。")
    indexes = list(connection.execute("PRAGMA index_list(settings)"))
    if not any(int(row[2]) == 1 for row in indexes):
        raise PurgerError("usage evidence settings 缺少唯一键，拒绝删除单条配置。")


def query_state(connection: sqlite3.Connection, identifiers: tuple[str, ...]) -> dict[str, int]:
    conditions = " OR ".join("instr(lower(value), ?) > 0" for _ in identifiers)
    parameters = tuple(identifiers)
    all_marker_rows = int(connection.execute(f"SELECT COUNT(*) FROM settings WHERE {conditions}", parameters).fetchone()[0])
    target_marker_rows = int(
        connection.execute(
            f"SELECT COUNT(*) FROM settings WHERE key = ? AND ({conditions})",
            (SETTING_KEY, *parameters),
        ).fetchone()[0]
    )
    target_rows = int(connection.execute("SELECT COUNT(*) FROM settings WHERE key = ?", (SETTING_KEY,)).fetchone()[0])
    return {"allMarkerRows": all_marker_rows, "targetMarkerRows": target_marker_rows, "targetRows": target_rows}


def audit(path: Path, identifiers: tuple[str, ...]) -> dict[str, Any]:
    with closing(open_database(path, write=False)) as connection:
        assert_schema(connection)
        state = query_state(connection, identifiers)
        integrity = [row[0] for row in connection.execute("PRAGMA integrity_check")]
        foreign_keys = list(connection.execute("PRAGMA foreign_key_check"))
    if integrity != ["ok"] or foreign_keys:
        raise PurgerError("usage evidence 完整性验证失败。")
    blocked = state["allMarkerRows"] - state["targetMarkerRows"]
    return {"state": state, "findingCount": state["targetMarkerRows"] + blocked, "blockedCount": blocked}


def apply(path: Path, identifiers: tuple[str, ...], *, require_live_cold_maintenance: bool) -> dict[str, Any]:
    with closing(open_database(path, write=True)) as connection:
        assert_schema(connection)
        before = query_state(connection, identifiers)
        if before["allMarkerRows"] != before["targetMarkerRows"]:
            raise PurgerError("usage evidence 还有不在受控 common_config_codex 的退休配置。")
        if before["targetMarkerRows"] > 1:
            raise PurgerError("common_config_codex 退休配置行数异常。")
        connection.execute("PRAGMA busy_timeout = 0")
        connection.execute("BEGIN IMMEDIATE")
        try:
            current = query_state(connection, identifiers)
            if current != before:
                raise PurgerError("usage evidence 在事务开始前发生变化，拒绝覆盖。")
            if before["targetMarkerRows"] == 1:
                cursor = connection.execute(
                    "DELETE FROM settings WHERE key = ?",
                    (SETTING_KEY,),
                )
                if int(cursor.rowcount) != 1:
                    raise PurgerError("common_config_codex 删除行数异常。")
            after = query_state(connection, identifiers)
            if after["allMarkerRows"] != 0 or after["targetRows"] != 0:
                raise PurgerError("usage evidence 退休配置未完全清除。")
            # A process can start after the caller's preflight. Re-check while
            # the SQLite transaction is still open so this path rolls back
            # instead of committing a hot write.
            if require_live_cold_maintenance:
                check_live_cold_maintenance()
            connection.execute("COMMIT")
        except BaseException:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            raise
        integrity = [row[0] for row in connection.execute("PRAGMA integrity_check")]
        foreign_keys = list(connection.execute("PRAGMA foreign_key_check"))
        if integrity != ["ok"] or foreign_keys:
            raise PurgerError("usage evidence 提交后完整性验证失败。")
    post = audit(path, identifiers)
    if post["findingCount"] != 0:
        raise PurgerError("usage evidence Apply 后 Audit 仍有退休配置。")
    return {"before": before, "after": post["state"], "changedRows": before["targetMarkerRows"]}


def make_result(*, ok: bool, mode: str, fixture: bool, path: Path | None, identifiers: tuple[str, ...], details: dict[str, Any] | None, changed: bool, error: str | None) -> dict[str, Any]:
    finding_count = 0 if details is None else int(details.get("findingCount", 0))
    return {
        "schemaVersion": 1,
        "ok": ok,
        "mode": mode,
        "fixture": fixture,
        "path": None if path is None else str(path),
        "retiredProjects": list(identifiers),
        "findingCount": finding_count,
        "changed": changed,
        "payloadBackupCreated": False,
        "backupPath": None,
        "details": details or {},
        "error": error,
    }


def main(argv: list[str]) -> int:
    args = parse_arguments(argv)
    path: Path | None = None
    fixture = False
    identifiers: tuple[str, ...] = ()
    try:
        _root, path, fixture = resolve_scope(args.fixture_root)
        identifiers = load_retired_ids()
        if args.mode == "Apply":
            confirmed = {value.casefold() for value in args.confirm_retired_project if value.strip()}
            if any(identifier not in confirmed for identifier in identifiers):
                raise PurgerError("Apply 必须为每个 retired project 显式传入 --confirm-retired-project。")
            if not args.cold_maintenance:
                raise PurgerError("Apply 必须显式传入 --cold-maintenance。")
            if not fixture:
                check_live_cold_maintenance()
            details = apply(path, identifiers, require_live_cold_maintenance=not fixture)
            payload = make_result(ok=True, mode=args.mode, fixture=fixture, path=path, identifiers=identifiers, details=details, changed=details["changedRows"] > 0, error=None)
        else:
            details = audit(path, identifiers)
            payload = make_result(ok=details["findingCount"] == 0, mode=args.mode, fixture=fixture, path=path, identifiers=identifiers, details=details, changed=False, error=None)
    except BaseException as exc:
        payload = make_result(ok=False, mode=args.mode, fixture=fixture, path=path, identifiers=identifiers, details=None, changed=False, error=str(exc))
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
