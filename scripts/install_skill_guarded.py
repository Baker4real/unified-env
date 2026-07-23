#!/usr/bin/env python3
"""Install a Codex skill and atomically reconcile its local governance state.

The model-facing ``skill-install-guard`` skill decides whether a candidate may
be installed.  This wrapper is the operational boundary: it stages the
candidate, writes provenance and the unified ledger, runs resource closure,
regenerates the local catalog, verifies the postcondition, and rolls back on
failure.  The bundled system installer remains an upstream helper and is not
modified.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as _datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import unquote, urlparse


sys.dont_write_bytecode = True


DEFAULT_ACTIVE_ROOT = Path(r"D:\Codex\.codex\skills")
DEFAULT_PLUGIN_CACHE_ROOT = Path(r"D:\Codex\.codex\plugins\cache")
DEFAULT_LEDGER = Path(r"D:\Codex\.codex\skills\.downloaded-skills-source-state.json")
DEFAULT_CATALOG = Path(r"D:\Codex\.codex\skill-catalog\catalog.json")
DEFAULT_GENERATOR = Path(r"D:\Codex\projects\统一环境\scripts\generate_skill_catalog.py")
DEFAULT_CLOSURE = Path(
    r"D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py"
)
DEFAULT_SYSTEM_INSTALLER = Path(
    r"D:\Codex\.codex\skills\.system\skill-installer\scripts\install-skill-from-github.py"
)
DEFAULT_PYTHON = Path(r"D:\Codex\tools\python314-official\python.exe")
DEFAULT_TEMP_ROOT = Path(r"D:\Codex\tmp\skill-install-guarded")
DEFAULT_LOCK_ROOT = Path(r"D:\Codex\.codex\skill-install")
DEFAULT_EVIDENCE_ROOT = Path(r"D:\Codex\.codex\run-evidence\skill-install-guarded")

SAFE_SKILL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
REPO_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$")


class InstallError(RuntimeError):
    """A fail-closed wrapper error."""


def utc_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def today() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).date().isoformat()


def is_reparse(path: Path) -> bool:
    if path.is_symlink():
        return True
    try:
        stat_result = path.stat()
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise InstallError(f"无法读取路径属性：{path}：{exc}") from exc
    return bool(getattr(stat_result, "st_file_attributes", 0) & 0x400)


def d_path(value: Path | str, *, label: str, must_exist: bool = False) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    if path.drive.casefold() != "d:":
        raise InstallError(f"{label}必须位于本机 D 盘：{path}")
    if must_exist and not path.exists():
        raise InstallError(f"{label}不存在：{path}")
    if path.exists() and is_reparse(path):
        raise InstallError(f"{label}不能是符号链接、junction 或其他 reparse point：{path}")
    return path.absolute()


def ensure_dir(path: Path, *, label: str) -> Path:
    path = d_path(path, label=label)
    if path.exists() and not path.is_dir():
        raise InstallError(f"{label}不是目录：{path}")
    path.mkdir(parents=True, exist_ok=True)
    if is_reparse(path):
        raise InstallError(f"{label}不能是 reparse point：{path}")
    return path


def ensure_file(path: Path, *, label: str) -> Path:
    path = d_path(path, label=label, must_exist=True)
    if not path.is_file():
        raise InstallError(f"{label}不是普通文件：{path}")
    return path


def ensure_tree_no_reparse(root: Path, *, label: str) -> None:
    """Reject links/junctions anywhere in a candidate before copying it."""
    if is_reparse(root):
        raise InstallError(f"{label}不能包含 reparse point：{root}")

    def onerror(error: OSError) -> None:
        raise InstallError(f"无法遍历{label}：{error}") from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        current_path = Path(current)
        for child_name in [*directories, *files]:
            child = current_path / child_name
            if is_reparse(child):
                raise InstallError(f"{label}不能包含 reparse point：{child}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path = d_path(path, label="原子写入目标")
    parent = ensure_dir(path.parent, label="原子写入目录")
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=parent,
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_bytes(
        path,
        (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
    )


def load_json(path: Path, *, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise InstallError(f"{label}不是可读取的合法 UTF-8 JSON：{path}：{exc}") from exc


def strip_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"', "`"}:
        return value[1:-1].strip()
    return value


def read_skill_name(skill_md: Path) -> str:
    try:
        lines = skill_md.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError) as exc:
        raise InstallError(f"无法读取 SKILL.md：{skill_md}：{exc}") from exc
    if not lines or lines[0].strip() != "---":
        raise InstallError(f"SKILL.md 缺少 frontmatter：{skill_md}")
    for line in lines[1:]:
        if line.strip() in {"---", "..."}:
            break
        match = re.match(r"^\s*name\s*:\s*(.+?)\s*$", line)
        if match:
            name = strip_scalar(match.group(1))
            if not name or not SAFE_SKILL_NAME.fullmatch(name):
                raise InstallError(f"SKILL.md 的 name 非法：{skill_md}：{name!r}")
            return name
    raise InstallError(f"SKILL.md frontmatter 缺少 name：{skill_md}")


def entry_name(entry: Any) -> str | None:
    if isinstance(entry, dict):
        value = entry.get("name") or entry.get("skill")
        return str(value) if isinstance(value, str) else None
    if isinstance(entry, str):
        return entry
    return None


def normalize_repo(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    value = value.strip().rstrip("/")
    if REPO_NAME.fullmatch(value):
        value = f"https://github.com/{value}"
    if value.endswith(".git"):
        value = value[:-4]
    return value.casefold().rstrip("/")


def github_repo_url(value: str | None) -> str | None:
    if not value:
        return None
    if REPO_NAME.fullmatch(value):
        return f"https://github.com/{value.removesuffix('.git')}"
    parsed = urlparse(value)
    if parsed.netloc.casefold() != "github.com":
        raise InstallError(f"source repository 必须是 GitHub 或 owner/repo：{value}")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise InstallError("source repository URL 不得包含用户信息、query 或 fragment")
    path = parsed.path.strip("/")
    if not path or path.count("/") != 1:
        raise InstallError(f"无法解析 GitHub repository：{value}")
    return f"https://github.com/{path.removesuffix('.git')}"


def parse_github_url(url: str) -> tuple[str, str]:
    parsed = urlparse(url)
    if parsed.netloc.casefold() != "github.com":
        raise InstallError(f"安装 URL 必须来自 github.com：{url}")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise InstallError("安装 URL 不得包含用户信息、query 或 fragment")
    parts = [unquote(part) for part in parsed.path.strip("/").split("/") if part]
    for marker in ("tree", "blob"):
        if marker in parts:
            index = parts.index(marker)
            if index + 2 >= len(parts):
                break
            path = "/".join(parts[index + 2 :])
            if path:
                return path, parts[index + 1]
    raise InstallError(f"URL 未包含可安装的 GitHub skill path：{url}")


def validate_decision_manifest(path: Path) -> dict[str, Any]:
    data = load_json(path, label="guard decision manifest")
    if not isinstance(data, dict):
        raise InstallError("guard decision manifest 顶层必须是 JSON 对象")
    decision = data.get("decision")
    if decision not in {"install", "update"}:
        raise InstallError("guard decision manifest 的 decision 必须是 install 或 update")
    source_status = data.get("source_status")
    if source_status is None and isinstance(data.get("source"), dict):
        source_status = data["source"].get("status")
    if source_status not in {"source-pass", "source-review"}:
        raise InstallError(
            "guard decision manifest 必须包含 source-pass 或 source-review；"
            f"当前为 {source_status!r}"
        )
    writing_gate = data.get("writing_great_skills")
    if isinstance(writing_gate, dict):
        gate_status = writing_gate.get("status")
    else:
        gate_status = writing_gate
    if gate_status not in {"pass", "passed", "no-change", "compliant"}:
        raise InstallError(
            "guard decision manifest 必须证明 writing-great-skills 已通过或无需修改"
        )
    return data


def target_specs(args: argparse.Namespace) -> list[tuple[str, str]]:
    specs: list[tuple[str, str]] = []
    if args.candidate:
        candidate = d_path(args.candidate, label="candidate", must_exist=True)
        if not candidate.is_dir():
            raise InstallError(f"candidate 必须是目录：{candidate}")
        name = args.name or candidate.name
        specs.append((name, candidate.name))
    elif args.url:
        upstream_path, _ = parse_github_url(args.url)
        specs.append((args.name or Path(upstream_path).name, upstream_path))
    else:
        if not args.repo or not args.paths:
            raise InstallError("远端安装必须同时提供 --repo 和 --path，或使用 --url/--candidate")
        for path in args.paths:
            path = path.strip("/")
            if not path:
                raise InstallError("--path 不能为空")
            specs.append((Path(path).name, path))
        if args.name:
            if len(specs) != 1:
                raise InstallError("多个 --path 不能同时使用 --name")
            specs[0] = (args.name, specs[0][1])

    names = [name for name, _ in specs]
    for name in names:
        if not SAFE_SKILL_NAME.fullmatch(name):
            raise InstallError(f"skill name 非法：{name!r}")
    if len(set(names)) != len(names):
        raise InstallError(f"本次安装包含重复 skill name：{names}")
    return specs


def apply_candidate_upstream_path(
    args: argparse.Namespace,
    decision: dict[str, Any],
    specs: list[tuple[str, str]],
) -> list[tuple[str, str]]:
    if not args.candidate:
        return specs
    source = decision.get("source")
    if not isinstance(source, dict) or source.get("upstream_path") is None:
        return specs
    upstream_path = source["upstream_path"]
    if not isinstance(upstream_path, str) or not upstream_path.strip():
        raise InstallError("source.upstream_path 必须是非空字符串")
    if any(not character.isprintable() for character in upstream_path):
        raise InstallError("source.upstream_path 不能包含不可打印字符")
    upstream_path = upstream_path.strip()
    parts = upstream_path.split("/")
    if (
        "\\" in upstream_path
        or "`" in upstream_path
        or upstream_path.startswith("/")
        or re.match(r"^[A-Za-z]:", upstream_path)
        or any(not part or part in {".", ".."} for part in parts)
    ):
        raise InstallError("source.upstream_path 必须是仓库内的 POSIX 相对路径")
    return [(specs[0][0], upstream_path)]


LEDGER_UPDATE_FIELDS = {
    "action",
    "installed_version",
    "path",
    "resource_paths",
    "status",
    "tag",
}


def ledger_updates(source: dict[str, Any]) -> dict[str, Any]:
    """Validate optional source-ledger facts supplied by an update decision."""
    raw = source.get("ledger_updates")
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise InstallError("source.ledger_updates 必须是对象")

    unexpected = sorted(set(raw) - LEDGER_UPDATE_FIELDS)
    if unexpected:
        raise InstallError(
            "source.ledger_updates 包含不允许的字段：" + ", ".join(unexpected)
        )

    normalized: dict[str, Any] = {}
    for field, value in raw.items():
        if field == "resource_paths":
            if not isinstance(value, list) or not value or not all(
                isinstance(item, str) and item.strip() for item in value
            ):
                raise InstallError("source.ledger_updates.resource_paths 必须是非空字符串数组")
            normalized[field] = list(value)
            continue
        if not isinstance(value, str) or not value.strip():
            raise InstallError(f"source.ledger_updates.{field} 必须是非空字符串")
        normalized[field] = value
    return normalized


def source_context(
    args: argparse.Namespace,
    decision: dict[str, Any],
    specs: list[tuple[str, str]],
) -> dict[str, Any]:
    source = decision.get("source") if isinstance(decision.get("source"), dict) else {}
    ledger_update_values = ledger_updates(source)
    repo_value = source.get("repo") or args.repo
    repo_url = None
    if repo_value:
        if REPO_NAME.fullmatch(str(repo_value)) or urlparse(str(repo_value)).netloc:
            repo_url = github_repo_url(str(repo_value))
        elif not args.candidate:
            raise InstallError(f"无法解析 source repository：{repo_value}")
    if args.url and not repo_url:
        parsed = urlparse(args.url)
        repo_parts = [part for part in parsed.path.strip("/").split("/") if part]
        if len(repo_parts) >= 2:
            repo_url = f"https://github.com/{repo_parts[0]}/{repo_parts[1]}"
    source_type = "github" if repo_url else "local-candidate"
    source_id = source.get("id")
    if not isinstance(source_id, str) or not source_id.strip():
        if repo_url:
            source_id = repo_url.removeprefix("https://github.com/").replace("/", "-")
        else:
            source_id = f"local-candidate-{specs[0][0]}"
    ref = source.get("ref") or args.ref or "main"
    commit = source.get("commit") or source.get("catalog_ref") or source.get("revision")
    writing_gate = decision.get("writing_great_skills")
    if isinstance(writing_gate, dict):
        writing_revision = writing_gate.get("revision") or "no-change"
    else:
        writing_revision = "no-change"
    overlay = decision.get("local_overlay")
    if isinstance(overlay, dict):
        overlay_status = overlay.get("status") or "none"
        overlay_summary = overlay.get("summary") or ""
    elif isinstance(overlay, list):
        overlay_status = "replayed"
        overlay_summary = "; ".join(str(item) for item in overlay)
    else:
        overlay_status = "none"
        overlay_summary = ""
    return {
        "decision": decision["decision"],
        "source_status": decision.get("source_status") or source.get("status"),
        "source_id": source_id,
        "source_type": source_type,
        "repo": repo_url,
        "ref": str(ref),
        "commit": str(commit) if commit else None,
        "writing_revision": str(writing_revision),
        "overlay_status": str(overlay_status),
        "overlay_summary": str(overlay_summary),
        "ledger_updates": ledger_update_values,
        "manifest_path": str(args.decision_manifest),
        "source_paths": [path for _, path in specs],
    }


def guarded_command(args: argparse.Namespace) -> str:
    if args.candidate:
        return f"guarded wrapper --candidate {args.candidate}"
    if args.url:
        return f"guarded wrapper --url {args.url}"
    return f"guarded wrapper --repo {args.repo} --path {' '.join(args.paths)}"


def source_record_text(
    *,
    skill_name: str,
    active_root: Path,
    upstream_path: str,
    context: dict[str, Any],
    command: str,
) -> str:
    repository = context["repo"] or "local candidate supplied by the user"
    lines = [
        "# Source Provenance",
        "",
        f"Skill: `{skill_name}`",
        f"Local path: `{active_root / skill_name}`",
        f"Active root: `{active_root}`",
        f"Recorded: {today()}",
        f"Status: {context['source_status']}",
        f"Decision: {context['decision']}",
        f"Source type: {context['source_type']}",
        f"Source repository: `{repository}`",
        f"Upstream path: `{upstream_path}`",
        f"Ref: `{context['ref']}`",
    ]
    if context["commit"]:
        lines.append(f"Commit or revision: `{context['commit']}`")
    lines.extend(
        [
            f"Retrieval: `{command}`",
            f"writing-great-skills gate: {context['writing_revision']}",
            f"Local overlay: {context['overlay_status']}"
            + (f" ({context['overlay_summary']})" if context["overlay_summary"] else ""),
            "Guarded activation: complete only after ledger, closure, catalog, and hash postchecks pass.",
            f"Decision manifest: `{context['manifest_path']}`",
            "",
        ]
    )
    return "\n".join(lines)


def append_source_record(
    path: Path,
    *,
    skill_name: str,
    active_root: Path,
    upstream_path: str,
    context: dict[str, Any],
    command: str,
) -> None:
    generated = source_record_text(
        skill_name=skill_name,
        active_root=active_root,
        upstream_path=upstream_path,
        context=context,
        command=command,
    )
    if path.exists():
        existing = path.read_text(encoding="utf-8-sig")
        match = re.search(r"^\s*Skill:\s*`?([^`\r\n]+)`?\s*$", existing, re.MULTILINE)
        if match and match.group(1).strip() != skill_name:
            raise InstallError(f"候选 SOURCE.md 的 Skill 与目录不一致：{path}")
        content = existing.rstrip() + "\n\n---\n\n" + generated
    else:
        content = generated
    atomic_write_bytes(path, (content.rstrip() + "\n").encode("utf-8"))


def update_ledger(
    data: dict[str, Any],
    *,
    names: list[str],
    context: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise InstallError("source ledger 顶层必须是 JSON 对象")
    for key in ("sources", "unresolved", "deleted"):
        if key not in data:
            data[key] = []
        if not isinstance(data[key], list):
            raise InstallError(f"source ledger 的 {key} 必须是数组")

    name_set = set(names)
    for key in ("unresolved", "deleted"):
        data[key] = [entry for entry in data[key] if entry_name(entry) not in name_set]
    for entry in data["sources"]:
        if not isinstance(entry, dict):
            continue
        skills = entry.get("skills")
        if isinstance(skills, list):
            entry["skills"] = [skill for skill in skills if skill not in name_set]

    source_id = str(context["source_id"])
    source_repo = context["repo"]
    target_source: dict[str, Any] | None = None
    for entry in data["sources"]:
        if not isinstance(entry, dict):
            continue
        if entry.get("id") == source_id or (
            source_repo and normalize_repo(entry.get("repo")) == normalize_repo(source_repo)
        ):
            target_source = entry
            break

    if target_source is None:
        target_source = {
            "id": source_id,
            "type": context["source_type"],
            "repo": source_repo or "local candidate",
            "ref": context["ref"],
            "skills": [],
            "status": "installed-by-guarded-wrapper",
            "local_changes": [],
        }
        data["sources"].append(target_source)
    target_source.setdefault("id", source_id)
    target_source.setdefault("type", context["source_type"])
    if source_repo:
        target_source["repo"] = source_repo
    if context["ref"]:
        target_source["ref"] = context["ref"]
    if context["commit"]:
        target_source["last_checked_commit"] = context["commit"]
        target_source["catalog_ref"] = context["commit"]
    target_source["last_guarded_install"] = utc_now()
    target_source.setdefault("status", "installed-by-guarded-wrapper")
    for field, value in context.get("ledger_updates", {}).items():
        target_source[field] = value
    skills = target_source.setdefault("skills", [])
    if not isinstance(skills, list):
        raise InstallError(f"source ledger source.skills 不是数组：{source_id}")
    for name in names:
        if name not in skills:
            skills.append(name)
    if context["overlay_status"].casefold() not in {"none", "no-change", ""}:
        changes = target_source.setdefault("local_changes", [])
        if not isinstance(changes, list):
            raise InstallError(f"source ledger local_changes 不是数组：{source_id}")
        summary = context["overlay_summary"] or context["overlay_status"]
        marker = f"guarded wrapper: {summary}"
        if not any(isinstance(item, dict) and item.get("summary") == marker for item in changes):
            changes.append({"date": today(), "summary": marker})
    data["updated_at"] = today()
    return data


def run_process(
    command: list[str],
    *,
    evidence_dir: Path,
    label: str,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        env=env,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    atomic_write_bytes(
        evidence_dir / f"{label}.stdout.txt",
        result.stdout.encode("utf-8", errors="replace"),
    )
    atomic_write_bytes(
        evidence_dir / f"{label}.stderr.txt",
        result.stderr.encode("utf-8", errors="replace"),
    )
    if check and result.returncode != 0:
        raise InstallError(
            f"{label} 失败，退出码 {result.returncode}；详见 {evidence_dir}"
        )
    return result


def run_closure(
    *,
    root: Path,
    closure_script: Path,
    interpreter: Path,
    evidence_dir: Path,
    label: str,
) -> dict[str, Any]:
    result = run_process(
        [
            str(interpreter),
            str(closure_script),
            "--root",
            str(root),
            "--strict",
            "--format",
            "json",
        ],
        evidence_dir=evidence_dir,
        label=label,
    )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise InstallError(f"{label} 未返回合法 JSON：{exc}") from exc
    summary = payload.get("summary") if isinstance(payload, dict) else None
    if not isinstance(summary, dict) or summary.get("finding_count") != 0:
        raise InstallError(f"{label} 有硬失败：{json.dumps(summary, ensure_ascii=False)}")
    return payload


def load_and_validate_manifest(path: Path, *, names: list[str]) -> dict[str, Any]:
    data = validate_decision_manifest(path)
    declared = data.get("skills")
    if declared is not None:
        if not isinstance(declared, list) or sorted(str(item) for item in declared) != sorted(names):
            raise InstallError("guard decision manifest 的 skills 与本次安装目标不一致")
    return data


def make_staging_ledger(names: list[str], context: dict[str, Any]) -> dict[str, Any]:
    return update_ledger(
        {"updated_at": today(), "notes": [], "sources": [], "unresolved": [], "deleted": []},
        names=names,
        context=context,
    )


def stage_candidate(
    *,
    args: argparse.Namespace,
    specs: list[tuple[str, str]],
    stage_root: Path,
    context: dict[str, Any],
    active_root: Path,
    closure_script: Path,
    interpreter: Path,
    evidence_dir: Path,
) -> dict[str, Any]:
    ensure_dir(stage_root, label="staging root")
    if args.candidate:
        candidate = d_path(args.candidate, label="candidate", must_exist=True)
        ensure_tree_no_reparse(candidate, label="candidate")
        name = specs[0][0]
        shutil.copytree(candidate, stage_root / name)
    else:
        command = [str(interpreter), str(args.system_installer)]
        if args.url:
            command.extend(["--url", args.url])
        else:
            command.extend(["--repo", args.repo, "--path", *args.paths])
        if args.ref and not args.url:
            command.extend(["--ref", args.ref])
        if args.name:
            command.extend(["--name", args.name])
        if args.method:
            command.extend(["--method", args.method])
        command.extend(["--dest", str(stage_root)])
        run_process(command, evidence_dir=evidence_dir, label="upstream-installer")

    names = [name for name, _ in specs]
    for name, upstream_path in specs:
        target = stage_root / name
        if not target.is_dir() or is_reparse(target):
            raise InstallError(f"staging 缺少安全的 skill 目录：{target}")
        ensure_tree_no_reparse(target, label=f"staging skill {name}")
        skill_md = target / "SKILL.md"
        if not skill_md.is_file() or is_reparse(skill_md):
            raise InstallError(f"staging 缺少安全的 SKILL.md：{skill_md}")
        actual_name = read_skill_name(skill_md)
        if actual_name != name:
            raise InstallError(f"SKILL.md name 与目标目录不一致：{actual_name!r} != {name!r}")
        append_source_record(
            target / "SOURCE.md",
            skill_name=name,
            active_root=active_root,
            upstream_path=upstream_path,
            context=context,
            command=guarded_command(args),
        )
    atomic_write_json(stage_root / ".downloaded-skills-source-state.json", make_staging_ledger(names, context))
    closure = run_closure(
        root=stage_root,
        closure_script=closure_script,
        interpreter=interpreter,
        evidence_dir=evidence_dir,
        label="staged-resource-closure",
    )
    return {"names": names, "closure": closure}


def safe_remove(path: Path) -> None:
    if not path.exists():
        return
    if is_reparse(path):
        raise InstallError(f"拒绝删除 reparse point：{path}")
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def path_exists_strict(path: Path, *, label: str) -> bool:
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise InstallError(f"无法确认{label}是否存在：{path}：{exc}") from exc


def tree_file_hashes(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}

    def onerror(error: OSError) -> None:
        raise InstallError(f"无法遍历 skill 内容树：{root}：{error}") from error

    for current, directories, files in os.walk(
        root,
        topdown=True,
        followlinks=False,
        onerror=onerror,
    ):
        directories.sort(key=str.casefold)
        files.sort(key=str.casefold)
        current_path = Path(current)
        for filename in files:
            source = current_path / filename
            if is_reparse(source) or not source.is_file():
                raise InstallError(f"skill 内容树只允许普通文件：{source}")
            relative = source.relative_to(root).as_posix()
            result[relative] = sha256_file(source)
    return result


def copy_tree_without_security_metadata(source: Path, destination: Path) -> None:
    """Copy skill content while letting every target inherit active-root ACLs."""
    ensure_tree_no_reparse(source, label="待激活 skill")
    if path_exists_strict(destination, label="激活临时目录"):
        raise InstallError(f"激活临时目录已存在：{destination}")
    destination.mkdir()
    try:
        root_skill_md = source / "SKILL.md"
        for current, directories, files in os.walk(
            source,
            topdown=True,
            followlinks=False,
        ):
            directories.sort(key=str.casefold)
            files.sort(key=str.casefold)
            current_path = Path(current)
            relative = current_path.relative_to(source)
            target_directory = destination / relative
            target_directory.mkdir(exist_ok=True)
            for directory in directories:
                child = current_path / directory
                if is_reparse(child):
                    raise InstallError(f"待激活 skill 不能包含 reparse point：{child}")
                (target_directory / directory).mkdir(exist_ok=True)
            for filename in files:
                child = current_path / filename
                if child == root_skill_md:
                    continue
                if is_reparse(child) or not child.is_file():
                    raise InstallError(f"待激活 skill 只允许普通文件：{child}")
                shutil.copyfile(child, target_directory / filename)
        if not root_skill_md.is_file() or is_reparse(root_skill_md):
            raise InstallError(f"待激活 skill 缺少安全的 SKILL.md：{root_skill_md}")
        shutil.copyfile(root_skill_md, destination / "SKILL.md")
        if tree_file_hashes(source) != tree_file_hashes(destination):
            raise InstallError(f"激活临时目录内容指纹不一致：{destination}")
    except Exception:
        if path_exists_strict(destination, label="失败的激活临时目录"):
            safe_remove(destination)
        raise


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
for root in roots:
    root.lstat()
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directory_count += 1
        current_path = Path(current)
        for directory in directories:
            child = current_path / directory
            if child.is_symlink():
                raise RuntimeError(f"reparse/symlink directory: {child}")
        for filename in files:
            child = current_path / filename
            if child.is_symlink() or not child.is_file():
                raise RuntimeError(f"non-regular file: {child}")
            with child.open("rb") as stream:
                while stream.read(1024 * 1024):
                    pass
            file_count += 1
print(json.dumps({"directory_count": directory_count, "file_count": file_count}))
"""
    runtime_result = run_process(
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
    acl_result = run_process(
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
    ensure_dir(backup.parent, label="backup 目录")
    shutil.copy2(path, backup)
    if sha256_file(path) != sha256_file(backup):
        raise InstallError(f"backup 指纹不一致：{path}")
    return backup


def activate_directories(
    *,
    stage_root: Path,
    active_root: Path,
    names: list[str],
    backup_root: Path,
    records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    ensure_dir(backup_root, label="skill backup 目录")
    for name in names:
        staged = stage_root / name
        active = active_root / name
        active_exists = path_exists_strict(active, label=f"active skill {name}")
        if active_exists and is_reparse(active):
            raise InstallError(f"active skill 目标是 reparse point：{active}")
        if active_exists and not active.is_dir():
            raise InstallError(f"active skill 目标不是目录：{active}")
        activation_temp = active_root / f"_disabled-guarded-{name}-{uuid.uuid4().hex}"
        record = {
            "name": name,
            "active": str(active),
            "backup": str(backup_root / name),
            "activation_temp": str(activation_temp),
            "had_existing": active_exists,
            "backup_moved": False,
            "activated": False,
        }
        records.append(record)
        copy_tree_without_security_metadata(staged, activation_temp)
        if active_exists:
            shutil.move(str(active), str(backup_root / name))
            record["backup_moved"] = True
        try:
            os.replace(activation_temp, active)
        except Exception as exc:
            raise InstallError(f"激活 skill 失败：{name}：{exc}") from exc
        record["activated"] = True
    return records


def rollback_directories(records: list[dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    for record in reversed(records):
        active = Path(record["active"])
        backup = Path(record["backup"])
        activation_temp = Path(record["activation_temp"])
        try:
            if path_exists_strict(activation_temp, label="rollback 激活临时目录"):
                safe_remove(activation_temp)
            if record["activated"] and path_exists_strict(active, label="rollback active skill"):
                safe_remove(active)
            if record["backup_moved"] and path_exists_strict(backup, label="rollback skill backup"):
                shutil.move(str(backup), str(active))
        except Exception as exc:  # pragma: no cover - exercised by injected host failures
            errors.append(f"{record['name']}: {exc}")
    return errors


def restore_file(path: Path, backup: Path | None) -> None:
    if backup is None:
        if path.exists():
            safe_remove(path)
        return
    ensure_dir(path.parent, label="恢复文件目录")
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.restore")
    shutil.copy2(backup, temporary)
    os.replace(temporary, path)


def verify_catalog(
    *,
    catalog_path: Path,
    active_root: Path,
    names: list[str],
) -> dict[str, Any]:
    catalog = load_json(catalog_path, label="skill catalog")
    if not isinstance(catalog, dict) or not isinstance(catalog.get("artifacts"), list):
        raise InstallError("skill catalog 缺少 artifacts 数组")
    if catalog.get("checks", {}).get("resource_closure", {}).get("status") != "pass":
        raise InstallError("skill catalog 的资源闭包检查不是 pass")
    verified: list[dict[str, Any]] = []
    for name in names:
        matches = [
            item
            for item in catalog["artifacts"]
            if isinstance(item, dict) and item.get("scope") == "active" and item.get("name") == name
        ]
        if len(matches) != 1:
            raise InstallError(f"skill catalog 对 {name} 的 active 条目数量不是 1：{len(matches)}")
        item = matches[0]
        if item.get("ledger_coverage") != "pass":
            raise InstallError(f"skill catalog 对 {name} 的 ledger coverage 不是 pass")
        source = item.get("source") if isinstance(item.get("source"), dict) else {}
        if source.get("status") in {None, "missing"} or source.get("conflicts"):
            raise InstallError(f"skill catalog 对 {name} 的 SOURCE.md 存在冲突或缺失")
        actual = sha256_file(active_root / name / "SKILL.md")
        recorded = item.get("integrity", {}).get("skill_md_sha256")
        if actual != recorded:
            raise InstallError(f"skill catalog 对 {name} 的 SKILL.md 哈希不一致")
        verified.append({"name": name, "skill_md_sha256": actual})
    return {"generated_at": catalog.get("generated_at"), "skills": verified}


@contextlib.contextmanager
def installation_lock(lock_path: Path) -> Iterator[None]:
    ensure_dir(lock_path.parent, label="skill 安装锁目录")
    try:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError as exc:
        raise InstallError(f"已有 skill 安装事务或遗留锁：{lock_path}；请先检查证据后再处理") from exc
    try:
        os.write(descriptor, f"pid={os.getpid()}\nutc={utc_now()}\n".encode("utf-8"))
        os.close(descriptor)
        descriptor = -1
        yield
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        lock_path.unlink(missing_ok=True)


def write_transaction_manifest(path: Path, payload: dict[str, Any]) -> None:
    atomic_write_json(path, payload)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="通过事务 wrapper 安装并校验 Codex skill")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--candidate", type=Path, help="已通过候选审查的本地 skill 目录")
    source.add_argument("--repo", help="GitHub owner/repo")
    source.add_argument("--url", help="GitHub skill tree/blob URL")
    parser.add_argument("--path", dest="paths", nargs="+", help="GitHub repo 内的 skill path")
    parser.add_argument("--ref", default="main")
    parser.add_argument("--name", help="单个 skill 的 active name")
    parser.add_argument("--method", choices=("auto", "download", "git"), default="auto")
    parser.add_argument("--decision-manifest", type=Path, required=True)
    parser.add_argument("--update", action="store_true", help="兼容旧调用；实际更新权限仍由 manifest decision=update 决定")
    parser.add_argument("--dry-run", action="store_true", help="只暂存和验证，不改变 active root、ledger 或 catalog")
    parser.add_argument("--active-root", type=Path, default=DEFAULT_ACTIVE_ROOT)
    parser.add_argument("--plugin-cache-root", type=Path, default=DEFAULT_PLUGIN_CACHE_ROOT)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--generator", type=Path, default=DEFAULT_GENERATOR)
    parser.add_argument("--closure-script", type=Path, default=DEFAULT_CLOSURE)
    parser.add_argument("--system-installer", type=Path, default=DEFAULT_SYSTEM_INSTALLER)
    parser.add_argument("--python", dest="interpreter", type=Path, default=DEFAULT_PYTHON)
    parser.add_argument("--temp-root", type=Path, default=DEFAULT_TEMP_ROOT)
    parser.add_argument("--lock-root", type=Path, default=DEFAULT_LOCK_ROOT)
    parser.add_argument("--evidence-root", type=Path, default=DEFAULT_EVIDENCE_ROOT)
    return parser


def execute(args: argparse.Namespace) -> dict[str, Any]:
    active_root = ensure_dir(args.active_root, label="active root")
    plugin_cache_root = ensure_dir(args.plugin_cache_root, label="plugin cache root")
    ledger_path = ensure_file(args.ledger, label="source ledger")
    generator = ensure_file(args.generator, label="catalog generator")
    closure_script = ensure_file(args.closure_script, label="resource closure script")
    interpreter = ensure_file(args.interpreter, label="Python interpreter")
    system_installer = d_path(args.system_installer, label="system installer")
    if not args.candidate:
        if not system_installer.exists() or not system_installer.is_file():
            raise InstallError(f"系统 skill installer 不存在：{system_installer}")
    catalog_path = d_path(args.catalog, label="catalog output")
    temp_root = ensure_dir(args.temp_root, label="skill staging temp root")
    evidence_root = ensure_dir(args.evidence_root, label="skill install evidence root")
    lock_root = ensure_dir(args.lock_root, label="skill install lock root")
    decision_path = d_path(args.decision_manifest, label="decision manifest", must_exist=True)
    specs = target_specs(args)
    names = [name for name, _ in specs]
    decision = load_and_validate_manifest(decision_path, names=names)
    specs = apply_candidate_upstream_path(args, decision, specs)
    if args.update and decision["decision"] != "update":
        raise InstallError("--update 只能与 decision=update 的 manifest 一起使用")
    if decision["decision"] == "update" and not args.update:
        # The guard manifest is the authorization.  The explicit flag is an
        # extra compatibility signal, not a second approval gate.
        pass
    context = source_context(args, decision, specs)
    transaction_id = uuid.uuid4().hex
    evidence_dir = evidence_root / f"install-{_datetime.datetime.now().strftime('%Y%m%dT%H%M%S')}-{transaction_id}"
    ensure_dir(evidence_dir, label="transaction evidence directory")
    manifest_path = evidence_dir / "manifest.json"
    plan = {
        "schema_version": 1,
        "transaction_id": transaction_id,
        "status": "prepared",
        "started_at": utc_now(),
        "decision": decision,
        "targets": names,
        "active_root": str(active_root),
        "ledger": str(ledger_path),
        "catalog": str(catalog_path),
        "wrapper": "D:/Codex/.codex/scripts/install-skill-guarded.cmd",
    }
    write_transaction_manifest(manifest_path, plan)

    stage_dir = Path(tempfile.mkdtemp(prefix=f"transaction-{transaction_id}-", dir=temp_root))
    directory_records: list[dict[str, Any]] = []
    ledger_backup: Path | None = None
    catalog_backup: Path | None = None
    state_backups_ready = False
    try:
        staged = stage_candidate(
            args=args,
            specs=specs,
            stage_root=stage_dir,
            context=context,
            active_root=active_root,
            closure_script=closure_script,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
        )
        if args.dry_run:
            result = {
                **plan,
                "status": "dry-run-pass",
                "completed_at": utc_now(),
                "staged": staged,
                "evidence": str(evidence_dir),
            }
            write_transaction_manifest(manifest_path, result)
            return result

        active_state = load_json(ledger_path, label="source ledger")
        backup_root = evidence_dir / "backups"
        ensure_dir(backup_root, label="transaction backup root")
        ledger_backup = backup_file(ledger_path, backup_root, "source-state-before.json")
        catalog_backup = backup_file(catalog_path, backup_root, "catalog-before.json")
        state_backups_ready = True
        for name in names:
            active = active_root / name
            if decision["decision"] == "install" and active.exists():
                raise InstallError(f"install 分支不能覆盖已有 active skill：{active}")
            if decision["decision"] == "update" and not active.exists():
                raise InstallError(f"update 分支要求已有 active skill：{active}")
        activate_directories(
            stage_root=stage_dir,
            active_root=active_root,
            names=names,
            backup_root=backup_root / "active-skills",
            records=directory_records,
        )
        activation_readability = verify_activation_readability(
            active_root=active_root,
            names=names,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
        )
        updated_ledger = update_ledger(active_state, names=names, context=context)
        atomic_write_json(ledger_path, updated_ledger)
        run_process(
            [
                str(interpreter),
                str(generator),
                "--write",
                "--active-root",
                str(active_root),
                "--plugin-cache-root",
                str(plugin_cache_root),
                "--ledger",
                str(ledger_path),
                "--output",
                str(catalog_path),
            ],
            evidence_dir=evidence_dir,
            label="catalog-generation",
        )
        post_closure = run_closure(
            root=active_root,
            closure_script=closure_script,
            interpreter=interpreter,
            evidence_dir=evidence_dir,
            label="post-resource-closure",
        )
        catalog_verification = verify_catalog(
            catalog_path=catalog_path,
            active_root=active_root,
            names=names,
        )
        result = {
            **plan,
            "status": "succeeded",
            "completed_at": utc_now(),
            "targets": names,
            "directory_records": directory_records,
            "activation_readability": activation_readability,
            "post_resource_closure": post_closure,
            "catalog_verification": catalog_verification,
            "catalog_sha256": sha256_file(catalog_path),
            "evidence": str(evidence_dir),
        }
        write_transaction_manifest(manifest_path, result)
        return result
    except Exception as exc:
        rollback_errors = rollback_directories(directory_records)
        if state_backups_ready:
            try:
                restore_file(ledger_path, ledger_backup)
                restore_file(catalog_path, catalog_backup)
            except Exception as restore_exc:
                rollback_errors.append(f"state restore: {restore_exc}")
        failure = {
            **plan,
            "status": "rollback-failed" if rollback_errors else "rolled-back",
            "completed_at": utc_now(),
            "error": str(exc),
            "rollback_errors": rollback_errors,
            "evidence": str(evidence_dir),
        }
        write_transaction_manifest(manifest_path, failure)
        raise InstallError(
            f"skill 安装未完成，状态={failure['status']}；原因：{exc}；证据：{evidence_dir}"
        ) from exc
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        with installation_lock(d_path(args.lock_root, label="skill install lock root") / "install.lock"):
            result = execute(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except InstallError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
