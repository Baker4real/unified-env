"""Backup moves, activation, retirement and rollback of active skill directories.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import uuid
from pathlib import Path
from typing import Any

from system_skill_provenance_repair import (
    _identity as system_path_identity,
)
import install_skill_guarded_base as _base
import install_skill_guarded_tree as _tree
from install_skill_guarded_base import InstallError, RecoveryRequiredError


def read_only_relative_paths(root: Path) -> list[str]:
    """Capture the write-bit state that make_tree_writable intentionally changes."""
    _base.ensure_tree_no_reparse(root, label="只读属性盘点目录")
    result: list[str] = []
    if not (root.stat().st_mode & stat.S_IWRITE):
        result.append(".")
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in [*directories, *files]:
            child = current_path / name
            if not (child.stat().st_mode & stat.S_IWRITE):
                result.append(child.relative_to(root).as_posix())
    return sorted(result)


def restore_read_only_paths(root: Path, relative_paths: list[str]) -> None:
    """Restore only the read-only bits cleared for a guarded tree move."""
    for relative in sorted(relative_paths, key=lambda value: value.count("/"), reverse=True):
        target = root if relative == "." else root / Path(relative)
        if not _base.path_exists_strict(target, label="只读属性恢复目标"):
            raise InstallError(f"只读属性恢复目标不存在：{target}")
        target.chmod(target.stat().st_mode & ~stat.S_IWRITE)


def merge_tree_contents(source: Path, destination: Path) -> None:
    """Merge a backup fragment into a source fragment without deleting either side."""
    _base.ensure_tree_no_reparse(source, label="恢复来源目录")
    if _base.path_exists_strict(destination, label="恢复目标目录"):
        if _base.is_reparse(destination) or not destination.is_dir():
            raise InstallError(f"恢复目标必须是普通目录：{destination}")
        _tree.make_tree_writable(destination)
    else:
        destination.mkdir(parents=True)
    for current, directories, files in os.walk(source, topdown=True, followlinks=False):
        directories.sort(key=str.casefold)
        files.sort(key=str.casefold)
        current_path = Path(current)
        relative = current_path.relative_to(source)
        target_directory = destination / relative
        target_directory.mkdir(exist_ok=True)
        for directory in directories:
            (target_directory / directory).mkdir(exist_ok=True)
        for filename in files:
            shutil.copyfile(current_path / filename, target_directory / filename)


def restore_move_union(
    *,
    source: Path,
    destination: Path,
    seal: dict[str, Any],
    label: str,
) -> None:
    """Reconstruct a tree after shutil.move partially copied or removed it."""
    if _base.path_exists_strict(source, label=f"{label}来源"):
        merge_tree_contents(source, destination)
    _tree.verify_tree_seal(destination, seal=seal, label=label)


def move_active_to_backup(active: Path, backup: Path) -> tuple[dict[str, Any], list[str]]:
    """Move active state while guaranteeing restoration after a partial fallback."""
    seal = _tree.tree_content_seal(active)
    read_only_paths = read_only_relative_paths(active)
    try:
        _tree.make_tree_writable(active)
        shutil.move(str(active), str(backup))
        _tree.verify_tree_seal(backup, seal=seal, label="active skill 事务备份")
        restore_read_only_paths(backup, read_only_paths)
    except Exception as move_error:
        try:
            restore_move_union(
                source=backup,
                destination=active,
                seal=seal,
                label="备份移动失败后的 active skill",
            )
            restore_read_only_paths(active, read_only_paths)
        except Exception as restore_error:
            raise RecoveryRequiredError(
                f"active skill 备份移动失败且无法证明恢复：{move_error}；恢复错误：{restore_error}"
            ) from restore_error
        raise InstallError(
            f"active skill 备份移动失败；原 active 已按内容 seal 恢复：{move_error}"
        ) from move_error
    return seal, read_only_paths


def verify_activation_readability(
    *,
    active_root: Path,
    names: list[str],
    interpreter: Path,
    evidence_dir: Path,
) -> dict[str, Any]:
    roots = [str(active_root / name) for name in names]
    probe_environment = dict(os.environ)
    probe_environment["CODEX_SKILL_READ_ROOTS"] = json.dumps(roots, ensure_ascii=False)
    probe_code = """
import json, os
from pathlib import Path

roots = [Path(item) for item in json.loads(os.environ["CODEX_SKILL_READ_ROOTS"])]
directory_count = 0
file_count = 0

def is_reparse(path):
    attributes = getattr(path.lstat(), "st_file_attributes", 0)
    return path.is_symlink() or bool(attributes & 0x400)

