from __future__ import annotations

import argparse
import copy
from contextvars import ContextVar
import ctypes
from ctypes import wintypes
from dataclasses import dataclass
from datetime import datetime, timezone

try:
    import fcntl
except ModuleNotFoundError:  # pragma: no cover - Windows uses CreateFileW below.
    fcntl = None  # type: ignore[assignment]
import hashlib
import io
import json
import mmap
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

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.11+ is required in production.
    tomllib = None  # type: ignore[assignment]


PRODUCTION_CODEX_HOME = Path(r"D:\Codex\.codex")
PRODUCTION_HEALTH_ROOT = Path(r"D:\agents\run-evidence\codex-hook-health")
FIXTURE_HEALTH_ROOT = Path(r"D:\agents\projects\统一环境\reports\codex-state-policy-test\health")
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
FILE_ATTRIBUTE_NORMAL = 0x0080
LEGACY_DESTINATION_ROOT = PureWindowsPath(r"D:\Users\WINDOWS\Documents\Codex")
PROJECTLESS_SOURCE_ROOT = PureWindowsPath(r"C:\Users\WINDOWS\Documents\Codex")
CANONICAL_CANDIDATE_ROOT = PureWindowsPath(r"D:\Documents\Codex")
INVENTORY_REPAIR_CONTRACT = "generation-hash-mutex-cas-reprobe"
APPROVED_MAP_FIELDS = frozenset(
    {"inventoryGeneration", "stateSha256", "mappingSha256", "mappings"}
)
FILE_ATTRIBUTE_DIRECTORY = 0x0010
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
DELETE_ACCESS = 0x00010000
SYNCHRONIZE_ACCESS = 0x00100000
FILE_READ_ATTRIBUTES = 0x0080
FILE_SHARE_READ = 0x00000001
FILE_SHARE_WRITE = 0x00000002
FILE_SHARE_DELETE = 0x00000004
OPEN_EXISTING = 3
CREATE_NEW = 1
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
FILE_FLAG_DELETE_ON_CLOSE = 0x04000000
LOCKFILE_FAIL_IMMEDIATELY = 0x00000001
LOCKFILE_EXCLUSIVE_LOCK = 0x00000002
# SQLite's WAL-index reserves eight bytes at this offset for its writer,
# checkpoint/recovery and reader locks.  A shared-memory lease must leave
# those bytes to SQLite while covering the data ranges around them.
SQLITE_SHM_LOCK_OFFSET = 120
SQLITE_SHM_LOCK_LENGTH = 8
COLD_MAINTENANCE_EVIDENCE_VERSION = "codex-state-cold-maintenance-v2"
COLD_MAINTENANCE_REQUIRED = "cold-maintenance-required"
ERROR_FILE_NOT_FOUND = 2
ERROR_PATH_NOT_FOUND = 3
ERROR_FILE_EXISTS = 80
SHORT_LEXICAL_SEGMENT = re.compile(r"^[^\\/]{1,8}~[0-9]+(?:\.[^\\/]+)?$", re.IGNORECASE)
FILE_RENAME_INFORMATION_EX = 65
FILE_RENAME_REPLACE_IF_EXISTS = 0x00000001
FILE_RENAME_POSIX_SEMANTICS = 0x00000002
MOVEFILE_REPLACE_EXISTING = 0x00000001
MOVEFILE_WRITE_THROUGH = 0x00000008
_ACTIVE_POLICY_SOURCE_LEASE: object | None = None
_ACTIVE_SQLITE_MISSING_SIDECAR_LEASES: ContextVar[tuple[object, ...]] = ContextVar(
    "active_sqlite_missing_sidecar_leases",
    default=(),
)


class _ByHandleFileInformation(ctypes.Structure):
    _fields_ = [
        ("file_attributes", wintypes.DWORD),
        ("creation_time", wintypes.FILETIME),
        ("last_access_time", wintypes.FILETIME),
        ("last_write_time", wintypes.FILETIME),
        ("volume_serial_number", wintypes.DWORD),
        ("file_size_high", wintypes.DWORD),
        ("file_size_low", wintypes.DWORD),
        ("number_of_links", wintypes.DWORD),
        ("file_index_high", wintypes.DWORD),
        ("file_index_low", wintypes.DWORD),
    ]


class _FileDispositionInfo(ctypes.Structure):
    _fields_ = [("delete_file", ctypes.c_ubyte)]


class _Overlapped(ctypes.Structure):
    _fields_ = [
        ("internal", ctypes.c_void_p),
        ("internal_high", ctypes.c_void_p),
        ("offset", wintypes.DWORD),
        ("offset_high", wintypes.DWORD),
        ("event", wintypes.HANDLE),
    ]


@dataclass(frozen=True)
class _LockedRange:
    overlap: _Overlapped
    offset: int
    length: int


@dataclass(frozen=True)
class _ByteRangeLease:
    ranges: tuple[_LockedRange, ...]


class _IoStatusBlock(ctypes.Structure):
    _fields_ = [
        ("status", ctypes.c_void_p),
        ("information", ctypes.c_size_t),
    ]


class StatePolicyError(RuntimeError):
    pass


@dataclass(frozen=True)
class PermissionPolicy:
    """The single, explicitly sourced permission policy for both state domains."""

    approval_policy: str
    sandbox_mode: str
    source: str
    source_hashes: tuple[tuple[str, str], ...] = ()
    codex_home: str | None = None
    source_identities: tuple[tuple[str, tuple[int, int]], ...] = ()
    source_values: tuple[tuple[str, str | None, str | None], ...] = ()

    def __post_init__(self) -> None:
        if (
            not isinstance(self.approval_policy, str)
            or self.approval_policy not in SUPPORTED_APPROVAL_POLICIES
        ):
            raise StatePolicyError("permission policy approval is unsupported")
        if (
            not isinstance(self.sandbox_mode, str)
            or self.sandbox_mode not in SUPPORTED_SANDBOX_MODES
        ):
            raise StatePolicyError("permission policy sandbox is unsupported")
        if not isinstance(self.source, str) or not self.source:
            raise StatePolicyError("permission policy source is missing")
        if not isinstance(self.source_hashes, tuple) or not self.source_hashes:
            raise StatePolicyError("permission policy source hash is missing")
        if not isinstance(self.codex_home, str) or not self.codex_home:
            raise StatePolicyError("permission policy home is missing")
        try:
            home_path = PureWindowsPath(self.codex_home)
        except (TypeError, ValueError) as exc:
            raise StatePolicyError("permission policy home is malformed") from exc
        if (
            not home_path.is_absolute()
            or home_path.drive.casefold() != "d:"
            or _path_lexical_issue(self.codex_home, home_path) is not None
        ):
            raise StatePolicyError("permission policy home is not a canonical D drive path")
        if not isinstance(self.source_identities, tuple) or len(self.source_identities) != len(self.source_hashes):
            raise StatePolicyError("permission policy source identity is missing")
        seen: set[str] = set()
        allowed_sources = {
            _windows_parts_casefold(PureWindowsPath(str(home_path / "config.toml"))),
            *(
                _windows_parts_casefold(PureWindowsPath(str(home_path / name)))
                for name in PERMISSION_POLICY_JSON_NAMES
            ),
        }
        for item in self.source_hashes:
            if not isinstance(item, tuple) or len(item) != 2:
                raise StatePolicyError("permission policy source hash is malformed")
            source, digest = item
            if not isinstance(source, str) or not isinstance(digest, str):
                raise StatePolicyError("permission policy source hash is malformed")
            source_path = PureWindowsPath(source)
            if (
                not source_path.is_absolute()
                or source_path.drive.casefold() != "d:"
                or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or source in seen
                or _windows_parts_casefold(source_path) not in allowed_sources
            ):
                raise StatePolicyError("permission policy source hash is malformed")
            seen.add(source)
        identity_sources: set[str] = set()
        for item in self.source_identities:
            if not isinstance(item, tuple) or len(item) != 2:
                raise StatePolicyError("permission policy source identity is malformed")
            source, identity = item
            if (
                not isinstance(source, str)
                or not isinstance(identity, tuple)
                or len(identity) != 2
                or not all(isinstance(value, int) and value >= 0 for value in identity)
                or source not in seen
                or source in identity_sources
            ):
                raise StatePolicyError("permission policy source identity is malformed")
            identity_sources.add(source)
        if identity_sources != seen:
            raise StatePolicyError("permission policy source identity is missing")
        if not isinstance(self.source_values, tuple) or len(self.source_values) != len(self.source_hashes):
            raise StatePolicyError("permission policy source values are missing")
        value_sources: set[str] = set()
        for item in self.source_values:
            if not isinstance(item, tuple) or len(item) != 3:
                raise StatePolicyError("permission policy source values are malformed")
            source, approval, sandbox = item
            if (
                not isinstance(source, str)
                or source not in seen
                or source in value_sources
                or (approval is not None and approval not in SUPPORTED_APPROVAL_POLICIES)
                or (sandbox is not None and sandbox not in SUPPORTED_SANDBOX_MODES)
            ):
                raise StatePolicyError("permission policy source values are malformed")
            value_sources.add(source)
        if value_sources != seen:
            raise StatePolicyError("permission policy source values are missing")
        if {
            approval for _source, approval, _sandbox in self.source_values if approval is not None
        } != {self.approval_policy}:
            raise StatePolicyError("permission policy source values conflict")
        if {
            sandbox for _source, _approval, sandbox in self.source_values if sandbox is not None
        } != {self.sandbox_mode}:
            raise StatePolicyError("permission policy source values conflict")

    @property
    def heartbeat_sandbox_type(self) -> str:
        return {
            "read-only": "readOnly",
            "workspace-write": "workspaceWrite",
            "danger-full-access": "dangerFullAccess",
        }[self.sandbox_mode]

    @property
    def sqlite_sandbox_policy(self) -> str:
        # The SQLite state stores the unrestricted mode as the internal disabled
        # sandbox object, while the other modes use the same JSON type spelling.
        if self.sandbox_mode == "danger-full-access":
            return '{"type":"disabled"}'
        return json.dumps({"type": self.sandbox_mode}, separators=(",", ":"))

    def as_dict(self) -> dict[str, str]:
        return {
            "approvalPolicy": self.approval_policy,
            "sandboxMode": self.sandbox_mode,
            "source": self.source,
        }


@dataclass(frozen=True)
class SqliteSourceSnapshot:
    """Bytes plus path/identity metadata for a SQLite database and sidecars."""

    payload: tuple[bytes | None, bytes | None, bytes | None, bytes | None]
    identities: tuple[
        tuple[int, int] | None,
        tuple[int, int] | None,
        tuple[int, int] | None,
        tuple[int, int] | None,
    ]
    metadata: tuple[
        tuple[bool, int | None, int | None, tuple[int, int] | None],
        tuple[bool, int | None, int | None, tuple[int, int] | None],
        tuple[bool, int | None, int | None, tuple[int, int] | None],
        tuple[bool, int | None, int | None, tuple[int, int] | None],
    ]
    content_known: tuple[bool, bool, bool, bool] = (True, True, True, True)

    def __iter__(self):
        # Preserve the old unpacking contract for snapshot fixture code.
        return iter(self.payload)


