#!/usr/bin/env python3
"""Atomically repair provenance for the exact Codex bundled system skill set."""

from __future__ import annotations

import copy
import datetime as _datetime
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import sys
import uuid
from pathlib import Path
from typing import Any

import yaml

_SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(_SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIRECTORY))

from generate_skill_catalog import (  # noqa: E402
    CatalogError,
    classify_closure_findings,
    parse_closure_output,
    verify_catalog_closure_check,
)


EXPECTED_SKILLS = (
    "imagegen",
    "openai-docs",
    "review-agent",
    "skill-creator",
    "skill-installer",
)
PLAN_FIELDS = {
    "artifact_type",
    "schema_version",
    "mode",
    "source_group_id",
    "package_identity_provider_sha256",
    "package_identity",
    "marker",
    "ledger_before_sha256",
    "catalog_before_sha256",
    "stability_check",
    "skills",
}
PACKAGE_FIELDS = {
    "schema_version",
    "package_name",
    "package_full_name",
    "package_family_name",
    "version",
    "publisher",
    "signature_kind",
    "signature_status",
    "appx_status",
    "install_location",
    "appx_manifest_path",
    "appx_manifest_sha256",
    "appx_signature_path",
    "appx_signature_sha256",
}
SKILL_FIELDS = {
    "name",
    "source_before_sha256",
    "official_integrity",
    "effective_integrity",
    "critical_files",
    "overlay",
}
INTEGRITY_FIELDS = {
    "algorithm",
    "excluded",
    "directory_count",
    "file_count",
    "tree_sha256",
    "skill_md_sha256",
}
INTEGRITY_ALGORITHM = (
    "sha256(utf8(concat(sorted_unicode_codepoint("
    "D + tab + relative_posix_directory + lf, or "
    "F + tab + relative_posix_file + tab + file_sha256 + lf)))); "
    "excludes any path segment named .git or __pycache__, and files ending in .pyc"
)
INTEGRITY_EXCLUDED = [
    "**/.git",
    "**/.git/**",
    "**/__pycache__",
    "**/__pycache__/**",
    "**/*.pyc",
]
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
DISPLAY_RECONCILE_MODE = "atomic-six-skill-display-reconcile"
DISPLAY_OVERLAY_KIND = "display-only"
DISPLAY_FILES = {"SKILL.md", "agents/openai.yaml"}
SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
SKILL_CREATOR_OVERLAY_KIND = "skill-creator-quick-validate-compatibility"
SKILL_CREATOR_OVERLAY_SKILL = ".system/skill-creator"
SKILL_CREATOR_CRITICAL_FILES = (
    "SKILL.md",
    "scripts/quick_validate.py",
    "scripts/test_quick_validate.py",
)
SKILL_CREATOR_OVERLAY_CONTRACT = {
    "accepted_frontmatter": {
        "argument-hint": "string",
        "disable-model-invocation": "boolean",
    },
    "non_string_keys": "reject",
    "unknown_fields": "reject",
}
SKILL_CREATOR_OVERLAY_FIELDS = {
    "schema_version",
    "kind",
    "skill",
    "package_identity_provider_sha256",
    "official_integrity",
    "effective_integrity",
    "critical_files",
    "contract",
}


class SystemProvenanceRepairError(RuntimeError):
    """A fail-closed system provenance repair error."""


def _utc_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _is_reparse(path: Path) -> bool:
    try:
        if path.is_symlink():
            return True
        is_junction = getattr(path, "is_junction", None)
        if callable(is_junction) and is_junction():
            return True
        status = path.stat()
    except OSError as exc:
        raise SystemProvenanceRepairError(
            f"无法读取路径属性：{path}：{exc}"
        ) from exc
    return bool(getattr(status, "st_file_attributes", 0) & 0x400)


def _assert_d_path(path: Path, *, label: str) -> Path:
    path = path.absolute()
    raw = str(path)
    if raw.startswith("\\\\") or raw.startswith("//"):
        raise SystemProvenanceRepairError(f"{label}不能是 UNC 路径：{path}")
    if os.name == "nt" and path.drive.casefold() != "d:":
        raise SystemProvenanceRepairError(f"{label}必须位于 D 盘：{path}")
    existing = path
    while not existing.exists() and existing.parent != existing:
        existing = existing.parent
    current = existing
    while True:
        if _is_reparse(current):
            raise SystemProvenanceRepairError(
                f"{label}的既有祖先不能是 reparse point：{current}"
            )
        if current.parent == current:
            break
        current = current.parent
    return path


def _require_file(path: Path, *, label: str, d_drive: bool = True) -> Path:
    path = _assert_d_path(path, label=label) if d_drive else path.absolute()
    if not path.is_file() or _is_reparse(path):
        raise SystemProvenanceRepairError(f"{label}必须是安全普通文件：{path}")
    return path


def _require_directory(path: Path, *, label: str, d_drive: bool = True) -> Path:
    path = _assert_d_path(path, label=label) if d_drive else path.absolute()
    if not path.is_dir() or _is_reparse(path):
        raise SystemProvenanceRepairError(f"{label}必须是安全普通目录：{path}")
    return path


def _ensure_directory(path: Path, *, label: str) -> Path:
    path = _assert_d_path(path, label=label)
    path.mkdir(parents=True, exist_ok=True)
    return _require_directory(path, label=label)


def _identity(path: Path) -> dict[str, int]:
    status = path.stat()
    return {
        "device": int(status.st_dev),
        "inode": int(status.st_ino),
    }