for root in roots:
    root.lstat()
    if is_reparse(root) or not root.is_dir():
        raise RuntimeError(f"reparse/non-directory root: {root}")
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directory_count += 1
        current_path = Path(current)
        if is_reparse(current_path) or not current_path.is_dir():
            raise RuntimeError(f"reparse/non-directory path: {current_path}")
        for directory in directories:
            child = current_path / directory
            if is_reparse(child) or not child.is_dir():
                raise RuntimeError(f"reparse/non-directory child: {child}")
        for filename in files:
            child = current_path / filename
            if is_reparse(child) or not child.is_file():
                raise RuntimeError(f"non-regular file: {child}")
            with child.open("rb") as stream:
                while stream.read(1024 * 1024):
                    pass
            file_count += 1
print(json.dumps({"directory_count": directory_count, "file_count": file_count}))
"""
    runtime_result = _base.run_process(
        [str(interpreter), "-c", probe_code],
        evidence_dir=evidence_dir,
        label="activation-readability-process",
        env=probe_environment,
    )
    try:
        runtime_payload = json.loads(runtime_result.stdout)
    except json.JSONDecodeError as exc:
        raise InstallError(f"activation readability 子进程未返回合法 JSON：{exc}") from exc

    powershell = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
    if not powershell:
        raise InstallError("无法找到 PowerShell，不能验证 Windows ACL 继承")
    acl_script = r"""
