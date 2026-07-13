from __future__ import annotations

import argparse
import copy
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import sqlite3
import sys
import tempfile
import time
from typing import Callable, TextIO
import uuid


PRODUCTION_CODEX_HOME = Path(r"D:\Codex\.codex")
PRODUCTION_HEALTH_ROOT = Path(r"D:\Codex\.codex\run-evidence\codex-hook-health")
FIXTURE_HEALTH_ROOT = Path(r"D:\Codex\projects\统一环境\reports\codex-state-policy-test\health")
MUTEX_NAME = r"Local\CodexGlobalStatePolicy"
MUTEX_TIMEOUT_MS = 1500
MAX_GLOBAL_ATTEMPTS = 3
DISABLED_SANDBOX = '{"type":"disabled"}'
SOURCE_PARTS = ("c:\\", "users", "windows", "documents", "codex")
DESTINATION_PARTS = ("D:\\", "Users", "WINDOWS", "Documents", "Codex")
TARGET_MAPS = (
    "thread-workspace-root-hints",
    "thread-projectless-output-directories",
)
FILE_ATTRIBUTE_REPARSE_POINT = 0x0400
LEGACY_DESTINATION_ROOT = PureWindowsPath(r"D:\Users\WINDOWS\Documents\Codex")


class StatePolicyError(RuntimeError):
    pass


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rewrite_projectless_path(value: object) -> object:
    if not isinstance(value, str):
        return value
    if value.startswith(("\\\\", "//")):
        return value
    raw_parts = re.split(r"[\\/]+", value)
    if any(part in (".", "..") for part in raw_parts):
        return value
    try:
        path = PureWindowsPath(value)
    except (TypeError, ValueError):
        return value
    if not path.is_absolute() or path.drive.casefold() != "c:" or path.root != "\\":
        return value
    parts = path.parts
    if len(parts) < len(SOURCE_PARTS):
        return value
    if tuple(part.casefold() for part in parts[: len(SOURCE_PARTS)]) != tuple(
        part.casefold() for part in SOURCE_PARTS
    ):
        return value
    return str(PureWindowsPath(*DESTINATION_PARTS, *parts[len(SOURCE_PARTS) :]))


def _windows_parts_casefold(path: PureWindowsPath) -> tuple[str, ...]:
    return tuple(part.casefold() for part in path.parts)


def _windows_is_same_or_child(path: PureWindowsPath, root: PureWindowsPath) -> bool:
    path_parts = _windows_parts_casefold(path)
    root_parts = _windows_parts_casefold(root)
    return len(path_parts) >= len(root_parts) and path_parts[: len(root_parts)] == root_parts


def _windows_relative_path(
    value: str,
    source_root: PureWindowsPath,
) -> tuple[str, ...] | None:
    try:
        source_path = PureWindowsPath(value)
    except (TypeError, ValueError):
        return None
    if not source_path.is_absolute() or not source_root.is_absolute():
        return None
    if source_path.drive.casefold() != source_root.drive.casefold():
        return None
    if any(part in (".", "..") for part in source_path.parts):
        return None
    source_parts = _windows_parts_casefold(source_path)
    root_parts = _windows_parts_casefold(source_root)
    if len(source_parts) < len(root_parts) or source_parts[: len(root_parts)] != root_parts:
        return None
    return tuple(source_path.parts[len(root_parts) :])


