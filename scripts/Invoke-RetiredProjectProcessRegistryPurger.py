#!/usr/bin/env python3
"""Remove only proven-stale retired project records from Codex process_manager."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
LIVE_CODEX_HOME = Path(r"D:\Codex\.codex")
MANIFEST_PATH = PROJECT_ROOT / "managed" / "codex-hooks" / "host-preflight-manifest.json"
HANDLE_BOUND_POLICY_PATH = PROJECT_ROOT / "scripts" / "lib" / "CodexHookPolicy.ps1"
FIXED_PWSH = Path(r"D:\Codex\tools\PowerShell\7.6.4\pwsh.exe")
REGISTRY_RELATIVE_PATH = Path("process_manager") / "chat_processes.json"
FIXTURE_MARKER_NAME = ".retired-project-process-registry-purger-fixture"
FIXTURE_MARKER_VALUE = "retired-project-process-registry-purger-fixture-v1\n"
FIXTURE_PREFIX = "retired-project-process-registry-purger-tests-"
EXPECTED_KEYS = frozenset({
    "chatTitle", "command", "conversationId", "cwd", "id", "itemId", "osPid", "processId", "startedAtMs", "turnId", "updatedAtMs",
})


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
    if not path.is_dir():
        raise PurgerError(f"{label} 不是普通目录：{path}")
    if stat.st_nlink > 1:
        raise PurgerError(f"{label} 的 link count 异常：{path}")
    return path.resolve(strict=True)


def assert_ordinary_file(path: Path, label: str) -> Path:
    try:
        stat = path.lstat()
    except FileNotFoundError as exc:
        raise PurgerError(f"{label} 不存在：{path}") from exc
    if path.is_symlink() or os.path.islink(path):
        raise PurgerError(f"{label} 是 reparse point 或 symlink：{path}")
    if not path.is_file():
        raise PurgerError(f"{label} 不是普通文件：{path}")
    if stat.st_nlink > 1:
        raise PurgerError(f"{label} 是 hard link：{path}")
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
    if not fixture_root:
        root = assert_ordinary_directory(LIVE_CODEX_HOME, "live Codex home")
        registry = root / REGISTRY_RELATIVE_PATH
        assert_physical_ancestry(registry.parent, root, "live process registry")
        return root, registry, False
    reports_root = assert_ordinary_directory(PROJECT_ROOT / "reports", "项目 reports 根")
    root = assert_ordinary_directory(Path(fixture_root), "FixtureRoot")
    try:
        relative = root.relative_to(reports_root)
    except ValueError as exc:
        raise PurgerError("FixtureRoot 必须位于项目 reports 受控测试树。") from exc
    parts = relative.parts
    if len(parts) != 2 or not parts[0].startswith(FIXTURE_PREFIX) or parts[1] != ".codex":
        raise PurgerError("FixtureRoot 不在专用 process registry purger fixture 内。")
    suffix = parts[0][len(FIXTURE_PREFIX):]
    if len(suffix) != 32 or any(char not in "0123456789abcdef" for char in suffix):
        raise PurgerError("FixtureRoot fixture 标识不合法。")
    assert_physical_ancestry(root, reports_root, "FixtureRoot")
    marker = assert_ordinary_file(root / FIXTURE_MARKER_NAME, "Fixture marker")
    if marker.read_text(encoding="utf-8") != FIXTURE_MARKER_VALUE:
        raise PurgerError("Fixture marker 内容不匹配。")
    return root, root / REGISTRY_RELATIVE_PATH, True


def load_retired_ids() -> tuple[str, ...]:
    manifest = json.loads(assert_ordinary_file(MANIFEST_PATH, "host preflight manifest").read_text(encoding="utf-8"))
    values = manifest.get("retiredProjectTrusts") if isinstance(manifest, dict) else None
    if not isinstance(values, list) or not values:
        raise PurgerError("host preflight manifest 的 retiredProjectTrusts 缺失或为空。")
    ids: list[str] = []
    for value in values:
        if not isinstance(value, str):
            raise PurgerError("retiredProjectTrusts 含非字符串。")
        identifier = value.replace("/", "\\").rstrip("\\").rsplit("\\", 1)[-1].casefold()
        if not identifier or not identifier.replace("-", "").isalnum():
            raise PurgerError("retired project 标识不受支持。")
        ids.append(identifier)
    if len(set(ids)) != len(ids):
        raise PurgerError("retired project 标识重复。")
    return tuple(ids)


def normalise_path(value: str) -> str:
    candidate = value.strip().replace("/", "\\")
    if candidate.startswith("\\\\?\\") or candidate.startswith("\\??\\"):
        candidate = candidate[4:]
    return candidate.rstrip("\\").casefold()


def is_retired_cwd(value: Any, identifiers: tuple[str, ...]) -> bool:
    if not isinstance(value, str):
        return False
    normalized = normalise_path(value)
    return any(normalized == f"d:\\codex\\projects\\{identifier}" or normalized.startswith(f"d:\\codex\\projects\\{identifier}\\") for identifier in identifiers)


def contains_retired_marker(value: Any, identifiers: tuple[str, ...]) -> bool:
    return isinstance(value, str) and any(identifier in value.casefold() for identifier in identifiers)


def classify_records(records: Any, identifiers: tuple[str, ...]) -> tuple[list[int], list[str]]:
    if not isinstance(records, list):
        raise PurgerError("chat_processes.json 根必须是 array。")
    removable: list[int] = []
    blocked: list[str] = []
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            blocked.append(f"record-{index}-not-object")
            continue
        if frozenset(record.keys()) != EXPECTED_KEYS:
            blocked.append(f"record-{index}-schema")
            continue
        marker_fields = [key for key, value in record.items() if contains_retired_marker(value, identifiers)]
        cwd_match = is_retired_cwd(record.get("cwd"), identifiers)
        command_match = contains_retired_marker(record.get("command"), identifiers)
        if not marker_fields and not cwd_match:
            continue
        if set(marker_fields) - {"cwd", "command"}:
            blocked.append(f"record-{index}-marker-outside-structured-fields")
            continue
        # Command text is user-controlled and may legitimately mention a retired
        # project while the process itself belongs to another workspace.  It can
        # corroborate an already allowlisted cwd, but never authorizes deletion.
        if not cwd_match:
            if command_match:
                blocked.append(f"record-{index}-command-without-retired-cwd")
            else:
                blocked.append(f"record-{index}-incomplete-retired-identity")
            continue
        if record.get("osPid") not in (None, 0) or record.get("processId") not in (None, 0):
            blocked.append(f"record-{index}-not-stale")
            continue
        removable.append(index)
    return removable, blocked


def _base64_text(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def _run_handle_bound_powershell(script: str, label: str, *, stdin_bytes: bytes = b"") -> str:
    pwsh = assert_ordinary_file(FIXED_PWSH, "固定 PowerShell runtime")
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    completed = subprocess.run(
        [str(pwsh), "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
        check=False,
        input=stdin_bytes,
        capture_output=True,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    try:
        stdout = completed.stdout.decode("utf-8", errors="strict")
        stderr = completed.stderr.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise PurgerError(f"{label} 的 handle-bound 操作输出不是 UTF-8。") from exc
    if completed.returncode != 0:
        detail = stderr.strip() or stdout.strip()
        raise PurgerError(f"{label} 的 handle-bound 操作失败：{detail}")
    return stdout.strip()


def get_handle_bound_snapshot(path: Path, root: Path) -> dict[str, Any]:
    policy = _base64_text(str(HANDLE_BOUND_POLICY_PATH))
    target = _base64_text(str(path))
    capability_root = _base64_text(str(root))
    script = f"""