$ErrorActionPreference = 'Stop'
$roots = ConvertFrom-Json ([Environment]::GetEnvironmentVariable('CODEX_SKILL_READ_ROOTS', 'Process'))
$normalRuntimeSids = @('S-1-5-11', 'S-1-5-32-545')
$itemCount = 0
foreach ($root in $roots) {
    $items = @((Get-Item -LiteralPath $root -Force -ErrorAction Stop)) + @(
        Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop
    )
    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        if ($acl.AreAccessRulesProtected) {
            throw "受保护 ACL 未从 active root 继承：$($item.FullName)"
        }
        $inheritedAllowSids = @(
            $acl.Access |
                Where-Object { $_.IsInherited -and $_.AccessControlType -eq 'Allow' } |
                ForEach-Object {
                    try {
                        $_.IdentityReference.Translate(
                            [System.Security.Principal.SecurityIdentifier]
                        ).Value
                    } catch {}
                }
        )
        if (@($inheritedAllowSids | Where-Object { $normalRuntimeSids -contains $_ }).Count -eq 0) {
            throw "active skill 缺少普通运行身份的继承读取权限：$($item.FullName)"
        }
        $itemCount++
    }
}
[ordered]@{ item_count = $itemCount } | ConvertTo-Json -Compress
"""
    acl_result = _base.run_process(
        [
            powershell,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            acl_script,
        ],
        evidence_dir=evidence_dir,
        label="activation-acl-inheritance",
        env=probe_environment,
    )
    try:
        acl_payload = json.loads(acl_result.stdout.lstrip("\ufeff"))
    except json.JSONDecodeError as exc:
        raise InstallError(f"ACL 继承检查未返回合法 JSON：{exc}") from exc
    return {
        "status": "passed",
        "process": "new-child-process",
        "directory_count": int(runtime_payload["directory_count"]),
        "file_count": int(runtime_payload["file_count"]),
        "acl_item_count": int(acl_payload["item_count"]),
    }


def backup_file(path: Path, backup_root: Path, label: str) -> Path | None:
    if not path.exists():
        return None
    backup = backup_root / label
    _base.ensure_dir(backup.parent, label="backup 目录")
    shutil.copy2(path, backup)
    if _base.sha256_file(path) != _base.sha256_file(backup):
        raise InstallError(f"backup 指纹不一致：{path}")
    return backup


def retire_directories(
    *,
    active_root: Path,
    names: list[str],
    backup_root: Path,
    records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    _base.ensure_dir(backup_root, label="retired skill backup 目录")
    _base.ensure_no_reparse_ancestors(active_root, label="active root")
    _base.ensure_no_reparse_ancestors(backup_root, label="retired skill backup 目录")
    for name in names:
        active = _base.d_path(active_root / name, label=f"待退场 active skill {name}")
        if not _base.path_exists_strict(active, label=f"待退场 active skill {name}"):
            raise InstallError(f"待退场 active skill 不存在：{active}")
        if _base.is_reparse(active) or not active.is_dir():
            raise InstallError(f"待退场 active skill 不是安全目录：{active}")
        record = {
            "name": name,
            "active": str(active),
            "backup": str(backup_root / name),
            "activation_temp": str(
                active_root / f"_disabled-guarded-retired-{name}-{uuid.uuid4().hex}"
            ),
            "had_existing": True,
            "backup_moved": False,
            "backup_seal": None,
            "backup_read_only_paths": [],
            "pre_activation_recovery_error": None,
            "activated": False,
            "retired": True,
        }
        records.append(record)
        try:
            backup_seal, backup_read_only_paths = move_active_to_backup(
                active,
                backup_root / name,
            )
            record["backup_seal"] = backup_seal
            record["backup_read_only_paths"] = backup_read_only_paths
            record["backup_moved"] = True
        except RecoveryRequiredError as exc:
            record["pre_activation_recovery_error"] = str(exc)
            raise
    return records


def activate_directories(
    *,
    stage_root: Path,
    active_root: Path,
    names: list[str],
    backup_root: Path,
    records: list[dict[str, Any]],
    payload_seals: dict[str, dict[str, Any]],
    must_not_exist: set[str] | None = None,
) -> list[dict[str, Any]]:
    _base.ensure_dir(backup_root, label="skill backup 目录")
    _base.ensure_no_reparse_ancestors(active_root, label="active root")
    _base.ensure_no_reparse_ancestors(backup_root, label="skill backup 目录")
    protected_new_names = set(must_not_exist or ())
    unexpected_protected_names = protected_new_names - set(names)
    if unexpected_protected_names:
        raise InstallError(
            "must_not_exist 包含非目标 skill："
            + ", ".join(sorted(unexpected_protected_names))
        )
    for name in names:
        staged = stage_root / name
        seal = payload_seals.get(name)
        if not isinstance(seal, dict):
            raise InstallError(f"staging 缺少 skill 内容 seal：{name}")
        _tree.verify_tree_seal(staged, seal=seal, label=f"staging skill {name}")
        active = _base.d_path(active_root / name, label=f"active skill {name}")
        active_exists = _base.path_exists_strict(active, label=f"active skill {name}")
        if name in protected_new_names and active_exists:
            raise InstallError(f"canonical rename successor 已在换入前出现：{active}")
        if active_exists and _base.is_reparse(active):
            raise InstallError(f"active skill 目标是 reparse point：{active}")
        if active_exists and not active.is_dir():
            raise InstallError(f"active skill 目标不是目录：{active}")
        activation_temp = _base.d_path(
            active_root / f"_disabled-guarded-{name}-{uuid.uuid4().hex}",
            label=f"激活临时目录 {name}",
        )
        record = {
            "name": name,
            "active": str(active),
            "backup": str(backup_root / name),
            "activation_temp": str(activation_temp),
            "had_existing": active_exists,
            "backup_moved": False,
            "backup_seal": None,
            "backup_read_only_paths": [],
            "pre_activation_recovery_error": None,
            "activated": False,
            "activated_payload_seal": seal,
            "activated_payload_identity": None,
        }
        records.append(record)
        _tree.copy_tree_without_security_metadata(staged, activation_temp)
        _tree.verify_tree_seal(
            activation_temp,
            seal=seal,
            label=f"激活临时目录 {name}",
        )
        record["activated_payload_identity"] = _tree.directory_identity(
            activation_temp,
            label=f"激活临时目录 {name}",
        )
        if active_exists:
            try:
                backup_seal, backup_read_only_paths = move_active_to_backup(
                    active,
                    backup_root / name,
                )
                record["backup_seal"] = backup_seal
                record["backup_read_only_paths"] = backup_read_only_paths
                record["backup_moved"] = True
            except RecoveryRequiredError as exc:
                record["pre_activation_recovery_error"] = str(exc)
                raise
        try:
            _tree.verify_tree_seal(
                activation_temp,
                seal=seal,
                label=f"原子换入前临时目录 {name}",
            )
            _base.ensure_no_reparse_ancestors(active_root, label="active root")
            if name in protected_new_names:
                if _base.path_exists_strict(active, label=f"canonical rename successor {name}"):
                    raise InstallError(
                        f"canonical rename successor 已在原子换入前出现：{active}"
                    )
                try:
                    os.rename(activation_temp, active)
                except OSError as rename_error:
                    if _base.path_exists_strict(
                        active, label=f"canonical rename successor {name}"
                    ):
                        raise InstallError(
                            f"canonical rename successor 在原子换入竞争中出现：{active}"
                        ) from rename_error
                    raise
            else:
                os.replace(activation_temp, active)
        except Exception as exc:
            raise InstallError(f"激活 skill 失败：{name}：{exc}") from exc
        record["activated"] = True
        activated_identity = record.get("activated_payload_identity")
        if not isinstance(activated_identity, dict):
            raise InstallError(f"已激活 skill 缺少目录 identity：{name}")
        _tree.verify_directory_identity(
            active,
            expected=activated_identity,
            label=f"已激活 skill {name}",
        )
        _tree.verify_tree_seal(active, seal=seal, label=f"已激活 skill {name}")
    return records


def rollback_directories(records: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    for record in reversed(records):
        active = Path(record["active"])
        backup = Path(record["backup"])
        activation_temp = Path(record["activation_temp"])
        try:
            if _base.path_exists_strict(activation_temp, label="rollback 激活临时目录"):
                _tree.safe_remove(activation_temp)
            seal = record.get("backup_seal")
            if record["backup_moved"]:
                if not isinstance(seal, dict):
                    raise InstallError(f"rollback 缺少 active skill 内容 seal：{record['name']}")
                if not _base.path_exists_strict(backup, label="rollback skill backup"):
                    raise InstallError(f"rollback active skill 事务备份不存在：{record['name']}")
                _tree.verify_tree_seal(
                    backup,
                    seal=seal,
                    label=f"rollback 删除 active 前事务备份 {record['name']}",
                )
            elif record["activated"] and record["had_existing"]:
                raise InstallError(f"rollback 已有 active skill 缺少事务备份：{record['name']}")
            if record["activated"]:
                if not _base.path_exists_strict(active, label="rollback active skill"):
                    raise InstallError(
                        f"rollback 已激活 skill 路径已消失，无法证明事务 payload 已移除：{record['name']}"
                    )
                activated_seal = record.get("activated_payload_seal")
                if not isinstance(activated_seal, dict):
                    raise InstallError(
                        f"rollback 缺少已激活 skill 内容 seal：{record['name']}"
                    )
                activated_identity = record.get("activated_payload_identity")
                if not isinstance(activated_identity, dict):
                    raise InstallError(
                        f"rollback 缺少已激活 skill 目录 identity：{record['name']}"
                    )
                _tree.verify_directory_identity(
                    active,
                    expected=activated_identity,
                    label=f"rollback 删除前事务 payload {record['name']}",
                )
                _tree.verify_tree_seal(
                    active,
                    seal=activated_seal,
                    label=f"rollback 删除前事务 payload {record['name']}",
                )
                _tree.safe_remove(active)
            if record["backup_moved"]:
                if record.get("retired") and _base.path_exists_strict(
                    active, label="rollback retired active skill"
                ):
                    raise InstallError(
                        f"rollback 待恢复旧名路径已被占用：{record['name']}"
                    )
                try:
                    _tree.make_tree_writable(backup)
                    shutil.move(str(backup), str(active))
                    _tree.verify_tree_seal(active, seal=seal, label=f"rollback active skill {record['name']}")
                except Exception:
                    restore_move_union(
                        source=backup,
                        destination=active,
                        seal=seal,
                        label=f"rollback active skill {record['name']}",
                    )
                read_only_paths = record.get("backup_read_only_paths")
                if not isinstance(read_only_paths, list) or any(
                    not isinstance(relative, str) for relative in read_only_paths
                ):
                    raise InstallError(f"rollback 只读属性记录不合法：{record['name']}")
                restore_read_only_paths(active, read_only_paths)
        except Exception as exc:  # pragma: no cover - exercised by injected host failures
            errors.append(f"{record['name']}: {exc}")
        if record.get("pre_activation_recovery_error"):
            errors.append(f"{record['name']}: {record['pre_activation_recovery_error']}")
    return errors


def restore_file(path: Path, backup: Path | None) -> None:
    if backup is None:
        if path.exists():
            _tree.safe_remove(path)
        return
    _base.ensure_dir(path.parent, label="恢复文件目录")
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.restore")
    shutil.copy2(backup, temporary)
    os.replace(temporary, path)


def restore_file_cas(
    path: Path,
    *,
    before: bytes | None,
    before_identity: dict[str, int] | None,
    written: bytes | None,
    written_identity: dict[str, int] | None,
    backup: Path | None,
) -> None:
    if path.exists() and not path.is_file():
        raise InstallError(f"rollback CAS target is not a regular file: {path}")
    current = path.read_bytes() if path.exists() else None
    current_identity = system_path_identity(path) if current is not None else None
    if current == before and current_identity == before_identity:
        return
    if current != written or current_identity != written_identity:
        raise InstallError(f"rollback CAS refused to overwrite concurrent state: {path}")
    restore_file(path, backup)
    restored = path.read_bytes() if path.exists() and path.is_file() else None
    if restored != before:
        raise InstallError(f"rollback CAS could not verify original bytes: {path}")