def _candidate_reparse(candidate: Path) -> bool:
    """Return whether an existing ancestor or the candidate is a reparse point."""
    lexical_chain: list[Path] = []
    current = candidate
    while True:
        lexical_chain.append(current)
        if current.parent == current:
            break
        current = current.parent
    for item in reversed(lexical_chain):
        try:
            metadata = item.lstat()
        except FileNotFoundError:
            continue
        except OSError:
            # An unreadable path cannot be treated as a safe canonical target.
            return True
        if item.is_symlink() or bool(
            getattr(metadata, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT
        ):
            return True
    return False


def _candidate_identity(candidate: Path) -> tuple[int, int] | None:
    try:
        metadata = candidate.stat()
    except OSError:
        return None
    device = int(getattr(metadata, "st_dev", 0))
    inode = int(getattr(metadata, "st_ino", 0))
    if device == 0 and inode == 0:
        return None
    return device, inode


def _path_inventory_entry(
    value: object,
    source_root: PureWindowsPath,
    candidate_root: Path,
    candidate_root_windows: PureWindowsPath,
) -> tuple[dict[str, object], tuple[int, int] | None]:
    source_hash = (
        hashlib.sha256(value.encode("utf-8")).hexdigest() if isinstance(value, str) else None
    )
    base: dict[str, object] = {
        "value": copy.deepcopy(value),
        "safe": False,
        "candidate": None,
        "reason": "unresolved-unknown-value",
        "reparse": False,
        "sourceSha256": source_hash,
    }
    if not isinstance(value, str):
        return base, None

    try:
        source_path = PureWindowsPath(value)
    except (TypeError, ValueError):
        base["reason"] = "unresolved-invalid-path"
        return base, None

    if _windows_is_same_or_child(source_path, LEGACY_DESTINATION_ROOT):
        base["reason"] = "unresolved-legacy-destination"
        return base, None

    relative_parts = _windows_relative_path(value, source_root)
    if relative_parts is None:
        base["reason"] = "unresolved-outside-source-root"
        return base, None

    # The historical destination is not a valid candidate, even when supplied
    # accidentally as the caller's candidate root.
    if _windows_is_same_or_child(candidate_root_windows, LEGACY_DESTINATION_ROOT):
        base["reason"] = "unresolved-legacy-destination"
        return base, None

    candidate = candidate_root.joinpath(*relative_parts)
    base["candidate"] = str(candidate)
    if _candidate_reparse(candidate):
        base["reason"] = "unresolved-reparse"
        base["reparse"] = True
        return base, None
    if not candidate.exists():
        base["reason"] = "unresolved-missing"
        return base, None
    identity = _candidate_identity(candidate)
    if identity is None:
        base["reason"] = "unresolved-identity"
        return base, None
    base["safe"] = True
    base["reason"] = "safe"
    return base, identity


def build_path_inventory(
    state: object,
    source_root: Path | str,
    candidate_root: Path | str,
) -> dict[str, object]:
    """Build a read-only, per-entry canonical path inventory.

    The function deliberately does not mutate *state* or touch any state file. It
    computes candidates only for the two known projectless maps. Unknown maps and
    values remain verbatim in the returned inventory for a later, explicit review.
    """
    if not isinstance(state, dict):
        raise StatePolicyError("global state root must be an object")
    try:
        source_root_windows = PureWindowsPath(str(source_root))
        candidate_root_windows = PureWindowsPath(str(candidate_root))
    except (TypeError, ValueError) as exc:
        raise StatePolicyError("path inventory roots are invalid") from exc
    if not source_root_windows.is_absolute():
        raise StatePolicyError("path inventory source root must be absolute")
    if not candidate_root_windows.is_absolute() or candidate_root_windows.drive.casefold() != "d:":
        raise StatePolicyError("path inventory candidate root must be an absolute D drive path")

    candidate_root_path = Path(candidate_root)
    maps: dict[str, dict[object, dict[str, object]]] = {}
    unknown: dict[object, object] = {}
    identities: dict[tuple[int, int], list[tuple[str, object]]] = {}

    for map_name, mapping in state.items():
        if map_name not in TARGET_MAPS or not isinstance(mapping, dict):
            unknown[map_name] = copy.deepcopy(mapping)
            continue
        inventory_map: dict[object, dict[str, object]] = {}
        maps[map_name] = inventory_map
        for identity, value in mapping.items():
            entry, final_identity = _path_inventory_entry(
                value,
                source_root_windows,
                candidate_root_path,
                candidate_root_windows,
            )
            inventory_map[identity] = entry
            if final_identity is not None:
                identities.setdefault(final_identity, []).append((map_name, identity))

    # A candidate that resolves to the same final filesystem identity as another
    # entry is not safe for an unreviewed one-to-one mapping. Keep both original
    # values and expose the ambiguity instead of choosing a winner.
    for final_identity, keys in identities.items():
        if len(keys) < 2:
            continue
        for map_name, identity in keys:
            entry = maps[map_name][identity]
            entry["safe"] = False
            entry["reason"] = "unresolved-ambiguous"

    return {
        "sourceRoot": str(source_root_windows),
        "candidateRoot": str(candidate_root_windows),
        "maps": maps,
        "unknown": unknown,
    }


def normalize_global_state(state: object) -> tuple[dict[str, object], dict[str, int]]:
    if not isinstance(state, dict):
        raise StatePolicyError("global state root must be an object")
    normalized = copy.deepcopy(state)
    path_changed = 0
    heartbeat_changed = 0
    for key in TARGET_MAPS:
        mapping = normalized.get(key)
        if not isinstance(mapping, dict):
            continue
        for identity, value in list(mapping.items()):
            replacement = rewrite_projectless_path(value)
            if replacement != value:
                mapping[identity] = replacement
                path_changed += 1

    atom = normalized.get("electron-persisted-atom-state")
    if isinstance(atom, dict):
        heartbeat = atom.get("heartbeat-thread-permissions-by-id")
        if isinstance(heartbeat, dict):
            for value in heartbeat.values():
                if not isinstance(value, dict):
                    continue
                sandbox = value.get("sandboxPolicy")
                sandbox_type = sandbox.get("type") if isinstance(sandbox, dict) else None
                if value.get("approvalPolicy") != "never" or sandbox_type != "dangerFullAccess":
                    value["activePermissionProfile"] = None
                    value["approvalPolicy"] = "never"
                    if not value.get("approvalsReviewer"):
                        value["approvalsReviewer"] = "user"
                    value["sandboxPolicy"] = {"type": "dangerFullAccess"}
                    heartbeat_changed += 1
    return normalized, {
        "pathChangedCount": path_changed,
        "heartbeatChangedCount": heartbeat_changed,
    }


def _strict_json_loads(data: bytes) -> dict[str, object]:
    try:
        text = data.decode("utf-8", errors="strict")

        def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
            result: dict[str, object] = {}
            for key, value in pairs:
                if key in result:
                    raise StatePolicyError("global state contains duplicate JSON keys")
                result[key] = value
            return result

        def reject_constant(_token: str) -> object:
            raise StatePolicyError("global state JSON is malformed")

        value = json.loads(
            text,
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except StatePolicyError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StatePolicyError("global state JSON is malformed") from exc
    if not isinstance(value, dict):
        raise StatePolicyError("global state root must be an object")
    return value


def _json_bytes(value: dict[str, object]) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise StatePolicyError("global state JSON serialization failed") from exc


def _fsync_parent(path: Path) -> None:
    if os.name != "nt":
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _write_same_directory_temp(path: Path, data: bytes) -> Path:
    descriptor, raw_path = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp_path = Path(raw_path)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        temp_path.unlink(missing_ok=True)
        raise
    return temp_path


def create_backup(backup_root: Path, original: bytes) -> Path:
    try:
        directory = backup_root / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}-{os.getpid()}-{uuid.uuid4().hex}"
        directory.mkdir(parents=True, exist_ok=False)
        path = directory / ".codex-global-state.json"
        temp = _write_same_directory_temp(path, original)
        os.replace(temp, path)
        _fsync_parent(path)
        return path
    except OSError as exc:
        raise StatePolicyError("global state backup failed") from exc


def update_global_state(
    path: Path,
    backup_root: Path,
    *,
    check_only: bool = False,
    max_attempts: int = MAX_GLOBAL_ATTEMPTS,
    before_prewrite_check: Callable[[int], None] | None = None,
) -> dict[str, object]:
    if not path.is_file():
        return {
            "status": "missing",
            "changed": False,
            "wouldChange": False,
            "changedCount": 0,
            "beforeSha256": None,
            "afterSha256": None,
            "attempts": 0,
        }
    if max_attempts != MAX_GLOBAL_ATTEMPTS:
        raise StatePolicyError("global state retry contract is fixed")
    for attempt in range(1, max_attempts + 1):
        original = path.read_bytes()
        before_hash = _sha256(original)
        state = _strict_json_loads(original)
        normalized, summary = normalize_global_state(state)
        changed_count = summary["pathChangedCount"] + summary["heartbeatChangedCount"]
        if changed_count == 0:
            return {
                "status": "converged",
                "changed": False,
                "wouldChange": False,
                "changedCount": 0,
                "beforeSha256": before_hash,
                "afterSha256": before_hash,
                "attempts": attempt,
                **summary,
            }
        if check_only:
            return {
                "status": "drift",
                "changed": False,
                "wouldChange": True,
                "changedCount": changed_count,
                "beforeSha256": before_hash,
                "afterSha256": before_hash,
                "attempts": attempt,
                **summary,
            }
        replacement = _json_bytes(normalized)
        temp_path = _write_same_directory_temp(path, replacement)
        try:
            try:
                create_backup(backup_root, original)
            except StatePolicyError:
                raise
            except OSError as exc:
                raise StatePolicyError("global state backup failed") from exc
            if before_prewrite_check is not None:
                before_prewrite_check(attempt)
            current = path.read_bytes()
            if _sha256(current) != before_hash:
                continue
            # A normal user-mode delete/replace can still race this final name-based
            # replacement. This is a bounded replay contract, not absolute CAS.
            os.replace(temp_path, path)
            _fsync_parent(path)
            published = path.read_bytes()
            if published != replacement:
                raise StatePolicyError("global state postwrite verification failed")
            _strict_json_loads(published)
            return {
                "status": "updated",
                "changed": True,
                "wouldChange": True,
                "changedCount": changed_count,
                "beforeSha256": before_hash,
                "afterSha256": _sha256(published),
                "attempts": attempt,
                **summary,
            }
        finally:
            temp_path.unlink(missing_ok=True)
    raise StatePolicyError("global state concurrent updates did not stabilize")


THREAD_DRIFT_SQL = """
select id from threads
where source='vscode'
  and (thread_source='user' or thread_source is null)
  and (
    approval_mode is null or approval_mode <> 'never'
    or sandbox_policy is null
    or sandbox_policy not in ('{"type":"disabled"}', 'danger-full-access')
  )
order by id
"""


def select_thread_updates(conn: sqlite3.Connection) -> list[str]:
    return [str(row[0]) for row in conn.execute(THREAD_DRIFT_SQL)]


def _capture_sqlite_source(path: Path) -> tuple[bytes | None, bytes | None, bytes | None, bytes | None]:
    paths = (
        path,
        Path(str(path) + "-wal"),
        Path(str(path) + "-shm"),
        Path(str(path) + "-journal"),
    )
    try:
        return tuple(candidate.read_bytes() if candidate.exists() else None for candidate in paths)
    except OSError as exc:
        raise StatePolicyError("thread state source snapshot is busy") from exc


def _assert_check_only_d_path_without_reparse(path: Path, *, name: str) -> None:
    windows_path = PureWindowsPath(str(path))
    if not windows_path.is_absolute() or windows_path.drive.casefold() != "d:":
        raise StatePolicyError(f"{name} must be an absolute D drive path")
    lexical_chain: list[Path] = []
    current = path
    while True:
        lexical_chain.append(current)
        if current.parent == current:
            break
        current = current.parent
    for candidate in reversed(lexical_chain):
        try:
            metadata = candidate.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise StatePolicyError(f"{name} path inspection failed") from exc
        if candidate.is_symlink() or bool(
            getattr(metadata, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT
        ):
            raise StatePolicyError(f"{name} path contains reparse point")


def _select_thread_updates_from_snapshot(
    path: Path,
    snapshot_root: Path,
    after_first_capture: Callable[[int], None] | None = None,
) -> tuple[list[str], int]:
    snapshot_windows_path = PureWindowsPath(str(snapshot_root))
    if not snapshot_windows_path.is_absolute() or snapshot_windows_path.drive.casefold() != "d:":
        raise StatePolicyError("thread state snapshot root must be an absolute D drive path")
    _assert_check_only_d_path_without_reparse(path, name="thread state source")
    _assert_check_only_d_path_without_reparse(snapshot_root, name="thread state snapshot root")
    for sidecar in (
        Path(str(path) + "-wal"),
        Path(str(path) + "-shm"),
        Path(str(path) + "-journal"),
    ):
        _assert_check_only_d_path_without_reparse(sidecar, name="thread state sidecar")
    created_roots: list[Path] = []
    candidate = snapshot_root
    while not candidate.exists():
        created_roots.append(candidate)
        candidate = candidate.parent
    try:
        snapshot_root.mkdir(parents=True, exist_ok=True)
        for attempt in range(1, MAX_GLOBAL_ATTEMPTS + 1):
            try:
                first = _capture_sqlite_source(path)
                if after_first_capture is not None:
                    after_first_capture(attempt)
                second = _capture_sqlite_source(path)
            except StatePolicyError:
                continue
            if first != second:
                continue
            database_bytes, wal_bytes, _shm_bytes, journal_bytes = first
            if database_bytes is None:
                raise StatePolicyError("thread state database disappeared during check")
            if journal_bytes is not None:
                # A rollback-journal writer can have uncommitted pages in the main
                # database. Refuse that snapshot rather than read or repair source.
                raise StatePolicyError("thread state rollback journal is active")
            snapshot_dir = Path(tempfile.mkdtemp(prefix="sqlite-check-", dir=snapshot_root))
            snapshot_db = snapshot_dir / "state.sqlite"
            try:
                snapshot_db.write_bytes(database_bytes)
                if wal_bytes is not None:
                    Path(str(snapshot_db) + "-wal").write_bytes(wal_bytes)
                # Deliberately omit the source SHM. SQLite may build/change SHM and
                # checkpoint only inside this D-drive disposable copy. The stable
                # DB+WAL pair retains committed, uncheckpointed rows without ever
                # opening the source database through SQLite.
                conn = sqlite3.connect(snapshot_db, timeout=1.5)
                try:
                    conn.execute("pragma busy_timeout=1500")
                    conn.execute("pragma query_only=on")
                    integrity_rows = [str(row[0]) for row in conn.execute("pragma quick_check")]
                    if not integrity_rows or any(value.casefold() != "ok" for value in integrity_rows):
                        raise StatePolicyError("thread state snapshot integrity check failed")
                    identities = select_thread_updates(conn)
                finally:
                    conn.close()
                try:
                    after_query = _capture_sqlite_source(path)
                except StatePolicyError:
                    continue
                if after_query != second:
                    continue
                return identities, len(integrity_rows)
            except sqlite3.Error as exc:
                raise StatePolicyError("thread state snapshot check failed") from exc
            finally:
                try:
                    shutil.rmtree(snapshot_dir)
                except OSError as exc:
                    raise StatePolicyError("thread state snapshot cleanup failed") from exc
                if snapshot_dir.exists():
                    raise StatePolicyError("thread state snapshot cleanup failed")
        raise StatePolicyError("thread state source did not stabilize for check")
    finally:
        for created_root in created_roots:
            try:
                created_root.rmdir()
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise StatePolicyError("thread state snapshot root cleanup failed") from exc


def update_thread_state(
    path: Path,
    *,
    check_only: bool = False,
    before_commit: Callable[[], None] | None = None,
    snapshot_root: Path | None = None,
    after_first_snapshot_capture: Callable[[int], None] | None = None,
) -> dict[str, object]:
    if not path.is_file():
        return {"status": "missing", "changedCount": 0, "wouldChangeCount": 0, "driftCount": 0}
    if not isinstance(DISABLED_SANDBOX, str):
        raise StatePolicyError("thread state policy constant is invalid")
    if check_only:
        if snapshot_root is None:
            raise StatePolicyError("thread state check snapshot root is required")
        identities, integrity_result_count = _select_thread_updates_from_snapshot(
            path,
            snapshot_root,
            after_first_capture=after_first_snapshot_capture,
        )
        return {
            "status": "drift" if identities else "converged",
            "changedCount": 0,
            "wouldChangeCount": len(identities),
            "driftCount": len(identities),
            "integrityOk": True,
            "integrityResultCount": integrity_result_count,
        }
    conn = sqlite3.connect(path, timeout=1.5)
    try:
        conn.execute("pragma busy_timeout=1500")
        try:
            conn.execute("begin immediate")
        except sqlite3.OperationalError as exc:
            raise StatePolicyError("thread state database busy") from exc
        try:
            identities = select_thread_updates(conn)
            if identities:
                conn.execute(
                    """
                    update threads set approval_mode='never', sandbox_policy=?
                    where source='vscode'
                      and (thread_source='user' or thread_source is null)
                      and (
                        approval_mode is null or approval_mode <> 'never'
                        or sandbox_policy is null
                        or sandbox_policy not in ('{"type":"disabled"}', 'danger-full-access')
                      )
                    """,
                    (DISABLED_SANDBOX,),
                )
            drift_count = int(conn.execute(f"select count(*) from ({THREAD_DRIFT_SQL})").fetchone()[0])
            if drift_count:
                raise StatePolicyError("thread state drift remains before commit")
            if before_commit is not None:
                before_commit()
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        verify_count = int(conn.execute(f"select count(*) from ({THREAD_DRIFT_SQL})").fetchone()[0])
        if verify_count:
            raise StatePolicyError("thread state postcommit drift remains")
        return {
            "status": "updated" if identities else "converged",
            "changedCount": len(identities),
            "wouldChangeCount": len(identities),
            "driftCount": verify_count,
        }
    except StatePolicyError:
        raise
    except sqlite3.OperationalError as exc:
        if "locked" in str(exc).lower() or "busy" in str(exc).lower():
            raise StatePolicyError("thread state database busy") from exc
        raise StatePolicyError("thread state database operation failed") from exc
    finally:
        conn.close()


class WindowsNamedMutex:
    WAIT_OBJECT_0 = 0
    WAIT_ABANDONED = 0x80
    WAIT_TIMEOUT = 0x102

    def __init__(self, name: str = MUTEX_NAME, timeout_ms: int = MUTEX_TIMEOUT_MS) -> None:
        self.name = name
        self.timeout_ms = timeout_ms
        self.handle: int | None = None

    def __enter__(self) -> "WindowsNamedMutex":
        if os.name != "nt":
            return self
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.argtypes = (ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR)
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        kernel32.WaitForSingleObject.restype = wintypes.DWORD
        kernel32.ReleaseMutex.argtypes = (wintypes.HANDLE,)
        kernel32.ReleaseMutex.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel32.CloseHandle.restype = wintypes.BOOL
        handle = kernel32.CreateMutexW(None, False, self.name)
        if not handle:
            raise StatePolicyError("state policy mutex creation failed")
        self.handle = handle
        result = kernel32.WaitForSingleObject(handle, self.timeout_ms)
        if result not in (self.WAIT_OBJECT_0, self.WAIT_ABANDONED):
            kernel32.CloseHandle(handle)
            self.handle = None
            if result == self.WAIT_TIMEOUT:
                raise StatePolicyError("state policy mutex busy")
            raise StatePolicyError("state policy mutex wait failed")
        return self

    def __exit__(self, *_args: object) -> None:
        if os.name == "nt" and self.handle is not None:
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.ReleaseMutex.argtypes = (wintypes.HANDLE,)
            kernel32.ReleaseMutex.restype = wintypes.BOOL
            kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
            kernel32.CloseHandle.restype = wintypes.BOOL
            kernel32.ReleaseMutex(self.handle)
            kernel32.CloseHandle(self.handle)
            self.handle = None


def _write_health(path: Path, envelope: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _json_bytes(envelope)
    temp = _write_same_directory_temp(path, data)
    try:
        os.replace(temp, path)
        _fsync_parent(path)
    finally:
        temp.unlink(missing_ok=True)


def _safe_error(exc: BaseException) -> str:
    known = str(exc).lower()
    if "busy" in known:
        return "state policy resource busy"
    if "malformed" in known or "json" in known:
        return "global state validation failed"
    if "backup" in known:
        return "global state backup failed"
    if "concurrent" in known:
        return "global state concurrent update limit reached"
    return "state policy operation failed"


def run_policy(
    codex_home: Path,
    *,
    check_only: bool,
    health_root: Path,
    output: TextIO = sys.stdout,
    write_health: bool | None = None,
) -> dict[str, object]:
    if write_health is None:
        write_health = not check_only
    started = datetime.now(timezone.utc)
    started_clock = time.monotonic()
    run_id = uuid.uuid4().hex
    errors: list[str] = []
    global_result: dict[str, object] = {"status": "not-run", "changed": False, "changedCount": 0}
    thread_result: dict[str, object] = {"status": "not-run", "changedCount": 0, "wouldChangeCount": 0, "driftCount": 0}
    try:
        with WindowsNamedMutex():
            global_result = update_global_state(
                codex_home / ".codex-global-state.json",
                codex_home / "backups_state" / "codex-state-policy",
                check_only=check_only,
            )
            production_home = _resolved_casefold(codex_home) == _resolved_casefold(PRODUCTION_CODEX_HOME)
            snapshot_root = (
                codex_home / "tmp" / "codex-state-policy-check"
                if production_home
                else health_root / "sqlite-snapshots"
            )
            thread_result = update_thread_state(
                codex_home / "state_5.sqlite",
                check_only=check_only,
                snapshot_root=snapshot_root if check_only else None,
            )
        ok = True
    except BaseException as exc:
        ok = False
        errors.append(_safe_error(exc))
    changed = bool(global_result.get("changed")) or int(thread_result.get("changedCount", 0)) > 0
    restart_required = changed
    global_drift_count = (
        int(global_result.get("changedCount", 0))
        if check_only and bool(global_result.get("wouldChange"))
        else 0
    )
    thread_drift_count = int(thread_result.get("driftCount", 0))
    drift_count = global_drift_count + thread_drift_count
    converged = ok and drift_count == 0
    payload: dict[str, object] = {
        "hookId": "codex-state-policy",
        "ok": ok,
        "changed": changed,
        "converged": converged,
        "driftCount": drift_count,
        "globalState": {
            "status": global_result.get("status"),
            "changedCount": int(global_result.get("changedCount", 0)),
            "beforeSha256": global_result.get("beforeSha256"),
            "afterSha256": global_result.get("afterSha256"),
        },
        "threadState": {
            "status": thread_result.get("status"),
            "changedCount": int(thread_result.get("changedCount", 0)),
            "driftCount": int(thread_result.get("driftCount", 0)),
            "integrityOk": bool(thread_result.get("integrityOk", False)),
            "integrityResultCount": int(thread_result.get("integrityResultCount", 0)),
        },
        "restartRequired": restart_required,
        "errors": errors,
    }
    completed = datetime.now(timezone.utc)
    health: dict[str, object] = {
        "hookId": "codex-state-policy",
        "runId": run_id,
        "startedAtUtc": started.isoformat(),
        "completedAtUtc": completed.isoformat(),
        "durationMs": int((time.monotonic() - started_clock) * 1000),
        "ok": ok,
        "changed": changed,
        "restartRequired": restart_required,
        "errors": errors,
    }
    if write_health:
        try:
            _write_health(health_root / "codex-state-policy.json", health)
        except OSError:
            errors.append("state policy health write failed")
            payload["ok"] = False
            payload["errors"] = errors
    output.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    return payload


def _resolved_casefold(path: Path) -> str:
    return str(path.resolve(strict=False)).casefold()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", default=str(PRODUCTION_CODEX_HOME))
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--health-root")
    args = parser.parse_args(argv)
    codex_home = Path(args.codex_home)
    is_production = _resolved_casefold(codex_home) == _resolved_casefold(PRODUCTION_CODEX_HOME)
    if args.check_only:
        health_root = Path(args.health_root) if args.health_root else FIXTURE_HEALTH_ROOT
        if _resolved_casefold(health_root) != _resolved_casefold(FIXTURE_HEALTH_ROOT):
            raise StatePolicyError("check-only health root is not the fixed fixture root")
    else:
        if not is_production or args.health_root is not None:
            raise StatePolicyError("write mode is restricted to the fixed production entry")
        health_root = PRODUCTION_HEALTH_ROOT
    output = sys.stdout if args.json else io.StringIO()
    payload = run_policy(
        codex_home,
        check_only=args.check_only,
        health_root=health_root,
        output=output,
        write_health=not args.check_only,
    )
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StatePolicyError as exc:
        print(json.dumps({"ok": False, "errors": [_safe_error(exc)]}, separators=(",", ":")))
        raise SystemExit(1)
