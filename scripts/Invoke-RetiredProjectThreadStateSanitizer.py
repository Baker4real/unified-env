#!/usr/bin/env python3
"""Remove retired-project metadata from Codex thread state without deleting threads.

The live database is only writable during a confirmed cold-maintenance window.
Fixture mode is deliberately constrained to the project's generated reports tree.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys
from dataclasses import dataclass
from typing import Any, Iterable


PROJECT_ROOT = Path(r"D:\agents\projects\统一环境")
LIVE_CODEX_HOME = Path(r"D:\Codex\.codex")
MANIFEST_PATH = PROJECT_ROOT / "managed" / "codex-hooks" / "host-preflight-manifest.json"
FIXTURE_MARKER_NAME = ".retired-project-thread-state-sanitizer-fixture"
FIXTURE_MARKER_VALUE = "retired-project-thread-state-sanitizer-fixture-v1\n"
FIXTURE_ROOT_PREFIX = "retired-project-thread-state-sanitizer-tests-"
NEUTRAL_LIVE_CWD = r"\\?\D:\Codex"
SCHEMA_VERSION = 1


class SanitizerError(RuntimeError):
    pass


@dataclass(frozen=True)
class Scope:
    root: Path
    database: Path
    neutral_cwd: str
    fixture: bool


@dataclass(frozen=True)
class RetiredProject:
    identifier: str
    root: str


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--mode", choices=("Audit", "Apply"), default="Audit")
    parser.add_argument("--confirm-retired-project", action="append", default=[])
    parser.add_argument("--fixture-root")
    parser.add_argument("--cold-maintenance", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--help", action="help")
    return parser.parse_args(argv)


def is_reparse_or_link(path: Path) -> bool:
    return path.is_symlink() or os.path.islink(path)


def assert_ordinary_directory(path: Path, label: str) -> Path:
    try:
        stat = path.lstat()
    except FileNotFoundError as exc:
        raise SanitizerError(f"{label} 不存在：{path}") from exc
    if is_reparse_or_link(path):
        raise SanitizerError(f"{label} 是 reparse point 或 symlink：{path}")
    if not path.is_dir():
        raise SanitizerError(f"{label} 不是普通目录：{path}")
    if stat.st_nlink > 1:
        raise SanitizerError(f"{label} 的 link count 异常：{path}")
    return path.resolve(strict=True)


def assert_ordinary_file(path: Path, label: str) -> Path:
    try:
        stat = path.lstat()
    except FileNotFoundError as exc:
        raise SanitizerError(f"{label} 不存在：{path}") from exc
    if is_reparse_or_link(path):
        raise SanitizerError(f"{label} 是 reparse point 或 symlink：{path}")
    if not path.is_file():
        raise SanitizerError(f"{label} 不是普通文件：{path}")
    if stat.st_nlink > 1:
        raise SanitizerError(f"{label} 是 hard link：{path}")
    return path.resolve(strict=True)


def assert_physical_ancestry(path: Path, boundary: Path, label: str) -> None:
    current = path
    boundary_resolved = boundary.resolve(strict=True)
    while True:
        if not current.exists():
            raise SanitizerError(f"{label} 的祖先不存在：{current}")
        if is_reparse_or_link(current):
            raise SanitizerError(f"{label} 的祖先是 reparse point 或 symlink：{current}")
        resolved = current.resolve(strict=True)
        if resolved == boundary_resolved:
            return
        parent = current.parent
        if parent == current:
            raise SanitizerError(f"{label} 越出受控根：{path}")
        current = parent


def assert_fixture_root(raw: str) -> Scope:
    reports_root = assert_ordinary_directory(PROJECT_ROOT / "reports", "项目 reports 根")
    candidate = Path(raw)
    if not candidate.is_absolute():
        raise SanitizerError("FixtureRoot 必须是绝对路径。")
    fixture_root = assert_ordinary_directory(candidate, "FixtureRoot")
    try:
        relative = fixture_root.relative_to(reports_root)
    except ValueError as exc:
        raise SanitizerError("FixtureRoot 必须位于项目 reports 受控测试树。") from exc
    parts = relative.parts
    if len(parts) != 2 or not parts[0].startswith(FIXTURE_ROOT_PREFIX) or parts[1] != ".codex":
        raise SanitizerError("FixtureRoot 不在专用 retired-project-thread-state-sanitizer fixture 内。")
    suffix = parts[0][len(FIXTURE_ROOT_PREFIX):]
    if len(suffix) != 32 or any(char not in "0123456789abcdef" for char in suffix):
        raise SanitizerError("FixtureRoot fixture 标识不合法。")
    assert_physical_ancestry(fixture_root, reports_root, "FixtureRoot")
    marker = assert_ordinary_file(fixture_root / FIXTURE_MARKER_NAME, "Fixture marker")
    if marker.read_text(encoding="utf-8") != FIXTURE_MARKER_VALUE:
        raise SanitizerError("Fixture marker 内容不匹配。")
    neutral_root = fixture_root / "neutral-host"
    assert_ordinary_directory(neutral_root, "Fixture neutral cwd")
    return Scope(
        root=fixture_root,
        database=fixture_root / "state_5.sqlite",
        neutral_cwd="\\\\?\\" + str(neutral_root),
        fixture=True,
    )


def assert_live_neutral_cwd() -> str:
    neutral = Path(r"D:\Codex")
    assert_ordinary_directory(neutral, "中性 Codex cwd")
    for prohibited in (".git", "AGENTS.md", "config.toml"):
        if (neutral / prohibited).exists():
            raise SanitizerError(f"中性 Codex cwd 不再是无项目根：{neutral / prohibited}")
    return NEUTRAL_LIVE_CWD


def resolve_scope(fixture_root: str | None) -> Scope:
    if fixture_root:
        return assert_fixture_root(fixture_root)
    root = assert_ordinary_directory(LIVE_CODEX_HOME, "live Codex home")
    database = root / "state_5.sqlite"
    assert_physical_ancestry(database.parent, root, "live thread-state 数据库")
    return Scope(root=root, database=database, neutral_cwd=assert_live_neutral_cwd(), fixture=False)


def normalise_windows_path(value: str) -> str:
    candidate = value.strip().replace("/", "\\")
    if candidate.startswith("\\\\?\\UNC\\"):
        candidate = "\\\\" + candidate[8:]
    elif candidate.startswith("\\\\?\\") or candidate.startswith("\\??\\"):
        candidate = candidate[4:]
    return candidate.rstrip("\\").casefold()


def load_retired_projects() -> tuple[RetiredProject, ...]:
    manifest_path = assert_ordinary_file(MANIFEST_PATH, "host preflight manifest")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SanitizerError("无法读取 host preflight manifest 中的 retiredProjectTrusts。") from exc
    values = manifest.get("retiredProjectTrusts") if isinstance(manifest, dict) else None
    if not isinstance(values, list) or not values:
        raise SanitizerError("host preflight manifest 的 retiredProjectTrusts 缺失或为空。")
    projects: list[RetiredProject] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str) or not value.strip():
            raise SanitizerError("retiredProjectTrusts 只能包含非空字符串。")
        root = normalise_windows_path(value)
        identifier = root.rsplit("\\", 1)[-1]
        if not identifier or not identifier.replace("-", "").isalnum():
            raise SanitizerError(f"retired project 标识不受支持：{value}")
        if identifier in seen:
            raise SanitizerError(f"retired project 标识重复：{identifier}")
        if not root.startswith("d:\\codex\\projects\\"):
            raise SanitizerError(f"retired project 不在受控 projects 根：{value}")
        seen.add(identifier)
        projects.append(RetiredProject(identifier=identifier, root=root))
    return tuple(projects)


def is_retired_cwd(value: Any, projects: tuple[RetiredProject, ...]) -> int:
    if not isinstance(value, str):
        return 0
    candidate = normalise_windows_path(value)
    return int(any(candidate == project.root or candidate.startswith(project.root + "\\") for project in projects))


def is_retired_origin(value: Any, projects: tuple[RetiredProject, ...]) -> int:
    if not isinstance(value, str):
        return 0
    candidate = value.casefold()
    return int(any(project.identifier in candidate for project in projects))


def register_matchers(connection: sqlite3.Connection, projects: tuple[RetiredProject, ...]) -> None:
    connection.create_function("retired_project_cwd", 1, lambda value: is_retired_cwd(value, projects), deterministic=True)
    connection.create_function("retired_project_origin", 1, lambda value: is_retired_origin(value, projects), deterministic=True)


def assert_thread_schema(connection: sqlite3.Connection) -> None:
    table = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'threads'"
    ).fetchone()
    if table is None:
        raise SanitizerError("thread state 缺少 threads table。")
    columns = {row[1]: row for row in connection.execute("PRAGMA table_info(threads)")}
    required = ("id", "cwd", "archived", "git_sha", "git_branch", "git_origin_url", "title", "first_user_message", "preview")
    missing = [name for name in required if name not in columns]
    if missing:
        raise SanitizerError("threads schema 缺少受控列：" + ",".join(missing))
    if int(columns["cwd"][3]) != 1:
        raise SanitizerError("threads.cwd 不再是 NOT NULL，拒绝套用当前清理契约。")


def query_counts(connection: sqlite3.Connection) -> dict[str, int]:
    rows = {
        "retiredCwd": "SELECT COUNT(*) FROM threads WHERE retired_project_cwd(cwd) = 1",
        "retiredCwdArchived": "SELECT COUNT(*) FROM threads WHERE retired_project_cwd(cwd) = 1 AND archived = 1",
        "retiredCwdNonArchived": "SELECT COUNT(*) FROM threads WHERE retired_project_cwd(cwd) = 1 AND archived <> 1",
        "retiredOrigin": "SELECT COUNT(*) FROM threads WHERE retired_project_origin(git_origin_url) = 1",
        "retiredOriginOutsideCwd": "SELECT COUNT(*) FROM threads WHERE retired_project_origin(git_origin_url) = 1 AND retired_project_cwd(cwd) = 0",
        "retiredOriginWithCwd": "SELECT COUNT(*) FROM threads WHERE retired_project_origin(git_origin_url) = 1 AND retired_project_cwd(cwd) = 1",
    }
    return {name: int(connection.execute(query).fetchone()[0]) for name, query in rows.items()}


def database_sidecar_sizes(database: Path) -> dict[str, int | None]:
    result: dict[str, int | None] = {}
    for suffix in ("", "-wal", "-shm", "-journal"):
        candidate = Path(str(database) + suffix)
        if candidate.exists():
            assert_ordinary_file(candidate, "thread state source")
            result[candidate.name] = candidate.stat().st_size
        else:
            result[candidate.name] = None
    return result


def check_live_cold_maintenance() -> None:
    # The caller's independent restart helper has already proven the complete
    # UI process tree absent. This guard rejects accidental hot invocation.
    try:
        import subprocess

        pwsh = Path(r"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe")
        assert_ordinary_file(pwsh, "固定 PowerShell runtime")
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
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, SanitizerError) as exc:
        raise SanitizerError("无法验证 Codex cold-maintenance 进程边界。") from exc
    if completed.returncode != 0:
        raise SanitizerError("Codex cold-maintenance 进程核验失败。")
    text = completed.stdout.strip()
    if text:
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise SanitizerError("Codex cold-maintenance 进程核验输出无效。") from exc
        pids = parsed if isinstance(parsed, list) else [parsed]
        if any(isinstance(pid, int) and pid > 0 for pid in pids):
            raise SanitizerError("仍有官方 Codex 进程，拒绝热修改 thread state。")


def assert_apply_confirmation(confirmations: Iterable[str], projects: tuple[RetiredProject, ...]) -> None:
    confirmed = {value.strip().casefold() for value in confirmations if isinstance(value, str) and value.strip()}
    missing = [project.identifier for project in projects if project.identifier not in confirmed]
    if missing:
        raise SanitizerError("Apply 必须为每个 retired project 显式传入 --confirm-retired-project。")


def open_database(scope: Scope, *, write: bool) -> sqlite3.Connection:
    database = assert_ordinary_file(scope.database, "thread state 数据库")
    assert_physical_ancestry(database.parent, scope.root, "thread state 数据库")
    database_sidecar_sizes(database)
    if write:
        return sqlite3.connect(str(database), isolation_level=None, timeout=0)
    return sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True, isolation_level=None, timeout=0)


def audit(scope: Scope, projects: tuple[RetiredProject, ...]) -> dict[str, Any]:
    with open_database(scope, write=False) as connection:
        register_matchers(connection, projects)
        assert_thread_schema(connection)
        counts = query_counts(connection)
        integrity = [row[0] for row in connection.execute("PRAGMA integrity_check")]
        foreign_keys = list(connection.execute("PRAGMA foreign_key_check"))
    if integrity != ["ok"]:
        raise SanitizerError("thread state integrity_check 未通过。")
    if foreign_keys:
        raise SanitizerError("thread state foreign_key_check 未通过。")
    return {
        "counts": counts,
        "findingCount": counts["retiredCwd"] + counts["retiredOrigin"],
        "sidecars": database_sidecar_sizes(scope.database),
    }


def apply(scope: Scope, projects: tuple[RetiredProject, ...]) -> dict[str, Any]:
    with open_database(scope, write=True) as connection:
        register_matchers(connection, projects)
        assert_thread_schema(connection)
        before = query_counts(connection)
        if before["retiredCwdNonArchived"] != 0:
            raise SanitizerError("退休 project 仍关联非 archived thread，拒绝改写。")
        if before["retiredOriginOutsideCwd"] != 0:
            raise SanitizerError("退休 git origin 存在于非退休 cwd thread，拒绝部分清理。")
        connection.execute("PRAGMA busy_timeout = 0")
        connection.execute("BEGIN IMMEDIATE")
        try:
            current = query_counts(connection)
            if current != before:
                raise SanitizerError("thread state 在事务开始前发生变化，拒绝覆盖。")
            cursor = connection.execute(
                """
                UPDATE threads
                SET cwd = ?, git_sha = NULL, git_branch = NULL, git_origin_url = NULL
                WHERE archived = 1 AND retired_project_cwd(cwd) = 1
                """,
                (scope.neutral_cwd,),
            )
            if int(cursor.rowcount) != before["retiredCwdArchived"]:
                raise SanitizerError("thread state 更新行数与审计不一致，拒绝部分提交。")
            after = query_counts(connection)
            if after["retiredCwd"] != 0 or after["retiredOrigin"] != 0:
                raise SanitizerError("thread state 结构化退休引用未完全清除。")
            neutral_count = int(
                connection.execute(
                    "SELECT COUNT(*) FROM threads WHERE archived = 1 AND cwd = ?",
                    (scope.neutral_cwd,),
                ).fetchone()[0]
            )
            neutral_git_count = int(
                connection.execute(
                    """
                    SELECT COUNT(*) FROM threads
                    WHERE archived = 1 AND cwd = ?
                      AND (git_sha IS NOT NULL OR git_branch IS NOT NULL OR git_origin_url IS NOT NULL)
                    """,
                    (scope.neutral_cwd,),
                ).fetchone()[0]
            )
            if neutral_count < before["retiredCwdArchived"] or neutral_git_count != 0:
                raise SanitizerError("中性 cwd 或 git 清理验证失败。")
            connection.execute("COMMIT")
        except BaseException:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            raise
        checkpoint = tuple(connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone())
        if len(checkpoint) != 3 or int(checkpoint[0]) != 0:
            raise SanitizerError("thread state WAL checkpoint 未完成。")
        integrity = [row[0] for row in connection.execute("PRAGMA integrity_check")]
        foreign_keys = list(connection.execute("PRAGMA foreign_key_check"))
        if integrity != ["ok"] or foreign_keys:
            raise SanitizerError("thread state 提交后完整性验证失败。")
    post = audit(scope, projects)
    if post["findingCount"] != 0:
        raise SanitizerError("thread state Apply 后 Audit 仍有退休引用。")
    return {
        "before": before,
        "after": post["counts"],
        "changedRows": before["retiredCwdArchived"],
        "walCheckpoint": {"busy": int(checkpoint[0]), "log": int(checkpoint[1]), "checkpointed": int(checkpoint[2])},
        "sidecars": post["sidecars"],
    }


def make_result(
    *,
    ok: bool,
    mode: str,
    scope: Scope | None,
    projects: tuple[RetiredProject, ...],
    finding_count: int,
    changed: bool,
    details: dict[str, Any] | None,
    error: str | None,
) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "ok": ok,
        "mode": mode,
        "fixture": False if scope is None else scope.fixture,
        "database": None if scope is None else str(scope.database),
        "retiredProjects": [project.identifier for project in projects],
        "neutralCwd": None if scope is None else scope.neutral_cwd,
        "findingCount": finding_count,
        "changed": changed,
        "payloadBackupCreated": False,
        "backupPath": None,
        "details": details or {},
        "error": error,
    }


def main(argv: list[str]) -> int:
    args = parse_arguments(argv)
    mode = args.mode
    scope: Scope | None = None
    projects: tuple[RetiredProject, ...] = ()
    try:
        scope = resolve_scope(args.fixture_root)
        projects = load_retired_projects()
        if mode == "Apply":
            assert_apply_confirmation(args.confirm_retired_project, projects)
            if not args.cold_maintenance:
                raise SanitizerError("Apply 必须显式传入 --cold-maintenance。")
            if not scope.fixture:
                check_live_cold_maintenance()
            details = apply(scope, projects)
            result = make_result(
                ok=True,
                mode=mode,
                scope=scope,
                projects=projects,
                finding_count=0,
                changed=details["changedRows"] > 0,
                details=details,
                error=None,
            )
        else:
            details = audit(scope, projects)
            result = make_result(
                ok=details["findingCount"] == 0,
                mode=mode,
                scope=scope,
                projects=projects,
                finding_count=details["findingCount"],
                changed=False,
                details=details,
                error=None,
            )
    except BaseException as exc:
        result = make_result(
            ok=False,
            mode=mode,
            scope=scope,
            projects=projects,
            finding_count=0,
            changed=False,
            details=None,
            error=str(exc),
        )
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