SUPPORTED_APPROVAL_POLICIES = frozenset(
    {"untrusted", "on-failure", "on-request", "never"}
)
SUPPORTED_SANDBOX_MODES = frozenset(
    {"read-only", "workspace-write", "danger-full-access"}
)
PERMISSION_POLICY_JSON_NAMES = ("policy.json", "state-policy.json")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_json_bytes(value: object) -> bytes:
    try:
        text = json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
            allow_nan=False,
        )
        try:
            return text.encode("utf-8")
        except UnicodeEncodeError:
            # ASCII escaping keeps lone-surrogate evidence hashable without
            # attempting to emit invalid UTF-8.  The original state bytes are
            # still preserved and never rewritten for such unresolved values.
            return json.dumps(
                value,
                ensure_ascii=True,
                separators=(",", ":"),
                sort_keys=True,
                allow_nan=False,
            ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise StatePolicyError("state generation serialization failed") from exc


def _inventory_hashes(state: dict[str, object]) -> tuple[str, str]:
    state_hash = _sha256(_canonical_json_bytes(state))
    mapping = {key: copy.deepcopy(state[key]) for key in TARGET_MAPS if key in state}
    mapping_hash = _sha256(_canonical_json_bytes(mapping))
    return state_hash, mapping_hash


def _is_projectless_source_value(value: str) -> bool:
    normalized = value.replace("/", "\\")
    for prefix in ("\\\\?\\", "\\\\.\\"):
        if normalized.startswith(prefix):
            normalized = normalized[len(prefix) :]
            break
    source = str(PROJECTLESS_SOURCE_ROOT).rstrip("\\").casefold()
    normalized = normalized.casefold()
    return normalized == source or normalized.startswith(source + "\\")


def _is_legacy_destination_value(value: str) -> bool:
    normalized = value.replace("/", "\\")
    for prefix in ("\\\\?\\", "\\\\.\\"):
        if normalized.startswith(prefix):
            normalized = normalized[len(prefix) :]
            break
    try:
        path = PureWindowsPath(normalized)
    except (TypeError, ValueError):
        return False
    return _windows_is_same_or_child(path, LEGACY_DESTINATION_ROOT)


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


def _is_reserved_device_component(value: str) -> bool:
    normalized = value.rstrip(" .")
    base = normalized.split(".", 1)[0].upper()
    if base in {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$"}:
        return True
    if len(base) == 4 and base[:3] in {"COM", "LPT"} and base[3] in "123456789":
        return True
    return base in {"COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"}


def _path_lexical_issue(value: str, path: PureWindowsPath) -> str | None:
    """Return a conservative reason for a non-canonical Windows spelling."""
    if "\x00" in value:
        return "invalid"
    try:
        value.encode("utf-8")
    except UnicodeError:
        return "invalid"
    if value.startswith(("\\\\?\\", "\\\\.\\")):
        return "alternate"
    raw_parts = re.split(r"[\\/]+", value)
    for raw_index, raw_part in enumerate(raw_parts):
        if not raw_part:
            continue
        if raw_part in (".", ".."):
            return "alternate"
        if _is_reserved_device_component(raw_part):
            return "device"
        if SHORT_LEXICAL_SEGMENT.fullmatch(raw_part):
            return "alternate"
        if raw_index > 0 and ":" in raw_part:
            return "alternate"
        if raw_part.endswith((".", " ")):
            return "alternate"
    for index, part in enumerate(path.parts):
        if index == 0:
            continue
        if part in (".", ".."):
            return "alternate"
        if _is_reserved_device_component(part):
            return "device"
        if SHORT_LEXICAL_SEGMENT.fullmatch(part):
            return "alternate"
        if ":" in part or part.endswith((".", " ")):
            return "alternate"
    return None


def _validate_inventory_root(
    value: Path | str,
    *,
    name: str,
    required_drive: str | None = None,
) -> PureWindowsPath:
    try:
        raw = os.fspath(value)
    except TypeError as exc:
        raise StatePolicyError(f"{name} must be a path string") from exc
    if not isinstance(raw, str):
        raise StatePolicyError(f"{name} must be a path string")
    try:
        path = PureWindowsPath(raw)
    except (TypeError, ValueError) as exc:
        raise StatePolicyError(f"{name} is invalid") from exc
    issue = _path_lexical_issue(raw, path)
    if issue is not None:
        raise StatePolicyError(f"{name} uses a non-canonical lexical path")
    if not path.is_absolute():
        raise StatePolicyError(f"{name} must be absolute")
    if path.drive.startswith("\\\\"):
        raise StatePolicyError(f"{name} must not use a UNC path")
    if required_drive is not None and path.drive.casefold() != required_drive.casefold():
        raise StatePolicyError(f"{name} must use the {required_drive} drive")
    return path


def _normalise_handle_path(value: str) -> str:
    unc_prefix = "\\\\?\\UNC\\"
    device_prefix = "\\\\?\\"
    if value.startswith(unc_prefix):
        return "\\\\" + value[len(unc_prefix) :]
    if value.startswith(device_prefix):
        return value[len(device_prefix) :]
    return value


def _path_compare_key(value: str) -> str:
    normalised = _normalise_handle_path(value)
    if len(normalised) == 3 and normalised[1:] == ":\\":
        return normalised.casefold()
    return normalised.rstrip("\\/").casefold()


def _probe_candidate(candidate: Path, *, require_directory: bool = False) -> dict[str, object]:
    """Open every candidate segment with OPEN_REPARSE_POINT and verify its handle."""
    default: dict[str, object] = {
        "state": "probe-error",
        "reparse": False,
        "finalPathVerified": False,
        "identity": None,
        "advisoryOnly": True,
    }
    if os.name != "nt":
        default["error"] = "Windows handle probe is unavailable"
        return default
    try:
        candidate_windows = PureWindowsPath(str(candidate))
        if not candidate_windows.is_absolute() or candidate_windows.drive.casefold() != "d:":
            default["state"] = "invalid"
            return default
        if _path_lexical_issue(str(candidate), candidate_windows) is not None:
            default["state"] = "invalid"
            return default
    except (TypeError, ValueError):
        default["state"] = "invalid"
        return default

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = (
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    )
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.GetFileInformationByHandle.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(_ByHandleFileInformation),
    )
    kernel32.GetFileInformationByHandle.restype = wintypes.BOOL
    kernel32.GetFinalPathNameByHandleW.argtypes = (
        wintypes.HANDLE,
        wintypes.LPWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
    )
    kernel32.GetFinalPathNameByHandleW.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    invalid_handle = ctypes.c_void_p(-1).value
    share_mode = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE
    flags = FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT
    handles: list[wintypes.HANDLE] = []

    def get_final_path(handle: wintypes.HANDLE) -> str | None:
        capacity = 512
        while capacity <= 32768:
            buffer = ctypes.create_unicode_buffer(capacity)
            length = kernel32.GetFinalPathNameByHandleW(handle, buffer, capacity, 0)
            if length == 0:
                return None
            if length < capacity:
                return buffer.value
            capacity = int(length) + 1
        return None

    def result(
        state: str,
        *,
        reparse: bool = False,
        final_path_verified: bool = False,
        identity: tuple[int, int] | None = None,
        path: str | None = None,
        error: int | str | None = None,
    ) -> dict[str, object]:
        payload: dict[str, object] = {
            "state": state,
            "reparse": reparse,
            "finalPathVerified": final_path_verified,
            "identity": list(identity) if identity is not None else None,
            "advisoryOnly": True,
        }
        if path is not None:
            payload["path"] = path
        if error is not None:
            payload["error"] = error
        return payload

    try:
        parts = candidate_windows.parts
        current = PureWindowsPath(parts[0])
        segments = list(parts[1:])
        for segment_index, segment in enumerate(segments):
            current = PureWindowsPath(current, segment)
            lexical = str(current)
            handle = kernel32.CreateFileW(
                lexical,
                FILE_READ_ATTRIBUTES,
                share_mode,
                None,
                OPEN_EXISTING,
                flags,
                None,
            )
            if not handle or handle == invalid_handle:
                error = int(ctypes.get_last_error())
                if error in (ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND):
                    return result("missing", path=lexical, error=error)
                return result("probe-error", path=lexical, error=error)
            handles.append(handle)
            info = _ByHandleFileInformation()
            if not kernel32.GetFileInformationByHandle(handle, ctypes.byref(info)):
                return result("probe-error", path=lexical, error=int(ctypes.get_last_error()))
            if info.file_attributes & FILE_ATTRIBUTE_REPARSE_POINT:
                return result("reparse", reparse=True, path=lexical)
            final_path = get_final_path(handle)
            if final_path is None:
                return result("probe-error", path=lexical, error="final path unavailable")
            if _path_compare_key(final_path) != _path_compare_key(lexical):
                return result("final-path-mismatch", path=lexical)
            is_final = segment_index == len(segments) - 1
            if not is_final and not (info.file_attributes & FILE_ATTRIBUTE_DIRECTORY):
                return result("non-directory-ancestor", final_path_verified=True, path=lexical)
            if is_final:
                if require_directory and not (info.file_attributes & FILE_ATTRIBUTE_DIRECTORY):
                    return result("non-directory-target", final_path_verified=True, path=lexical)
                identity = (
                    int(info.volume_serial_number),
                    (int(info.file_index_high) << 32) | int(info.file_index_low),
                )
                if identity == (0, 0):
                    return result("identity-unavailable", final_path_verified=True, path=lexical)
                return result(
                    "verified",
                    final_path_verified=True,
                    identity=identity,
                    path=lexical,
                )
        # A drive root has no child segment but is still a valid final target.
        root_lexical = str(current)
        handle = kernel32.CreateFileW(
            root_lexical,
            FILE_READ_ATTRIBUTES,
            share_mode,
            None,
            OPEN_EXISTING,
            flags,
            None,
        )
        if not handle or handle == invalid_handle:
            return result("probe-error", path=root_lexical, error=int(ctypes.get_last_error()))
        handles.append(handle)
        info = _ByHandleFileInformation()
        if not kernel32.GetFileInformationByHandle(handle, ctypes.byref(info)):
            return result("probe-error", path=root_lexical, error=int(ctypes.get_last_error()))
        if info.file_attributes & FILE_ATTRIBUTE_REPARSE_POINT:
            return result("reparse", reparse=True, path=root_lexical)
        final_path = get_final_path(handle)
        if final_path is None or _path_compare_key(final_path) != _path_compare_key(root_lexical):
            return result("final-path-mismatch", path=root_lexical)
        if require_directory and not (info.file_attributes & FILE_ATTRIBUTE_DIRECTORY):
            return result("non-directory-target", final_path_verified=True, path=root_lexical)
        identity = (
            int(info.volume_serial_number),
            (int(info.file_index_high) << 32) | int(info.file_index_low),
        )
        if identity == (0, 0):
            return result("identity-unavailable", final_path_verified=True, path=root_lexical)
        return result("verified", final_path_verified=True, identity=identity, path=root_lexical)
    finally:
        for handle in reversed(handles):
            kernel32.CloseHandle(handle)


def _candidate_reparse(candidate: Path) -> bool:
    return bool(_probe_candidate(candidate).get("reparse"))


def _candidate_identity(candidate: Path) -> tuple[int, int] | None:
    identity = _probe_candidate(candidate).get("identity")
    if not isinstance(identity, list) or len(identity) != 2:
        return None
    return int(identity[0]), int(identity[1])


def _path_inventory_entry(
    value: object,
    source_root: PureWindowsPath,
    candidate_root: Path,
    candidate_root_windows: PureWindowsPath,
    source_root_allowed: bool,
    candidate_root_allowed: bool,
    candidate_root_ready: bool,
) -> tuple[dict[str, object], tuple[int, int] | None]:
    source_hash: str | None = None
    if isinstance(value, str):
        try:
            source_hash = hashlib.sha256(value.encode("utf-8")).hexdigest()
        except UnicodeError:
            source_hash = None
    base: dict[str, object] = {
        "value": copy.deepcopy(value),
        "safe": False,
        "candidate": None,
        "reason": "unresolved-unknown-value",
        "reparse": False,
        "sourceSha256": source_hash,
        "finalIdentity": None,
        "probe": {
            "state": "not-probed",
            "reparse": False,
            "finalPathVerified": False,
            "identity": None,
            "advisoryOnly": True,
        },
    }
    if not isinstance(value, str):
        return base, None
    if not source_root_allowed:
        base["reason"] = "unresolved-source-root-not-allowed"
        return base, None
    if _windows_is_same_or_child(candidate_root_windows, LEGACY_DESTINATION_ROOT):
        base["reason"] = "unresolved-legacy-destination"
        return base, None
    if not candidate_root_allowed:
        base["reason"] = "unresolved-candidate-root-not-allowed"
        return base, None
    if not candidate_root_ready:
        base["reason"] = "unresolved-candidate-root-unavailable"
        return base, None

    try:
        source_path = PureWindowsPath(value)
    except (TypeError, ValueError):
        base["reason"] = "unresolved-invalid-path"
        return base, None

    lexical_issue = _path_lexical_issue(value, source_path)
    if lexical_issue == "invalid":
        base["reason"] = "unresolved-invalid-path"
        base["sourceSha256"] = None
        return base, None
    if lexical_issue == "device":
        base["reason"] = "unresolved-device-name"
        return base, None
    if lexical_issue == "alternate":
        base["reason"] = "unresolved-alternate-lexical"
        return base, None

    if _windows_is_same_or_child(source_path, LEGACY_DESTINATION_ROOT):
        base["reason"] = "unresolved-legacy-destination"
        return base, None

    relative_parts = _windows_relative_path(value, source_root)
    if relative_parts is None:
        base["reason"] = "unresolved-outside-source-root"
        return base, None

    candidate = candidate_root.joinpath(*relative_parts)
    base["candidate"] = str(candidate)
    probe = _probe_candidate(candidate)
    base["probe"] = copy.deepcopy(probe)
    probe_state = str(probe.get("state"))
    base["reparse"] = bool(probe.get("reparse"))
    if probe_state == "reparse":
        base["reason"] = "unresolved-reparse"
        return base, None
    if probe_state == "missing":
        base["reason"] = "unresolved-missing"
        return base, None
    if probe_state == "identity-unavailable":
        base["reason"] = "unresolved-identity"
        return base, None
    if probe_state == "final-path-mismatch":
        base["reason"] = "unresolved-final-path-mismatch"
        return base, None
    if probe_state == "non-directory-ancestor":
        base["reason"] = "unresolved-non-directory"
        return base, None
    if probe_state != "verified":
        base["reason"] = "unresolved-probe-error"
        return base, None
    identity_value = probe.get("identity")
    if not isinstance(identity_value, list) or len(identity_value) != 2:
        base["reason"] = "unresolved-identity"
        return base, None
    identity = (int(identity_value[0]), int(identity_value[1]))
    base["safe"] = True
    base["reason"] = "safe"
    base["finalIdentity"] = list(identity)
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
    A ``safe`` result is an advisory point-in-time probe only. Task 2/7 repair code
    must bind the state generation/hash and repeat the handle-bound probe while
    holding the state mutex, then publish with a CAS/postcheck contract.
    """
    if not isinstance(state, dict):
        raise StatePolicyError("global state root must be an object")
    state_hash, mapping_hash = _inventory_hashes(state)
    source_root_windows = _validate_inventory_root(source_root, name="path inventory source root")
    candidate_root_windows = _validate_inventory_root(
        candidate_root,
        name="path inventory candidate root",
        required_drive="D:",
    )
    source_root_allowed = _windows_parts_casefold(source_root_windows) == _windows_parts_casefold(
        PROJECTLESS_SOURCE_ROOT
    )
    candidate_root_allowed = _windows_parts_casefold(candidate_root_windows) == _windows_parts_casefold(
        CANONICAL_CANDIDATE_ROOT
    )
    if candidate_root_allowed:
        candidate_root_probe = _probe_candidate(Path(CANONICAL_CANDIDATE_ROOT), require_directory=True)
    else:
        candidate_root_probe = {
            "state": "not-probed",
            "reparse": False,
            "finalPathVerified": False,
            "identity": None,
            "advisoryOnly": True,
        }
    candidate_root_ready = candidate_root_allowed and candidate_root_probe.get("state") == "verified"

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
                source_root_allowed,
                candidate_root_allowed,
                candidate_root_ready,
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

    # The generation claim is deliberately different from the state hash.  It
    # binds the canonical source/mapping hashes to this inventory's exact
    # candidate roots, probe dispositions and final identities.  An approval
    # captured for a different probe result therefore cannot be replayed merely
    # because the JSON bytes happen to be unchanged.
    generation_payload = {
        "contract": INVENTORY_REPAIR_CONTRACT,
        "stateSha256": state_hash,
        "mappingSha256": mapping_hash,
        "sourceRoot": str(source_root_windows),
        "candidateRoot": str(candidate_root_windows),
        "sourceRootAllowed": source_root_allowed,
        "candidateRootAllowed": candidate_root_allowed,
        "candidateRootReady": candidate_root_ready,
        "candidateRootProbe": candidate_root_probe,
        "maps": maps,
    }
    inventory_generation = "inventory-v1-" + _sha256(_canonical_json_bytes(generation_payload))

    return {
        "inventoryGeneration": inventory_generation,
        "stateSha256": state_hash,
        "mappingSha256": mapping_hash,
        "sourceRoot": str(source_root_windows),
        "sourceRootAllowed": source_root_allowed,
        "candidateRoot": str(candidate_root_windows),
        "candidateRootAllowed": candidate_root_allowed,
        "candidateRootProbe": candidate_root_probe,
        "safeAdvisory": True,
        "repairContract": INVENTORY_REPAIR_CONTRACT,
        "maps": maps,
        "unknown": unknown,
    }


def _validate_permission_value(name: str, value: object, allowed: frozenset[str]) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise StatePolicyError(f"permission policy {name} is missing or unsupported")
    return value


def _permission_fields_from_mapping(document: object) -> tuple[object | None, object | None]:
    if not isinstance(document, dict):
        return None, None
    approval: object | None = None
    sandbox: object | None = None
    for key in ("approval_policy", "approvalPolicy", "approval-mode", "approvalMode"):
        if key in document:
            if approval is not None and document[key] != approval:
                raise StatePolicyError("permission policy source contains conflicting approval values")
            approval = document[key]
    for key in ("sandbox_mode", "sandboxMode", "sandbox-mode", "sandboxPolicy"):
        if key not in document:
            continue
        value = document[key]
        if isinstance(value, dict):
            value = value.get("type")
            if isinstance(value, str):
                value = {
                    "readOnly": "read-only",
                    "workspaceWrite": "workspace-write",
                    "dangerFullAccess": "danger-full-access",
                    "disabled": "danger-full-access",
                }.get(value, value)
        if sandbox is not None and value != sandbox:
            raise StatePolicyError("permission policy source contains conflicting sandbox values")
        sandbox = value
    nested = document.get("permissionPolicy")
    if nested is not None:
        if not isinstance(nested, dict):
            raise StatePolicyError("permission policy nested source is malformed")
        nested_approval, nested_sandbox = _permission_fields_from_mapping(nested)
        if nested_approval is not None:
            if approval is not None and nested_approval != approval:
                raise StatePolicyError("permission policy source contains conflicting approval values")
            approval = nested_approval
        if nested_sandbox is not None:
            if sandbox is not None and nested_sandbox != sandbox:
                raise StatePolicyError("permission policy source contains conflicting sandbox values")
            sandbox = nested_sandbox
    return approval, sandbox


PERMISSION_SOURCE_FIELDS = frozenset(
    {
        "approval_policy",
        "approvalPolicy",
        "approval-mode",
        "approvalMode",
        "sandbox_mode",
        "sandboxMode",
        "sandbox-mode",
        "sandboxPolicy",
        "permissionPolicy",
    }
)


def _permission_source_unknown_fields(document: object) -> set[str]:
    if not isinstance(document, dict):
        return {"<non-object>"}
    unknown = {str(key) for key in document if key not in PERMISSION_SOURCE_FIELDS}
    nested = document.get("permissionPolicy")
    if nested is not None:
        unknown.update(_permission_source_unknown_fields(nested))
    return unknown


def _load_permission_policy_sources(codex_home: Path) -> list[tuple[str, object, str]]:
    if not codex_home.is_absolute():
        raise StatePolicyError("permission policy home must be absolute")
    if codex_home.drive.casefold() != "d:":
        raise StatePolicyError("permission policy home must be on the D drive")
    sources: list[tuple[str, object, str]] = []
    config_path = codex_home / "config.toml"
    _assert_check_only_d_path_without_reparse(
        config_path,
        name="permission policy config",
    )
    if config_path.exists():
        if not config_path.is_file() or config_path.is_symlink():
            raise StatePolicyError("permission policy config path is not a regular file")
        if tomllib is None:
            raise StatePolicyError("permission policy TOML parser unavailable")
        try:
            raw = config_path.read_bytes()
            document = tomllib.loads(raw.decode("utf-8", errors="strict"))
        except (OSError, UnicodeError, ValueError) as exc:
            raise StatePolicyError("permission policy config is malformed") from exc
        sources.append((str(config_path), document, _sha256(raw)))
    for name in PERMISSION_POLICY_JSON_NAMES:
        policy_path = codex_home / name
        _assert_check_only_d_path_without_reparse(
            policy_path,
            name="permission policy source",
        )
        if not policy_path.exists():
            continue
        if not policy_path.is_file() or policy_path.is_symlink():
            raise StatePolicyError("permission policy source is not a regular file")
        try:
            raw = policy_path.read_bytes()
            document = _strict_json_loads(raw)
        except OSError as exc:
            raise StatePolicyError("permission policy source is unreadable") from exc
        sources.append((str(policy_path), document, _sha256(raw)))
    return sources


def resolve_permission_policy(codex_home: Path | str) -> PermissionPolicy:
    """Resolve approval/sandbox only from controlled, local policy sources.

    A missing field or disagreement between sources is an intentional hard stop;
    the state guard must never guess a broader permission profile.
    """
    home = Path(codex_home)
    sources = _load_permission_policy_sources(home)
    if not sources:
        raise StatePolicyError("permission policy source is missing")
    approvals: list[tuple[str, str]] = []
    sandboxes: list[tuple[str, str]] = []
    source_hashes: list[tuple[str, str]] = []
    source_identities: list[tuple[str, tuple[int, int]]] = []
    source_values: list[tuple[str, str | None, str | None]] = []
    for source, document, source_hash in sources:
        source_hashes.append((source, source_hash))
        approval, sandbox = _permission_fields_from_mapping(document)
        is_supplemental = PureWindowsPath(source).name.casefold() in {
            name.casefold() for name in PERMISSION_POLICY_JSON_NAMES
        }
        if is_supplemental:
            unknown_fields = _permission_source_unknown_fields(document)
            if unknown_fields:
                raise StatePolicyError("permission policy source contains unknown fields")
            if approval is None or sandbox is None:
                raise StatePolicyError("permission policy supplemental source is missing approval or sandbox")
        source_identity = _file_handle_identity(Path(source))
        if source_identity is None:
            raise StatePolicyError("permission policy source disappeared")
        try:
            if _sha256(Path(source).read_bytes()) != source_hash:
                raise StatePolicyError("permission policy source changed during resolution")
        except OSError as exc:
            raise StatePolicyError("permission policy source is unreadable") from exc
        if _file_handle_identity(Path(source)) != source_identity:
            raise StatePolicyError("permission policy source changed during resolution")
        source_identities.append((source, source_identity))
        approval_value = (
            _validate_permission_value("approval", approval, SUPPORTED_APPROVAL_POLICIES)
            if approval is not None
            else None
        )
        sandbox_value = (
            _validate_permission_value("sandbox", sandbox, SUPPORTED_SANDBOX_MODES)
            if sandbox is not None
            else None
        )
        source_values.append((source, approval_value, sandbox_value))
        if approval_value is not None:
            approvals.append((source, approval_value))
        if sandbox_value is not None:
            sandboxes.append((source, sandbox_value))
    if not approvals or not sandboxes:
        raise StatePolicyError("permission policy is missing approval or sandbox")
    approval_values = {value for _source, value in approvals}
    sandbox_values = {value for _source, value in sandboxes}
    if len(approval_values) != 1 or len(sandbox_values) != 1:
        raise StatePolicyError("permission policy sources conflict")
    source_names = ",".join(source for source, _value, _hash in sources)
    return PermissionPolicy(
        approval_policy=next(iter(approval_values)),
        sandbox_mode=next(iter(sandbox_values)),
        source=source_names,
        source_hashes=tuple(source_hashes),
        codex_home=str(home),
        source_identities=tuple(source_identities),
        source_values=tuple(source_values),
    )


def _assert_permission_policy_unchanged(permission_policy: PermissionPolicy) -> None:
    if not isinstance(permission_policy.codex_home, str) or not permission_policy.codex_home:
        raise StatePolicyError("permission policy home is missing")
    _assert_permission_policy_fingerprint(permission_policy)


def _assert_permission_policy_fingerprint(permission_policy: PermissionPolicy) -> None:
    """Re-resolve policy sources without relying on a patchable outer guard."""
    active_lease = _ACTIVE_POLICY_SOURCE_LEASE
    if active_lease is not None and getattr(active_lease, "permission_policy", None) == permission_policy:
        active_lease.assert_unchanged()  # type: ignore[attr-defined]
        return
    current = resolve_permission_policy(Path(permission_policy.codex_home))
    if current != permission_policy:
        raise StatePolicyError("permission policy changed concurrently")


def _resolve_policy_for_path(path: Path, permission_policy: PermissionPolicy | None) -> PermissionPolicy:
    if permission_policy is not None:
        if not isinstance(permission_policy, PermissionPolicy):
            raise StatePolicyError("permission policy object is invalid")
        if not isinstance(permission_policy.codex_home, str) or not permission_policy.codex_home:
            raise StatePolicyError("permission policy home is missing")
        policy_home = PureWindowsPath(permission_policy.codex_home)
        path_home = PureWindowsPath(str(path.parent))
        if _windows_parts_casefold(path_home) != _windows_parts_casefold(policy_home):
            raise StatePolicyError("permission policy is bound to a different codex home")
        return permission_policy
    return resolve_permission_policy(path.parent)


def _approved_candidate(
    approved_mappings: object,
    map_name: str,
    identity: object,
) -> str | None:
    if not isinstance(approved_mappings, dict):
        return None
    nested = approved_mappings.get(map_name)
    if isinstance(nested, dict) and identity in nested:
        candidate = nested[identity]
        return candidate if isinstance(candidate, str) else None
    return None


def _validate_approved_map(
    inventory: dict[str, object],
    approved_map: object,
    path_mode: str,
) -> dict[object, object] | None:
    if approved_map is None:
        return None
    if not isinstance(approved_map, dict):
        raise StatePolicyError("approved map generation contract is malformed")
    for field in ("inventoryGeneration", "stateSha256", "mappingSha256", "mappings"):
        if field not in approved_map:
            raise StatePolicyError("approved map generation contract is missing")
    unknown_fields = set(approved_map) - APPROVED_MAP_FIELDS
    if unknown_fields:
        raise StatePolicyError("approved map contains unknown fields")
    inventory_generation = inventory.get("inventoryGeneration")
    state_hash = inventory.get("stateSha256")
    mapping_hash = inventory.get("mappingSha256")
    if (
        not isinstance(inventory_generation, str)
        or not inventory_generation.startswith("inventory-v1-")
        or not re.fullmatch(r"inventory-v1-[0-9a-f]{64}", inventory_generation)
        or not isinstance(state_hash, str)
        or not re.fullmatch(r"[0-9a-f]{64}", state_hash)
        or not isinstance(mapping_hash, str)
        or not re.fullmatch(r"[0-9a-f]{64}", mapping_hash)
    ):
        raise StatePolicyError("approved map inventory generation is malformed")
    if approved_map.get("inventoryGeneration") != inventory_generation:
        raise StatePolicyError("approved map generation does not match inventory")
    if approved_map.get("stateSha256") != state_hash:
        raise StatePolicyError("approved map state hash does not match inventory")
    if approved_map.get("mappingSha256") != mapping_hash:
        raise StatePolicyError("approved map mapping hash does not match inventory")
    if not all(
        isinstance(approved_map.get(field), str)
        and re.fullmatch(
            r"[0-9a-f]{64}",
            str(approved_map.get(field)),
        )
        for field in ("stateSha256", "mappingSha256")
    ):
        raise StatePolicyError("approved map hash is malformed")
    mappings = approved_map.get("mappings")
    if not isinstance(mappings, dict):
        raise StatePolicyError("approved map mappings are malformed")
    inventory_maps = inventory.get("maps")
    if not isinstance(inventory_maps, dict):
        raise StatePolicyError("approved map inventory is malformed")
    for map_name, entries in mappings.items():
        if map_name not in TARGET_MAPS or not isinstance(entries, dict):
            raise StatePolicyError("approved map contains an unknown mapping")
        inventory_entries = inventory_maps.get(map_name)
        if not isinstance(inventory_entries, dict):
            raise StatePolicyError("approved map mapping is not present in inventory")
        for identity, candidate in entries.items():
            entry = inventory_entries.get(identity)
            valid = (
                isinstance(candidate, str)
                and isinstance(entry, dict)
                and bool(entry.get("safe"))
                and entry.get("candidate") == candidate
            )
            if not valid:
                raise StatePolicyError("approved map contains an unresolved entry")
    if path_mode == "repair-all-approved":
        # The broad repair mode is still bounded by the same safe inventory,
        # but it must account for every currently safe entry instead of
        # silently repairing only a reviewed subset.
        for map_name, entries in inventory_maps.items():
            if not isinstance(entries, dict):
                continue
            approved_entries = mappings.get(map_name, {})
            if not isinstance(approved_entries, dict):
                raise StatePolicyError("approved map mappings are malformed")
            for identity, entry in entries.items():
                if isinstance(entry, dict) and entry.get("safe"):
                    candidate = entry.get("candidate")
                    if approved_entries.get(identity) != candidate:
                        raise StatePolicyError("approved map does not approve every safe entry")
    return mappings


def _should_repair_path(
    *,
    path_mode: str,
    approved_mappings: object,
    map_name: str,
    identity: object,
    entry: dict[str, object],
) -> bool:
    if path_mode == "inventory":
        return False
    if path_mode not in {"repair-safe-only", "repair-all-approved"}:
        raise StatePolicyError("unknown state path mode")
    if not bool(entry.get("safe")):
        return False
    approved = _approved_candidate(approved_mappings, map_name, identity)
    candidate = entry.get("candidate")
    return isinstance(approved, str) and approved == candidate


def _reprobe_approved_paths(
    inventory: dict[str, object],
    approved_mappings: object,
    path_mode: str,
) -> None:
    """Re-probe every approved target immediately before CAS publication."""
    maps = inventory.get("maps")
    if not isinstance(maps, dict):
        return
    for map_name, entries in maps.items():
        if not isinstance(entries, dict):
            continue
        for identity, entry in entries.items():
            if not isinstance(entry, dict) or not _should_repair_path(
                path_mode=path_mode,
                approved_mappings=approved_mappings,
                map_name=str(map_name),
                identity=identity,
                entry=entry,
            ):
                continue
            candidate = entry.get("candidate")
            expected_identity = entry.get("finalIdentity")
            if not isinstance(candidate, str) or not isinstance(expected_identity, list):
                raise StatePolicyError("approved path inventory entry is incomplete")
            probe = _probe_candidate(Path(candidate))
            if probe.get("state") != "verified" or probe.get("reparse"):
                raise StatePolicyError("approved path reprobe failed")
            if probe.get("identity") != expected_identity:
                raise StatePolicyError("approved path identity changed")


def normalize_global_state(
    state: object,
    *,
    permission_policy: PermissionPolicy | None = None,
    path_mode: str = "inventory",
    path_inventory: dict[str, object] | None = None,
    approved_map: object = None,
) -> tuple[dict[str, object], dict[str, int]]:
    if not isinstance(state, dict):
        raise StatePolicyError("global state root must be an object")
    if path_mode not in {"inventory", "repair-safe-only", "repair-all-approved"}:
        raise StatePolicyError("unknown state path mode")
    if permission_policy is None:
        raise StatePolicyError("permission policy is required")
    if not isinstance(permission_policy, PermissionPolicy):
        raise StatePolicyError("permission policy object is invalid")
    normalized = copy.deepcopy(state)
    path_changed = 0
    path_drift = 0
    heartbeat_changed = 0
    if path_inventory is None:
        path_inventory = build_path_inventory(
            state,
            PROJECTLESS_SOURCE_ROOT,
            CANONICAL_CANDIDATE_ROOT,
        )
    approved_mappings = _validate_approved_map(path_inventory, approved_map, path_mode)
    inventory_maps = path_inventory.get("maps") if isinstance(path_inventory, dict) else None
    for key in TARGET_MAPS:
        mapping = normalized.get(key)
        if not isinstance(mapping, dict):
            continue
        inventory_map = inventory_maps.get(key) if isinstance(inventory_maps, dict) else None
        if not isinstance(inventory_map, dict):
            inventory_map = {}
        for identity, value in list(mapping.items()):
            entry = inventory_map.get(identity)
            if not isinstance(entry, dict):
                continue
            if isinstance(value, str) and (
                _is_projectless_source_value(value)
                or _is_legacy_destination_value(value)
                or entry.get("reason") == "unresolved-legacy-destination"
            ):
                path_drift += 1
            if _should_repair_path(
                path_mode=path_mode,
                approved_mappings=approved_mappings,
                map_name=key,
                identity=identity,
                entry=entry,
            ):
                candidate = entry.get("candidate")
                if isinstance(candidate, str) and candidate != value:
                    mapping[identity] = candidate
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
                if (
                    value.get("approvalPolicy") != permission_policy.approval_policy
                    or sandbox_type != permission_policy.heartbeat_sandbox_type
                ):
                    value["activePermissionProfile"] = None
                    value["approvalPolicy"] = permission_policy.approval_policy
                    if not value.get("approvalsReviewer"):
                        value["approvalsReviewer"] = "user"
                    value["sandboxPolicy"] = {"type": permission_policy.heartbeat_sandbox_type}
                    heartbeat_changed += 1
    return normalized, {
        "pathChangedCount": path_changed,
        "pathDriftCount": path_drift,
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
    except (TypeError, ValueError, UnicodeError) as exc:
        raise StatePolicyError("global state JSON serialization failed") from exc


def _fsync_parent(path: Path) -> None:
    if os.name != "nt":
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _file_handle_identity(path: Path) -> tuple[int, int] | None:
    """Return a stable file identity without following a reparse target."""
    if os.name != "nt":
        try:
            metadata = path.stat()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise StatePolicyError("state file identity unavailable") from exc
        return int(metadata.st_dev), int(metadata.st_ino)

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = (
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    )
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.GetFileInformationByHandle.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(_ByHandleFileInformation),
    )
    kernel32.GetFileInformationByHandle.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    handle = kernel32.CreateFileW(
        str(path),
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_DELETE,
        None,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        None,
    )
    invalid_handle = ctypes.c_void_p(-1).value
    if not handle or handle == invalid_handle:
        error = int(ctypes.get_last_error())
        if error in (ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND):
            return None
        raise StatePolicyError("state file identity unavailable")
    try:
        info = _ByHandleFileInformation()
        if not kernel32.GetFileInformationByHandle(handle, ctypes.byref(info)):
            raise StatePolicyError("state file identity unavailable")
        identity = (
            int(info.volume_serial_number),
            (int(info.file_index_high) << 32) | int(info.file_index_low),
        )
        if identity == (0, 0):
            raise StatePolicyError("state file identity unavailable")
        return identity
    finally:
        kernel32.CloseHandle(handle)


def _open_publish_handle(
    path: Path,
    *,
    desired_access: int,
    share_mode: int,
) -> tuple[object, wintypes.HANDLE]:
    if os.name != "nt":
        raise StatePolicyError("handle-bound publish is unavailable")
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = (
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    )
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.GetFileInformationByHandle.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(_ByHandleFileInformation),
    )
    kernel32.GetFileInformationByHandle.restype = wintypes.BOOL
    kernel32.GetFinalPathNameByHandleW.argtypes = (
        wintypes.HANDLE,
        wintypes.LPWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
    )
    kernel32.GetFinalPathNameByHandleW.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    handle = kernel32.CreateFileW(
        str(path),
        desired_access,
        share_mode,
        None,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
        None,
    )
    invalid_handle = ctypes.c_void_p(-1).value
    if not handle or handle == invalid_handle:
        error = int(ctypes.get_last_error())
        kernel32.CloseHandle(handle) if handle and handle != invalid_handle else None
        raise StatePolicyError(f"state publish handle unavailable ({error})")
    return kernel32, handle


def _probe_cold_maintenance_sources(codex_home: Path) -> dict[str, list[int]]:
    """Prove that the SQLite source-set is not held by another process."""
    _validate_inventory_root(codex_home, name="cold maintenance home", required_drive="D:")
    database = codex_home / "state_5.sqlite"
    paths = (
        database,
        Path(str(database) + "-wal"),
        Path(str(database) + "-shm"),
        Path(str(database) + "-journal"),
    )
    identities: dict[str, list[int]] = {}
    for index, path in enumerate(paths):
        _assert_check_only_d_path_without_reparse(path, name="cold maintenance source")
        try:
            path.lstat()
        except FileNotFoundError:
            if index == 0:
                raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
            continue
        except OSError as exc:
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
        try:
            regular_file = path.is_file()
        except OSError as exc:
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
        if path.is_symlink() or not regular_file:
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
        identity: tuple[int, int] | None = None
        if os.name == "nt":
            kernel32: object | None = None
            handle: wintypes.HANDLE | None = None
            try:
                kernel32, handle = _open_publish_handle(
                    path,
                    desired_access=GENERIC_READ | FILE_READ_ATTRIBUTES | SYNCHRONIZE_ACCESS,
                    share_mode=0,
                )
                identity = _publish_handle_info(kernel32, handle, path)
            except (OSError, StatePolicyError) as exc:
                raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
            finally:
                if kernel32 is not None and handle is not None:
                    _close_publish_handle(kernel32, handle)
        else:
            if fcntl is None:
                raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
            descriptor: int | None = None
            try:
                descriptor = os.open(path, os.O_RDONLY)
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                metadata = os.fstat(descriptor)
                identity = (int(metadata.st_dev), int(metadata.st_ino))
            except (OSError, TypeError) as exc:
                raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
            finally:
                if descriptor is not None:
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_UN)
                    except (OSError, TypeError):
                        pass
                    os.close(descriptor)
        if identity is None or identity == (0, 0):
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
        identities[path.name] = [int(identity[0]), int(identity[1])]
    return identities


def _assert_cold_maintenance_sources(
    codex_home: Path,
    *,
    expected_database_identity: tuple[int, int] | None = None,
) -> dict[str, list[int]]:
    actual = _probe_cold_maintenance_sources(codex_home)
    if (
        expected_database_identity is not None
        and actual.get("state_5.sqlite") != list(expected_database_identity)
    ):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    return actual


def _capture_cold_source_generation(
    codex_home: Path,
) -> tuple[SqliteSourceSnapshot, dict[str, list[int]], dict[str, str]]:
    source_set = _probe_cold_maintenance_sources(codex_home)
    database = codex_home / "state_5.sqlite"
    snapshot = _capture_sqlite_source(database)
    source_hashes: dict[str, str] = {}
    for index, path in enumerate(
        (
            database,
            Path(str(database) + "-wal"),
            Path(str(database) + "-shm"),
            Path(str(database) + "-journal"),
        )
    ):
        identity = snapshot.identities[index]
        payload = snapshot.payload[index]
        if identity is None:
            continue
        if payload is None or not snapshot.content_known[index]:
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
        source_hashes[path.name] = _sha256(payload)
    actual_set = {
        name: list(snapshot.identities[index])
        for index, name in enumerate(
            (
                database.name,
                Path(str(database) + "-wal").name,
                Path(str(database) + "-shm").name,
                Path(str(database) + "-journal").name,
            )
        )
        if snapshot.identities[index] is not None
    }
    if actual_set != source_set or database.name not in source_hashes:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    return snapshot, actual_set, source_hashes


def _normalise_cold_source_set(value: object) -> dict[str, list[int]] | None:
    if not isinstance(value, dict):
        return None
    result: dict[str, list[int]] = {}
    for name, identity in value.items():
        if (
            not isinstance(name, str)
            or not isinstance(identity, (list, tuple))
            or len(identity) != 2
            or not all(isinstance(item, int) and item >= 0 for item in identity)
        ):
            return None
        result[name] = [int(identity[0]), int(identity[1])]
    return result


def _normalise_cold_source_hashes(value: object) -> dict[str, str] | None:
    if not isinstance(value, dict):
        return None
    result: dict[str, str] = {}
    for name, digest in value.items():
        if (
            not isinstance(name, str)
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            return None
        result[name] = digest
    return result


def _rebase_cold_sqlite_snapshot(
    path: Path,
    expected_database_identity: tuple[int, int],
    expected_database_hash: str | None,
) -> SqliteSourceSnapshot:
    snapshot = _capture_sqlite_source(path)
    if (
        snapshot.identities[0] != expected_database_identity
        or (
            expected_database_hash is not None
            and _sha256(snapshot.payload[0] or b"") != expected_database_hash
        )
        or _sqlite_snapshot_has_unknown_sidecars(snapshot)
    ):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    return snapshot


def _sqlite_logical_hash(connection: sqlite3.Connection) -> str:
    """Hash the transaction-visible logical database, independent of checkpoint layout."""
    try:
        payload = connection.serialize()
    except (sqlite3.Error, MemoryError) as exc:
        raise StatePolicyError("thread state logical snapshot unavailable") from exc
    if not isinstance(payload, bytes) or not payload:
        raise StatePolicyError("thread state logical snapshot unavailable")
    return _sha256(payload)


def _assert_no_new_sqlite_sidecars(
    expected: SqliteSourceSnapshot,
    actual: SqliteSourceSnapshot,
) -> None:
    for index in range(1, 4):
        if expected.identities[index] is None and actual.identities[index] is not None:
            raise StatePolicyError(
                "thread state sidecar appeared after commit; unsafe-partial"
            )


def _close_publish_handle(kernel32: object, handle: wintypes.HANDLE) -> None:
    try:
        kernel32.CloseHandle(handle)  # type: ignore[attr-defined]
    except OSError:
        pass


def _open_publish_byte_lock(
    path: Path,
    *,
    shared: bool = False,
) -> tuple[object, wintypes.HANDLE, _ByteRangeLease]:
    """Open a shared read handle and lock the current generation range.

    SQLite keeps its own database/WAL handles open with broad sharing, so a
    second no-share handle cannot be acquired after a connection is active.
    A Windows byte-range lock is the compatible handle-bound alternative: it
    blocks in-place writes and same-name replacement while preserving the
    SQLite connection's legitimate WAL lifecycle.
    """
    kernel32, handle = _open_publish_handle(
        path,
        desired_access=GENERIC_READ,
        share_mode=FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    )
    byte_lease: _ByteRangeLease | None = None
    try:
        kernel32.GetFileSizeEx.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(ctypes.c_longlong),
        )
        kernel32.GetFileSizeEx.restype = wintypes.BOOL
        size = ctypes.c_longlong()
        if not kernel32.GetFileSizeEx(handle, ctypes.byref(size)):  # type: ignore[attr-defined]
            raise StatePolicyError("state generation byte lease size unavailable")
        if size.value < 0 or size.value >= 0xFFFFFFFFFFFFFFFF:
            raise StatePolicyError("state generation byte lease size is unsupported")
        # Lock the complete observed file plus its first append byte.  A
        # byte-zero token is insufficient: an output callback could otherwise
        # patch a non-zero page or extend the file past the lease.  SQLite's
        # WAL-index has a fixed lock-byte window; shared leases split around
        # that window so they coexist with SQLite's own writer lock.
        end = max(1, int(size.value) + 1)
        if shared:
            ranges_to_lock: list[tuple[int, int, bool]] = []
            prefix_end = min(end, SQLITE_SHM_LOCK_OFFSET)
            if prefix_end:
                ranges_to_lock.append((0, prefix_end, False))
            suffix_start = SQLITE_SHM_LOCK_OFFSET + SQLITE_SHM_LOCK_LENGTH
            if end > suffix_start:
                ranges_to_lock.append((suffix_start, end - suffix_start, False))
        else:
            ranges_to_lock = [(0, end, True)]
        if not ranges_to_lock:
            raise StatePolicyError("state generation byte lease range is empty")
        kernel32.LockFileEx.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.DWORD,
            ctypes.POINTER(_Overlapped),
        )
        kernel32.LockFileEx.restype = wintypes.BOOL
        locked_ranges: list[_LockedRange] = []
        for offset, lock_length, exclusive in ranges_to_lock:
            if lock_length <= 0:
                continue
            overlap = _Overlapped()
            overlap.offset = offset & 0xFFFFFFFF
            overlap.offset_high = (offset >> 32) & 0xFFFFFFFF
            lock_flags = LOCKFILE_EXCLUSIVE_LOCK if exclusive else 0
            if not kernel32.LockFileEx(  # type: ignore[attr-defined]
                handle,
                lock_flags | LOCKFILE_FAIL_IMMEDIATELY,
                0,
                lock_length & 0xFFFFFFFF,
                (lock_length >> 32) & 0xFFFFFFFF,
                ctypes.byref(overlap),
            ):
                error = int(ctypes.get_last_error())
                raise StatePolicyError(f"state generation byte lease unavailable ({error})")
            locked_ranges.append(
                _LockedRange(overlap=overlap, offset=offset, length=lock_length)
            )
        byte_lease = _ByteRangeLease(ranges=tuple(locked_ranges))
        after_size = ctypes.c_longlong()
        if not kernel32.GetFileSizeEx(handle, ctypes.byref(after_size)):  # type: ignore[attr-defined]
            raise StatePolicyError("state generation byte lease size unavailable")
        if after_size.value != size.value:
            raise StatePolicyError("state generation target grew before lease")
        return kernel32, handle, byte_lease
    except BaseException:
        if byte_lease is None:
            _close_publish_handle(kernel32, handle)
        else:
            _close_publish_byte_lock(kernel32, handle, byte_lease)
        raise


def _close_publish_byte_lock(
    kernel32: object,
    handle: wintypes.HANDLE,
    lease: _ByteRangeLease,
) -> None:
    try:
        kernel32.UnlockFileEx.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.DWORD,
            ctypes.POINTER(_Overlapped),
        )
        kernel32.UnlockFileEx.restype = wintypes.BOOL
        for locked_range in reversed(lease.ranges):
            kernel32.UnlockFileEx(  # type: ignore[attr-defined]
                handle,
                0,
                locked_range.length & 0xFFFFFFFF,
                (locked_range.length >> 32) & 0xFFFFFFFF,
                ctypes.byref(locked_range.overlap),
            )
    except (AttributeError, OSError):
        pass
    finally:
        _close_publish_handle(kernel32, handle)


def _publish_handle_info(
    kernel32: object,
    handle: wintypes.HANDLE,
    path: Path,
) -> tuple[int, int]:
    info = _ByHandleFileInformation()
    if not kernel32.GetFileInformationByHandle(handle, ctypes.byref(info)):  # type: ignore[attr-defined]
        raise StatePolicyError("state publish handle identity unavailable")
    if info.file_attributes & FILE_ATTRIBUTE_REPARSE_POINT:
        raise StatePolicyError("state publish target contains reparse point")
    if info.file_attributes & FILE_ATTRIBUTE_DIRECTORY:
        raise StatePolicyError("state publish target is not a regular file")
    capacity = 512
    final_path: str | None = None
    while capacity <= 32768:
        buffer = ctypes.create_unicode_buffer(capacity)
        length = kernel32.GetFinalPathNameByHandleW(  # type: ignore[attr-defined]
            handle,
            buffer,
            capacity,
            0,
        )
        if length == 0:
            break
        if length < capacity:
            final_path = buffer.value
            break
        capacity = int(length) + 1
    if final_path is None or _path_compare_key(final_path) != _path_compare_key(str(path)):
        raise StatePolicyError("state publish handle final path mismatch")
    identity = (
        int(info.volume_serial_number),
        (int(info.file_index_high) << 32) | int(info.file_index_low),
    )
    if identity == (0, 0):
        raise StatePolicyError("state publish handle identity unavailable")
    return identity


def _open_missing_sidecar_handle(
    path: Path,
) -> tuple[object, wintypes.HANDLE]:
    """Reserve an absent sidecar name without allowing a later replacement.

    A missing SQLite WAL journal cannot carry a byte-range lease.  On Windows
    the directory itself has no useful child-creation lock, so reserve the
    exact name with a delete-on-close handle and no sharing.  Any writer,
    replacement, or reparse-point creation attempt then fails with a sharing
    violation while the lease is held.  ``CREATE_NEW`` is required here: if a
    journal appears after the caller's existence check, the open must fail
    without ever acquiring a handle to (and therefore deleting) that file.
    """
    if os.name != "nt":
        raise StatePolicyError("missing sidecar no-create lease is unavailable")
    _assert_check_only_d_path_without_reparse(path, name="missing sidecar lease")
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = (
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    )
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    handle = kernel32.CreateFileW(
        str(path),
        GENERIC_READ | GENERIC_WRITE | DELETE_ACCESS,
        0,
        None,
        CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_DELETE_ON_CLOSE,
        None,
    )
    invalid_handle = ctypes.c_void_p(-1).value
    if not handle or handle == invalid_handle:
        error = int(ctypes.get_last_error())
        if error == ERROR_FILE_EXISTS:
            # CREATE_NEW never returns an existing file handle.  In
            # particular, do not close a handle here: doing so with
            # DELETE_ON_CLOSE could remove a competitor's journal.
            raise StatePolicyError("missing sidecar appeared before lease")
        if handle and handle != invalid_handle:
            kernel32.CloseHandle(handle)
        raise StatePolicyError(f"missing sidecar lease unavailable ({error})")
    return kernel32, handle


class SqliteMissingSidecarLease:
    """Hold a cold-start WAL journal name against creation or replacement."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._windows_handle: tuple[object, wintypes.HANDLE] | None = None
        self._expected_identity: tuple[int, int] | None = None
        self._closed = False

    def __enter__(self) -> "SqliteMissingSidecarLease":
        try:
            if self.path.exists():
                raise StatePolicyError("missing sidecar appeared before lease")
            kernel32, handle = _open_missing_sidecar_handle(self.path)
            try:
                actual_identity = _publish_handle_info(kernel32, handle, self.path)
            except BaseException:
                _close_publish_handle(kernel32, handle)
                raise
            self._windows_handle = (kernel32, handle)
            self._expected_identity = actual_identity
            active = _ACTIVE_SQLITE_MISSING_SIDECAR_LEASES.get()
            _ACTIVE_SQLITE_MISSING_SIDECAR_LEASES.set((*active, self))
        except BaseException:
            self.close()
            raise
        return self

    def reserves(self, path: Path) -> bool:
        return not self._closed and _path_compare_key(str(self.path)) == _path_compare_key(str(path))

    def assert_unchanged(self) -> None:
        if self._closed or self._windows_handle is None or self._expected_identity is None:
            raise StatePolicyError("missing sidecar lease is closed")
        _assert_check_only_d_path_without_reparse(
            self.path,
            name="missing sidecar lease",
        )
        kernel32, handle = self._windows_handle
        if _publish_handle_info(kernel32, handle, self.path) != self._expected_identity:
            raise StatePolicyError("missing sidecar lease changed concurrently")

    def close(self) -> None:
        if self._closed:
            return
        active = _ACTIVE_SQLITE_MISSING_SIDECAR_LEASES.get()
        _ACTIVE_SQLITE_MISSING_SIDECAR_LEASES.set(
            tuple(candidate for candidate in active if candidate is not self)
        )
        if self._windows_handle is not None:
            kernel32, handle = self._windows_handle
            _close_publish_handle(kernel32, handle)
            self._windows_handle = None
        self._closed = True

    def __exit__(self, *_args: object) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass


def _active_sqlite_missing_sidecar_lease(
    path: Path,
) -> SqliteMissingSidecarLease | None:
    for candidate in reversed(_ACTIVE_SQLITE_MISSING_SIDECAR_LEASES.get()):
        if (
            isinstance(candidate, SqliteMissingSidecarLease)
            and candidate.reserves(path)
        ):
            return candidate
    return None


class _DirectoryPathLease:
    """Hold an existing D-drive directory against rename/reparse replacement."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._windows_handle: tuple[object, wintypes.HANDLE] | None = None

    def __enter__(self) -> "_DirectoryPathLease":
        _assert_check_only_d_path_without_reparse(self.path, name="shadow directory lease")
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.argtypes = (
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            ctypes.c_void_p,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        )
        kernel32.CreateFileW.restype = wintypes.HANDLE
        kernel32.GetFileInformationByHandle.argtypes = (
            wintypes.HANDLE,
            ctypes.POINTER(_ByHandleFileInformation),
        )
        kernel32.GetFileInformationByHandle.restype = wintypes.BOOL
        kernel32.GetFinalPathNameByHandleW.argtypes = (
            wintypes.HANDLE,
            wintypes.LPWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
        )
        kernel32.GetFinalPathNameByHandleW.restype = wintypes.DWORD
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel32.CloseHandle.restype = wintypes.BOOL
        handle = kernel32.CreateFileW(
            str(self.path),
            GENERIC_READ,
            FILE_SHARE_READ,
            None,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            None,
        )
        invalid_handle = ctypes.c_void_p(-1).value
        if not handle or handle == invalid_handle:
            raise StatePolicyError("shadow directory lease unavailable")
        try:
            info = _ByHandleFileInformation()
            if not kernel32.GetFileInformationByHandle(handle, ctypes.byref(info)):
                raise StatePolicyError("shadow directory identity unavailable")
            if not info.file_attributes & FILE_ATTRIBUTE_DIRECTORY:
                raise StatePolicyError("shadow lease target is not a directory")
            if info.file_attributes & FILE_ATTRIBUTE_REPARSE_POINT:
                raise StatePolicyError("shadow directory contains reparse point")
            capacity = 512
            final_path: str | None = None
            while capacity <= 32768:
                buffer = ctypes.create_unicode_buffer(capacity)
                length = kernel32.GetFinalPathNameByHandleW(handle, buffer, capacity, 0)
                if length == 0:
                    break
                if length < capacity:
                    final_path = buffer.value
                    break
                capacity = int(length) + 1
            if final_path is None or _path_compare_key(final_path) != _path_compare_key(str(self.path)):
                raise StatePolicyError("shadow directory final path mismatch")
        except BaseException:
            kernel32.CloseHandle(handle)
            raise
        self._windows_handle = (kernel32, handle)
        return self

    def close(self) -> None:
        if self._windows_handle is not None:
            kernel32, handle = self._windows_handle
            kernel32.CloseHandle(handle)  # type: ignore[attr-defined]
            self._windows_handle = None

    def __exit__(self, *_args: object) -> None:
        self.close()


def _delete_owned_shadow_file(
    path: Path,
    expected_identity: tuple[int, int],
    expected_payload: bytes,
) -> None:
    """Delete only the exact shadow-file generation captured after SQLite closed."""
    kernel32, handle = _open_publish_handle(
        path,
        desired_access=GENERIC_READ | DELETE_ACCESS | SYNCHRONIZE_ACCESS,
        share_mode=FILE_SHARE_READ,
    )
    try:
        if _publish_handle_info(kernel32, handle, path) != expected_identity:
            raise StatePolicyError("cold state shadow file identity changed before cleanup")
        if _read_publish_handle_bytes(kernel32, handle) != expected_payload:
            raise StatePolicyError("cold state shadow file bytes changed before cleanup")
        kernel32.SetFileInformationByHandle.argtypes = (  # type: ignore[attr-defined]
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        )
        kernel32.SetFileInformationByHandle.restype = wintypes.BOOL  # type: ignore[attr-defined]
        disposition = _FileDispositionInfo(1)
        if not kernel32.SetFileInformationByHandle(  # type: ignore[attr-defined]
            handle,
            4,  # FileDispositionInfo
            ctypes.byref(disposition),
            ctypes.sizeof(disposition),
        ):
            raise StatePolicyError("cold state shadow file conditional delete failed")
    finally:
        _close_publish_handle(kernel32, handle)


def _read_publish_handle_bytes(kernel32: object, handle: wintypes.HANDLE) -> bytes:
    kernel32.GetFileSizeEx.argtypes = (wintypes.HANDLE, ctypes.POINTER(ctypes.c_longlong))  # type: ignore[attr-defined]
    kernel32.GetFileSizeEx.restype = wintypes.BOOL  # type: ignore[attr-defined]
    kernel32.SetFilePointerEx.argtypes = (
        wintypes.HANDLE,
        ctypes.c_longlong,
        ctypes.POINTER(ctypes.c_longlong),
        wintypes.DWORD,
    )  # type: ignore[attr-defined]
    kernel32.SetFilePointerEx.restype = wintypes.BOOL  # type: ignore[attr-defined]
    kernel32.ReadFile.argtypes = (
        wintypes.HANDLE,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.c_void_p,
    )  # type: ignore[attr-defined]
    kernel32.ReadFile.restype = wintypes.BOOL  # type: ignore[attr-defined]
    length = ctypes.c_longlong()
    if not kernel32.GetFileSizeEx(handle, ctypes.byref(length)):  # type: ignore[attr-defined]
        raise StatePolicyError("state publish target bytes unavailable")
    if length.value < 0 or length.value > 128 * 1024 * 1024:
        raise StatePolicyError("state publish target is too large")
    if not kernel32.SetFilePointerEx(handle, 0, None, 0):  # type: ignore[attr-defined]
        raise StatePolicyError("state publish target seek failed")
    remaining = int(length.value)
    chunks: list[bytes] = []
    while remaining:
        chunk_size = min(1024 * 1024, remaining)
        buffer = ctypes.create_string_buffer(chunk_size)
        read = wintypes.DWORD()
        if not kernel32.ReadFile(handle, buffer, chunk_size, ctypes.byref(read), None):  # type: ignore[attr-defined]
            raise StatePolicyError("state publish target read failed")
        if read.value == 0:
            raise StatePolicyError("state publish target read truncated")
        chunks.append(buffer.raw[: read.value])
        remaining -= int(read.value)
    return b"".join(chunks)


def _read_sqlite_shm_mapped_bytes(path: Path) -> bytes:
    """Read a SQLite WAL-index while SQLite owns its byte-range locks.

    Windows can deny a second ``ReadFile`` on ``-shm`` while an active SQLite
    connection owns the WAL-index lock window, even though a read-only file
    mapping remains observable.  The mapping is intentionally read-only and
    is used only as a content observation; callers still re-check identity,
    size, metadata and the complete payload before accepting a generation.
    If the mapping cannot be established, the generation is not safely
    observable and must fail closed rather than downgrade to metadata-only
    validation.
    """
    try:
        with path.open("rb") as stream:
            length = int(stream.seek(0, os.SEEK_END))
            stream.seek(0)
            if length == 0:
                return b""
            with mmap.mmap(stream.fileno(), length, access=mmap.ACCESS_READ) as mapped:
                return mapped[:]
    except (OSError, ValueError, BufferError) as exc:
        raise StatePolicyError("thread state SHM lock window unavailable") from exc


class StateTargetLease:
    """Hold a published state target against replacement until the caller returns."""

    def __init__(
        self,
        path: Path,
        *,
        expected_identity: tuple[int, int],
        expected_hash: str,
    ) -> None:
        self.path = path
        self.expected_identity = expected_identity
        self.expected_hash = expected_hash
        self._windows_handle: tuple[object, wintypes.HANDLE] | None = None
        self._portable_stream: object | None = None
        self._closed = False

    def __enter__(self) -> "StateTargetLease":
        try:
            _assert_check_only_d_path_without_reparse(
                self.path,
                name="state target lease",
            )
            if os.name == "nt":
                # No write or delete sharing: an external writer cannot mutate,
                # replace, or unlink the published target while it is leased.
                kernel32, handle = _open_publish_handle(
                    self.path,
                    desired_access=GENERIC_READ,
                    share_mode=FILE_SHARE_READ,
                )
                try:
                    actual_identity = _publish_handle_info(kernel32, handle, self.path)
                    actual_hash = _sha256(_read_publish_handle_bytes(kernel32, handle))
                    if (
                        actual_identity != self.expected_identity
                        or actual_hash != self.expected_hash
                    ):
                        raise StatePolicyError("state target changed before lease")
                except BaseException:
                    _close_publish_handle(kernel32, handle)
                    raise
                self._windows_handle = (kernel32, handle)
            else:
                stream = self.path.open("rb")
                try:
                    actual_identity = _file_handle_identity(self.path)
                    actual_hash = _sha256(stream.read())
                    if (
                        actual_identity != self.expected_identity
                        or actual_hash != self.expected_hash
                    ):
                        raise StatePolicyError("state target changed before lease")
                    stream.seek(0)
                except BaseException:
                    stream.close()
                    raise
                self._portable_stream = stream
        except BaseException:
            self.close()
            raise
        return self

    def assert_unchanged(self) -> None:
        if self._closed:
            raise StatePolicyError("state target lease is closed")
        if os.name == "nt":
            if self._windows_handle is None:
                raise StatePolicyError("state target lease is incomplete")
            kernel32, handle = self._windows_handle
            if _publish_handle_info(kernel32, handle, self.path) != self.expected_identity:
                raise StatePolicyError("state target changed concurrently")
            if _sha256(_read_publish_handle_bytes(kernel32, handle)) != self.expected_hash:
                raise StatePolicyError("state target changed concurrently")
            return
        if (
            _file_handle_identity(self.path) != self.expected_identity
            or _sha256(self.path.read_bytes()) != self.expected_hash
        ):
            raise StatePolicyError("state target changed concurrently")

    def close(self) -> None:
        if self._closed:
            return
        if self._windows_handle is not None:
            kernel32, handle = self._windows_handle
            _close_publish_handle(kernel32, handle)
            self._windows_handle = None
        if self._portable_stream is not None:
            try:
                self._portable_stream.close()  # type: ignore[attr-defined]
            except OSError:
                pass
            self._portable_stream = None
        self._closed = True

    def __exit__(self, *_args: object) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass


class SqliteTargetLease:
    """Hold a SQLite writer or read-only lease while the run result is finalized."""

    def __init__(
        self,
        path: Path,
        *,
        expected_identity: tuple[int, int],
        permission_policy: PermissionPolicy,
        expected_snapshot: SqliteSourceSnapshot | None = None,
        read_only: bool = False,
    ) -> None:
        self.path = path
        self.expected_identity = expected_identity
        self.permission_policy = permission_policy
        self.expected_snapshot = expected_snapshot
        self.read_only = read_only
        self._connection: sqlite3.Connection | None = None
        self._windows_byte_locks: list[tuple[int, object, wintypes.HANDLE, _ByteRangeLease]] = []
        self._missing_sidecar_lease: SqliteMissingSidecarLease | None = None
        self._closed = False

    @classmethod
    def from_connection(
        cls,
        path: Path,
        *,
        expected_identity: tuple[int, int],
        permission_policy: PermissionPolicy,
        expected_snapshot: SqliteSourceSnapshot,
        connection: sqlite3.Connection,
        missing_sidecar_lease: SqliteMissingSidecarLease | None = None,
        read_only: bool = False,
    ) -> "SqliteTargetLease":
        if not connection.in_transaction:
            raise StatePolicyError("sqlite return lease connection is inactive")
        lease = cls(
            path,
            expected_identity=expected_identity,
            permission_policy=permission_policy,
            expected_snapshot=expected_snapshot,
            read_only=read_only,
        )
        lease._connection = connection
        lease._missing_sidecar_lease = missing_sidecar_lease
        try:
            lease._acquire_generation_locks()
        except BaseException:
            lease.close()
            raise
        return lease

    def _acquire_generation_locks(self) -> None:
        if os.name != "nt" or self.expected_snapshot is None:
            return
        paths = (
            self.path,
            Path(str(self.path) + "-wal"),
            Path(str(self.path) + "-shm"),
            Path(str(self.path) + "-journal"),
        )
        try:
            for index, candidate in enumerate(paths):
                if self.expected_snapshot.identities[index] is None:
                    continue
                _assert_check_only_d_path_without_reparse(
                    candidate,
                    name="state generation lease",
                )
                if not candidate.is_file():
                    raise StatePolicyError("state generation target disappeared")
                kernel32, handle, byte_lease = _open_publish_byte_lock(
                    candidate,
                    # SQLite itself owns shared-memory lock bytes.  The
                    # main/WAL/journal ranges remain exclusive; the SHM range
                    # is split around SQLite's lock-byte window so an active
                    # reader or writer transaction can coexist.
                    # The read-only transaction materializes its WAL pages
                    # before this call, so the complete WAL range can remain
                    # exclusive.  An active writer or reader connection owns
                    # SQLite's SHM lock window; retain the split SHM lease.
                    shared=index == 2,
                )
                try:
                    actual_identity = _publish_handle_info(kernel32, handle, candidate)
                    expected_identity = self.expected_snapshot.identities[index]
                    if expected_identity is None or actual_identity != expected_identity:
                        raise StatePolicyError("state generation target changed before lease")
                except BaseException:
                    _close_publish_byte_lock(kernel32, handle, byte_lease)
                    raise
                self._windows_byte_locks.append((index, kernel32, handle, byte_lease))
        except BaseException:
            self._close_generation_locks()
            raise

    def _close_generation_locks(self) -> None:
        for _index, kernel32, handle, byte_lease in reversed(self._windows_byte_locks):
            _close_publish_byte_lock(kernel32, handle, byte_lease)
        self._windows_byte_locks.clear()

    def __enter__(self) -> "SqliteTargetLease":
        try:
            self._connection = _connect_sqlite_bound(self.path, self.expected_identity)
            self._connection.execute("pragma busy_timeout=0")
            if self.read_only:
                self._connection.execute("pragma query_only=on")
                self._connection.execute("begin")
                # Materialize the read transaction's WAL pages before taking
                # the generation locks.  Otherwise SQLite can report a disk
                # I/O error when the subsequent Windows WAL lease is acquired
                # ahead of its first page read.
                select_thread_updates(self._connection, self.permission_policy)
            else:
                self._connection.execute("begin immediate")
            self._acquire_generation_locks()
            if self.read_only and self.expected_snapshot is not None:
                # Opening a read transaction legitimately updates SQLite's
                # SHM reader-lock bytes.  Rebase the strict content baseline
                # after the generation locks are held, while retaining the
                # original identity/path checks for the race into the lease.
                locked_sidecar_indices = {
                    index
                    for index, _kernel32, _handle, _byte_lease in self._windows_byte_locks
                    if index > 0 and index != 2
                }
                self.expected_snapshot = _assert_sqlite_snapshot_identity(
                    self.expected_snapshot,
                    self.path,
                    allow_new_sidecars=False,
                    allow_removed_sidecars=True,
                    check_main_metadata=False,
                    check_sidecar_content=False,
                    handle_sources={
                        index: (kernel32, handle)
                        for index, kernel32, handle, _byte_lease in self._windows_byte_locks
                        if index == 0
                    },
                    locked_sidecar_indices=locked_sidecar_indices,
                )
            self.assert_unchanged(strict_sidecar_content=False)
        except BaseException:
            self.close()
            raise
        return self

    def assert_unchanged(self, *, strict_sidecar_content: bool = False) -> None:
        if self._closed or self._connection is None:
            raise StatePolicyError("sqlite target lease is closed")
        if os.name == "nt" and self.expected_snapshot is not None:
            expected_lock_count = sum(identity is not None for identity in self.expected_snapshot.identities)
            if len(self._windows_byte_locks) != expected_lock_count:
                raise StatePolicyError("state generation byte lease is incomplete")
        if _file_handle_identity(self.path) != self.expected_identity:
            raise StatePolicyError("thread state target changed concurrently")
        if self.expected_snapshot is not None:
            handle_sources = {
                index: (kernel32, handle)
                for index, kernel32, handle, _byte_lease in self._windows_byte_locks
                # SQLite may deny a second read of WAL/SHM while the active
                # transaction owns those handles.  The identity and
                # byte-range leases remain authoritative for those files;
                # use the verified main handle for the strict row gate.
                if index == 0
            }
            locked_sidecar_indices = {
                index
                for index, _kernel32, _handle, _byte_lease in self._windows_byte_locks
                if index > 0
                and (not self.read_only or index != 2)
                # The writer's split SHM lease deliberately leaves SQLite's
                # lock window (120..127) to the connection, but strict return
                # gates must compare the mapped payload rather than treating
                # that window as implicitly trusted.  If the payload cannot
                # be observed, _capture_sqlite_source fails closed.
                and not (strict_sidecar_content and index == 2)
            }
            current_snapshot = _assert_sqlite_snapshot_identity(
                self.expected_snapshot,
                self.path,
                allow_new_sidecars=False,
                allow_removed_sidecars=True,
                check_main_metadata=False,
                check_sidecar_content=strict_sidecar_content,
                handle_sources=handle_sources or None,
                locked_sidecar_indices=locked_sidecar_indices,
                strict_sidecar_content_indices={2} if strict_sidecar_content else None,
            )
            if strict_sidecar_content:
                if (
                    self.expected_snapshot.content_known[0]
                    and current_snapshot.content_known[0]
                    and self.expected_snapshot.payload[0] != current_snapshot.payload[0]
                ):
                    raise StatePolicyError("thread state database bytes changed during return gate")
                if self.expected_snapshot.content_known[0] != current_snapshot.content_known[0]:
                    raise StatePolicyError("thread state database bytes unavailable during return gate")
            if strict_sidecar_content:
                locked_sidecars = {
                    index
                    for index, _kernel32, _handle, _byte_lease in self._windows_byte_locks
                    if index > 0
                    and (not self.read_only or index != 2)
                    and not (strict_sidecar_content and index == 2)
                }
                for index in range(1, 4):
                    if index in locked_sidecars:
                        # The byte-range lease is stronger than a second
                        # byte read: SQLite may deny that read while keeping
                        # its WAL/SHM handle open, but an outsider cannot
                        # write or replace the locked generation.
                        continue
                    if (
                        self.expected_snapshot.content_known[index]
                        != current_snapshot.content_known[index]
                    ):
                        raise StatePolicyError("thread state sidecar bytes unavailable during return gate")
        if not self.read_only and select_thread_updates(self._connection, self.permission_policy):
            raise StatePolicyError("thread state target changed concurrently")

    def assert_no_create(self) -> None:
        """Keep an initially absent WAL journal under a no-create monitor.

        SQLite WAL mode legitimately starts with a database/WAL/SHM set and no
        rollback journal.  The write path reserves that name with
        ``SqliteMissingSidecarLease``; callers that hold no reservation retain
        the legacy re-probe as a fail-closed fallback.  A journal appearing
        after the normal lease assertion is an unbounded generation and must
        never be silently accepted.
        """
        if self._closed or self._connection is None:
            raise StatePolicyError("sqlite target lease is closed")
        snapshot = self.expected_snapshot
        if snapshot is None or snapshot.identities[1] is None or snapshot.identities[3] is not None:
            return
        journal_path = Path(str(self.path) + "-journal")
        missing_sidecar_lease = self._missing_sidecar_lease
        if (
            isinstance(missing_sidecar_lease, SqliteMissingSidecarLease)
            and missing_sidecar_lease.reserves(journal_path)
        ):
            missing_sidecar_lease.assert_unchanged()
            return
        try:
            journal_path.lstat()
        except FileNotFoundError:
            return
        except OSError as exc:
            raise StatePolicyError(
                "thread state source generation is unbounded"
            ) from exc
        try:
            _assert_check_only_d_path_without_reparse(
                journal_path,
                name="thread state generation monitor",
            )
        except StatePolicyError as exc:
            if "reparse" in str(exc).casefold():
                raise StatePolicyError(
                    "thread state source generation is unbounded (reparse)"
                ) from exc
            raise
        raise StatePolicyError("thread state source generation is unbounded")

    def close(self) -> None:
        if self._closed:
            return
        try:
            if self._connection is not None:
                connection = self._connection
                self._connection = None
                try:
                    connection.rollback()
                except sqlite3.Error:
                    pass
                connection.close()
        finally:
            try:
                self._close_generation_locks()
            finally:
                try:
                    if self._missing_sidecar_lease is not None:
                        self._missing_sidecar_lease.close()
                        self._missing_sidecar_lease = None
                finally:
                    self._closed = True

    def __exit__(self, *_args: object) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass


class PermissionPolicySourceLease:
    """Hold policy source handles without sharing write access during a state update."""

    def __init__(self, permission_policy: PermissionPolicy) -> None:
        self.permission_policy = permission_policy
        self._windows_handles: list[tuple[object, wintypes.HANDLE]] = []
        self._portable_streams: list[object] = []
        self._previous_lease: object | None = None
        self._closed = False

    def __enter__(self) -> "PermissionPolicySourceLease":
        global _ACTIVE_POLICY_SOURCE_LEASE
        expected_hashes = dict(self.permission_policy.source_hashes)
        try:
            for source, expected_identity in self.permission_policy.source_identities:
                path = Path(source)
                _assert_check_only_d_path_without_reparse(
                    path,
                    name="permission policy source lease",
                )
                expected_hash = expected_hashes.get(source)
                if expected_hash is None:
                    raise StatePolicyError("permission policy source lease hash is missing")
                if os.name == "nt":
                    kernel32, handle = _open_publish_handle(
                        path,
                        desired_access=GENERIC_READ,
                        share_mode=FILE_SHARE_READ,
                    )
                    try:
                        actual_identity = _publish_handle_info(kernel32, handle, path)
                        actual_hash = _sha256(_read_publish_handle_bytes(kernel32, handle))
                        if actual_identity != expected_identity or actual_hash != expected_hash:
                            raise StatePolicyError("permission policy source changed before lease")
                    except BaseException:
                        _close_publish_handle(kernel32, handle)
                        raise
                    self._windows_handles.append((kernel32, handle))
                else:
                    stream = path.open("rb")
                    try:
                        actual_hash = _sha256(stream.read())
                        if _file_handle_identity(path) != expected_identity or actual_hash != expected_hash:
                            raise StatePolicyError("permission policy source changed before lease")
                        stream.seek(0)
                    except BaseException:
                        stream.close()
                        raise
                    self._portable_streams.append(stream)
        except BaseException:
            self.close()
            raise
        self._previous_lease = _ACTIVE_POLICY_SOURCE_LEASE
        _ACTIVE_POLICY_SOURCE_LEASE = self
        return self

    def assert_unchanged(self) -> None:
        expected_hashes = dict(self.permission_policy.source_hashes)
        expected_sources = {
            _path_compare_key(source)
            for source, _identity in self.permission_policy.source_identities
        }
        home = Path(self.permission_policy.codex_home)
        for name in ("config.toml", *PERMISSION_POLICY_JSON_NAMES):
            candidate = home / name
            _assert_check_only_d_path_without_reparse(
                candidate,
                name="permission policy source lease",
            )
            if candidate.exists() != (_path_compare_key(str(candidate)) in expected_sources):
                raise StatePolicyError("permission policy source changed concurrently")
        if os.name == "nt" and len(self._windows_handles) != len(self.permission_policy.source_identities):
            raise StatePolicyError("permission policy source lease is incomplete")
        for source_index, (source, expected_identity) in enumerate(self.permission_policy.source_identities):
            path = Path(source)
            expected_hash = expected_hashes.get(source)
            if expected_hash is None or not path.exists():
                raise StatePolicyError("permission policy source changed concurrently")
            if os.name == "nt":
                kernel32, handle = self._windows_handles[source_index]
                if _publish_handle_info(kernel32, handle, path) != expected_identity:
                    raise StatePolicyError("permission policy source changed concurrently")
                if _file_handle_identity(path) != expected_identity:
                    raise StatePolicyError("permission policy source changed concurrently")
                if _sha256(_read_publish_handle_bytes(kernel32, handle)) != expected_hash:
                    raise StatePolicyError("permission policy source changed concurrently")
            else:
                if _file_handle_identity(path) != expected_identity or _sha256(path.read_bytes()) != expected_hash:
                    raise StatePolicyError("permission policy source changed concurrently")

    def close(self) -> None:
        global _ACTIVE_POLICY_SOURCE_LEASE
        if self._closed:
            return
        for kernel32, handle in reversed(self._windows_handles):
            _close_publish_handle(kernel32, handle)
        self._windows_handles.clear()
        for stream in reversed(self._portable_streams):
            try:
                stream.close()  # type: ignore[attr-defined]
            except OSError:
                pass
        self._portable_streams.clear()
        if _ACTIVE_POLICY_SOURCE_LEASE is self:
            _ACTIVE_POLICY_SOURCE_LEASE = self._previous_lease
        self._closed = True

    def __exit__(self, *_args: object) -> None:
        self.close()


def _rename_temp_by_handle(
    kernel32: object,
    handle: wintypes.HANDLE,
    target: Path,
    *,
    replace_if_exists: bool,
) -> None:
    ntdll = ctypes.WinDLL("ntdll", use_last_error=True)
    ntdll.NtSetInformationFile.argtypes = (
        wintypes.HANDLE,
        ctypes.POINTER(_IoStatusBlock),
        ctypes.c_void_p,
        wintypes.ULONG,
        ctypes.c_int,
    )
    ntdll.NtSetInformationFile.restype = ctypes.c_long
    ntdll.RtlNtStatusToDosError.argtypes = (ctypes.c_long,)
    ntdll.RtlNtStatusToDosError.restype = wintypes.ULONG
    target_leaf = PureWindowsPath(str(target)).name
    name_bytes = target_leaf.encode("utf-16-le")
    root_offset = ctypes.sizeof(ctypes.c_void_p)
    length_offset = root_offset + ctypes.sizeof(ctypes.c_void_p)
    name_offset = length_offset + ctypes.sizeof(wintypes.DWORD)
    buffer_length = name_offset + len(name_bytes)
    rename_buffer = ctypes.create_string_buffer(buffer_length)
    flags = FILE_RENAME_POSIX_SEMANTICS
    if replace_if_exists:
        flags |= FILE_RENAME_REPLACE_IF_EXISTS
    ctypes.memmove(rename_buffer, ctypes.byref(ctypes.c_uint32(flags)), 4)
    ctypes.memset(ctypes.addressof(rename_buffer) + root_offset, 0, ctypes.sizeof(ctypes.c_void_p))
    ctypes.memmove(
        ctypes.addressof(rename_buffer) + length_offset,
        ctypes.byref(ctypes.c_uint32(len(name_bytes))),
        ctypes.sizeof(wintypes.DWORD),
    )
    ctypes.memmove(
        ctypes.addressof(rename_buffer) + name_offset,
        name_bytes,
        len(name_bytes),
    )
    io_status = _IoStatusBlock()
    status = ntdll.NtSetInformationFile(
        handle,
        ctypes.byref(io_status),
        ctypes.byref(rename_buffer),
        buffer_length,
        FILE_RENAME_INFORMATION_EX,
    )
    if status != 0:
        error = int(ntdll.RtlNtStatusToDosError(status))
        raise StatePolicyError(f"state publish rename failed ({error})")


def _move_path_by_name(source: Path, target: Path, *, replace_if_exists: bool) -> None:
    """Use native no-replace name publication for the lease hand-off."""
    if os.name != "nt":
        if target.exists() and not replace_if_exists:
            raise StatePolicyError("state publish target appeared concurrently")
        os.replace(source, target)
        return
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.MoveFileExW.argtypes = (wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD)
    kernel32.MoveFileExW.restype = wintypes.BOOL
    flags = MOVEFILE_WRITE_THROUGH
    if replace_if_exists:
        flags |= MOVEFILE_REPLACE_EXISTING
    if not kernel32.MoveFileExW(str(source), str(target), flags):
        error = int(ctypes.get_last_error())
        if not replace_if_exists and target.exists():
            raise StatePolicyError("state publish target appeared concurrently")
        raise StatePolicyError(f"state publish path move failed ({error})")


def _restore_bytes_no_replace(path: Path, data: bytes) -> bool:
    """Restore a lease snapshot without overwriting a competitor."""
    if path.exists():
        return False
    temporary = _write_same_directory_temp(path, data)
    kernel32: object | None = None
    handle: wintypes.HANDLE | None = None
    try:
        if os.name != "nt":
            if path.exists():
                return False
            os.link(temporary, path)
            return path.is_file() and path.read_bytes() == data
        kernel32, handle = _open_publish_handle(
            temporary,
            desired_access=GENERIC_READ | DELETE_ACCESS | SYNCHRONIZE_ACCESS,
            share_mode=0,
        )
        identity = _publish_handle_info(kernel32, handle, temporary)
        if _sha256(_read_publish_handle_bytes(kernel32, handle)) != _sha256(data):
            return False
        _rename_temp_by_handle(kernel32, handle, path, replace_if_exists=False)
        return _publish_handle_info(kernel32, handle, path) == identity and _read_publish_handle_bytes(
            kernel32, handle
        ) == data
    except (OSError, StatePolicyError):
        return False
    finally:
        if kernel32 is not None and handle is not None:
            _close_publish_handle(kernel32, handle)
        temporary.unlink(missing_ok=True)


def _publish_temp_file(
    path: Path,
    temp_path: Path,
    *,
    expected_hash: str | None = None,
    expected_identity: tuple[int, int] | None = None,
    replace_if_exists: bool = True,
    permission_policy: PermissionPolicy | None = None,
) -> tuple[int, int]:
    """Publish a same-directory temp while holding a verified target lease."""
    _assert_check_only_d_path_without_reparse(path, name="state publish target")
    _assert_check_only_d_path_without_reparse(temp_path, name="state publish temporary")
    replacement_identity = _file_handle_identity(temp_path)
    if replacement_identity is None:
        raise StatePolicyError("state publish temporary identity unavailable")
    if os.name != "nt":
        if path.exists():
            if expected_identity is not None and _file_handle_identity(path) != expected_identity:
                raise StatePolicyError("state publish target changed concurrently")
            if expected_hash is not None and _sha256(path.read_bytes()) != expected_hash:
                raise StatePolicyError("state publish target changed concurrently")
        elif not replace_if_exists:
            raise StatePolicyError("state publish target appeared concurrently")
        os.replace(temp_path, path)
        published_identity = _file_handle_identity(path)
        if published_identity != replacement_identity:
            raise StatePolicyError("state publish postwrite identity mismatch")
        return published_identity

    target_kernel32: object | None = None
    target_handle: wintypes.HANDLE | None = None
    temp_kernel32: object | None = None
    temp_handle: wintypes.HANDLE | None = None
    lease_backup_path: Path | None = None
    lease_snapshot_path: Path | None = None
    lease_snapshot_identity: tuple[int, int] | None = None
    lease_snapshot_kernel32: object | None = None
    lease_snapshot_handle: wintypes.HANDLE | None = None
    snapshot_temporary: Path | None = None
    lease_handoff = False
    lease_published = False
    lease_snapshot_keep = False
    lease_expected_identity: tuple[int, int] | None = None
    target_snapshot_bytes: bytes | None = None
    try:
        target_exists = path.exists()
        if target_exists:
            target_kernel32, target_handle = _open_publish_handle(
                path,
                desired_access=GENERIC_READ | DELETE_ACCESS,
                share_mode=FILE_SHARE_READ | FILE_SHARE_DELETE,
            )
            target_identity = _publish_handle_info(target_kernel32, target_handle, path)
            if expected_identity is not None and target_identity != expected_identity:
                raise StatePolicyError("state publish target changed concurrently")
            target_snapshot_bytes = _read_publish_handle_bytes(target_kernel32, target_handle)
            if expected_hash is not None and _sha256(target_snapshot_bytes) != expected_hash:
                raise StatePolicyError("state publish target changed concurrently")
        elif not replace_if_exists:
            # A missing target is intentionally published with a no-replace
            # rename, so a competing creator cannot be overwritten.
            target_identity = None
        else:
            target_identity = None

        temp_kernel32, temp_handle = _open_publish_handle(
            temp_path,
            desired_access=GENERIC_READ | DELETE_ACCESS | SYNCHRONIZE_ACCESS,
            share_mode=0,
        )
        if _publish_handle_info(temp_kernel32, temp_handle, temp_path) != replacement_identity:
            raise StatePolicyError("state publish temporary changed concurrently")
        if target_exists and expected_identity is not None:
            if _file_handle_identity(path) != expected_identity:
                raise StatePolicyError("state publish target changed concurrently")
        if target_exists and expected_hash is not None:
            # Sample the same leased handle again immediately before the
            # native rename.  This catches an already-open writer that changed
            # the inode after the initial sample; identity alone cannot detect
            # that case.
            if (
                _sha256(_read_publish_handle_bytes(target_kernel32, target_handle))
                != expected_hash
            ):
                raise StatePolicyError("state publish target changed concurrently")
        if target_exists:
            # Re-read the final path from the *same target handle* immediately
            # before the rename.  A competitor that renamed/recreated the path
            # after the preceding byte sample must fail closed instead of being
            # overwritten by REPLACE_IF_EXISTS.
            final_target_identity = _publish_handle_info(target_kernel32, target_handle, path)
            if expected_identity is not None and final_target_identity != expected_identity:
                raise StatePolicyError("state publish target changed concurrently")
            if expected_hash is not None and _sha256(_read_publish_handle_bytes(target_kernel32, target_handle)) != expected_hash:
                raise StatePolicyError("state publish target changed concurrently")
            if replace_if_exists:
                # There is no kernel compare-and-swap rename on Windows. Move
                # the verified old name away first, then publish the new name
                # with a native *no-replace* operation. Any competitor that
                # recreates the target in this hand-off window is preserved and
                # causes publication to fail closed instead of being replaced.
                lease_backup_path = path.parent / f".{path.name}.{uuid.uuid4().hex}.lease"
                _assert_check_only_d_path_without_reparse(
                    lease_backup_path,
                    name="state publish lease backup",
                )
                if lease_backup_path.exists():
                    raise StatePolicyError("state publish lease backup already exists")
                if target_snapshot_bytes is None:
                    raise StatePolicyError("state publish target snapshot is missing")
                lease_snapshot_path = path.parent / f".{path.name}.{uuid.uuid4().hex}.snapshot"
                _assert_check_only_d_path_without_reparse(
                    lease_snapshot_path,
                    name="state publish lease snapshot",
                )
                snapshot_temporary = _write_same_directory_temp(path, target_snapshot_bytes)
                lease_snapshot_kernel32, lease_snapshot_handle = _open_publish_handle(
                    snapshot_temporary,
                    desired_access=GENERIC_READ | DELETE_ACCESS | SYNCHRONIZE_ACCESS,
                    share_mode=0,
                )
                lease_snapshot_identity = _publish_handle_info(
                    lease_snapshot_kernel32,
                    lease_snapshot_handle,
                    snapshot_temporary,
                )
                if _sha256(
                    _read_publish_handle_bytes(lease_snapshot_kernel32, lease_snapshot_handle)
                ) != _sha256(target_snapshot_bytes):
                    raise StatePolicyError("state publish lease snapshot changed concurrently")
                _rename_temp_by_handle(
                    lease_snapshot_kernel32,
                    lease_snapshot_handle,
                    lease_snapshot_path,
                    replace_if_exists=False,
                )
                lease_snapshot_identity = _publish_handle_info(
                    lease_snapshot_kernel32,
                    lease_snapshot_handle,
                    lease_snapshot_path,
                )
                if _sha256(_read_publish_handle_bytes(lease_snapshot_kernel32, lease_snapshot_handle)) != _sha256(
                    target_snapshot_bytes
                ):
                    raise StatePolicyError("state publish lease snapshot changed concurrently")
                try:
                    final_snapshot_target_identity = _publish_handle_info(
                        target_kernel32,
                        target_handle,
                        path,
                    )
                except StatePolicyError as exc:
                    raise StatePolicyError("state publish target changed concurrently") from exc
                if final_snapshot_target_identity != target_identity or _sha256(
                    _read_publish_handle_bytes(target_kernel32, target_handle)
                ) != _sha256(target_snapshot_bytes):
                    raise StatePolicyError("state publish target changed concurrently")
                if permission_policy is not None:
                    _assert_permission_policy_fingerprint(permission_policy)
                lease_expected_identity = expected_identity if expected_identity is not None else target_identity
                lease_handoff = True
                _move_path_by_name(path, lease_backup_path, replace_if_exists=False)
                lease_identity = _file_handle_identity(lease_backup_path)
                if lease_identity != lease_expected_identity:
                    raise StatePolicyError("state publish target changed concurrently")
                if target_kernel32 is not None and target_handle is not None:
                    _close_publish_handle(target_kernel32, target_handle)
                    target_kernel32 = None
                    target_handle = None
                if path.exists():
                    raise StatePolicyError("state publish target appeared concurrently")
                if _publish_handle_info(temp_kernel32, temp_handle, temp_path) != replacement_identity:
                    raise StatePolicyError("state publish temporary changed concurrently")
                _rename_temp_by_handle(temp_kernel32, temp_handle, path, replace_if_exists=False)
                published_identity = _publish_handle_info(temp_kernel32, temp_handle, path)
                if published_identity != replacement_identity:
                    raise StatePolicyError("state publish postwrite identity mismatch")
                lease_published = True
                return published_identity
        _rename_temp_by_handle(
            temp_kernel32,
            temp_handle,
            path,
            replace_if_exists=target_exists and replace_if_exists,
        )
        published_identity = _publish_handle_info(temp_kernel32, temp_handle, path)
        if published_identity != replacement_identity:
            raise StatePolicyError("state publish postwrite identity mismatch")
        return published_identity
    except BaseException:
        if lease_handoff and not lease_published:
            if target_kernel32 is not None and target_handle is not None:
                _close_publish_handle(target_kernel32, target_handle)
                target_kernel32 = None
                target_handle = None
            try:
                lease_identity = _file_handle_identity(lease_backup_path) if lease_backup_path is not None else None
            except (OSError, StatePolicyError):
                lease_identity = None
            if lease_backup_path is not None and lease_identity is not None:
                try:
                    _move_path_by_name(lease_backup_path, path, replace_if_exists=False)
                except (OSError, StatePolicyError):
                    pass
            restored_original = False
            if target_snapshot_bytes is not None:
                try:
                    restored_original = (
                        path.exists()
                        and lease_expected_identity is not None
                        and _file_handle_identity(path) == lease_expected_identity
                    )
                except (OSError, StatePolicyError):
                    restored_original = False
                if not restored_original and not path.exists():
                    restored_original = _restore_bytes_no_replace(path, target_snapshot_bytes)
            lease_snapshot_keep = not restored_original
        raise
    finally:
        if temp_kernel32 is not None and temp_handle is not None:
            _close_publish_handle(temp_kernel32, temp_handle)
        if target_kernel32 is not None and target_handle is not None:
            _close_publish_handle(target_kernel32, target_handle)
        if lease_snapshot_kernel32 is not None and lease_snapshot_handle is not None:
            _close_publish_handle(lease_snapshot_kernel32, lease_snapshot_handle)
        if snapshot_temporary is not None:
            snapshot_temporary.unlink(missing_ok=True)
        if lease_published and lease_backup_path is not None:
            try:
                lease_is_original = (
                    lease_snapshot_identity is not None
                    and lease_expected_identity is not None
                    and _file_handle_identity(lease_backup_path) == lease_expected_identity
                    and target_snapshot_bytes is not None
                    and lease_backup_path.read_bytes() == target_snapshot_bytes
                )
                if lease_is_original:
                    lease_backup_path.unlink(missing_ok=True)
                else:
                    lease_snapshot_keep = True
            except (OSError, StatePolicyError):
                # A changed or unverifiable lease must retain the snapshot as
                # the last verified copy of the original bytes.
                lease_snapshot_keep = True
        if lease_snapshot_path is not None and not lease_snapshot_keep:
            try:
                if lease_snapshot_identity is not None and _file_handle_identity(lease_snapshot_path) == lease_snapshot_identity:
                    lease_snapshot_path.unlink(missing_ok=True)
            except (OSError, StatePolicyError):
                pass


def _write_same_directory_temp(path: Path, data: bytes) -> Path:
    _assert_check_only_d_path_without_reparse(
        path.parent,
        name="state writer target",
    )
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
        _assert_check_only_d_path_without_reparse(
            backup_root,
            name="global state backup root",
        )
        directory = backup_root / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}-{os.getpid()}-{uuid.uuid4().hex}"
        directory.mkdir(parents=True, exist_ok=False)
        _assert_check_only_d_path_without_reparse(
            directory,
            name="global state backup directory",
        )
        path = directory / ".codex-global-state.json"
        temp = _write_same_directory_temp(path, original)
        _publish_temp_file(path, temp, replace_if_exists=False)
        _fsync_parent(path)
        return path
    except OSError as exc:
        raise StatePolicyError("global state backup failed") from exc


def _update_global_state_impl(
    path: Path,
    backup_root: Path,
    *,
    permission_policy: PermissionPolicy | None = None,
    path_mode: str = "inventory",
    approved_map: object = None,
    source_root: Path | str | None = None,
    candidate_root: Path | str | None = None,
    check_only: bool = False,
    max_attempts: int = MAX_GLOBAL_ATTEMPTS,
    before_prewrite_check: Callable[[int], None] | None = None,
) -> dict[str, object]:
    if path_mode not in {"inventory", "repair-safe-only", "repair-all-approved"}:
        raise StatePolicyError("unknown state path mode")
    permission_policy = _resolve_policy_for_path(path, permission_policy)
    _assert_permission_policy_unchanged(permission_policy)
    if source_root is None:
        source_root = PROJECTLESS_SOURCE_ROOT
    if candidate_root is None:
        candidate_root = CANONICAL_CANDIDATE_ROOT
    _assert_check_only_d_path_without_reparse(path, name="global state source")
    if not path.is_file():
        return {
            "status": "missing",
            "changed": False,
            "wouldChange": False,
            "changedCount": 0,
            "driftCount": 0,
            "beforeSha256": None,
            "afterSha256": None,
            "attempts": 0,
            "pathInventory": None,
        }
    if max_attempts != MAX_GLOBAL_ATTEMPTS:
        raise StatePolicyError("global state retry contract is fixed")
    for attempt in range(1, max_attempts + 1):
        before_identity = _file_handle_identity(path)
        if before_identity is None:
            raise StatePolicyError("global state source disappeared")
        try:
            original = path.read_bytes()
        except OSError as exc:
            raise StatePolicyError("global state source is unreadable") from exc
        if _file_handle_identity(path) != before_identity:
            continue
        before_hash = _sha256(original)
        state = _strict_json_loads(original)
        inventory = build_path_inventory(state, source_root, candidate_root)
        normalized, summary = normalize_global_state(
            state,
            permission_policy=permission_policy,
            path_mode=path_mode,
            path_inventory=inventory,
            approved_map=approved_map,
        )
        changed_count = summary["pathChangedCount"] + summary["heartbeatChangedCount"]
        drift_count = summary["pathDriftCount"] + summary["heartbeatChangedCount"]
        if drift_count == 0:
            return {
                "status": "converged",
                "changed": False,
                "wouldChange": False,
                "changedCount": 0,
                "driftCount": 0,
                "beforeSha256": before_hash,
                "afterSha256": before_hash,
                "attempts": attempt,
                "pathInventory": inventory,
                **summary,
            }
        if check_only:
            return {
                "status": "drift",
                "changed": False,
                "wouldChange": True,
                "changedCount": changed_count,
                "driftCount": drift_count,
                "beforeSha256": before_hash,
                "afterSha256": before_hash,
                "attempts": attempt,
                "pathInventory": inventory,
                **summary,
            }
        if changed_count == 0:
            return {
                "status": "unresolved",
                "changed": False,
                "wouldChange": True,
                "changedCount": 0,
                "driftCount": drift_count,
                "beforeSha256": before_hash,
                "afterSha256": before_hash,
                "attempts": attempt,
                "pathInventory": inventory,
                **summary,
            }
        replacement = _json_bytes(normalized)
        temp_path = _write_same_directory_temp(path, replacement)
        policy_lease: PermissionPolicySourceLease | None = None
        target_lease: StateTargetLease | None = None
        try:
            try:
                create_backup(backup_root, original)
            except StatePolicyError:
                raise
            except OSError as exc:
                raise StatePolicyError("global state backup failed") from exc
            if before_prewrite_check is not None:
                before_prewrite_check(attempt)
            # Rebind the policy source and the target identity after all
            # potentially slow preparation, still inside the caller mutex.
            _assert_permission_policy_fingerprint(permission_policy)
            current = path.read_bytes()
            if (
                _sha256(current) != before_hash
                or _file_handle_identity(path) != before_identity
            ):
                continue
            approved_mappings = _validate_approved_map(inventory, approved_map, path_mode)
            _reprobe_approved_paths(inventory, approved_mappings, path_mode)
            replacement_identity = _file_handle_identity(temp_path)
            if replacement_identity is None:
                raise StatePolicyError("global state replacement identity unavailable")
            policy_lease = PermissionPolicySourceLease(permission_policy)
            policy_lease.__enter__()
            # Hold a verified target lease through the native class-65 rename;
            # the identity/hash checks also refuse a same-bytes replacement.
            published_identity = _publish_temp_file(
                path,
                temp_path,
                expected_hash=before_hash,
                expected_identity=before_identity,
                permission_policy=permission_policy,
            )
            _fsync_parent(path)
            published = path.read_bytes()
            if (
                published != replacement
                or published_identity != replacement_identity
            ):
                raise StatePolicyError("global state postwrite verification failed")
            try:
                target_lease = StateTargetLease(
                    path,
                    expected_identity=published_identity,
                    expected_hash=_sha256(published),
                )
                target_lease.__enter__()
                target_lease.assert_unchanged()
            except StatePolicyError as target_exc:
                if target_lease is not None:
                    target_lease.close()
                    target_lease = None
                _raise_global_policy_change_after_publish(
                    path,
                    original,
                    published,
                    published_identity,
                    target_exc,
                )
            try:
                _assert_permission_policy_fingerprint(permission_policy)
            except StatePolicyError as policy_exc:
                if target_lease is not None:
                    target_lease.close()
                    target_lease = None
                _raise_global_policy_change_after_publish(
                    path,
                    original,
                    published,
                    published_identity,
                    policy_exc,
                )
            published_state = _strict_json_loads(published)
            published_inventory = build_path_inventory(
                published_state,
                source_root,
                candidate_root,
            )
            _published_normalized, published_summary = normalize_global_state(
                published_state,
                permission_policy=permission_policy,
                path_mode="inventory",
                path_inventory=published_inventory,
                approved_map=None,
            )
            published_drift = (
                published_summary["pathDriftCount"]
                + published_summary["heartbeatChangedCount"]
            )
            try:
                if target_lease is None:
                    raise StatePolicyError("global state target lease is missing")
                target_lease.assert_unchanged()
                _assert_permission_policy_fingerprint(permission_policy)
                return {
                    "status": "updated",
                    "changed": True,
                    "wouldChange": True,
                    "changedCount": changed_count,
                    "driftCount": published_drift,
                    "beforeSha256": before_hash,
                    "afterSha256": _sha256(published),
                    "beforeIdentity": list(before_identity),
                    "afterIdentity": list(replacement_identity),
                    "attempts": attempt,
                    "pathInventory": published_inventory,
                    **summary,
                }
            except StatePolicyError as policy_exc:
                if target_lease is not None:
                    target_lease.close()
                    target_lease = None
                _raise_global_policy_change_after_publish(
                    path,
                    original,
                    published,
                    published_identity,
                    policy_exc,
                )
        finally:
            if target_lease is not None:
                target_lease.close()
            if policy_lease is not None:
                policy_lease.close()
            temp_path.unlink(missing_ok=True)
    raise StatePolicyError("global state concurrent updates did not stabilize")


def update_global_state(
    path: Path,
    backup_root: Path,
    *,
    permission_policy: PermissionPolicy | None = None,
    path_mode: str = "inventory",
    approved_map: object = None,
    source_root: Path | str | None = None,
    candidate_root: Path | str | None = None,
    check_only: bool = False,
    max_attempts: int = MAX_GLOBAL_ATTEMPTS,
    before_prewrite_check: Callable[[int], None] | None = None,
) -> dict[str, object]:
    resolved_policy = _resolve_policy_for_path(path, permission_policy)
    return _update_global_state_impl(
        path,
        backup_root,
        permission_policy=resolved_policy,
        path_mode=path_mode,
        approved_map=approved_map,
        source_root=source_root,
        candidate_root=candidate_root,
        check_only=check_only,
        max_attempts=max_attempts,
        before_prewrite_check=before_prewrite_check,
    )


THREAD_DRIFT_SQL = """
select id from threads
where source='vscode'
  and (thread_source='user' or thread_source is null)
  and (
    approval_mode is null or approval_mode <> ?
    or sandbox_policy is null
    or (
      sandbox_policy <> ?
      and (? <> '{"type":"disabled"}' or sandbox_policy <> 'danger-full-access')
    )
  )
order by id
"""


def select_thread_updates(
    conn: sqlite3.Connection,
    permission_policy: PermissionPolicy,
) -> list[str]:
    if not isinstance(permission_policy, PermissionPolicy):
        raise StatePolicyError("permission policy object is invalid")
    return [
        str(row[0])
        for row in conn.execute(
            THREAD_DRIFT_SQL,
            (
                permission_policy.approval_policy,
                permission_policy.sqlite_sandbox_policy,
                permission_policy.sqlite_sandbox_policy,
            ),
        )
    ]


def _capture_thread_rows(
    conn: sqlite3.Connection,
    thread_ids: list[str],
) -> dict[str, tuple[str | None, str | None]]:
    if not thread_ids:
        return {}
    placeholders = ",".join("?" for _ in thread_ids)
    rows = conn.execute(
        f"select id, approval_mode, sandbox_policy from threads where id in ({placeholders})",
        tuple(thread_ids),
    ).fetchall()
    captured: dict[str, tuple[str | None, str | None]] = {}
    for row in rows:
        if len(row) < 3 or not isinstance(row[0], str):
            raise StatePolicyError("thread state row snapshot is malformed")
        if (not isinstance(row[1], str) and row[1] is not None) or (
            not isinstance(row[2], str) and row[2] is not None
        ):
            raise StatePolicyError("thread state row snapshot is malformed")
        captured[row[0]] = (row[1], row[2])
    if len(captured) != len(thread_ids):
        raise StatePolicyError("thread state row disappeared during update")
    return captured


def _rollback_thread_rows_after_policy_change(
    conn: sqlite3.Connection,
    path: Path,
    source_identity: tuple[int, int],
    original_rows: dict[str, tuple[str | None, str | None]],
    permission_policy: PermissionPolicy,
) -> bool:
    """Reverse a committed update only when every row still matches its CAS value."""
    if not original_rows:
        return True
    expected_new = (
        permission_policy.approval_policy,
        permission_policy.sqlite_sandbox_policy,
    )
    try:
        if _file_handle_identity(path) != source_identity:
            return False
        conn.execute("begin immediate")
        for thread_id, original in original_rows.items():
            current = conn.execute(
                "select approval_mode, sandbox_policy from threads where id=?",
                (thread_id,),
            ).fetchone()
            if current is None:
                conn.rollback()
                return False
            current_values = (current[0], current[1])
            if current_values == original:
                continue
            if current_values != expected_new:
                conn.rollback()
                return False
            changed = conn.execute(
                """
                update threads
                set approval_mode=?, sandbox_policy=?
                where id=? and approval_mode=? and sandbox_policy=?
                """,
                (
                    original[0],
                    original[1],
                    thread_id,
                    expected_new[0],
                    expected_new[1],
                ),
            )
            if changed.rowcount != 1:
                conn.rollback()
                return False
        if _file_handle_identity(path) != source_identity:
            conn.rollback()
            return False
        conn.commit()
        for thread_id, original in original_rows.items():
            current = conn.execute(
                "select approval_mode, sandbox_policy from threads where id=?",
                (thread_id,),
            ).fetchone()
            if current is None or (current[0], current[1]) != original:
                return False
        return True
    except (OSError, sqlite3.Error, StatePolicyError):
        try:
            conn.rollback()
        except sqlite3.Error:
            pass
        return False


def _raise_thread_policy_change_after_commit(
    conn: sqlite3.Connection,
    path: Path,
    source_identity: tuple[int, int],
    original_rows: dict[str, tuple[str | None, str | None]],
    permission_policy: PermissionPolicy,
    policy_exc: StatePolicyError,
) -> None:
    rolled_back = _rollback_thread_rows_after_policy_change(
        conn,
        path,
        source_identity,
        original_rows,
        permission_policy,
    )
    target_change = "target lease" in str(policy_exc).casefold() or "target" in str(policy_exc).casefold()
    subject = "thread state target lease" if target_change else "permission policy"
    if rolled_back:
        raise StatePolicyError(
            f"{subject} changed after thread commit; state rolled back"
        ) from policy_exc
    raise StatePolicyError(
        f"{subject} changed after thread commit; rollback failed"
    ) from policy_exc


def _capture_sqlite_source(
    path: Path,
    *,
    handle_sources: dict[int, tuple[object, wintypes.HANDLE]] | None = None,
) -> SqliteSourceSnapshot:
    paths = (
        path,
        Path(str(path) + "-wal"),
        Path(str(path) + "-shm"),
        Path(str(path) + "-journal"),
    )
    payload: list[bytes | None] = []
    identities: list[tuple[int, int] | None] = []
    metadata: list[tuple[bool, int | None, int | None, tuple[int, int] | None]] = []
    content_known: list[bool] = []
    try:
        for index, candidate in enumerate(paths):
            _assert_check_only_d_path_without_reparse(candidate, name="thread state source")
            missing_sidecar_lease = _active_sqlite_missing_sidecar_lease(candidate)
            if (
                index == 3
                and isinstance(missing_sidecar_lease, SqliteMissingSidecarLease)
            ):
                # The lease intentionally creates a zero-byte placeholder so
                # Windows can deny later child creation.  Keep that physical
                # file out of the logical SQLite source tuple.
                missing_sidecar_lease.assert_unchanged()
                payload.append(None)
                identities.append(None)
                metadata.append((False, None, None, _file_handle_identity(candidate.parent)))
                content_known.append(True)
                continue
            exists = candidate.exists()
            if not exists:
                payload.append(None)
                identities.append(None)
                metadata.append((False, None, None, _file_handle_identity(candidate.parent)))
                content_known.append(True)
                continue
            try:
                locked_source = (handle_sources or {}).get(index)
                if locked_source is not None:
                    raw = _read_publish_handle_bytes(*locked_source)
                else:
                    raw = candidate.read_bytes()
                known = True
            except PermissionError:
                if index == 0:
                    raise
                if index == 2:
                    # SQLite may deny a second byte reader for -shm while its
                    # connection owns offsets 120..127.  Do not silently
                    # replace a missing payload with metadata-only evidence:
                    # a same-size/same-mtime in-place write would otherwise
                    # be indistinguishable from a stable generation.  A
                    # read-only mapping remains observable on Windows and
                    # gives the strict return gate a real payload to compare.
                    raw = _read_sqlite_shm_mapped_bytes(candidate)
                    known = True
                else:
                    # SQLite may hold -wal/-journal with a sharing mode that
                    # denies a second byte reader.  Their complete byte-range
                    # leases and identity/metadata gates remain authoritative;
                    # SHM is never allowed to take this metadata-only path.
                    raw = None
                    known = False
            identity = _file_handle_identity(candidate)
            if identity is None:
                raise StatePolicyError("thread state source identity unavailable")
            stat = candidate.stat()
            parent_identity = _file_handle_identity(candidate.parent)
            payload.append(raw)
            identities.append(identity)
            metadata.append((True, int(stat.st_size), int(stat.st_mtime_ns), parent_identity))
            content_known.append(known)
    except OSError as exc:
        raise StatePolicyError("thread state source snapshot is busy") from exc
    return SqliteSourceSnapshot(
        payload=(payload[0], payload[1], payload[2], payload[3]),
        identities=(identities[0], identities[1], identities[2], identities[3]),
        metadata=(metadata[0], metadata[1], metadata[2], metadata[3]),
        content_known=(content_known[0], content_known[1], content_known[2], content_known[3]),
    )


def _sqlite_snapshot_has_unknown_sidecars(snapshot: SqliteSourceSnapshot) -> bool:
    known = getattr(snapshot, "content_known", None)
    if not isinstance(known, tuple) or len(known) != 4:
        return True
    return any(known[index] is not True for index in range(1, 4))


def _missing_permission_policy_supplementals(permission_policy: PermissionPolicy) -> tuple[str, ...]:
    home = Path(permission_policy.codex_home or "")
    return tuple(
        name
        for name in PERMISSION_POLICY_JSON_NAMES
        if not (home / name).is_file()
    )


def _sqlite_generation_unbounded(
    initial: SqliteSourceSnapshot,
    final: SqliteSourceSnapshot,
) -> bool:
    """Return whether the initial SQLite source-set cannot be leased safely."""
    missing_initial = {
        index
        for index in range(1, 4)
        if initial.identities[index] is None
    }
    if (
        missing_initial == {3}
        and initial.identities[1] is not None
        and initial.identities[2] is not None
    ):
        # A WAL database may legitimately have no rollback journal.  The
        # write path must first acquire SqliteMissingSidecarLease; this helper
        # only classifies the generation after that no-create proof exists.
        return False
    # Keep the final snapshot in the contract for callers that compare the
    # source generation, but never let a later required sidecar appearance
    # repair an initial gap.
    del final
    return bool(missing_initial)


def _connect_sqlite_bound(path: Path, expected_identity: tuple[int, int]) -> sqlite3.Connection:
    """Open SQLite and prove its main database resolves to the checked path."""
    try:
        conn = sqlite3.connect(path, timeout=1.5)
    except sqlite3.Error as exc:
        raise StatePolicyError("thread state database operation failed") from exc
    try:
        rows = conn.execute("pragma database_list").fetchall()
        main_paths = [str(row[2]) for row in rows if len(row) >= 3 and str(row[1]).casefold() == "main"]
        if len(main_paths) != 1 or _path_compare_key(main_paths[0]) != _path_compare_key(str(path)):
            raise StatePolicyError("thread state database path changed during connect")
        if _file_handle_identity(path) != expected_identity:
            raise StatePolicyError("thread state database changed during connect")
        return conn
    except (OSError, sqlite3.Error, StatePolicyError):
        conn.close()
        raise


def _assert_sqlite_snapshot_identity(
    before: SqliteSourceSnapshot,
    path: Path,
    *,
    allow_new_sidecars: bool,
    allow_removed_sidecars: bool = False,
    check_main_metadata: bool = True,
    check_sidecar_content: bool = False,
    handle_sources: dict[int, tuple[object, wintypes.HANDLE]] | None = None,
    locked_sidecar_indices: set[int] | None = None,
    sidecar_content_indices: set[int] | None = None,
    strict_sidecar_content_indices: set[int] | None = None,
) -> SqliteSourceSnapshot:
    """Reject path/identity replay between a checked snapshot and SQLite I/O."""
    if handle_sources:
        after = _capture_sqlite_source(path, handle_sources=handle_sources)
    else:
        after = _capture_sqlite_source(path)
    locked_indices = set(locked_sidecar_indices or {})
    content_indices = (
        set(range(1, 4))
        if sidecar_content_indices is None
        else set(sidecar_content_indices)
    )
    strict_indices = set(strict_sidecar_content_indices or {})
    if before.identities[0] != after.identities[0] or (
        check_main_metadata and before.metadata[0] != after.metadata[0]
    ):
        raise StatePolicyError("thread state concurrent replacement")
    for index in range(1, 4):
        expected = before.identities[index]
        actual = after.identities[index]
        if before.metadata[index][3] != after.metadata[index][3]:
            raise StatePolicyError("thread state sidecar parent changed concurrently")
        if expected is not None and actual is None and allow_removed_sidecars:
            continue
        if expected is not None and actual != expected:
            raise StatePolicyError("thread state sidecar concurrent replacement")
        if expected is None and actual is not None and not allow_new_sidecars:
            raise StatePolicyError("thread state sidecar appeared during check")
        if expected is not None and check_sidecar_content and index in content_indices:
            if index in locked_indices and index not in strict_indices:
                # A leased WAL/SHM/journal may legitimately change SQLite's
                # lock bytes while the identity/range lease prevents an
                # outsider from replacing or writing the generation.  SQLite
                # may also deny a second byte reader while this lease is
                # active; identity plus the byte-range lease is the stable
                # contract for content.  Metadata remains observable and
                # catches an output callback that writes the lock window.
                if before.metadata[index] != after.metadata[index]:
                    raise StatePolicyError("thread state sidecar metadata changed during return gate")
                continue
            if index == 2 and index not in strict_indices:
                # SQLite may legitimately rewrite the WAL-index lock window
                # while its active connection advances a transaction.  This
                # is only a pre-return identity/metadata gate; the final
                # SqliteTargetLease strict gate passes ``{2}`` and compares
                # the mapped payload in full, failing closed if it cannot be
                # observed.
                if before.metadata[index] != after.metadata[index]:
                    raise StatePolicyError("thread state sidecar metadata changed concurrently")
                continue
            if (
                not (index == 2 and index in strict_indices)
                and before.metadata[index] != after.metadata[index]
            ):
                raise StatePolicyError("thread state sidecar metadata changed concurrently")
            if index == 2 and index in strict_indices:
                if before.content_known[index] != after.content_known[index]:
                    raise StatePolicyError("thread state sidecar bytes unavailable during return gate")
            if (
                before.content_known[index]
                and after.content_known[index]
                and before.payload[index] != after.payload[index]
            ):
                raise StatePolicyError("thread state sidecar bytes changed concurrently")
    return after


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
    permission_policy: PermissionPolicy,
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
            if any(not first.content_known[index] for index in range(1, 4)):
                raise StatePolicyError("thread state sidecar bytes unavailable during check")
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
                    identities = select_thread_updates(conn, permission_policy)
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


def _apply_thread_policy_updates(
    connection: sqlite3.Connection,
    permission_policy: PermissionPolicy,
) -> tuple[list[str], int]:
    identities = select_thread_updates(connection, permission_policy)
    if identities:
        connection.execute(
            """
            update threads set approval_mode=?, sandbox_policy=?
            where source='vscode'
              and (thread_source='user' or thread_source is null)
              and (
                approval_mode is null or approval_mode <> ?
                or sandbox_policy is null
                or (
                  sandbox_policy <> ?
                  and (? <> '{"type":"disabled"}' or sandbox_policy <> 'danger-full-access')
                )
              )
            """,
            (
                permission_policy.approval_policy,
                permission_policy.sqlite_sandbox_policy,
                permission_policy.approval_policy,
                permission_policy.sqlite_sandbox_policy,
                permission_policy.sqlite_sandbox_policy,
            ),
        )
    drift_count = int(
        connection.execute(
            f"select count(*) from ({THREAD_DRIFT_SQL})",
            (
                permission_policy.approval_policy,
                permission_policy.sqlite_sandbox_policy,
                permission_policy.sqlite_sandbox_policy,
            ),
        ).fetchone()[0]
    )
    return identities, drift_count


def _build_expected_cold_sqlite_snapshot(
    source: SqliteSourceSnapshot,
    path: Path,
    permission_policy: PermissionPolicy,
) -> tuple[list[str], str, SqliteSourceSnapshot]:
    shadow_dir: Path | None = None
    shadow_lease: _DirectoryPathLease | None = None
    expected_targets: tuple[Path, ...] = ()
    cleanup_snapshot: SqliteSourceSnapshot | None = None
    with _DirectoryPathLease(path.parent):
        try:
            shadow_dir = Path(
                tempfile.mkdtemp(prefix="codex-state-policy-cold-expected-", dir=path.parent)
            )
            shadow_lease = _DirectoryPathLease(shadow_dir)
            shadow_lease.__enter__()
            shadow_db = shadow_dir / "state.sqlite"
            expected_targets = (
                shadow_db,
                Path(str(shadow_db) + "-wal"),
                Path(str(shadow_db) + "-shm"),
                Path(str(shadow_db) + "-journal"),
            )
            for index, target in enumerate(expected_targets):
                payload = source.payload[index]
                if payload is not None:
                    target.write_bytes(payload)
            connection = sqlite3.connect(shadow_db, timeout=1.5)
            try:
                connection.execute("pragma busy_timeout=1500")
                mode = str(
                    connection.execute("pragma locking_mode=exclusive").fetchone()[0]
                ).casefold()
                if mode != "exclusive":
                    raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
                connection.execute("pragma wal_autocheckpoint=0")
                connection.execute("begin immediate")
                identities, drift_count = _apply_thread_policy_updates(
                    connection,
                    permission_policy,
                )
                if drift_count:
                    raise StatePolicyError("thread state shadow drift remains before commit")
                expected_logical_hash = _sqlite_logical_hash(connection)
                connection.commit()
                connection.execute("begin immediate")
                if _sqlite_logical_hash(connection) != expected_logical_hash:
                    raise StatePolicyError("thread state shadow changed during commit")
                expected = _capture_sqlite_source(shadow_db)
                return identities, expected_logical_hash, expected
            finally:
                try:
                    connection.rollback()
                except sqlite3.Error:
                    pass
                connection.close()
                cleanup_snapshot = _capture_sqlite_source(shadow_db)
        except sqlite3.Error as exc:
            raise StatePolicyError("thread state shadow transaction failed") from exc
        finally:
            cleanup_error: BaseException | None = None
            if shadow_dir is not None:
                try:
                    if cleanup_snapshot is None:
                        raise StatePolicyError("cold state shadow cleanup generation unavailable")
                    for index, target in enumerate(expected_targets):
                        identity = cleanup_snapshot.identities[index]
                        payload = cleanup_snapshot.payload[index]
                        if identity is None:
                            if target.exists():
                                raise StatePolicyError(
                                    "cold state shadow file appeared before cleanup"
                                )
                            continue
                        if payload is None or cleanup_snapshot.content_known[index] is not True:
                            raise StatePolicyError(
                                "cold state shadow file bytes unavailable for cleanup"
                            )
                        _delete_owned_shadow_file(target, identity, payload)
                    if any(shadow_dir.iterdir()):
                        raise StatePolicyError("cold state shadow directory contains unknown entries")
                except BaseException as exc:
                    cleanup_error = exc
                finally:
                    if shadow_lease is not None:
                        shadow_lease.close()
                if cleanup_error is None:
                    try:
                        shadow_dir.rmdir()
                    except OSError as exc:
                        cleanup_error = StatePolicyError(
                            "cold state shadow directory cleanup failed"
                        )
                        cleanup_error.__cause__ = exc
            if cleanup_error is not None and sys.exc_info()[0] is None:
                raise cleanup_error


def _assert_expected_cold_physical_snapshot(
    expected: SqliteSourceSnapshot,
    actual: SqliteSourceSnapshot,
) -> None:
    for index in range(4):
        if (expected.identities[index] is None) != (actual.identities[index] is None):
            raise StatePolicyError(
                "thread state physical generation changed during commit; unsafe-partial"
            )
        if expected.content_known[index] is not True or actual.content_known[index] is not True:
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
        if expected.payload[index] != actual.payload[index]:
            raise StatePolicyError(
                "thread state physical generation changed during commit; unsafe-partial"
            )


def _update_thread_state_impl(
    path: Path,
    *,
    permission_policy: PermissionPolicy | None = None,
    check_only: bool = False,
    cold_maintenance: bool = False,
    maintenance_evidence: object = None,
    before_commit: Callable[[], None] | None = None,
    snapshot_root: Path | None = None,
    after_first_snapshot_capture: Callable[[int], None] | None = None,
    retain_return_lease: bool = False,
) -> dict[str, object]:
    # Keep the cold-maintenance return-lease contract at the implementation
    # boundary as well as the public wrapper.  Callers inside this module (or
    # tests/tools reaching the private helper directly) must not be able to
    # bypass the lease that closes the post-commit source-generation window.
    if cold_maintenance and not check_only and not retain_return_lease:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    permission_policy = _resolve_policy_for_path(path, permission_policy)
    _assert_permission_policy_unchanged(permission_policy)
    if cold_maintenance:
        _require_cold_maintenance_evidence(Path(permission_policy.codex_home or path.parent), maintenance_evidence)
    initial_snapshot = _capture_sqlite_source(path)
    if initial_snapshot.payload[0] is None:
        return {"status": "missing", "changedCount": 0, "wouldChangeCount": 0, "driftCount": 0}
    if check_only:
        if snapshot_root is None:
            raise StatePolicyError("thread state check snapshot root is required")
        identities, integrity_result_count = _select_thread_updates_from_snapshot(
            path,
            snapshot_root,
            permission_policy,
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
    if initial_snapshot.identities[2] is not None and not cold_maintenance:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    if _sqlite_snapshot_has_unknown_sidecars(initial_snapshot):
        raise StatePolicyError("thread state sidecar bytes unavailable for write")
    if cold_maintenance:
        # Cold repair is supported only for a bounded WAL generation.  A
        # rollback-journal database changes its main bytes at COMMIT and cannot
        # provide the same source-generation/return-lease contract; reject it
        # before opening a write transaction instead of committing then failing.
        if initial_snapshot.identities[1] is None or initial_snapshot.identities[2] is None:
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
        _assert_cold_maintenance_sources(
            Path(permission_policy.codex_home or path.parent)
        )
    source_identity = initial_snapshot.identities[0]
    if source_identity is None:
        raise StatePolicyError("thread state source disappeared")
    source_bytes_hash = _sha256(initial_snapshot.payload[0] or b"")
    missing_sidecar_lease: SqliteMissingSidecarLease | None = None
    if cold_maintenance and initial_snapshot.identities[3] is None:
        missing_sidecar_lease = SqliteMissingSidecarLease(
            Path(str(path) + "-journal")
        )
        missing_sidecar_lease.__enter__()
    try:
        conn = _connect_sqlite_bound(path, source_identity)
    except BaseException:
        if missing_sidecar_lease is not None:
            missing_sidecar_lease.close()
        raise
    policy_lease: PermissionPolicySourceLease | None = None
    return_lease: SqliteTargetLease | None = None
    return_lease_active = False
    return_lease_handoff = False
    expected_cold_logical_hash: str | None = None
    expected_cold_physical_snapshot: SqliteSourceSnapshot | None = None
    try:
        conn.execute("pragma busy_timeout=1500")
        if cold_maintenance:
            locking_mode = str(
                conn.execute("pragma locking_mode=exclusive").fetchone()[0]
            ).casefold()
            if locking_mode != "exclusive":
                raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
            # Keep the cold writer's WAL generation stable.  Automatic
            # checkpointing is a physical layout optimization and is deferred
            # until after the returned exclusive connection lease is released.
            conn.execute("pragma wal_autocheckpoint=0")
            connected_snapshot = _rebase_cold_sqlite_snapshot(
                path,
                source_identity,
                source_bytes_hash,
            )
            # Opening a quiescent WAL database can legitimately refresh the SHM
            # index metadata.  The no-share probe above proves that this refresh
            # belongs to our newly opened connection, so anchor all later gates
            # to the post-open source tuple rather than rejecting its own metadata.
            initial_snapshot = connected_snapshot
        _assert_sqlite_snapshot_identity(
            initial_snapshot,
            path,
            allow_new_sidecars=False,
            check_sidecar_content=True,
        )
        try:
            conn.execute("begin immediate")
        except sqlite3.OperationalError as exc:
            if cold_maintenance:
                raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
            raise StatePolicyError("thread state database busy") from exc
        try:
            if cold_maintenance:
                initial_snapshot = _rebase_cold_sqlite_snapshot(
                    path,
                    source_identity,
                    source_bytes_hash,
                )
            if _file_handle_identity(path) != source_identity:
                raise StatePolicyError("thread state concurrent replacement")
            if _sha256(path.read_bytes()) != source_bytes_hash:
                raise StatePolicyError("thread state concurrent update")
            _assert_sqlite_snapshot_identity(
                initial_snapshot,
                path,
                allow_new_sidecars=True,
                check_main_metadata=False,
                check_sidecar_content=True,
            )
            _assert_permission_policy_unchanged(permission_policy)
            identities = select_thread_updates(conn, permission_policy)
            original_rows = _capture_thread_rows(conn, identities)
            if cold_maintenance:
                (
                    shadow_identities,
                    expected_cold_logical_hash,
                    expected_cold_physical_snapshot,
                ) = _build_expected_cold_sqlite_snapshot(
                    initial_snapshot,
                    path,
                    permission_policy,
                )
                if shadow_identities != identities:
                    raise StatePolicyError(
                        "thread state shadow selection changed concurrently"
                    )
            applied_identities, drift_count = _apply_thread_policy_updates(
                conn,
                permission_policy,
            )
            if applied_identities != identities:
                raise StatePolicyError("thread state selection changed before update")
            if drift_count:
                raise StatePolicyError("thread state drift remains before commit")
            if _file_handle_identity(path) != source_identity:
                raise StatePolicyError("thread state concurrent replacement")
            if _sha256(path.read_bytes()) != source_bytes_hash:
                raise StatePolicyError("thread state concurrent update")
            transaction_snapshot = _capture_sqlite_source(path)
            # SQLite may own the WAL/SHM handles after the update starts, so a
            # late byte read can become unavailable even though the initial
            # source snapshot was fully known.  The initial fail-closed gate,
            # plus the identity/metadata checks below, anchors this generation
            # without rejecting a legitimate SQLite-owned sidecar.
            if before_commit is not None:
                before_commit()
            policy_lease = PermissionPolicySourceLease(permission_policy)
            policy_lease.__enter__()
            if _file_handle_identity(path) != source_identity:
                raise StatePolicyError("thread state concurrent replacement")
            if _sha256(path.read_bytes()) != source_bytes_hash:
                raise StatePolicyError("thread state concurrent update")
            _assert_sqlite_snapshot_identity(
                transaction_snapshot,
                path,
                allow_new_sidecars=False,
                check_main_metadata=False,
                check_sidecar_content=True,
                sidecar_content_indices={2} if cold_maintenance else None,
                strict_sidecar_content_indices={2} if cold_maintenance else None,
            )
            _assert_permission_policy_fingerprint(permission_policy)
            _assert_sqlite_snapshot_identity(
                transaction_snapshot,
                path,
                allow_new_sidecars=False,
                check_main_metadata=False,
                check_sidecar_content=True,
                sidecar_content_indices={2} if cold_maintenance else None,
                strict_sidecar_content_indices={2} if cold_maintenance else None,
            )
            _assert_sqlite_snapshot_identity(
                transaction_snapshot,
                path,
                allow_new_sidecars=False,
                check_main_metadata=False,
                check_sidecar_content=True,
                sidecar_content_indices={2} if cold_maintenance else None,
                strict_sidecar_content_indices={2} if cold_maintenance else None,
            )
            if _file_handle_identity(path) != source_identity:
                raise StatePolicyError("thread state concurrent replacement")
            if _sha256(path.read_bytes()) != source_bytes_hash:
                raise StatePolicyError("thread state concurrent update")
            if cold_maintenance and _sqlite_logical_hash(conn) != expected_cold_logical_hash:
                raise StatePolicyError("thread state live transaction differs from shadow")
            conn.commit()
            try:
                _assert_permission_policy_fingerprint(permission_policy)
            except StatePolicyError as policy_exc:
                _raise_thread_policy_change_after_commit(
                    conn,
                    path,
                    source_identity,
                    original_rows,
                    permission_policy,
                    policy_exc,
                )
        except BaseException:
            conn.rollback()
            raise
        try:
            # Keep a RESERVED SQLite writer lease across every postcommit gate
            # and the return expression.  A competing SQLite writer must fail
            # instead of changing rows after the final policy check.
            conn.execute("begin immediate")
            return_lease_active = True
        except sqlite3.OperationalError as exc:
            raise StatePolicyError(
                "thread state target lease unavailable after commit; unsafe-partial"
            ) from exc
        if cold_maintenance:
            # COMMIT may legitimately checkpoint WAL pages into the main file,
            # so physical hashes cannot distinguish that transition from an
            # external SQLite writer.  Compare the transaction-visible logical
            # database captured before COMMIT with the state visible after the
            # RESERVED lease is reacquired.  Any intervening logical write is
            # an unsafe partial result and must never be rebased as success.
            if (
                expected_cold_logical_hash is None
                or _sqlite_logical_hash(conn) != expected_cold_logical_hash
            ):
                raise StatePolicyError(
                    "thread state changed during commit handoff; unsafe-partial"
                )
            postcommit_snapshot = _rebase_cold_sqlite_snapshot(
                path,
                source_identity,
                None,
            )
            _assert_no_new_sqlite_sidecars(transaction_snapshot, postcommit_snapshot)
            if expected_cold_physical_snapshot is None:
                raise StatePolicyError("thread state expected physical generation is missing")
            _assert_expected_cold_physical_snapshot(
                expected_cold_physical_snapshot,
                postcommit_snapshot,
            )
            transaction_snapshot = postcommit_snapshot
        if _file_handle_identity(path) != source_identity:
            raise StatePolicyError("thread state concurrent replacement")
        verify_count = int(
            conn.execute(
                f"select count(*) from ({THREAD_DRIFT_SQL})",
                (
                    permission_policy.approval_policy,
                    permission_policy.sqlite_sandbox_policy,
                    permission_policy.sqlite_sandbox_policy,
                ),
            ).fetchone()[0]
        )
        if verify_count:
            raise StatePolicyError("thread state postcommit drift remains")
        if _file_handle_identity(path) != source_identity:
            raise StatePolicyError("thread state concurrent replacement")
        final_snapshot = _assert_sqlite_snapshot_identity(
            transaction_snapshot,
            path,
            allow_new_sidecars=False,
            allow_removed_sidecars=True,
            check_main_metadata=False,
            check_sidecar_content=cold_maintenance,
            sidecar_content_indices={2} if cold_maintenance else None,
            strict_sidecar_content_indices={2} if cold_maintenance else None,
        )
        try:
            _assert_permission_policy_fingerprint(permission_policy)
            result = {
                "status": "updated" if identities else "converged",
                "changedCount": len(identities),
                "wouldChangeCount": len(identities),
                "driftCount": verify_count,
                "_sourceSnapshot": final_snapshot,
            }
            if retain_return_lease:
                return_lease = SqliteTargetLease.from_connection(
                    path,
                    expected_identity=source_identity,
                    permission_policy=permission_policy,
                    expected_snapshot=final_snapshot,
                    connection=conn,
                    missing_sidecar_lease=missing_sidecar_lease,
                )
                # Keep the same SQLite connection (and its SHM lock bytes)
                # alive through the caller's output envelope.  Closing it and
                # reacquiring a complete SHM byte lock would create an
                # unobservable close-to-lock window at offsets 120..127.
                # Retaining the connection makes that handoff unnecessary:
                # SQLite itself owns the lock window while our leases cover
                # every other byte and sidecar name.
                return_lease_handoff = True
                missing_sidecar_lease = None
                result["_returnLease"] = return_lease
            return result
        except StatePolicyError as policy_exc:
            if return_lease_handoff:
                if return_lease is not None:
                    return_lease.close()
                return_lease_handoff = False
                raise
            if return_lease_active:
                conn.rollback()
                return_lease_active = False
            _raise_thread_policy_change_after_commit(
                conn,
                path,
                source_identity,
                original_rows,
                permission_policy,
                policy_exc,
            )
    except StatePolicyError:
        raise
    except sqlite3.OperationalError as exc:
        if "locked" in str(exc).lower() or "busy" in str(exc).lower():
            if cold_maintenance:
                raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
            raise StatePolicyError("thread state database busy") from exc
        raise StatePolicyError("thread state database operation failed") from exc
    finally:
        if return_lease_active and not return_lease_handoff:
            try:
                conn.rollback()
            except sqlite3.Error:
                pass
        try:
            if policy_lease is not None:
                policy_lease.close()
        finally:
            try:
                if not return_lease_handoff:
                    conn.close()
            finally:
                if missing_sidecar_lease is not None:
                    missing_sidecar_lease.close()


def update_thread_state(
    path: Path,
    *,
    permission_policy: PermissionPolicy | None = None,
    check_only: bool = False,
    cold_maintenance: bool = False,
    maintenance_evidence: object = None,
    before_commit: Callable[[], None] | None = None,
    snapshot_root: Path | None = None,
    after_first_snapshot_capture: Callable[[int], None] | None = None,
    retain_return_lease: bool = False,
) -> dict[str, object]:
    resolved_policy = _resolve_policy_for_path(path, permission_policy)
    if cold_maintenance and not check_only and not retain_return_lease:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    return _update_thread_state_impl(
        path,
        permission_policy=resolved_policy,
        check_only=check_only,
        cold_maintenance=cold_maintenance,
        maintenance_evidence=maintenance_evidence,
        before_commit=before_commit,
        snapshot_root=snapshot_root,
        after_first_snapshot_capture=after_first_snapshot_capture,
        retain_return_lease=retain_return_lease,
    )


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
    _assert_check_only_d_path_without_reparse(path, name="state policy health target")
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _json_bytes(envelope)
    temp = _write_same_directory_temp(path, data)
    try:
        _publish_temp_file(path, temp)
        _fsync_parent(path)
    finally:
        temp.unlink(missing_ok=True)


def _safe_error(exc: BaseException) -> str:
    known = str(exc).lower()
    if COLD_MAINTENANCE_REQUIRED in known:
        return COLD_MAINTENANCE_REQUIRED
    if "cold maintenance" in known or ("shm" in known and "generation" in known):
        return "state policy generation requires cold maintenance"
    if "generation-unbounded" in known or ("generation" in known and "unbounded" in known):
        return "state policy generation is unbounded"
    if "busy" in known:
        return "state policy resource busy"
    if "sidecar bytes unavailable" in known:
        return "state policy sidecar bytes unavailable"
    if "malformed" in known or "json" in known:
        return "global state validation failed"
    if "backup" in known:
        return "global state backup failed"
    if "concurrent" in known:
        return "global state concurrent update limit reached"
    return "state policy operation failed"


def _require_cold_maintenance_evidence(
    codex_home: Path,
    evidence: object,
) -> None:
    """Validate the explicit, offline contract required for SQLite WAL repair."""
    if not isinstance(evidence, dict):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    if evidence.get("schema") != COLD_MAINTENANCE_EVIDENCE_VERSION:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    try:
        _validate_inventory_root(
            codex_home,
            name="cold maintenance home",
            required_drive="D:",
        )
    except StatePolicyError as exc:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
    evidence_home = evidence.get("codexHome")
    if (
        not isinstance(evidence_home, str)
        or _path_compare_key(evidence_home) != _path_compare_key(str(codex_home))
    ):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    if evidence.get("sqliteStopped") is not True:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    if evidence.get("backupVerified") is not True:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    backup_path_value = evidence.get("backupPath")
    backup_hash = evidence.get("backupSha256")
    backup_identity = evidence.get("backupIdentity")
    if (
        not isinstance(backup_path_value, str)
        or not isinstance(backup_hash, str)
        or not re.fullmatch(r"[0-9a-f]{64}", backup_hash)
        or not isinstance(backup_identity, (list, tuple))
        or len(backup_identity) != 2
        or not all(isinstance(value, int) and value >= 0 for value in backup_identity)
    ):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    try:
        backup_windows = _validate_inventory_root(
            backup_path_value,
            name="cold maintenance backup",
            required_drive="D:",
        )
        backup_path = Path(str(backup_windows))
        _assert_check_only_d_path_without_reparse(
            backup_path,
            name="cold maintenance backup",
        )
        if not backup_path.is_file() or backup_path.is_symlink():
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
        actual_identity = _file_handle_identity(backup_path)
        if actual_identity is None or list(actual_identity) != list(backup_identity):
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
        if _sha256(backup_path.read_bytes()) != backup_hash:
            raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    except (OSError, StatePolicyError) as exc:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
    source_database_identity = evidence.get("sourceDatabaseIdentity")
    source_database_hash = evidence.get("sourceDatabaseSha256")
    expected_source_set = _normalise_cold_source_set(evidence.get("sourceSet"))
    expected_source_hashes = _normalise_cold_source_hashes(evidence.get("sourceHashes"))
    if (
        not isinstance(source_database_identity, (list, tuple))
        or len(source_database_identity) != 2
        or not all(isinstance(value, int) and value >= 0 for value in source_database_identity)
        or not isinstance(source_database_hash, str)
        or not re.fullmatch(r"[0-9a-f]{64}", source_database_hash)
        or expected_source_set is None
        or expected_source_hashes is None
    ):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    try:
        source_snapshot, actual_source_set, actual_source_hashes = _capture_cold_source_generation(codex_home)
    except (OSError, StatePolicyError) as exc:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED) from exc
    if (
        expected_source_set != actual_source_set
        or expected_source_hashes != actual_source_hashes
        or actual_source_set.get("state_5.sqlite") != list(source_database_identity)
        or actual_source_hashes.get("state_5.sqlite") != source_database_hash
        or source_snapshot.payload[0] is None
        or _sha256(source_snapshot.payload[0]) != source_database_hash
        or backup_hash != source_database_hash
    ):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    source_paths = {
        _path_compare_key(str(codex_home / name))
        for name in actual_source_set
    }
    if _path_compare_key(backup_path_value) in source_paths:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    if list(backup_identity) in actual_source_set.values():
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)


def build_cold_maintenance_evidence(
    codex_home: Path,
    backup_path: Path,
) -> dict[str, object]:
    """Create evidence only after the source set and backup pass cold gates."""
    _validate_inventory_root(codex_home, name="cold maintenance home", required_drive="D:")
    backup_windows = _validate_inventory_root(
        backup_path,
        name="cold maintenance backup",
        required_drive="D:",
    )
    backup = Path(str(backup_windows))
    _assert_check_only_d_path_without_reparse(backup, name="cold maintenance backup")
    if not backup.is_file() or backup.is_symlink():
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    identity = _file_handle_identity(backup)
    if identity is None:
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    source_snapshot, source_set, source_hashes = _capture_cold_source_generation(codex_home)
    backup_hash = _sha256(backup.read_bytes())
    if (
        source_snapshot.payload[0] is None
        or backup_hash != source_hashes.get("state_5.sqlite")
        or _path_compare_key(str(backup))
        in {_path_compare_key(str(codex_home / name)) for name in source_set}
        or list(identity) in source_set.values()
    ):
        raise StatePolicyError(COLD_MAINTENANCE_REQUIRED)
    evidence: dict[str, object] = {
        "schema": COLD_MAINTENANCE_EVIDENCE_VERSION,
        "codexHome": str(codex_home),
        "sqliteStopped": True,
        "backupVerified": True,
        "backupPath": str(backup),
        "backupSha256": backup_hash,
        "backupIdentity": list(identity),
        "sourceDatabaseIdentity": source_set["state_5.sqlite"],
        "sourceDatabaseSha256": source_hashes["state_5.sqlite"],
        "sourceSet": source_set,
        "sourceHashes": source_hashes,
    }
    _require_cold_maintenance_evidence(codex_home, evidence)
    return evidence


def _redact_path_inventory(inventory: object) -> object:
    """Keep inventory disposition evidence while omitting raw local values."""
    if not isinstance(inventory, dict):
        return inventory
    redacted: dict[str, object] = {}
    for key in (
        "inventoryGeneration",
        "stateSha256",
        "mappingSha256",
        "sourceRootAllowed",
        "candidateRootAllowed",
        "safeAdvisory",
        "repairContract",
    ):
        if key in inventory:
            redacted[key] = copy.deepcopy(inventory[key])
    for key in ("sourceRoot", "candidateRoot"):
        if key in redacted:
            redacted[key] = "<omitted>"
    redacted["sourceRoot"] = "<omitted>"
    redacted["candidateRoot"] = "<omitted>"
    maps = redacted.get("maps")
    inventory_maps = inventory.get("maps")
    evidence: list[dict[str, object]] = []
    if isinstance(inventory_maps, dict):
        for entries in inventory_maps.values():
            if not isinstance(entries, dict):
                continue
            for entry in entries.values():
                if not isinstance(entry, dict):
                    continue
                evidence.append(
                    {
                        "safe": bool(entry.get("safe")),
                        "reason": entry.get("reason")
                        if isinstance(entry.get("reason"), str)
                        else "unknown",
                        "reparse": bool(entry.get("reparse")),
                        "sourceSha256": entry.get("sourceSha256")
                        if isinstance(entry.get("sourceSha256"), str)
                        else None,
                        "finalIdentity": copy.deepcopy(entry.get("finalIdentity")),
                    }
                )
    redacted["entries"] = evidence
    unknown = inventory.get("unknown")
    redacted["unknownCount"] = len(unknown) if isinstance(unknown, dict) else 0
    redacted.pop("maps", None)
    return redacted


def _restore_global_state_snapshot(
    path: Path,
    original: bytes,
    *,
    expected_hash: str,
    expected_identity: tuple[int, int] | None,
) -> bool:
    """Best-effort reverse CAS used only while the domain mutex is held."""
    try:
        _assert_check_only_d_path_without_reparse(path, name="global state rollback target")
        if not path.is_file():
            return False
        current = path.read_bytes()
        current_identity = _file_handle_identity(path)
        if _sha256(current) != expected_hash:
            return False
        if expected_identity is not None and current_identity != expected_identity:
            return False
        replacement = _write_same_directory_temp(path, original)
        try:
            replacement_identity = _file_handle_identity(replacement)
            if replacement_identity is None:
                return False
            if _sha256(path.read_bytes()) != expected_hash or _file_handle_identity(path) != current_identity:
                return False
            _publish_temp_file(
                path,
                replacement,
                expected_hash=expected_hash,
                expected_identity=expected_identity,
            )
            _fsync_parent(path)
            return (
                path.read_bytes() == original
                and _file_handle_identity(path) == replacement_identity
            )
        finally:
            replacement.unlink(missing_ok=True)
    except (OSError, StatePolicyError):
        return False


def _raise_global_policy_change_after_publish(
    path: Path,
    original: bytes,
    published: bytes,
    published_identity: tuple[int, int],
    policy_exc: StatePolicyError,
) -> None:
    rolled_back = _restore_global_state_snapshot(
        path,
        original,
        expected_hash=_sha256(published),
        expected_identity=published_identity,
    )
    target_change = "target lease" in str(policy_exc).casefold() or "target" in str(policy_exc).casefold()
    subject = "global state target lease" if target_change else "permission policy"
    if rolled_back:
        raise StatePolicyError(
            f"{subject} changed after global publish; state rolled back"
        ) from policy_exc
    raise StatePolicyError(
        f"{subject} changed after global publish; rollback failed"
    ) from policy_exc


def _claim_global_publication_after_failure(
    path: Path,
    before: bytes | None,
    before_identity: tuple[int, int] | None,
) -> dict[str, object]:
    """Recover a non-optional publication fact when a postwrite step raises."""
    claim: dict[str, object] = {
        "status": "unsafe-partial",
        "changed": True,
        "wouldChange": True,
        "changedCount": 1,
        "driftCount": 0,
        "beforeSha256": _sha256(before) if before is not None else None,
        "afterSha256": None,
        "beforeIdentity": list(before_identity) if before_identity is not None else None,
        "afterIdentity": None,
        "pathInventory": None,
    }
    try:
        _assert_check_only_d_path_without_reparse(path, name="global state publication claim")
        if not path.is_file():
            return claim
        current = path.read_bytes()
        current_identity = _file_handle_identity(path)
        if current_identity is None:
            return claim
        current_hash = _sha256(current)
        claim["afterSha256"] = current_hash
        claim["afterIdentity"] = list(current_identity)
        if before is not None and before_identity is not None and current == before and current_identity == before_identity:
            claim.update(
                {
                    "status": "not-published",
                    "changed": False,
                    "wouldChange": False,
                    "changedCount": 0,
                }
            )
        else:
            claim["status"] = "published-unknown"
    except (OSError, StatePolicyError):
        # A missing/unreadable target is itself unsafe-partial: the caller must
        # not report not-run or silently assume that no bytes were published.
        return claim
    return claim


def run_policy(
    codex_home: Path,
    *,
    check_only: bool,
    health_root: Path,
    output: TextIO = sys.stdout,
    write_health: bool | None = None,
    path_mode: str = "inventory",
    permission_policy: PermissionPolicy | None = None,
    approved_map: object = None,
    cold_maintenance: bool = False,
    maintenance_evidence: object = None,
) -> dict[str, object]:
    if write_health is None:
        write_health = not check_only
    started = datetime.now(timezone.utc)
    started_clock = time.monotonic()
    run_id = uuid.uuid4().hex
    errors: list[str] = []
    global_result: dict[str, object] = {
        "status": "not-run",
        "changed": False,
        "changedCount": 0,
        "driftCount": 0,
        "pathInventory": None,
    }
    thread_result: dict[str, object] = {"status": "not-run", "changedCount": 0, "wouldChangeCount": 0, "driftCount": 0}
    policy_return_lease: PermissionPolicySourceLease | None = None
    global_return_lease: StateTargetLease | None = None
    sqlite_return_lease: SqliteTargetLease | None = None
    pending_sqlite_return_lease: SqliteTargetLease | None = None
    sqlite_changed = False
    try:
        if permission_policy is None:
            permission_policy = resolve_permission_policy(codex_home)
        elif not isinstance(permission_policy, PermissionPolicy):
            raise StatePolicyError("permission policy object is invalid")
        if cold_maintenance:
            _require_cold_maintenance_evidence(codex_home, maintenance_evidence)
        if not check_only:
            missing_policy_sources = _missing_permission_policy_supplementals(permission_policy)
            if missing_policy_sources:
                errors.extend(("generation-unbounded", "unsafe-partial"))
                raise StatePolicyError("permission policy source generation is unbounded")
        global_path = codex_home / ".codex-global-state.json"
        db_path = codex_home / "state_5.sqlite"
        with WindowsNamedMutex():
            # Capture both domains before publication.  The SQLite tuple is
            # compared after a downstream failure so a committed partial write
            # is reported as unsafe instead of being mistaken for a clean run.
            _assert_permission_policy_unchanged(permission_policy)
            policy_return_lease = PermissionPolicySourceLease(permission_policy)
            policy_return_lease.__enter__()
            global_snapshot: bytes | None = None
            global_snapshot_identity: tuple[int, int] | None = None
            _assert_check_only_d_path_without_reparse(
                global_path,
                name="global state source",
            )
            if not global_path.is_file():
                raise StatePolicyError("global state source is missing")
            if global_path.is_file():
                global_snapshot_identity = _file_handle_identity(global_path)
                global_snapshot = global_path.read_bytes()
                if (
                    global_snapshot_identity is None
                    or _file_handle_identity(global_path) != global_snapshot_identity
                ):
                    raise StatePolicyError("global state source changed while snapshotting")
            _assert_check_only_d_path_without_reparse(db_path, name="thread state source")
            if not db_path.is_file():
                raise StatePolicyError("thread state source is missing")
            for sidecar in (
                Path(str(db_path) + "-wal"),
                Path(str(db_path) + "-shm"),
                Path(str(db_path) + "-journal"),
            ):
                _assert_check_only_d_path_without_reparse(sidecar, name="thread state sidecar")
            try:
                sqlite_snapshot = _capture_sqlite_source(db_path)
            except StatePolicyError as exc:
                if not check_only and "shm lock window unavailable" in str(exc).casefold():
                    # A write/repair generation is not safe when the active
                    # SQLite connection's SHM lock window cannot be observed.
                    # Do not let the caller mistake the fail-closed result for
                    # a clean no-op; maintenance must quiesce SQLite first.
                    errors.append("unsafe-partial")
                raise
            if sqlite_snapshot.identities[2] is not None and not cold_maintenance:
                # A live SQLite WAL-index owns the 120..127 lock window.  The
                # lifecycle publisher cannot atomically transfer that window
                # to an output-bound lease, so a write/repair would leave a
                # close-to-return race even when payload reads are available.
                # Require a cold maintenance run with SQLite stopped; never
                # publish the global JSON half of a WAL+SHM repair.
                errors.extend(("generation-unbounded", COLD_MAINTENANCE_REQUIRED))
                errors.append("repair-required" if check_only else "unsafe-partial")
                raise StatePolicyError(
                    "thread state SHM generation requires cold maintenance repair"
                )
            if not check_only and _sqlite_snapshot_has_unknown_sidecars(sqlite_snapshot):
                # A valid WAL generation is writable only when every existing
                # sidecar is identity- and byte-observable.  Do this before
                # global publication so an unreadable WAL or SHM cannot turn
                # into a cross-domain partial result.
                errors.append("unsafe-partial")
                raise StatePolicyError("thread state sidecar bytes unavailable for write")
            if not check_only and _sqlite_generation_unbounded(sqlite_snapshot, sqlite_snapshot):
                # A missing required source name cannot carry a handle-bound
                # no-create lease.  Reject before the global JSON publisher
                # runs so a repair never leaves cross-domain partial state.
                errors.extend(("generation-unbounded", "unsafe-partial"))
                raise StatePolicyError("thread state source generation is unbounded")
            try:
                global_result = update_global_state(
                    global_path,
                    codex_home / "backups_state" / "codex-state-policy",
                    permission_policy=permission_policy,
                    path_mode=path_mode,
                    approved_map=approved_map,
                    check_only=check_only,
                )
            except BaseException:
                publication_claim = _claim_global_publication_after_failure(
                    global_path,
                    global_snapshot,
                    global_snapshot_identity,
                )
                if bool(publication_claim.get("changed")):
                    global_result = publication_claim
                    errors.append("unsafe-partial")
                raise
            if global_result.get("status") == "missing":
                raise StatePolicyError("global state source disappeared")
            try:
                if global_snapshot is None or global_snapshot_identity is None:
                    raise StatePolicyError("global return target snapshot is missing")
                if bool(global_result.get("changed")):
                    after_hash = global_result.get("afterSha256")
                    after_identity = global_result.get("afterIdentity")
                    if (
                        not isinstance(after_hash, str)
                        or not isinstance(after_identity, list)
                        or len(after_identity) != 2
                    ):
                        raise StatePolicyError("global return target identity is missing")
                    expected_global_hash = after_hash
                    expected_global_identity = (int(after_identity[0]), int(after_identity[1]))
                else:
                    expected_global_hash = _sha256(global_snapshot)
                    expected_global_identity = global_snapshot_identity
                global_return_lease = StateTargetLease(
                    global_path,
                    expected_identity=expected_global_identity,
                    expected_hash=expected_global_hash,
                )
                global_return_lease.__enter__()
                global_return_lease.assert_unchanged()
            except BaseException:
                if bool(global_result.get("changed")):
                    errors.append("unsafe-partial")
                raise
            production_home = _resolved_casefold(codex_home) == _resolved_casefold(PRODUCTION_CODEX_HOME)
            snapshot_root = (
                codex_home / "tmp" / "codex-state-policy-check"
                if production_home
                else health_root / "sqlite-snapshots"
            )
            try:
                thread_result = update_thread_state(
                    db_path,
                    permission_policy=permission_policy,
                    check_only=check_only,
                    cold_maintenance=cold_maintenance,
                    maintenance_evidence=maintenance_evidence,
                    snapshot_root=snapshot_root if check_only else None,
                    retain_return_lease=not check_only,
                )
                candidate_return_lease = thread_result.get("_returnLease")
                if isinstance(candidate_return_lease, SqliteTargetLease):
                    pending_sqlite_return_lease = candidate_return_lease
                if thread_result.get("status") == "missing":
                    raise StatePolicyError("thread state source disappeared")
                if not check_only:
                    final_snapshot = thread_result.get("_sourceSnapshot")
                    if not isinstance(final_snapshot, SqliteSourceSnapshot):
                        raise StatePolicyError("thread state return snapshot is missing")
                    if _sqlite_generation_unbounded(sqlite_snapshot, final_snapshot):
                        errors.extend(("generation-unbounded", "unsafe-partial"))
                        raise StatePolicyError("thread state source generation is unbounded")
            except BaseException:
                if pending_sqlite_return_lease is not None:
                    pending_sqlite_return_lease.close()
                    pending_sqlite_return_lease = None
                if global_return_lease is not None:
                    global_return_lease.close()
                    global_return_lease = None
                sqlite_changed = True
                try:
                    current_sqlite_snapshot = _capture_sqlite_source(db_path)
                    sqlite_changed = (
                        _sqlite_snapshot_has_unknown_sidecars(sqlite_snapshot)
                        or _sqlite_snapshot_has_unknown_sidecars(current_sqlite_snapshot)
                        or current_sqlite_snapshot != sqlite_snapshot
                    )
                except BaseException:
                    sqlite_changed = True
                if sqlite_changed and "unsafe-partial" not in errors:
                    errors.append("unsafe-partial")
                rolled_back = False
                if (
                    not sqlite_changed
                    and bool(global_result.get("changed"))
                    and global_snapshot is not None
                    and global_snapshot_identity is not None
                ):
                    after_hash = global_result.get("afterSha256")
                    after_identity = global_result.get("afterIdentity")
                    if (
                        isinstance(after_hash, str)
                        and isinstance(after_identity, list)
                        and len(after_identity) == 2
                    ):
                        rolled_back = _restore_global_state_snapshot(
                            global_path,
                            global_snapshot,
                            expected_hash=after_hash,
                            expected_identity=(int(after_identity[0]), int(after_identity[1])),
                        )
                if rolled_back:
                    global_result["status"] = "rolled-back"
                    global_result["changed"] = False
                    global_result["changedCount"] = 0
                    global_result["afterSha256"] = _sha256(global_snapshot)
                    global_result["afterIdentity"] = list(global_snapshot_identity)
                    errors.append("state policy rollback completed")
                elif bool(global_result.get("changed")):
                    errors.append("unsafe-partial")
                raise
            try:
                database_identity = sqlite_snapshot.identities[0]
                if database_identity is None:
                    raise StatePolicyError("thread state return target identity is missing")
                if check_only:
                    # Check-only must remain a read-only observation through
                    # the output envelope.  Re-capture before acquiring the
                    # lease so the advisory snapshot cannot become a false
                    # stable result if a writer ran during the check phase.
                    current_snapshot = _capture_sqlite_source(db_path)
                    if current_snapshot != sqlite_snapshot:
                        raise StatePolicyError("thread state source changed during check")
                    sqlite_return_lease = SqliteTargetLease(
                        db_path,
                        expected_identity=database_identity,
                        permission_policy=permission_policy,
                        expected_snapshot=sqlite_snapshot,
                        read_only=True,
                    )
                    sqlite_return_lease.__enter__()
                    sqlite_return_lease.assert_unchanged(strict_sidecar_content=True)
                else:
                    expected_snapshot = thread_result.get("_sourceSnapshot")
                    if not isinstance(expected_snapshot, SqliteSourceSnapshot):
                        raise StatePolicyError("thread state return snapshot is missing")
                    if pending_sqlite_return_lease is None:
                        raise StatePolicyError("thread state return lease connection is missing")
                    sqlite_return_lease = pending_sqlite_return_lease
                    pending_sqlite_return_lease = None
                    sqlite_return_lease.assert_unchanged()
            except BaseException:
                if (
                    sqlite_changed
                    or bool(global_result.get("changed"))
                    or int(thread_result.get("changedCount", 0)) > 0
                ) and "unsafe-partial" not in errors:
                    errors.append("unsafe-partial")
                raise
        ok = True
    except BaseException as exc:
        ok = False
        if sqlite_changed and "unsafe-partial" not in errors:
            errors.append("unsafe-partial")
        errors.append(_safe_error(exc))
    changed = (
        sqlite_changed
        or bool(global_result.get("changed"))
        or int(thread_result.get("changedCount", 0)) > 0
    )
    restart_required = changed
    global_drift_count = int(global_result.get("driftCount", 0))
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
            "driftCount": global_drift_count,
        },
        "threadState": {
            "status": thread_result.get("status"),
            "changedCount": int(thread_result.get("changedCount", 0)),
            "driftCount": int(thread_result.get("driftCount", 0)),
            "integrityOk": bool(thread_result.get("integrityOk", False)),
            "integrityResultCount": int(thread_result.get("integrityResultCount", 0)),
        },
        "pathInventory": _redact_path_inventory(global_result.get("pathInventory")),
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
        except (OSError, StatePolicyError):
            errors.append("state policy health write failed")
            payload["ok"] = False
            payload["errors"] = errors
    def run_return_gates() -> None:
        if sqlite_return_lease is not None:
            sqlite_return_lease.assert_unchanged(strict_sidecar_content=True)
            sqlite_return_lease.assert_no_create()
        if global_return_lease is not None:
            global_return_lease.assert_unchanged()
        if policy_return_lease is not None:
            policy_return_lease.assert_unchanged()

    def mark_return_gate_failure(exc: BaseException) -> None:
        if "unsafe-partial" not in errors:
            errors.append("unsafe-partial")
        known = str(exc).casefold()
        if (
            "generation-unbounded" in known
            or ("generation" in known and "unbounded" in known)
            or ("sidecar" in known and "appeared" in known)
        ) and "generation-unbounded" not in errors:
            errors.append("generation-unbounded")
        errors.append(_safe_error(exc))
        payload["ok"] = False
        payload["converged"] = False
        payload["errors"] = errors
        health["ok"] = False
        health["errors"] = errors
        if write_health:
            try:
                _write_health(health_root / "codex-state-policy.json", health)
            except (OSError, StatePolicyError):
                errors.append("state policy health write failed")
                payload["errors"] = errors

    def output_is_seekable() -> bool:
        try:
            return bool(output.seekable())
        except (AttributeError, OSError, io.UnsupportedOperation):
            return False

    def write_exact(target: TextIO, value: str) -> None:
        written = target.write(value)
        if not isinstance(written, int) or written != len(value):
            raise StatePolicyError("state policy output short write")

    def emit_controlled_failure() -> None:
        # A pipe/real stdout cannot retract a provisional line.  Keep that
        # channel free of a misleading success envelope and send the single
        # fail-closed result to the controlled diagnostic channel instead.
        try:
            sys.stderr.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        except (AttributeError, OSError, io.UnsupportedOperation):
            pass

    try:
        return_gate_failed = False
        try:
            run_return_gates()
        except BaseException as exc:
            return_gate_failed = True
            mark_return_gate_failure(exc)
        rendered = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
        seekable_output = output_is_seekable()
        if not seekable_output:
            if not return_gate_failed:
                mark_return_gate_failure(StatePolicyError("state policy output is not seekable"))
            emit_controlled_failure()
            return payload
        if return_gate_failed:
            try:
                write_exact(output, rendered)
            except BaseException:
                emit_controlled_failure()
            return payload
        try:
            write_exact(output, rendered)
        except BaseException as exc:
            mark_return_gate_failure(exc)
            rewritten = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
            try:
                output.seek(0)
                output.truncate(0)
                write_exact(output, rewritten)
            except BaseException:
                emit_controlled_failure()
            return payload
        try:
            # A sink can run arbitrary code from write().  A second,
            # consecutive assertion closes the gap where that callback
            # creates a sidecar or policy source immediately after the
            # first post-write assertion returns.
            run_return_gates()
            run_return_gates()
        except BaseException as exc:
            mark_return_gate_failure(exc)
            rewritten = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
            try:
                output.seek(0)
                output.truncate(0)
                write_exact(output, rewritten)
            except BaseException:
                emit_controlled_failure()
        return payload
    finally:
        if sqlite_return_lease is not None:
            sqlite_return_lease.close()
        if pending_sqlite_return_lease is not None:
            pending_sqlite_return_lease.close()
        if global_return_lease is not None:
            global_return_lease.close()
        if policy_return_lease is not None:
            policy_return_lease.close()


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
    # Keep the protocol sink outside the lease-bound policy run.  The run
    # writes into a seekable buffer so a late return-gate failure can replace
    # the provisional envelope instead of exposing an earlier ``ok=true``
    # line to the hook consumer.
    output = io.StringIO()
    payload = run_policy(
        codex_home,
        check_only=args.check_only,
        health_root=health_root,
        output=output,
        write_health=not args.check_only,
    )
    if args.json:
        sys.stdout.write(output.getvalue())
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StatePolicyError as exc:
        print(json.dumps({"ok": False, "errors": [_safe_error(exc)]}, separators=(",", ":")))
        raise SystemExit(1)
