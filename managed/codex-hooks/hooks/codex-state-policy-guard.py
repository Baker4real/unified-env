from __future__ import annotations

import argparse
import copy
import ctypes
from ctypes import wintypes
from dataclasses import dataclass
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

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.11+ is required in production.
    tomllib = None  # type: ignore[assignment]


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
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
ERROR_FILE_NOT_FOUND = 2
ERROR_PATH_NOT_FOUND = 3
SHORT_LEXICAL_SEGMENT = re.compile(r"^[^\\/]{1,8}~[0-9]+(?:\.[^\\/]+)?$", re.IGNORECASE)
FILE_RENAME_INFORMATION_EX = 65
FILE_RENAME_REPLACE_IF_EXISTS = 0x00000001
FILE_RENAME_POSIX_SEMANTICS = 0x00000002
MOVEFILE_REPLACE_EXISTING = 0x00000001
MOVEFILE_WRITE_THROUGH = 0x00000008


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
            ):
                raise StatePolicyError("permission policy source identity is malformed")

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
    if config_path.exists():
        _assert_check_only_d_path_without_reparse(
            config_path,
            name="permission policy config",
        )
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
        if not policy_path.exists():
            continue
        _assert_check_only_d_path_without_reparse(
            policy_path,
            name="permission policy source",
        )
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
        source_identities.append((source, source_identity))
        if approval is not None:
            approvals.append(
                (
                    source,
                    _validate_permission_value("approval", approval, SUPPORTED_APPROVAL_POLICIES),
                )
            )
        if sandbox is not None:
            sandboxes.append(
                (
                    source,
                    _validate_permission_value("sandbox", sandbox, SUPPORTED_SANDBOX_MODES),
                )
            )
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
    )


def _assert_permission_policy_unchanged(permission_policy: PermissionPolicy) -> None:
    if not isinstance(permission_policy.codex_home, str) or not permission_policy.codex_home:
        raise StatePolicyError("permission policy home is missing")
    identity_by_source = {
        source: identity for source, identity in permission_policy.source_identities
    }
    for source, expected_hash in permission_policy.source_hashes:
        source_path = Path(source)
        _assert_check_only_d_path_without_reparse(
            source_path,
            name="permission policy source",
        )
        try:
            actual_hash = _sha256(source_path.read_bytes())
        except OSError as exc:
            raise StatePolicyError("permission policy source is unreadable") from exc
        if actual_hash != expected_hash:
            raise StatePolicyError("permission policy changed concurrently")
        actual_identity = _file_handle_identity(source_path)
        if actual_identity is None or actual_identity != identity_by_source.get(source):
            raise StatePolicyError("permission policy source changed concurrently")


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


def _close_publish_handle(kernel32: object, handle: wintypes.HANDLE) -> None:
    try:
        kernel32.CloseHandle(handle)  # type: ignore[attr-defined]
    except OSError:
        pass


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