$ErrorActionPreference = 'Stop'
. ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{policy}')))
$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{target}'))
$root = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{capability_root}'))
$snapshot = Get-CodexHookCapabilityFileSnapshot -Path $path -CapabilityRoot $root -AllowedExactPaths @($path) -Name 'retired process registry snapshot'
[pscustomobject][ordered]@{{
    exists = [bool]$snapshot.exists
    state = [string]$snapshot.state
    sha256 = $snapshot.sha256
    identity = @($snapshot.identity)
}} | ConvertTo-Json -Compress
"""
    raw = _run_handle_bound_powershell(script, "process registry snapshot")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PurgerError("process registry handle-bound snapshot 输出无效。") from exc
    if not isinstance(value, dict):
        raise PurgerError("process registry handle-bound snapshot 不是 object。")
    identity = value.get("identity")
    if (
        value.get("exists") is not True
        or value.get("state") != "regular-file"
        or not isinstance(value.get("sha256"), str)
        or not isinstance(identity, list)
        or len(identity) != 2
        or any(not isinstance(item, str) or not item for item in identity)
    ):
        raise PurgerError("process registry handle-bound snapshot 未返回普通文件身份。")
    return value


def read_registry(path: Path, root: Path) -> tuple[bytes, list[Any], dict[str, Any]]:
    source = assert_ordinary_file(path, "process registry")
    data = source.read_bytes()
    snapshot = get_handle_bound_snapshot(source, root)
    if snapshot["sha256"].casefold() != hashlib.sha256(data).hexdigest().casefold():
        raise PurgerError("process registry 读取期间内容或身份漂移。")
    try:
        text = data.decode("utf-8-sig")
        parsed = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PurgerError("chat_processes.json 不是受支持的 UTF-8 JSON。") from exc
    if not isinstance(parsed, list):
        raise PurgerError("chat_processes.json 根必须是 array。")
    return data, parsed, snapshot


def check_live_cold_maintenance() -> None:
    pwsh = assert_ordinary_file(Path(r"D:\Codex\tools\PowerShell\7.6.4\pwsh.exe"), "固定 PowerShell runtime")
    command = (
        "$ErrorActionPreference='Stop';"
        "$root='C:\\Program Files\\WindowsApps\\OpenAI.Codex_';"
        "$items=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) });"
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
    if completed.returncode != 0:
        raise PurgerError("Codex cold-maintenance 进程核验失败。")
    text = completed.stdout.strip()
    if text:
        parsed = json.loads(text)
        pids = parsed if isinstance(parsed, list) else [parsed]
        if any(isinstance(pid, int) and pid > 0 for pid in pids):
            raise PurgerError("仍有官方 Codex 进程，拒绝热修改 process registry。")


def write_atomic_without_backup(
    path: Path,
    root: Path,
    source: bytes,
    source_snapshot: dict[str, Any],
    records: list[Any],
    *,
    require_cold_maintenance: bool,
) -> None:
    replacement = (json.dumps(records, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if replacement == source:
        return
    source_hash = hashlib.sha256(source).hexdigest()
    replacement_hash = hashlib.sha256(replacement).hexdigest()
    identity_json = json.dumps(source_snapshot["identity"], ensure_ascii=True, separators=(",", ":"))
    policy = _base64_text(str(HANDLE_BOUND_POLICY_PATH))
    target = _base64_text(str(path))
    capability_root = _base64_text(str(root))
    identity = _base64_text(identity_json)
    replacement_length = len(replacement)
    before_rename = """