def _read_json(path: Path, *, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SystemProvenanceRepairError(f"{label}不是合法 UTF-8 JSON：{path}：{exc}") from exc


def _atomic_write_bytes(path: Path, data: bytes) -> None:
    _ensure_directory(path.parent, label="原子写入父目录")
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _atomic_write_json(path: Path, value: Any) -> bytes:
    data = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    _atomic_write_bytes(path, data)
    return data


def _optional_bytes(path: Path) -> bytes | None:
    if not path.exists():
        return None
    if not path.is_file() or _is_reparse(path):
        raise SystemProvenanceRepairError(f"事务目标不是安全普通文件：{path}")
    return path.read_bytes()


def _assert_file_cas(
    path: Path,
    *,
    expected_identity: dict[str, int],
    expected_bytes: bytes,
    label: str,
) -> None:
    if _identity(path) != expected_identity or path.read_bytes() != expected_bytes:
        raise SystemProvenanceRepairError(f"{label} identity/bytes 在事务期间漂移")


def _tree_integrity(
    root: Path,
    *,
    overrides: dict[str, bytes] | None = None,
) -> dict[str, Any]:
    root = _require_directory(root, label="system skill payload")
    override_values = overrides or {}
    directories_result: list[str] = []
    files_result: dict[str, str] = {}

    def onerror(error: OSError) -> None:
        raise SystemProvenanceRepairError(
            f"无法遍历 system skill payload：{root}：{error}"
        ) from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        current_path = Path(current)
        retained_directories: list[str] = []
        for name in directories:
            child = current_path / name
            if _is_reparse(child) or not child.is_dir():
                raise SystemProvenanceRepairError(
                    f"system skill payload 只允许普通目录：{child}"
                )
            if name.casefold() in {".git", "__pycache__"}:
                continue
            retained_directories.append(name)
            directories_result.append(child.relative_to(root).as_posix())
        directories[:] = sorted(retained_directories, key=str.casefold)
        files.sort(key=str.casefold)
        for filename in files:
            source = current_path / filename
            if _is_reparse(source) or not source.is_file():
                raise SystemProvenanceRepairError(
                    f"system skill payload 只允许普通文件：{source}"
                )
            relative = source.relative_to(root).as_posix()
            if (
                filename.casefold() in {".git", "__pycache__"}
                or filename.casefold().endswith(".pyc")
                or relative.casefold() == "source.md"
            ):
                continue
            files_result[relative] = _sha256_bytes(
                override_values[relative]
                if relative in override_values
                else source.read_bytes()
            )
    records = [f"D\t{relative}\n" for relative in directories_result]
    records.extend(
        f"F\t{relative}\t{digest}\n" for relative, digest in files_result.items()
    )
    tree_sha256 = _sha256_bytes("".join(sorted(records)).encode("utf-8"))
    skill_hash = files_result.get("SKILL.md")
    if skill_hash is None:
        raise SystemProvenanceRepairError(f"system skill 缺少 SKILL.md：{root}")
    return {
        "algorithm": INTEGRITY_ALGORITHM,
        "excluded": list(INTEGRITY_EXCLUDED),
        "directory_count": len(directories_result),
        "file_count": len(files_result),
        "tree_sha256": tree_sha256,
        "skill_md_sha256": skill_hash,
    }


def _validate_integrity(value: Any, *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != INTEGRITY_FIELDS:
        raise SystemProvenanceRepairError(f"{label}字段不符合 schema")
    if value.get("algorithm") != INTEGRITY_ALGORITHM:
        raise SystemProvenanceRepairError(f"{label}.algorithm 不受支持")
    if value.get("excluded") != INTEGRITY_EXCLUDED:
        raise SystemProvenanceRepairError(f"{label}.excluded 不受支持")
    for field in ("directory_count", "file_count"):
        if isinstance(value.get(field), bool) or not isinstance(value.get(field), int):
            raise SystemProvenanceRepairError(f"{label}.{field} 必须是整数")
    for field in ("tree_sha256", "skill_md_sha256"):
        digest = value.get(field)
        if not isinstance(digest, str) or not SHA256_HEX.fullmatch(digest):
            raise SystemProvenanceRepairError(f"{label}.{field} 必须是小写 SHA-256")
    return copy.deepcopy(value)


def validate_skill_creator_compatibility_overlay(value: Any) -> dict[str, Any]:
    """Validate the only candidate-driven overlay allowed for skill-creator."""
    if not isinstance(value, dict) or set(value) != SKILL_CREATOR_OVERLAY_FIELDS:
        raise SystemProvenanceRepairError(
            "system_provenance_overlay fields do not match the managed schema"
        )
    if (
        value.get("schema_version") != 1
        or value.get("kind") != SKILL_CREATOR_OVERLAY_KIND
        or value.get("skill") != SKILL_CREATOR_OVERLAY_SKILL
    ):
        raise SystemProvenanceRepairError(
            "system_provenance_overlay identity is not the managed skill-creator overlay"
        )
    if value.get("contract") != SKILL_CREATOR_OVERLAY_CONTRACT:
        raise SystemProvenanceRepairError(
            "skill-creator quick_validate compatibility contract is not exact"
        )
    provider_hash = value.get("package_identity_provider_sha256")
    if not isinstance(provider_hash, str) or not SHA256_HEX.fullmatch(provider_hash):
        raise SystemProvenanceRepairError(
            "skill-creator overlay must bind the Store identity provider SHA-256"
        )
    official = _validate_integrity(
        value.get("official_integrity"),
        label="system_provenance_overlay.official_integrity",
    )
    effective = _validate_integrity(
        value.get("effective_integrity"),
        label="system_provenance_overlay.effective_integrity",
    )
    if official == effective:
        raise SystemProvenanceRepairError(
            "skill-creator compatibility overlay must change effective integrity"
        )
    critical = value.get("critical_files")
    if (
        not isinstance(critical, dict)
        or set(critical) != set(SKILL_CREATOR_CRITICAL_FILES)
        or any(
            not isinstance(critical.get(relative), str)
            or not SHA256_HEX.fullmatch(critical[relative])
            for relative in SKILL_CREATOR_CRITICAL_FILES
        )
    ):
        raise SystemProvenanceRepairError(
            "skill-creator compatibility overlay must bind the exact critical payload files"
        )
    if critical["SKILL.md"] != effective["skill_md_sha256"]:
        raise SystemProvenanceRepairError(
            "skill-creator critical SKILL.md hash does not match effective integrity"
        )
    return {
        "schema_version": 1,
        "kind": SKILL_CREATOR_OVERLAY_KIND,
        "skill": SKILL_CREATOR_OVERLAY_SKILL,
        "package_identity_provider_sha256": provider_hash,
        "official_integrity": official,
        "effective_integrity": effective,
        "critical_files": copy.deepcopy(critical),
        "contract": copy.deepcopy(SKILL_CREATOR_OVERLAY_CONTRACT),
    }


def skill_creator_overlay_ledger_projection(value: Any) -> dict[str, Any]:
    overlay = validate_skill_creator_compatibility_overlay(value)
    return {
        "kind": overlay["kind"],
        "schema_version": overlay["schema_version"],
        "contract": copy.deepcopy(overlay["contract"]),
        "payload_files": copy.deepcopy(overlay["critical_files"]),
    }


def system_skill_integrity(root: Path) -> dict[str, Any]:
    """Public transaction helper using the SOURCE-excluding system tree seal."""
    return _tree_integrity(root)


def system_skill_payload_inventory(root: Path) -> dict[str, Any]:
    """Return the exact SOURCE-excluding directories and file hashes for diff binding."""
    root = _require_directory(root, label="system skill payload")
    directories_result: list[str] = []
    files_result: dict[str, str] = {}

    def onerror(error: OSError) -> None:
        raise SystemProvenanceRepairError(
            f"cannot inventory system skill payload {root}: {error}"
        ) from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        current_path = Path(current)
        retained: list[str] = []
        for name in directories:
            child = current_path / name
            if _is_reparse(child) or not child.is_dir():
                raise SystemProvenanceRepairError(
                    f"system skill payload contains unsafe directory: {child}"
                )
            if name.casefold() in {".git", "__pycache__"}:
                continue
            retained.append(name)
            directories_result.append(child.relative_to(root).as_posix())
        directories[:] = sorted(retained, key=str.casefold)
        files.sort(key=str.casefold)
        for filename in files:
            source = current_path / filename
            if _is_reparse(source) or not source.is_file():
                raise SystemProvenanceRepairError(
                    f"system skill payload contains unsafe file: {source}"
                )
            relative = source.relative_to(root).as_posix()
            if filename.casefold().endswith(".pyc") or relative.casefold() == "source.md":
                continue
            files_result[relative] = _sha256_file(source)
    return {
        "directories": sorted(directories_result),
        "files": dict(sorted(files_result.items())),
    }


def _frontmatter(path: Path, data: bytes) -> dict[str, Any]:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise SystemProvenanceRepairError(f"SKILL.md 不是合法 UTF-8：{path}") from exc
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise SystemProvenanceRepairError(f"SKILL.md 缺少 YAML frontmatter：{path}")
    try:
        end = next(index for index in range(1, len(lines)) if lines[index].strip() in {"---", "..."})
    except StopIteration as exc:
        raise SystemProvenanceRepairError(f"SKILL.md frontmatter 未闭合：{path}") from exc
    try:
        value = yaml.safe_load("\n".join(lines[1:end])) or {}
    except yaml.YAMLError as exc:
        raise SystemProvenanceRepairError(f"SKILL.md frontmatter 非法：{path}：{exc}") from exc
    if not isinstance(value, dict):
        raise SystemProvenanceRepairError(f"SKILL.md frontmatter 必须是对象：{path}")
    return value


def _review_overlay_bytes(path: Path, baseline: bytes) -> bytes:
    frontmatter = _frontmatter(path, baseline)
    if frontmatter.get("name") != "review-agent":
        raise SystemProvenanceRepairError("review-agent frontmatter name 漂移")
    if "disable-model-invocation" in frontmatter:
        raise SystemProvenanceRepairError(
            "review-agent official baseline 已包含 disable-model-invocation"
        )
    encoding = "utf-8-sig" if baseline.startswith(b"\xef\xbb\xbf") else "utf-8"
    text = baseline.decode(encoding)
    newline = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines(keepends=True)
    end = next(
        (
            index
            for index in range(1, len(lines))
            if lines[index].strip() in {"---", "..."}
        ),
        None,
    )
    if end is None:
        raise SystemProvenanceRepairError("review-agent frontmatter 未闭合")
    lines.insert(end, f"disable-model-invocation: true{newline}")
    encoded = "".join(lines).encode("utf-8")
    patched = (b"\xef\xbb\xbf" if baseline.startswith(b"\xef\xbb\xbf") else b"") + encoded
    patched_frontmatter = _frontmatter(path, patched)
    if patched_frontmatter.get("disable-model-invocation") is not True:
        raise SystemProvenanceRepairError("review-agent invocation overlay 未生效")
    return patched


def _run_process(
    command: list[str],
    *,
    evidence_dir: Path,
    label: str,
    allowed_returncodes: tuple[int, ...] = (0,),
) -> str:
    completed = _run_process_raw(command, evidence_dir=evidence_dir, label=label)
    if completed.returncode not in allowed_returncodes:
        detail = (completed.stderr or completed.stdout).strip()
        raise SystemProvenanceRepairError(
            f"{label} 失败，exit={completed.returncode}：{detail}"
        )
    return completed.stdout


def _run_process_raw(
    command: list[str], *, evidence_dir: Path, label: str
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        creationflags=SUBPROCESS_CREATION_FLAGS,
    )
    (evidence_dir / f"{label}.stdout.txt").write_text(
        completed.stdout, encoding="utf-8"
    )
    (evidence_dir / f"{label}.stderr.txt").write_text(
        completed.stderr, encoding="utf-8"
    )
    return completed


def system_closure_targets() -> list[str]:
    return [f".system/{name}" for name in EXPECTED_SKILLS]


def _run_strict_closure(
    *,
    interpreter: Path,
    closure_script: Path,
    active_root: Path,
    evidence_dir: Path,
    label: str,
) -> dict[str, Any]:
    """Run strict closure; exit 0/1 are results, crashes and bad JSON fail closed."""

    completed = _run_process_raw(
        [
            str(interpreter),
            "-X",
            "utf8",
            "-I",
            str(closure_script),
            "--root",
            str(active_root),
            "--strict",
            "--format",
            "json",
        ],
        evidence_dir=evidence_dir,
        label=label,
    )
    try:
        return parse_closure_output(completed.stdout, completed.returncode, label=label)
    except CatalogError as exc:
        raise SystemProvenanceRepairError(str(exc)) from exc


def evaluate_system_closure_gate(
    *,
    payload: dict[str, Any],
    baseline: dict[str, Any],
    targets: list[str],
    label: str,
) -> dict[str, Any]:
    """Same baseline-diff + target rule as install_skill_guarded.evaluate_closure_gate."""

    gate = {
        "label": label,
        **classify_closure_findings(
            payload["findings"],
            baseline_findings=baseline["findings"],
            targets=targets,
        ),
    }
    if gate["status"] != "pass":
        raise SystemProvenanceRepairError(
            f"{label} 门禁失败：新增 finding {len(gate['new_findings'])} 条，"
            f"target finding {len(gate['target_findings'])} 条："
            + json.dumps(
                {
                    "new_findings": gate["new_findings"],
                    "target_findings": gate["target_findings"],
                },
                ensure_ascii=False,
            )
        )
    return gate


def _query_package_identity(
    *,
    interpreter: Path,
    provider: Path,
    expected: dict[str, Any],
    evidence_dir: Path | None,
    label: str,
) -> dict[str, Any]:
    completed = subprocess.run(
        [str(interpreter), "-X", "utf8", "-I", str(provider), "--package-name", "OpenAI.Codex"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        creationflags=SUBPROCESS_CREATION_FLAGS,
    )
    if evidence_dir is not None:
        (evidence_dir / f"{label}.stdout.txt").write_text(
            completed.stdout, encoding="utf-8"
        )
        (evidence_dir / f"{label}.stderr.txt").write_text(
            completed.stderr, encoding="utf-8"
        )
    if completed.returncode != 0:
        raise SystemProvenanceRepairError(
            f"Store package identity provider 失败，exit={completed.returncode}："
            f"{(completed.stderr or completed.stdout).strip()}"
        )
    try:
        observed = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise SystemProvenanceRepairError(
            "Store package identity provider 未返回合法 JSON"
        ) from exc
    if observed != expected:
        raise SystemProvenanceRepairError("Store package identity 与 repair plan 不一致")
    _validate_package_identity(observed)
    return observed


def _validate_package_identity(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != PACKAGE_FIELDS:
        raise SystemProvenanceRepairError("package_identity 字段不符合 schema")
    if value.get("schema_version") != 1 or value.get("package_name") != "OpenAI.Codex":
        raise SystemProvenanceRepairError("Store package identity schema/name 不受支持")
    for field in PACKAGE_FIELDS - {"schema_version"}:
        if not isinstance(value.get(field), str) or not value[field]:
            raise SystemProvenanceRepairError(f"package_identity.{field} 必须是非空字符串")
    if value["signature_kind"] != "Store":
        raise SystemProvenanceRepairError("Store package SignatureKind 不是 Store")
    if value["signature_status"] != "Valid":
        raise SystemProvenanceRepairError("Store package signature 不是 Valid")
    if value["appx_status"] != "Ok":
        raise SystemProvenanceRepairError("Store package AppX status 不是 Ok")
    for field in ("appx_manifest_sha256", "appx_signature_sha256"):
        if not SHA256_HEX.fullmatch(value[field]):
            raise SystemProvenanceRepairError(f"package_identity.{field} 不是小写 SHA-256")
    install_location = _require_directory(
        Path(value["install_location"]), label="Store package install location", d_drive=False
    )
    if install_location.name.casefold() != value["package_full_name"].casefold():
        raise SystemProvenanceRepairError("Store package install location 与 PackageFullName 不一致")
    manifest_path = _require_file(
        Path(value["appx_manifest_path"]), label="AppxManifest.xml", d_drive=False
    )
    signature_path = _require_file(
        Path(value["appx_signature_path"]), label="AppxSignature.p7x", d_drive=False
    )
    try:
        manifest_path.relative_to(install_location)
        signature_path.relative_to(install_location)
    except ValueError as exc:
        raise SystemProvenanceRepairError("AppX identity 文件不在 install location 内") from exc
    if manifest_path.name.casefold() != "appxmanifest.xml":
        raise SystemProvenanceRepairError("AppxManifest 路径不规范")
    if signature_path.name.casefold() != "appxsignature.p7x":
        raise SystemProvenanceRepairError("AppxSignature 路径不规范")
    if _sha256_file(manifest_path) != value["appx_manifest_sha256"]:
        raise SystemProvenanceRepairError("AppxManifest SHA-256 漂移")
    if _sha256_file(signature_path) != value["appx_signature_sha256"]:
        raise SystemProvenanceRepairError("AppxSignature SHA-256 漂移")
    return copy.deepcopy(value)


def _package_path_identities(package: dict[str, Any]) -> dict[str, dict[str, int]]:
    return {
        "install_location": _identity(Path(package["install_location"])),
        "appx_manifest": _identity(Path(package["appx_manifest_path"])),
        "appx_signature": _identity(Path(package["appx_signature_path"])),
    }


class _DisplayLoader(yaml.SafeLoader):
    def construct_mapping(self, node: Any, deep: bool = False) -> dict[str, Any]:
        keys: set[str] = set()
        for key_node, _ in node.value:
            if key_node.tag != "tag:yaml.org,2002:str" or key_node.value in keys:
                raise SystemProvenanceRepairError("display YAML requires unique string keys")
            keys.add(key_node.value)
        return super().construct_mapping(node, deep=deep)


def _display_contract(relative: str, data: bytes) -> tuple[str, str, list[str], str, tuple[bool, str, str]]:
    text = data.decode("utf-8-sig")
    body = ""
    framing = (data.startswith(b"\xef\xbb\xbf"), "", "")
    if relative == "SKILL.md":
        lines = text.splitlines(keepends=True)
        if not lines or lines[0].strip() != "---":
            raise SystemProvenanceRepairError("display SKILL.md lacks frontmatter")
        end = next(
            (i for i in range(1, len(lines)) if lines[i].strip() in {"---", "..."}),
            None,
        )
        if end is None:
            raise SystemProvenanceRepairError("display SKILL.md frontmatter is not closed")
        framing = (framing[0], lines[0], lines[end])
        text, body = "".join(lines[1:end]), "".join(lines[end + 1:])
    try:
        # JSON expansion removes YAML alias sharing before masking display fields.
        value = json.loads(json.dumps(yaml.load(text, Loader=_DisplayLoader), allow_nan=False))
    except (yaml.YAMLError, TypeError, ValueError) as exc:
        raise SystemProvenanceRepairError(f"invalid display YAML: {relative}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemProvenanceRepairError(f"display YAML must be a mapping: {relative}")
    container = value if relative == "SKILL.md" else value.get("interface", {})
    if not isinstance(container, dict):
        raise SystemProvenanceRepairError("display interface must be a mapping")
    fields = ("description",) if relative == "SKILL.md" else ("short_description", "default_prompt")
    present = []
    for field in fields:
        if field in container:
            if not isinstance(container[field], str):
                raise SystemProvenanceRepairError(f"display field must be a string: {field}")
            present.append(field)
            container.pop(field)
    node = yaml.compose(text, Loader=_DisplayLoader)
    if relative != "SKILL.md":
        node = next((v for k, v in node.value if k.value == "interface"), None)
    spans = []
    if node is not None:
        for key, scalar in node.value:
            if key.value in present:
                start, end = scalar.start_mark.index, scalar.end_mark.index
                # Block scalars own their final newline; keep the line boundary.
                suffix = ""
                if text[start:end].endswith("\r\n"):
                    suffix = "\r\n"
                elif text[start:end].endswith("\n"):
                    suffix = "\n"
                spans.append((start, end, "<display>" + suffix))
    masked = text
    for start, end, replacement in sorted(spans, reverse=True):
        masked = masked[:start] + replacement + masked[end:]
    return json.dumps(value, sort_keys=True, allow_nan=False), body, present, masked, framing


def _validate_display_overlay(overlay: Any) -> None:
    if (
        not isinstance(overlay, dict)
        or set(overlay) != {"kind", "baseline_files", "base_overlay"}
        or overlay.get("kind") != DISPLAY_OVERLAY_KIND
        or not isinstance(overlay.get("base_overlay"), dict)
    ):
        raise SystemProvenanceRepairError("display overlay schema is invalid")
    files = overlay["baseline_files"]
    if (
        not isinstance(files, dict)
        or "SKILL.md" not in files
        or not set(files).issubset(DISPLAY_FILES)
        or any(not isinstance(text, str) for text in files.values())
    ):
        raise SystemProvenanceRepairError("display baseline must bind only the two display files")


def _verify_display_baseline(root: Path, spec: dict[str, Any], prior: dict[str, Any]) -> None:
    if (
        spec["official_integrity"] != prior.get("official_integrity")
        or spec["source_before_sha256"] is None
        or spec["source_before_sha256"] != prior.get("source_md_sha256")
        or set(spec["critical_files"]) != set(prior.get("critical_files", {}))
    ):
        raise SystemProvenanceRepairError("display reconciliation changed the recorded baseline")
    previous_overlay = prior.get("overlay", {})
    base_overlay = (
        previous_overlay.get("base_overlay")
        if previous_overlay.get("kind") == DISPLAY_OVERLAY_KIND
        else previous_overlay
    )
    if (
        spec["overlay"]["base_overlay"] != base_overlay
        or base_overlay.get("kind") not in {
            "none", "review-agent-invocation-parity", SKILL_CREATOR_OVERLAY_KIND,
        }
    ):
        raise SystemProvenanceRepairError("display reconciliation changed the underlying overlay")
    baseline = {k: v.encode("utf-8") for k, v in spec["overlay"]["baseline_files"].items()}
    for relative, before in baseline.items():
        path = _require_file(root / relative, label="display payload")
        if _display_contract(relative, before) != _display_contract(relative, path.read_bytes()):
            raise SystemProvenanceRepairError(f"non-display content changed: {root.name}/{relative}")
    if _tree_integrity(root, overrides=baseline) != prior.get("effective_integrity"):
        raise SystemProvenanceRepairError(f"display baseline tree does not match ledger: {root.name}")


def _display_overlay_projection(overlay: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": DISPLAY_OVERLAY_KIND,
        "base_overlay": copy.deepcopy(overlay["base_overlay"]),
        "baseline_file_sha256": {
            relative: _sha256_bytes(text.encode("utf-8"))
            for relative, text in overlay["baseline_files"].items()
        },
    }


def _validate_plan(path: Path) -> dict[str, Any]:
    data = _read_json(path, label="system provenance repair plan")
    if not isinstance(data, dict) or set(data) != PLAN_FIELDS:
        raise SystemProvenanceRepairError("system provenance repair plan 字段不符合 schema")
    if (
        data.get("artifact_type") != "codex.system-skill-provenance-repair"
        or data.get("schema_version") != 1
        or data.get("mode") not in {"atomic-six-skill-bootstrap", DISPLAY_RECONCILE_MODE}
        or data.get("source_group_id") != "codex-bundled-system-skills"
    ):
        raise SystemProvenanceRepairError("system provenance repair plan identity/schema 不受支持")
    provider_hash = data.get("package_identity_provider_sha256")
    if not isinstance(provider_hash, str) or not SHA256_HEX.fullmatch(provider_hash):
        raise SystemProvenanceRepairError("package identity provider SHA-256 不合法")
    _validate_package_identity(data.get("package_identity"))
    marker = data.get("marker")
    if (
        not isinstance(marker, dict)
        or set(marker) != {"relative_path", "sha256"}
        or marker.get("relative_path") != ".system/.codex-system-skills.marker"
        or not isinstance(marker.get("sha256"), str)
        or not SHA256_HEX.fullmatch(marker["sha256"])
    ):
        raise SystemProvenanceRepairError("system marker 绑定不符合 schema")
    for field in ("ledger_before_sha256", "catalog_before_sha256"):
        if not isinstance(data.get(field), str) or not SHA256_HEX.fullmatch(data[field]):
            raise SystemProvenanceRepairError(f"{field} 必须是小写 SHA-256")
    stability = data.get("stability_check")
    if not isinstance(stability, dict) or set(stability) != {"observations", "interval_seconds"}:
        raise SystemProvenanceRepairError("stability_check 字段不符合 schema")
    observations = stability.get("observations")
    interval_seconds = stability.get("interval_seconds")
    if (
        isinstance(observations, bool)
        or not isinstance(observations, int)
        or observations < 2
        or isinstance(interval_seconds, bool)
        or not isinstance(interval_seconds, (int, float))
        or interval_seconds < 0
    ):
        raise SystemProvenanceRepairError("stability_check 至少需要两次非负间隔观测")
    raw_skills = data.get("skills")
    if not isinstance(raw_skills, list) or [item.get("name") if isinstance(item, dict) else None for item in raw_skills] != list(EXPECTED_SKILLS):
        raise SystemProvenanceRepairError("repair plan 必须精确绑定五项 system skill")
    for index, item in enumerate(raw_skills):
        if not isinstance(item, dict) or set(item) != SKILL_FIELDS:
            raise SystemProvenanceRepairError(f"skills[{index}] 字段不符合 schema")
        before_hash = item.get("source_before_sha256")
        if before_hash is not None and (
            not isinstance(before_hash, str) or not SHA256_HEX.fullmatch(before_hash)
        ):
            raise SystemProvenanceRepairError(
                f"skills[{index}].source_before_sha256 不合法"
            )
        official = _validate_integrity(
            item.get("official_integrity"), label=f"skills[{index}].official_integrity"
        )
        effective = _validate_integrity(
            item.get("effective_integrity"), label=f"skills[{index}].effective_integrity"
        )
        critical = item.get("critical_files")
        if not isinstance(critical, dict) or any(
            not isinstance(key, str)
            or not key
            or "\\" in key
            or Path(key).is_absolute()
            or any(part in {"", ".", ".."} for part in key.split("/"))
            or not isinstance(value, str)
            or not SHA256_HEX.fullmatch(value)
            for key, value in critical.items()
        ):
            raise SystemProvenanceRepairError(f"skills[{index}].critical_files 不合法")
        overlay = item.get("overlay")
        if data["mode"] == DISPLAY_RECONCILE_MODE:
            _validate_display_overlay(overlay)
        elif item["name"] == "review-agent":
            if overlay != {
                "kind": "review-agent-invocation-parity",
                "disable_model_invocation": True,
                "allow_implicit_invocation": False,
                "parity_file": "agents/openai.yaml",
            }:
                raise SystemProvenanceRepairError("review-agent overlay 不是授权的最小 parity overlay")
            if set(critical) != {"agents/openai.yaml"}:
                raise SystemProvenanceRepairError("review-agent 必须绑定 agents/openai.yaml")
            if official == effective:
                raise SystemProvenanceRepairError("review-agent effective integrity 未绑定 overlay")
        else:
            if overlay != {"kind": "none"} or critical:
                raise SystemProvenanceRepairError(f"{item['name']} 不允许 payload overlay")
            if official != effective:
                raise SystemProvenanceRepairError(f"{item['name']} official/effective integrity 不一致")
    return data


def _source_record(
    *,
    active_root: Path,
    source_group_id: str,
    package: dict[str, Any],
    marker_sha256: str,
    spec: dict[str, Any],
) -> bytes:
    name = spec["name"]
    official = spec["official_integrity"]
    effective = spec["effective_integrity"]
    overlay = spec["overlay"]
    if overlay.get("kind") == DISPLAY_OVERLAY_KIND:
        overlay_value = (
            "display-only: SKILL.md description; agents/openai.yaml "
            "interface.short_description/default_prompt; preserved base overlay: "
            + overlay["base_overlay"]["kind"]
        )
    elif name == "review-agent":
        overlay_value = (
            "disable-model-invocation: true; "
            "agents/openai.yaml allow_implicit_invocation: false"
        )
    elif overlay.get("kind") == SKILL_CREATOR_OVERLAY_KIND:
        payload = overlay.get("payload_files")
        if not isinstance(payload, dict) or set(payload) != set(
            SKILL_CREATOR_CRITICAL_FILES
        ):
            raise SystemProvenanceRepairError(
                "skill-creator SOURCE overlay projection is incomplete"
            )
        overlay_value = (
            "skill-creator quick_validate compatibility v1; "
            "argument-hint=string; disable-model-invocation=boolean; "
            "non-string and unknown frontmatter keys rejected; payload SHA-256: "
            + ", ".join(
                f"{relative}={payload[relative]}"
                for relative in SKILL_CREATOR_CRITICAL_FILES
            )
        )
        if "base_overlay" in overlay:
            overlay_value += (
                "; preserved base overlay: " + overlay["base_overlay"]["kind"]
                + "; baseline effective tree SHA-256: "
                + overlay["baseline_integrity"]["tree_sha256"]
            )
    else:
        overlay_value = "none"
    text = "\n".join(
        [
            "# Source Provenance",
            "",
            "This record binds the active system skill to the observed signed Codex Store package.",
            "It does not claim a public upstream repository or commit.",
            "",
            "---",
            "# Current Source Record",
            f"Skill: .system/{name}",
            f"Local path: {active_root / '.system' / name}",
            f"Active root: {active_root}",
            "Source type: codex-bundled-system",
            f"Source group: {source_group_id}",
            f"Source root: {active_root / '.system'}",
            "Status: tracked bundled system skill",
            f"Package full name: {package['package_full_name']}",
            f"Package version: {package['version']}",
            f"Package publisher: {package['publisher']}",
            f"Signature kind: {package['signature_kind']}",
            f"Signature status: {package['signature_status']}",
            f"AppX status: {package['appx_status']}",
            f"AppxManifest SHA-256: {package['appx_manifest_sha256']}",
            f"AppxSignature SHA-256: {package['appx_signature_sha256']}",
            f"System marker SHA-256: {marker_sha256}",
            f"Official tree SHA-256: {official['tree_sha256']}",
            f"Official SKILL.md SHA-256: {official['skill_md_sha256']}",
            f"Effective tree SHA-256: {effective['tree_sha256']}",
            f"Effective SKILL.md SHA-256: {effective['skill_md_sha256']}",
            f"Local overlay: {overlay_value}",
            "",
        ]
    )
    if overlay["kind"] == "none" and official != effective:
        raise SystemProvenanceRepairError(f"{name} overlay provenance 不一致")
    return text.encode("utf-8")


def _validate_ledger(
    *,
    data: Any,
    active_root: Path,
    source_group_id: str,
) -> tuple[dict[str, Any], int]:
    if not isinstance(data, dict):
        raise SystemProvenanceRepairError("source ledger 顶层必须是 JSON 对象")
    for key in ("sources", "unresolved", "deleted"):
        if not isinstance(data.get(key), list):
            raise SystemProvenanceRepairError(f"source ledger.{key} 必须是数组")
    matches = [
        (index, entry)
        for index, entry in enumerate(data["sources"])
        if isinstance(entry, dict) and entry.get("id") == source_group_id
    ]
    if len(matches) != 1:
        raise SystemProvenanceRepairError("codex-bundled-system-skills source group 不唯一")
    index, entry = matches[0]
    expected_skills = {f".system/{name}" for name in EXPECTED_SKILLS}
    skills = entry.get("skills")
    if (
        entry.get("type") != "codex-bundled-system"
        or not isinstance(skills, list)
        or any(not isinstance(item, str) for item in skills)
        or set(skills) != expected_skills
        or len(skills) != len(expected_skills)
    ):
        raise SystemProvenanceRepairError("system source group type/skill set 漂移")
    expected_root = str(active_root / ".system").replace("\\", "/").casefold()
    actual_root = str(entry.get("source_root", "")).replace("\\", "/").casefold()
    if actual_root != expected_root:
        raise SystemProvenanceRepairError("system source group source_root 漂移")
    return copy.deepcopy(data), index


def _updated_ledger(
    *,
    data: dict[str, Any],
    source_index: int,
    plan: dict[str, Any],
    source_hashes: dict[str, str],
) -> dict[str, Any]:
    updated = copy.deepcopy(data)
    entry = updated["sources"][source_index]
    entry["system_provenance"] = {
        "schema_version": 1,
        "package_identity": copy.deepcopy(plan["package_identity"]),
        "marker": copy.deepcopy(plan["marker"]),
        "skills": [
            {
                "name": spec["name"],
                "path": f".system/{spec['name']}",
                "official_integrity": copy.deepcopy(spec["official_integrity"]),
                "effective_integrity": copy.deepcopy(spec["effective_integrity"]),
                "critical_files": copy.deepcopy(spec["critical_files"]),
                "overlay": (
                    _display_overlay_projection(spec["overlay"])
                    if plan["mode"] == DISPLAY_RECONCILE_MODE
                    else copy.deepcopy(spec["overlay"])
                ),
                "source_md_sha256": source_hashes[spec["name"]],
            }
            for spec in plan["skills"]
        ],
    }
    entry["last_guarded_install"] = _utc_now()
    changes = entry.setdefault("local_changes", [])
    if not isinstance(changes, list):
        raise SystemProvenanceRepairError("system source group local_changes 必须是数组")
    summary = (
        "guarded system provenance repair: atomically bound five bundled skills to the "
        "signed Store package and restored review-agent disable-model-invocation parity."
    )
    if plan["mode"] == DISPLAY_RECONCILE_MODE:
        summary = (
            "guarded display-only provenance reconciliation: preserved all five official "
            "baselines and payload bytes; verified display fields against prior effective trees."
        )
    if not any(
        isinstance(item, dict)
        and item.get("skill") == ".system/review-agent"
        and item.get("summary") == summary
        for item in changes
    ):
        changes.append(
            {
                "skill": ".system/review-agent",
                "date": _datetime.date.today().isoformat(),
                "summary": summary,
            }
        )
    updated["updated_at"] = _utc_now()
    return updated


def _verify_catalog(
    *,
    catalog_path: Path,
    active_root: Path,
    plan: dict[str, Any],
    baseline_findings: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    catalog = _read_json(catalog_path, label="skill catalog")
    artifacts = catalog.get("artifacts") if isinstance(catalog, dict) else None
    if not isinstance(artifacts, list):
        raise SystemProvenanceRepairError("skill catalog 缺少 artifacts 数组")
    try:
        closure_check = verify_catalog_closure_check(
            catalog.get("checks", {}).get("resource_closure"),
            targets=system_closure_targets(),
            baseline_findings=baseline_findings,
        )
    except CatalogError as exc:
        raise SystemProvenanceRepairError(f"skill catalog 资源闭包检查不可接受：{exc}") from exc
    verified: list[dict[str, Any]] = []
    for spec in plan["skills"]:
        name = spec["name"]
        matches = [
            item
            for item in artifacts
            if isinstance(item, dict)
            and item.get("scope") == "system"
            and item.get("name") == name
            and item.get("relative_path") == f".system/{name}/SKILL.md"
        ]
        if len(matches) != 1:
            raise SystemProvenanceRepairError(f"catalog 对 {name} 的 system 条目不唯一")
        artifact = matches[0]
        if artifact.get("ledger_coverage") != "pass" or artifact.get("conflicts"):
            raise SystemProvenanceRepairError(f"catalog 对 {name} 的 ledger/source/parity 有冲突")
        if artifact.get("integrity", {}).get("skill_md_sha256") != spec["effective_integrity"]["skill_md_sha256"]:
            raise SystemProvenanceRepairError(f"catalog 对 {name} 的 SKILL.md hash 漂移")
        source = artifact.get("source")
        if (
            not isinstance(source, dict)
            or source.get("status") in {None, "missing", "unknown"}
            or source.get("conflicts")
        ):
            raise SystemProvenanceRepairError(f"catalog 对 {name} 的 SOURCE.md 无效")
        if name == "review-agent":
            invocation = artifact.get("invocation")
            if (
                not isinstance(invocation, dict)
                or invocation.get("mode") != "user-invoked"
                or invocation.get("disable_model_invocation") is not True
                or invocation.get("allow_implicit_invocation") is not False
            ):
                raise SystemProvenanceRepairError("review-agent invocation parity 未闭合")
        verified.append(
            {
                "name": name,
                "skill_md_sha256": artifact["integrity"]["skill_md_sha256"],
                "source_md_sha256": source.get("integrity", {}).get("sha256"),
            }
        )
    return {
        "generated_at": catalog.get("generated_at"),
        "skills": verified,
        "resource_closure": closure_check,
    }


def _observe_state(
    *,
    active_root: Path,
    ledger_path: Path,
    catalog_path: Path,
    interpreter: Path,
    provider: Path,
    plan: dict[str, Any],
    expected_directory_identities: dict[str, dict[str, int]],
    expected_package_identities: dict[str, dict[str, int]],
    plan_path: Path,
    expected_plan_identity: dict[str, int],
    expected_plan_bytes: bytes,
    expected_provider_identity: dict[str, int],
    expected_provider_bytes: bytes,
    expected_ledger_identity: dict[str, int],
    expected_ledger_bytes: bytes,
    expected_catalog_identity: dict[str, int],
    expected_catalog_bytes: bytes,
    expected_source_bytes: dict[str, bytes],
    evidence_dir: Path,
    label: str,
) -> dict[str, Any]:
    _assert_file_cas(
        plan_path,
        expected_identity=expected_plan_identity,
        expected_bytes=expected_plan_bytes,
        label="repair plan",
    )
    _assert_file_cas(
        provider,
        expected_identity=expected_provider_identity,
        expected_bytes=expected_provider_bytes,
        label="Store package identity provider",
    )
    package = _query_package_identity(
        interpreter=interpreter,
        provider=provider,
        expected=plan["package_identity"],
        evidence_dir=evidence_dir,
        label=f"{label}-package-identity",
    )
    if _package_path_identities(package) != expected_package_identities:
        raise SystemProvenanceRepairError(
            "Store package path identity 在事务期间漂移"
        )
    _assert_file_cas(
        ledger_path,
        expected_identity=expected_ledger_identity,
        expected_bytes=expected_ledger_bytes,
        label="source ledger",
    )
    _assert_file_cas(
        catalog_path,
        expected_identity=expected_catalog_identity,
        expected_bytes=expected_catalog_bytes,
        label="skill catalog",
    )
    marker_path = active_root / Path(*plan["marker"]["relative_path"].split("/"))
    if _sha256_file(marker_path) != plan["marker"]["sha256"]:
        raise SystemProvenanceRepairError("system marker 在事务期间漂移")
    if _identity(marker_path) != expected_directory_identities["marker"]:
        raise SystemProvenanceRepairError("system marker identity 在事务期间漂移")
    skills: list[dict[str, Any]] = []
    for spec in plan["skills"]:
        name = spec["name"]
        root = active_root / ".system" / name
        if _identity(root) != expected_directory_identities[name]:
            raise SystemProvenanceRepairError(f"{name} directory identity 在事务期间漂移")
        integrity = _tree_integrity(root)
        if integrity != spec["effective_integrity"]:
            raise SystemProvenanceRepairError(f"{name} effective payload 在事务期间漂移")
        source_path = root / "SOURCE.md"
        if _optional_bytes(source_path) != expected_source_bytes[name]:
            raise SystemProvenanceRepairError(f"{name} SOURCE.md 在事务期间漂移")
        for relative, expected_hash in spec["critical_files"].items():
            critical = _require_file(
                root / Path(*relative.split("/")), label=f"{name} critical file"
            )
            if _sha256_file(critical) != expected_hash:
                raise SystemProvenanceRepairError(f"{name} critical payload 漂移：{relative}")
        skills.append(
            {
                "name": name,
                "directory_identity": expected_directory_identities[name],
                "integrity": integrity,
                "source_md_sha256": _sha256_bytes(expected_source_bytes[name]),
            }
        )
    return {
        "label": label,
        "observed_at": _utc_now(),
        "package_full_name": package["package_full_name"],
        "marker_sha256": plan["marker"]["sha256"],
        "ledger_sha256": _sha256_file(ledger_path),
        "catalog_sha256": _sha256_file(catalog_path),
        "skills": skills,
    }


def _optional_identity(path: Path) -> dict[str, int] | None:
    if not path.exists():
        return None
    return _identity(path)


def _restore_cas(
    path: Path,
    *,
    before: bytes | None,
    before_identity: dict[str, int] | None,
    written: bytes | None,
    written_identity: dict[str, int] | None,
) -> None:
    current = _optional_bytes(path)
    current_identity = _optional_identity(path)
    if current == before and current_identity == before_identity:
        return
    if current != written or current_identity != written_identity:
        raise SystemProvenanceRepairError(
            f"rollback CAS 失败，目标 identity/bytes 不是事务写入值或原始值：{path}"
        )
    if before is None:
        path.unlink()
    else:
        _atomic_write_bytes(path, before)
    if _optional_bytes(path) != before:
        raise SystemProvenanceRepairError(f"rollback 无法验证原始字节：{path}")


def execute(args: Any) -> dict[str, Any]:
    plan_path = _require_file(
        Path(args.system_provenance_repair_plan), label="system provenance repair plan"
    )
    plan_bytes = plan_path.read_bytes()
    plan_identity = _identity(plan_path)
    plan = _validate_plan(plan_path)
    _assert_file_cas(
        plan_path,
        expected_identity=plan_identity,
        expected_bytes=plan_bytes,
        label="repair plan",
    )
    active_root = _require_directory(Path(args.active_root), label="active root")
    plugin_cache_root = _require_directory(
        Path(args.plugin_cache_root), label="plugin cache root"
    )
    ledger_path = _require_file(Path(args.ledger), label="source ledger")
    catalog_path = _require_file(Path(args.catalog), label="skill catalog")
    generator = _require_file(Path(args.generator), label="catalog generator")
    closure_script = _require_file(
        Path(args.closure_script), label="resource closure script"
    )
    interpreter = _require_file(Path(args.interpreter), label="Python interpreter")
    provider = _require_file(
        Path(args.system_package_provider), label="Store package identity provider"
    )
    provider_bytes = provider.read_bytes()
    provider_identity = _identity(provider)
    temp_root = _ensure_directory(Path(args.temp_root), label="repair staging root")
    evidence_root = _ensure_directory(Path(args.evidence_root), label="repair evidence root")
    if _sha256_bytes(provider_bytes) != plan["package_identity_provider_sha256"]:
        raise SystemProvenanceRepairError("Store package identity provider SHA-256 漂移")
    if _sha256_file(ledger_path) != plan["ledger_before_sha256"]:
        raise SystemProvenanceRepairError("source ledger 在 repair plan 后漂移")
    if _sha256_file(catalog_path) != plan["catalog_before_sha256"]:
        raise SystemProvenanceRepairError("skill catalog 在 repair plan 后漂移")
    if (
        active_root == Path(r"D:\agents\skills-manager\skills")
        and plan["stability_check"]["interval_seconds"] < 10
    ):
        raise SystemProvenanceRepairError("live repair stability interval 不能小于 10 秒")

    system_root = _require_directory(active_root / ".system", label="system skill root")
    marker_path = _require_file(
        active_root / Path(*plan["marker"]["relative_path"].split("/")),
        label="system skill marker",
    )
    if _sha256_file(marker_path) != plan["marker"]["sha256"]:
        raise SystemProvenanceRepairError("system skill marker SHA-256 与 plan 不一致")
    package = _query_package_identity(
        interpreter=interpreter,
        provider=provider,
        expected=plan["package_identity"],
        evidence_dir=None,
        label="preflight-package-identity",
    )
    package_identities = _package_path_identities(package)
    ledger, source_index = _validate_ledger(
        data=_read_json(ledger_path, label="source ledger"),
        active_root=active_root,
        source_group_id=plan["source_group_id"],
    )
    display_only = plan["mode"] == DISPLAY_RECONCILE_MODE
    input_integrity = "effective_integrity" if display_only else "official_integrity"
    prior_specs: dict[str, Any] = {}
    if display_only:
        provenance = ledger["sources"][source_index].get("system_provenance")
        if (
            not isinstance(provenance, dict)
            or provenance.get("package_identity") != plan["package_identity"]
            or provenance.get("marker") != plan["marker"]
            or not isinstance(provenance.get("skills"), list)
            or [p.get("name") if isinstance(p, dict) else None for p in provenance["skills"]]
            != list(EXPECTED_SKILLS)
        ):
            raise SystemProvenanceRepairError("display reconciliation lacks a matching prior provenance")
        prior_specs = {p["name"]: p for p in provenance["skills"]}

    baseline_identities: dict[str, dict[str, int]] = {"marker": _identity(marker_path)}
    source_before: dict[str, bytes | None] = {}
    source_written: dict[str, bytes] = {}
    review_before: bytes | None = None
    review_written: bytes | None = None
    for spec in plan["skills"]:
        name = spec["name"]
        root = _require_directory(system_root / name, label=f"system skill {name}")
        baseline_identities[name] = _identity(root)
        if _tree_integrity(root) != spec[input_integrity]:
            raise SystemProvenanceRepairError(f"{name} input tree/hash 与 plan 不一致")
        if display_only:
            _verify_display_baseline(root, spec, prior_specs[name])
        for relative, expected_hash in spec["critical_files"].items():
            critical = _require_file(
                root / Path(*relative.split("/")), label=f"{name} critical file"
            )
            if _sha256_file(critical) != expected_hash:
                raise SystemProvenanceRepairError(f"{name} critical file hash 与 plan 不一致")
        source_path = root / "SOURCE.md"
        source_before[name] = _optional_bytes(source_path)
        expected_before = spec["source_before_sha256"]
        actual_before = (
            _sha256_bytes(source_before[name]) if source_before[name] is not None else None
        )
        if actual_before != expected_before:
            raise SystemProvenanceRepairError(f"{name} SOURCE.md baseline 与 plan 不一致")
        if name == "review-agent":
            review_path = _require_file(root / "SKILL.md", label="review-agent SKILL.md")
            review_before = review_path.read_bytes()
            try:
                parity = yaml.safe_load((root / "agents" / "openai.yaml").read_text(encoding="utf-8-sig"))
            except (OSError, UnicodeError, yaml.YAMLError) as exc:
                raise SystemProvenanceRepairError("review-agent openai.yaml 不是合法 YAML") from exc
            policy = parity.get("policy") if isinstance(parity, dict) else None
            if not isinstance(policy, dict) or policy.get("allow_implicit_invocation") is not False:
                raise SystemProvenanceRepairError("review-agent allow_implicit_invocation 不是 false")
            if display_only:
                if _frontmatter(review_path, review_before).get("disable-model-invocation") is not True:
                    raise SystemProvenanceRepairError("review-agent invocation parity drifted")
                review_written = review_before
            else:
                review_written = _review_overlay_bytes(review_path, review_before)
            if _tree_integrity(root, overrides={"SKILL.md": review_written}) != spec["effective_integrity"]:
                raise SystemProvenanceRepairError("review-agent overlay effective hash 与 plan 不一致")
        source_written[name] = _source_record(
            active_root=active_root,
            source_group_id=plan["source_group_id"],
            package=package,
            marker_sha256=plan["marker"]["sha256"],
            spec=spec,
        )
    if review_before is None or review_written is None:
        raise SystemProvenanceRepairError("repair plan 未建立 review-agent overlay")

    source_hashes = {name: _sha256_bytes(data) for name, data in source_written.items()}
    updated_ledger = _updated_ledger(
        data=ledger,
        source_index=source_index,
        plan=plan,
        source_hashes=source_hashes,
    )
    projected_ledger_bytes = (json.dumps(updated_ledger, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if args.dry_run:
        return {
            "schema_version": 1,
            "status": "dry-run-pass",
            "targets": list(EXPECTED_SKILLS),
            "source_md_sha256": source_hashes,
            "projected_ledger_sha256": _sha256_bytes(projected_ledger_bytes),
        }

    evidence_dir = evidence_root / (
        "system-provenance-"
        + _datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
        + "-"
        + uuid.uuid4().hex
    )
    _ensure_directory(evidence_dir, label="system provenance evidence")
    backups_dir = _ensure_directory(evidence_dir / "backups", label="repair backup root")
    manifest_path = evidence_dir / "manifest.json"
    transaction = {
        "schema_version": 1,
        "status": "prepared",
        "started_at": _utc_now(),
        "plan_path": str(plan_path),
        "plan_sha256": _sha256_file(plan_path),
        "targets": list(EXPECTED_SKILLS),
        "active_root": str(active_root),
        "ledger": str(ledger_path),
        "catalog": str(catalog_path),
        "package_identity": package,
        "backups": [],
    }
    before_values: dict[str, tuple[Path, bytes | None]] = {}
    before_identities: dict[str, dict[str, int] | None] = {}
    written_values: dict[str, bytes | None] = {}
    written_identities: dict[str, dict[str, int] | None] = {}

    def register_backup(label: str, path: Path, before: bytes | None) -> None:
        before_values[label] = (path, before)
        before_identities[label] = _optional_identity(path)
        record = {
            "label": label,
            "path": str(path),
            "exists": before is not None,
            "identity": before_identities[label],
            "sha256": _sha256_bytes(before) if before is not None else None,
            "backup": None,
        }
        if before is not None:
            backup_path = backups_dir / f"{len(before_values):02d}-{label}.bin"
            _atomic_write_bytes(backup_path, before)
            if _sha256_file(backup_path) != record["sha256"]:
                raise SystemProvenanceRepairError(f"backup hash 校验失败：{label}")
            record["backup"] = str(backup_path)
        transaction["backups"].append(record)

    for name in EXPECTED_SKILLS:
        register_backup(
            f"source-{name}", system_root / name / "SOURCE.md", source_before[name]
        )
    if not display_only:
        register_backup("review-agent-skill", system_root / "review-agent" / "SKILL.md", review_before)
    register_backup("ledger", ledger_path, ledger_path.read_bytes())
    register_backup("catalog", catalog_path, catalog_path.read_bytes())
    _atomic_write_json(manifest_path, transaction)

    stage_dir = Path(tempfile.mkdtemp(prefix="system-provenance-", dir=temp_root))
    closure_targets = system_closure_targets()
    try:
        baseline_closure = _run_strict_closure(
            interpreter=interpreter,
            closure_script=closure_script,
            active_root=active_root,
            evidence_dir=evidence_dir,
            label="baseline-resource-closure",
        )
        baseline_closure_path = evidence_dir / "baseline-resource-closure.json"
        _atomic_write_json(baseline_closure_path, baseline_closure)
        closure_gate_arguments = [
            "--closure-baseline",
            str(baseline_closure_path),
            *[
                argument
                for target in closure_targets
                for argument in ("--closure-target", target)
            ],
        ]
        for name, data in source_written.items():
            staged = stage_dir / name / "SOURCE.md"
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_bytes(data)
            if staged.read_bytes() != data:
                raise SystemProvenanceRepairError(f"{name} SOURCE.md staging hash 不一致")
        if not display_only:
            staged_review = stage_dir / "review-agent" / "SKILL.md"
            staged_review.parent.mkdir(parents=True, exist_ok=True)
            staged_review.write_bytes(review_written)

        pre_write_package = _query_package_identity(
            interpreter=interpreter,
            provider=provider,
            expected=plan["package_identity"],
            evidence_dir=evidence_dir,
            label="pre-write-package-identity",
        )
        _assert_file_cas(
            plan_path,
            expected_identity=plan_identity,
            expected_bytes=plan_bytes,
            label="repair plan",
        )
        _assert_file_cas(
            provider,
            expected_identity=provider_identity,
            expected_bytes=provider_bytes,
            label="Store package identity provider",
        )
        if _package_path_identities(pre_write_package) != package_identities:
            raise SystemProvenanceRepairError(
                "Store package path identity 在写前 CAS 复验中漂移"
            )
        if _sha256_file(marker_path) != plan["marker"]["sha256"] or _identity(marker_path) != baseline_identities["marker"]:
            raise SystemProvenanceRepairError("system marker 在写前 CAS 复验中漂移")
        if _sha256_file(ledger_path) != plan["ledger_before_sha256"] or _sha256_file(catalog_path) != plan["catalog_before_sha256"]:
            raise SystemProvenanceRepairError("ledger/catalog 在写前 CAS 复验中漂移")
        for spec in plan["skills"]:
            name = spec["name"]
            root = system_root / name
            if _identity(root) != baseline_identities[name] or _tree_integrity(root) != spec[input_integrity]:
                raise SystemProvenanceRepairError(f"{name} 在写前 CAS 复验中漂移")
            if _optional_bytes(root / "SOURCE.md") != source_before[name]:
                raise SystemProvenanceRepairError(f"{name} SOURCE.md 在写前 CAS 复验中漂移")

        for name, data in source_written.items():
            path = system_root / name / "SOURCE.md"
            _atomic_write_bytes(path, data)
            written_values[f"source-{name}"] = data
            written_identities[f"source-{name}"] = _identity(path)
        review_path = system_root / "review-agent" / "SKILL.md"
        if not display_only:
            _atomic_write_bytes(review_path, review_written)
            written_values["review-agent-skill"] = review_written
            written_identities["review-agent-skill"] = _identity(review_path)
        _atomic_write_bytes(ledger_path, projected_ledger_bytes)
        written_values["ledger"] = projected_ledger_bytes
        written_identities["ledger"] = _identity(ledger_path)

        generated_catalog_path = stage_dir / "generated-catalog.json"
        _run_process(
            [
                str(interpreter),
                "-X",
                "utf8",
                "-I",
                str(generator),
                "--write",
                "--active-root",
                str(active_root),
                "--plugin-cache-root",
                str(plugin_cache_root),
                "--ledger",
                str(ledger_path),
                "--output",
                str(generated_catalog_path),
                *closure_gate_arguments,
            ],
            evidence_dir=evidence_dir,
            label="catalog-generation",
        )
        projected_catalog_bytes = generated_catalog_path.read_bytes()
        projected_catalog_hash = _sha256_bytes(projected_catalog_bytes)
        _assert_file_cas(
            ledger_path,
            expected_identity=written_identities["ledger"],
            expected_bytes=projected_ledger_bytes,
            label="source ledger after catalog generation",
        )
        _assert_file_cas(
            catalog_path,
            expected_identity=before_identities["catalog"],
            expected_bytes=before_values["catalog"][1] or b"",
            label="skill catalog baseline before write",
        )
        _atomic_write_bytes(catalog_path, projected_catalog_bytes)
        written_values["catalog"] = projected_catalog_bytes
        written_identities["catalog"] = _identity(catalog_path)
        closure = _run_strict_closure(
            interpreter=interpreter,
            closure_script=closure_script,
            active_root=active_root,
            evidence_dir=evidence_dir,
            label="post-resource-closure",
        )
        closure_gate = evaluate_system_closure_gate(
            payload=closure,
            baseline=baseline_closure,
            targets=closure_targets,
            label="post-resource-closure",
        )
        post_catalog_path = stage_dir / "post-catalog.json"
        _run_process(
            [
                str(interpreter),
                "-X",
                "utf8",
                "-I",
                str(generator),
                "--write",
                "--active-root",
                str(active_root),
                "--plugin-cache-root",
                str(plugin_cache_root),
                "--ledger",
                str(ledger_path),
                "--output",
                str(post_catalog_path),
                *closure_gate_arguments,
            ],
            evidence_dir=evidence_dir,
            label="post-catalog-generation",
        )
        try:
            expected_catalog = json.loads(projected_catalog_bytes.decode("utf-8"))
            observed_catalog = json.loads(post_catalog_path.read_bytes().decode("utf-8"))
            actual_catalog = json.loads(catalog_path.read_bytes().decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise SystemProvenanceRepairError("post-generation catalog 不是合法 UTF-8 JSON") from exc
        expected_catalog.pop("generated_at", None)
        observed_catalog.pop("generated_at", None)
        actual_catalog.pop("generated_at", None)
        if observed_catalog != expected_catalog or actual_catalog != expected_catalog:
            raise SystemProvenanceRepairError(
                "post-generation catalog 与 projected expected catalog 不一致"
            )
        catalog_verification = _verify_catalog(
            catalog_path=catalog_path,
            active_root=active_root,
            plan=plan,
            baseline_findings=baseline_closure["findings"],
        )
        observations: list[dict[str, Any]] = []
        for index in range(plan["stability_check"]["observations"]):
            if index:
                time.sleep(plan["stability_check"]["interval_seconds"])
            observations.append(
                _observe_state(
                    active_root=active_root,
                    ledger_path=ledger_path,
                    catalog_path=catalog_path,
                    interpreter=interpreter,
                    provider=provider,
                    plan=plan,
                    expected_directory_identities=baseline_identities,
                    expected_package_identities=package_identities,
                    plan_path=plan_path,
                    expected_plan_identity=plan_identity,
                    expected_plan_bytes=plan_bytes,
                    expected_provider_identity=provider_identity,
                    expected_provider_bytes=provider_bytes,
                    expected_ledger_identity=written_identities["ledger"],
                    expected_ledger_bytes=projected_ledger_bytes,
                    expected_catalog_identity=written_identities["catalog"],
                    expected_catalog_bytes=projected_catalog_bytes,
                    expected_source_bytes=source_written,
                    evidence_dir=evidence_dir,
                    label=f"stability-{index + 1}",
                )
            )
        result = {
            **transaction,
            "status": "succeeded",
            "completed_at": _utc_now(),
            "source_md_sha256": source_hashes,
            "ledger_sha256": _sha256_file(ledger_path),
            "catalog_sha256": _sha256_file(catalog_path),
            "projected_catalog_sha256": projected_catalog_hash,
            "catalog_verification": catalog_verification,
            "baseline_resource_closure": baseline_closure,
            "post_resource_closure": closure,
            "post_resource_closure_gate": closure_gate,
            "preexisting_findings": closure_gate["preexisting_findings"],
            "stability_observations": observations,
            "evidence": str(evidence_dir),
        }
        _atomic_write_json(manifest_path, result)
        return result
    except Exception as exc:
        rollback_errors: list[str] = []
        for label in reversed(list(before_values)):
            path, before = before_values[label]
            try:
                _restore_cas(
                    path,
                    before=before,
                    before_identity=before_identities[label],
                    written=written_values.get(label),
                    written_identity=written_identities.get(label),
                )
            except Exception as rollback_exc:
                rollback_errors.append(f"{label}: {rollback_exc}")
        failure = {
            **transaction,
            "status": "rollback-failed" if rollback_errors else "rolled-back",
            "completed_at": _utc_now(),
            "error": str(exc),
            "rollback_errors": rollback_errors,
            "evidence": str(evidence_dir),
        }
        _atomic_write_json(manifest_path, failure)
        raise SystemProvenanceRepairError(
            f"system provenance repair 未完成，状态={failure['status']}；"
            f"原因：{exc}；证据：{evidence_dir}"
        ) from exc
    finally:
        import shutil

        shutil.rmtree(stage_dir, ignore_errors=True)