def _publish_temp_file(
    path: Path,
    temp_path: Path,
    *,
    expected_hash: str | None = None,
    expected_identity: tuple[int, int] | None = None,
    replace_if_exists: bool = True,
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
    lease_published = False
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
            if (
                expected_hash is not None
                and _sha256(_read_publish_handle_bytes(target_kernel32, target_handle))
                != expected_hash
            ):
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
                _move_path_by_name(path, lease_backup_path, replace_if_exists=False)
                lease_identity = _file_handle_identity(lease_backup_path)
                lease_expected_identity = expected_identity if expected_identity is not None else target_identity
                if lease_identity != lease_expected_identity:
                    if target_kernel32 is not None and target_handle is not None:
                        _close_publish_handle(target_kernel32, target_handle)
                        target_kernel32 = None
                        target_handle = None
                    if not path.exists() and lease_backup_path.exists():
                        try:
                            _move_path_by_name(lease_backup_path, path, replace_if_exists=False)
                        except StatePolicyError:
                            pass
                    raise StatePolicyError("state publish target changed concurrently")
                if target_kernel32 is not None and target_handle is not None:
                    _close_publish_handle(target_kernel32, target_handle)
                    target_kernel32 = None
                    target_handle = None
                if path.exists():
                    raise StatePolicyError("state publish target appeared concurrently")
                if _file_handle_identity(temp_path) != replacement_identity:
                    raise StatePolicyError("state publish temporary changed concurrently")
                if temp_kernel32 is not None and temp_handle is not None:
                    _close_publish_handle(temp_kernel32, temp_handle)
                    temp_kernel32 = None
                    temp_handle = None
                _move_path_by_name(temp_path, path, replace_if_exists=False)
                published_identity = _file_handle_identity(path)
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
    finally:
        if temp_kernel32 is not None and temp_handle is not None:
            _close_publish_handle(temp_kernel32, temp_handle)
        if target_kernel32 is not None and target_handle is not None:
            _close_publish_handle(target_kernel32, target_handle)
        if lease_published and lease_backup_path is not None:
            try:
                if _file_handle_identity(lease_backup_path) == expected_identity:
                    lease_backup_path.unlink(missing_ok=True)
            except (OSError, StatePolicyError):
                # The new state is already published; leave an auditable lease
                # backup when cleanup itself cannot be verified.
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
            _assert_permission_policy_unchanged(permission_policy)
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
            # Hold a verified target lease through the native class-65 rename;
            # the identity/hash checks also refuse a same-bytes replacement.
            published_identity = _publish_temp_file(
                path,
                temp_path,
                expected_hash=before_hash,
                expected_identity=before_identity,
            )
            _fsync_parent(path)
            published = path.read_bytes()
            if (
                published != replacement
                or published_identity != replacement_identity
            ):
                raise StatePolicyError("global state postwrite verification failed")
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
        finally:
            temp_path.unlink(missing_ok=True)
    raise StatePolicyError("global state concurrent updates did not stabilize")


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


def _capture_sqlite_source(path: Path) -> SqliteSourceSnapshot:
    paths = (
        path,
        Path(str(path) + "-wal"),
        Path(str(path) + "-shm"),
        Path(str(path) + "-journal"),
    )
    payload: list[bytes | None] = []
    identities: list[tuple[int, int] | None] = []
    metadata: list[tuple[bool, int | None, int | None, tuple[int, int] | None]] = []
    try:
        for candidate in paths:
            _assert_check_only_d_path_without_reparse(candidate, name="thread state source")
            exists = candidate.exists()
            if not exists:
                payload.append(None)
                identities.append(None)
                metadata.append((False, None, None, _file_handle_identity(candidate.parent)))
                continue
            raw = candidate.read_bytes()
            identity = _file_handle_identity(candidate)
            if identity is None:
                raise StatePolicyError("thread state source identity unavailable")
            stat = candidate.stat()
            parent_identity = _file_handle_identity(candidate.parent)
            payload.append(raw)
            identities.append(identity)
            metadata.append((True, int(stat.st_size), int(stat.st_mtime_ns), parent_identity))
    except OSError as exc:
        raise StatePolicyError("thread state source snapshot is busy") from exc
    return SqliteSourceSnapshot(
        payload=(payload[0], payload[1], payload[2], payload[3]),
        identities=(identities[0], identities[1], identities[2], identities[3]),
        metadata=(metadata[0], metadata[1], metadata[2], metadata[3]),
    )


def _assert_sqlite_snapshot_identity(
    before: SqliteSourceSnapshot,
    path: Path,
    *,
    allow_new_sidecars: bool,
    check_main_metadata: bool = True,
) -> SqliteSourceSnapshot:
    """Reject path/identity replay between a checked snapshot and SQLite I/O."""
    after = _capture_sqlite_source(path)
    if before.identities[0] != after.identities[0] or (
        check_main_metadata and before.metadata[0] != after.metadata[0]
    ):
        raise StatePolicyError("thread state concurrent replacement")
    for index in range(1, 4):
        expected = before.identities[index]
        actual = after.identities[index]
        if expected is not None and actual != expected:
            raise StatePolicyError("thread state sidecar concurrent replacement")
        if expected is None and actual is not None and not allow_new_sidecars:
            raise StatePolicyError("thread state sidecar appeared during check")
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


def update_thread_state(
    path: Path,
    *,
    permission_policy: PermissionPolicy | None = None,
    check_only: bool = False,
    before_commit: Callable[[], None] | None = None,
    snapshot_root: Path | None = None,
    after_first_snapshot_capture: Callable[[int], None] | None = None,
) -> dict[str, object]:
    permission_policy = _resolve_policy_for_path(path, permission_policy)
    _assert_permission_policy_unchanged(permission_policy)
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
    source_identity = initial_snapshot.identities[0]
    if source_identity is None:
        raise StatePolicyError("thread state source disappeared")
    source_bytes_hash = _sha256(initial_snapshot.payload[0] or b"")
    conn = sqlite3.connect(path, timeout=1.5)
    try:
        conn.execute("pragma busy_timeout=1500")
        _assert_sqlite_snapshot_identity(initial_snapshot, path, allow_new_sidecars=False)
        try:
            conn.execute("begin immediate")
        except sqlite3.OperationalError as exc:
            raise StatePolicyError("thread state database busy") from exc
        try:
            if _file_handle_identity(path) != source_identity:
                raise StatePolicyError("thread state concurrent replacement")
            if _sha256(path.read_bytes()) != source_bytes_hash:
                raise StatePolicyError("thread state concurrent update")
            _assert_sqlite_snapshot_identity(
                initial_snapshot,
                path,
                allow_new_sidecars=True,
                check_main_metadata=False,
            )
            _assert_permission_policy_unchanged(permission_policy)
            identities = select_thread_updates(conn, permission_policy)
            if identities:
                conn.execute(
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
                conn.execute(
                    f"select count(*) from ({THREAD_DRIFT_SQL})",
                    (
                        permission_policy.approval_policy,
                        permission_policy.sqlite_sandbox_policy,
                        permission_policy.sqlite_sandbox_policy,
                    ),
                ).fetchone()[0]
            )
            if drift_count:
                raise StatePolicyError("thread state drift remains before commit")
            if _file_handle_identity(path) != source_identity:
                raise StatePolicyError("thread state concurrent replacement")
            if _sha256(path.read_bytes()) != source_bytes_hash:
                raise StatePolicyError("thread state concurrent update")
            if before_commit is not None:
                before_commit()
            if _file_handle_identity(path) != source_identity:
                raise StatePolicyError("thread state concurrent replacement")
            if _sha256(path.read_bytes()) != source_bytes_hash:
                raise StatePolicyError("thread state concurrent update")
            _assert_sqlite_snapshot_identity(
                initial_snapshot,
                path,
                allow_new_sidecars=True,
                check_main_metadata=False,
            )
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
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
        _assert_sqlite_snapshot_identity(
            initial_snapshot,
            path,
            allow_new_sidecars=True,
            check_main_metadata=False,
        )
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
    if "busy" in known:
        return "state policy resource busy"
    if "malformed" in known or "json" in known:
        return "global state validation failed"
    if "backup" in known:
        return "global state backup failed"
    if "concurrent" in known:
        return "global state concurrent update limit reached"
    return "state policy operation failed"


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
    try:
        if permission_policy is None:
            permission_policy = resolve_permission_policy(codex_home)
        elif not isinstance(permission_policy, PermissionPolicy):
            raise StatePolicyError("permission policy object is invalid")
        global_path = codex_home / ".codex-global-state.json"
        db_path = codex_home / "state_5.sqlite"
        with WindowsNamedMutex():
            # Capture both domains before publication.  The SQLite tuple is
            # compared after a downstream failure so a committed partial write
            # is reported as unsafe instead of being mistaken for a clean run.
            _assert_permission_policy_unchanged(permission_policy)
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
            sqlite_snapshot = _capture_sqlite_source(db_path)
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
                    snapshot_root=snapshot_root if check_only else None,
                )
                if thread_result.get("status") == "missing":
                    raise StatePolicyError("thread state source disappeared")
            except BaseException:
                sqlite_changed = True
                try:
                    sqlite_changed = _capture_sqlite_source(db_path) != sqlite_snapshot
                except BaseException:
                    sqlite_changed = True
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
        ok = True
    except BaseException as exc:
        ok = False
        errors.append(_safe_error(exc))
    changed = bool(global_result.get("changed")) or int(thread_result.get("changedCount", 0)) > 0
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