$beforeRename = {
    param($TemporaryFile)
    $officialRoot = 'C:\\Program Files\\WindowsApps\\OpenAI.Codex_'
    $items = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($officialRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($items.Count -gt 0) { throw '仍有官方 Codex 进程，拒绝热修改 process registry。' }
}
""" if require_cold_maintenance else "$beforeRename = $null\n"
    script = f"""
$ErrorActionPreference = 'Stop'
. ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{policy}')))
$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{target}'))
$root = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{capability_root}'))
$identityJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{identity}'))
$expectedIdentity = @($identityJson | ConvertFrom-Json)
$expectedReplacementLength = {replacement_length}
$replacementStream = [Console]::OpenStandardInput()
[byte[]]$replacement = [byte[]]::new($expectedReplacementLength)
$replacementOffset = 0
while ($replacementOffset -lt $expectedReplacementLength) {{
    $read = $replacementStream.Read($replacement, $replacementOffset, $expectedReplacementLength - $replacementOffset)
    if ($read -le 0) {{ throw 'replacement stdin 在完整读取前结束。' }}
    $replacementOffset += $read
}}
if ($replacementStream.ReadByte() -ne -1) {{ throw 'replacement stdin 含有超出预期长度的 bytes。' }}
if ((Get-CodexHookBytesSha256 -Bytes $replacement) -cne '{replacement_hash}') {{
    throw 'replacement stdin SHA-256 与预期不一致。'
}}
{before_rename}
Set-CodexHookAtomicFileBytesWithCapability `
    -Path $path `
    -Bytes $replacement `
    -ExpectedExists $true `
    -ExpectedSha256 '{source_hash}' `
    -ExpectedIdentity $expectedIdentity `
    -AfterSha256 '{replacement_hash}' `
    -CapabilityRoot $root `
    -AllowedExactPaths @($path) `
    -Scope 'retired process registry purger' `
    -BeforeRename $beforeRename
"""
    _run_handle_bound_powershell(script, "process registry 原子发布", stdin_bytes=replacement)


def result(*, ok: bool, mode: str, fixture: bool, path: Path | None, ids: tuple[str, ...], ready: int, blocked: list[str], changed: bool, error: str | None) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "ok": ok,
        "mode": mode,
        "fixture": fixture,
        "path": None if path is None else str(path),
        "retiredProjects": list(ids),
        "findingCount": ready + len(blocked),
        "readyRecordCount": ready,
        "blockedRecordCount": len(blocked),
        "blockedReasons": blocked,
        "changed": changed,
        "payloadBackupCreated": False,
        "backupPath": None,
        "error": error,
    }


def main(argv: list[str]) -> int:
    args = parse_arguments(argv)
    path: Path | None = None
    fixture = False
    identifiers: tuple[str, ...] = ()
    try:
        root, path, fixture = resolve_scope(args.fixture_root)
        identifiers = load_retired_ids()
        source, records, source_snapshot = read_registry(path, root)
        removable, blocked = classify_records(records, identifiers)
        if args.mode == "Apply":
            confirmed = {value.casefold() for value in args.confirm_retired_project if value.strip()}
            if any(identifier not in confirmed for identifier in identifiers):
                raise PurgerError("Apply 必须为每个 retired project 显式传入 --confirm-retired-project。")
            if not args.cold_maintenance:
                raise PurgerError("Apply 必须显式传入 --cold-maintenance。")
            if not fixture:
                check_live_cold_maintenance()
            if blocked:
                raise PurgerError("存在无法安全删除的 retired process registry record。")
            if removable:
                remove_set = set(removable)
                write_atomic_without_backup(
                    path,
                    root,
                    source,
                    source_snapshot,
                    [record for index, record in enumerate(records) if index not in remove_set],
                    require_cold_maintenance=not fixture,
                )
            post_source, post_records, _post_snapshot = read_registry(path, root)
            del post_source
            post_removable, post_blocked = classify_records(post_records, identifiers)
            if post_removable or post_blocked:
                raise PurgerError("Apply 后 process registry 仍有退休记录。")
            payload = result(ok=True, mode=args.mode, fixture=fixture, path=path, ids=identifiers, ready=0, blocked=[], changed=bool(removable), error=None)
        else:
            payload = result(ok=not removable and not blocked, mode=args.mode, fixture=fixture, path=path, ids=identifiers, ready=len(removable), blocked=blocked, changed=False, error=None)
    except BaseException as exc:
        payload = result(ok=False, mode=args.mode, fixture=fixture, path=path, ids=identifiers, ready=0, blocked=[], changed=False, error=str(exc))
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
