#!/usr/bin/env python3
"""Prepare the bundled ``.system`` provenance repair for the guarded wrapper.

A Codex app refresh rewrites ``.system`` in the unified skills root: the five ``SOURCE.md``
files disappear, the review-agent invocation parity line and the skill-creator quick_validate
compatibility overlay are gone, and every guarded install then fails closed until the five
skills are bound again. This tool reads the active root and writes only to the evidence
directory and plan path it is given; the guarded wrapper stays the only writer of the active
root. It runs from the module source path and is not part of the deployment closure.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

import yaml


IMPLEMENTATION_ROOT = Path(__file__).resolve().parent
if str(IMPLEMENTATION_ROOT) not in sys.path:
    sys.path.insert(0, str(IMPLEMENTATION_ROOT))

import generate_skill_catalog as GEN  # noqa: E402
import install_skill_guarded_payload as PAYLOAD  # noqa: E402
import system_skill_provenance_repair as REPAIR  # noqa: E402


DEFAULT_ACTIVE_ROOT = Path(r"D:\agents\skills-manager\skills")
DEFAULT_CATALOG = Path(r"D:\Codex\.codex\skill-catalog\catalog.json")
DEFAULT_PROVIDER = Path(r"D:\Codex\.codex\scripts\system_package_identity.py")
WRAPPER_COMMAND = r"D:\Codex\.codex\scripts\install-skill-guarded.cmd"
MENU_COMMAND = r"node D:\Codex\.codex\scripts\apply-skill-menu-i18n-overlay.cjs --system-only"
RUNBOOK = r"D:\Codex\.codex\docs\agent-guidance\skill-operations.md"
TOOL_COMMAND = f'python -X utf8 "{Path(__file__).resolve()}"'
SOURCE_GROUP_ID = "codex-bundled-system-skills"
MARKER_RELATIVE = ".system/.codex-system-skills.marker"
BOOTSTRAP_MODE = "atomic-six-skill-bootstrap"
DISPLAY_FILES = ("SKILL.md", "agents/openai.yaml")
PRESERVED_DIR = "official"
PRESERVED_MANIFEST = "official-display.json"
PRESERVED_ARTIFACT = "codex.system-official-display"
STATUS_EXIT = {"healthy": 0, "needs-bootstrap": 1, "needs-skill-creator-overlay": 1, "needs-review": 3}
CREATOR_TEST_ASSET = IMPLEMENTATION_ROOT.parent / "overlays" / "skill-creator-quick-validate" / "test_quick_validate.py"
# The compatibility payload reviewed on 2026-09-06, written with LF; each target must match the official text once.
CREATOR_PATCHES = (
    (
        "SKILL.md",
        "preserve supported optional fields such as existing `metadata` when appropriate.",
        "preserve supported optional fields such as existing `metadata`, `argument-hint` (string),"
        " and `disable-model-invocation` (boolean) when appropriate.",
    ),
    (
        "scripts/quick_validate.py",
        '    allowed_properties = {"name", "description", "license", "allowed-tools", "metadata"}\n',
        "    if any(not isinstance(key, str) for key in frontmatter):\n"
        '        return False, "Frontmatter keys must be strings"\n'
        "\n"
        "    allowed_properties = {\n"
        '        "name",\n'
        '        "description",\n'
        '        "license",\n'
        '        "allowed-tools",\n'
        '        "metadata",\n'
        '        "argument-hint",\n'
        '        "disable-model-invocation",\n'
        "    }\n",
    ),
    (
        "scripts/quick_validate.py",
        "        return False, \"Missing 'description' in frontmatter\"\n\n    name = frontmatter.get(\"name\", \"\")\n",
        "        return False, \"Missing 'description' in frontmatter\"\n"
        "\n"
        '    if "argument-hint" in frontmatter and not isinstance(frontmatter["argument-hint"], str):\n'
        '        return False, "argument-hint must be a string"\n'
        '    if "disable-model-invocation" in frontmatter and not isinstance(\n'
        '        frontmatter["disable-model-invocation"], bool\n'
        "    ):\n"
        '        return False, "disable-model-invocation must be a boolean"\n'
        "\n"
        '    name = frontmatter.get("name", "")\n',
    ),
)


class PrepareError(RuntimeError):
    """A precondition for preparing the repair does not hold; nothing was written."""


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _load_chinese_dominant(closure_script: Path) -> Callable[[str], bool]:
    """The closure script owns the rule for a Chinese menu entry; load it rather than restate it."""
    spec = importlib.util.spec_from_file_location("skill_resource_closure_rules", closure_script)
    if spec is None or spec.loader is None:
        raise PrepareError(f"无法加载 closure 脚本：{closure_script}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.chinese_dominant


def _display_values(files: dict[str, bytes]) -> list[str]:
    """The menu fields: SKILL.md frontmatter description and agents/openai.yaml interface text."""
    values: list[str] = []
    lines = files["SKILL.md"].decode("utf-8-sig").splitlines()
    if lines and lines[0].strip() == "---":
        end = next((i for i, line in enumerate(lines[1:], 1) if line.strip() in {"---", "..."}), None)
        if end is not None:
            metadata = yaml.safe_load("\n".join(lines[1:end])) or {}
            if isinstance(metadata, dict) and metadata.get("description") is not None:
                values.append(str(metadata["description"]))
    if "agents/openai.yaml" in files:
        data = yaml.safe_load(files["agents/openai.yaml"].decode("utf-8-sig")) or {}
        interface = data.get("interface", {}) if isinstance(data, dict) else {}
        if isinstance(interface, dict):
            values.extend(str(interface[field]) for field in ("short_description", "default_prompt") if field in interface)
    return values


def _display_language(files: dict[str, bytes], chinese_dominant: Callable[[str], bool]) -> str:
    flags = [chinese_dominant(value) for value in _display_values(files)]
    if flags and all(flags):
        return "translated"
    if not any(flags):
        return "official"
    return "mixed"


def _display_files(skill_root: Path) -> list[str]:
    return [relative for relative in DISPLAY_FILES if (skill_root / relative).is_file()]


def _live_display(skill_root: Path) -> dict[str, bytes]:
    return {relative: (skill_root / relative).read_bytes() for relative in _display_files(skill_root)}


def _git(active_root: Path, *args: str) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(active_root), *args],
        capture_output=True,
        check=False,
        creationflags=REPAIR.SUBPROCESS_CREATION_FLAGS,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        raise PrepareError(f"git {' '.join(args)} 失败，exit={completed.returncode}：{detail}")
    return completed.stdout


def _query_package_identity(interpreter: Path, provider: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [str(interpreter), "-X", "utf8", "-I", str(provider), "--package-name", "OpenAI.Codex"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        creationflags=REPAIR.SUBPROCESS_CREATION_FLAGS,
    )
    if completed.returncode != 0:
        raise PrepareError(
            f"Store package identity provider 失败，exit={completed.returncode}："
            f"{(completed.stderr or completed.stdout).strip()}"
        )
    try:
        identity = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise PrepareError("Store package identity provider 未返回合法 JSON") from exc
    REPAIR._validate_package_identity(identity)
    return identity


def _command_preserve_official(args: argparse.Namespace, closure_script: Path) -> dict[str, Any]:
    evidence: Path = args.evidence
    if (evidence / PRESERVED_DIR).exists() or (evidence / PRESERVED_MANIFEST).exists():
        raise PrepareError(f"证据目录里已有官方原文，拒绝覆盖：{evidence}")
    chinese_dominant = _load_chinese_dominant(closure_script)
    system_root = args.active_root / ".system"
    marker_sha256 = _sha256_file(system_root / ".codex-system-skills.marker")
    commit = None
    origin = "the live .system tree before the menu replay"
    if args.from_git is not None:
        commit = _git(args.active_root, "rev-parse", "--verify", f"{args.from_git}^{{commit}}").decode("ascii").strip()
        if _sha256_bytes(_git(args.active_root, "cat-file", "blob", f"{commit}:{MARKER_RELATIVE}")) != marker_sha256:
            raise PrepareError(f"提交 {commit} 的 .system marker 与当前不同：它不是这次刷新之后的快照")
        origin = f"skills root commit {commit}"
    captured: dict[str, dict[str, bytes]] = {}
    for name in REPAIR.EXPECTED_SKILLS:
        root = system_root / name
        if commit is None:
            files = _live_display(root)
        else:
            files = {
                relative: _git(args.active_root, "cat-file", "blob", f"{commit}:.system/{name}/{relative}")
                for relative in _display_files(root)
            }
        language = _display_language(files, chinese_dominant)
        if language != "official":
            raise PrepareError(
                f".system/{name} 的展示字段已不是官方原文（{language}）。菜单已被中文化时，"
                "改用 --from-git <刷新后、中文化前的 skills 根提交> 从快照取官方原文"
            )
        captured[name] = files
    manifest = {
        "artifact_type": PRESERVED_ARTIFACT,
        "schema_version": 1,
        "preserved_at": _utc_now(),
        "origin": origin,
        "git_commit": commit,
        "marker_sha256": marker_sha256,
        "files": {
            name: {relative: _sha256_bytes(data) for relative, data in files.items()}
            for name, files in captured.items()
        },
    }
    for name, files in captured.items():
        for relative, data in files.items():
            target = evidence / PRESERVED_DIR / name / Path(*relative.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    (evidence / PRESERVED_MANIFEST).write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return {"evidence": str(evidence), "preserved": {name: sorted(files) for name, files in captured.items()}}


def _load_preserved(evidence: Path, system_root: Path) -> tuple[dict[str, dict[str, bytes]], str]:
    try:
        manifest = json.loads((evidence / PRESERVED_MANIFEST).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PrepareError(f"读不到官方原文保存清单：{evidence / PRESERVED_MANIFEST}（{exc}）") from exc
    if manifest.get("artifact_type") != PRESERVED_ARTIFACT or manifest.get("schema_version") != 1:
        raise PrepareError("官方原文保存清单的 artifact_type 或 schema_version 不符")
    preserved: dict[str, dict[str, bytes]] = {}
    for name in REPAIR.EXPECTED_SKILLS:
        recorded = manifest.get("files", {}).get(name)
        if not isinstance(recorded, dict) or "SKILL.md" not in recorded:
            raise PrepareError(f"官方原文保存清单缺少 .system/{name}")
        preserved[name] = {}
        for relative, digest in recorded.items():
            data = (evidence / PRESERVED_DIR / name / Path(*relative.split("/"))).read_bytes()
            if _sha256_bytes(data) != digest:
                raise PrepareError(f"保存的官方原文与清单 SHA-256 不一致：.system/{name}/{relative}")
            preserved[name][relative] = data
    if manifest.get("marker_sha256") != _sha256_file(system_root / ".codex-system-skills.marker"):
        raise PrepareError("保存官方原文之后 .system marker 变了，Codex 可能又刷新过：重新 preserve-official")
    source = (
        f"Official display bytes preserved by prepare_system_provenance_repair.py preserve-official "
        f"at {manifest['preserved_at']} from {manifest['origin']}"
    )
    return preserved, source


def _bootstrap_skill(root: Path, name: str, preserved: dict[str, bytes]) -> dict[str, Any]:
    if (root / "SOURCE.md").exists():
        raise PrepareError(
            f".system/{name} 已有 SOURCE.md：bootstrap 计划只用于官方刷新后五个 SOURCE.md 都缺失的状态，先跑 status"
        )
    if sorted(preserved) != _display_files(root):
        raise PrepareError(f".system/{name} 现有的展示文件与保存的官方原文不是同一组：{_display_files(root)}")
    overrides = {relative: data for relative, data in preserved.items() if data != (root / relative).read_bytes()}
    official = REPAIR._tree_integrity(root, overrides=overrides)
    effective = REPAIR.system_skill_integrity(root)
    critical: dict[str, str] = {}
    base_overlay: dict[str, Any] = {"kind": "none"}
    if name == "review-agent":
        skill = root / "SKILL.md"
        critical = {"agents/openai.yaml": _sha256_file(root / "agents" / "openai.yaml")}
        effective = REPAIR._tree_integrity(
            root, overrides={"SKILL.md": REPAIR._review_overlay_bytes(skill, skill.read_bytes())}
        )
        base_overlay = dict(REPAIR.REVIEW_PARITY_OVERLAY)
    overlay = base_overlay
    if overrides:
        overlay = {
            "kind": REPAIR.DISPLAY_OVERLAY_KIND,
            "baseline_files": {relative: data.decode("utf-8") for relative, data in preserved.items()},
            "base_overlay": base_overlay,
        }
    return {
        "name": name,
        "source_before_sha256": None,
        "official_integrity": official,
        "effective_integrity": effective,
        "critical_files": critical,
        "overlay": overlay,
    }


def build_bootstrap_plan(
    *,
    active_root: Path,
    ledger: Path,
    catalog: Path,
    provider: Path,
    interpreter: Path,
    observations: int,
    interval_seconds: int,
    evidence: Path,
) -> dict[str, Any]:
    """The bootstrap plan; a menu changed since the preserved official text becomes a display-only overlay."""
    system_root = active_root / ".system"
    preserved, baseline_source = _load_preserved(evidence, system_root)
    skills = [_bootstrap_skill(system_root / name, name, preserved[name]) for name in REPAIR.EXPECTED_SKILLS]
    plan: dict[str, Any] = {
        "artifact_type": "codex.system-skill-provenance-repair",
        "schema_version": 1,
        "mode": BOOTSTRAP_MODE,
    }
    if any(spec["overlay"]["kind"] == REPAIR.DISPLAY_OVERLAY_KIND for spec in skills):
        plan["official_baseline_source"] = baseline_source
    plan.update(
        {
            "source_group_id": SOURCE_GROUP_ID,
            "package_identity_provider_sha256": _sha256_file(provider),
            "package_identity": _query_package_identity(interpreter, provider),
            "marker": {
                "relative_path": MARKER_RELATIVE,
                "sha256": _sha256_file(system_root / ".codex-system-skills.marker"),
            },
            "ledger_before_sha256": _sha256_file(ledger),
            "catalog_before_sha256": _sha256_file(catalog),
            "stability_check": {"observations": observations, "interval_seconds": interval_seconds},
            "skills": skills,
        }
    )
    return plan


def _command_plan(args: argparse.Namespace, ledger: Path) -> dict[str, Any]:
    if args.out.exists():
        raise PrepareError(f"计划文件已存在，拒绝覆盖：{args.out}")
    plan = build_bootstrap_plan(
        active_root=args.active_root,
        ledger=ledger,
        catalog=args.catalog,
        provider=args.system_package_provider,
        interpreter=args.python,
        observations=args.stability_observations,
        interval_seconds=args.stability_interval,
        evidence=args.evidence,
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    display = [spec["name"] for spec in plan["skills"] if spec["overlay"]["kind"] == REPAIR.DISPLAY_OVERLAY_KIND]
    return {"plan": str(args.out), "mode": plan["mode"], "display_only": display}


def _system_findings(interpreter: Path, closure_script: Path, active_root: Path) -> list[dict[str, Any]]:
    """Strict closure findings on the five .system targets: the ones the install gate always blocks on."""
    completed = subprocess.run(
        [str(interpreter), "-X", "utf8", "-I", str(closure_script), "--root", str(active_root), "--strict", "--format", "json"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        creationflags=REPAIR.SUBPROCESS_CREATION_FLAGS,
    )
    payload = GEN.parse_closure_output(completed.stdout, completed.returncode, label="strict closure")
    targets = REPAIR.system_closure_targets()
    return [finding for finding in payload["findings"] if GEN.finding_hits_targets(finding, targets)]


def _system_provenance(ledger: Path) -> dict[str, Any] | None:
    data = json.loads(ledger.read_text(encoding="utf-8"))
    entries = [
        entry for entry in data.get("sources", []) if isinstance(entry, dict) and entry.get("id") == SOURCE_GROUP_ID
    ]
    if len(entries) != 1:
        raise PrepareError(f"账本里的 {SOURCE_GROUP_ID} source group 不唯一")
    provenance = entries[0].get("system_provenance")
    return provenance if isinstance(provenance, dict) else None


def _binding_drift(system_root: Path, provenance: dict[str, Any] | None) -> list[str]:
    """What the live .system tree no longer shares with the ledger binding."""
    if provenance is None:
        return ["账本的 system source group 没有 system_provenance"]
    drift: list[str] = []
    if (provenance.get("marker") or {}).get("sha256") != _sha256_file(system_root / ".codex-system-skills.marker"):
        drift.append(".system marker 与账本不一致：Codex 刷新过 .system")
    records = {item.get("name"): item for item in provenance.get("skills", []) if isinstance(item, dict)}
    for name in REPAIR.EXPECTED_SKILLS:
        record, root = records.get(name), system_root / name
        if record is None:
            drift.append(f".system/{name} 在账本里没有记录")
            continue
        if REPAIR.system_skill_integrity(root) != record.get("effective_integrity"):
            drift.append(f".system/{name} 的文件树与账本 effective_integrity 不一致")
        if _sha256_file(root / "SOURCE.md") != record.get("source_md_sha256"):
            drift.append(f".system/{name}/SOURCE.md 与账本 source_md_sha256 不一致")
    return drift


def _binds_creator_overlay(overlay: Any) -> bool:
    """Whether a skill-creator record holds the compatibility overlay; a later display reconcile wraps it in base_overlay."""
    while isinstance(overlay, dict):
        if overlay.get("kind") == REPAIR.SKILL_CREATOR_OVERLAY_KIND:
            return True
        overlay = overlay.get("base_overlay")
    return False


def _command_status(args: argparse.Namespace, ledger: Path, closure_script: Path) -> dict[str, Any]:
    system_root = args.active_root / ".system"
    roots = {name: system_root / name for name in REPAIR.EXPECTED_SKILLS}
    missing_source = [name for name, root in roots.items() if not (root / "SOURCE.md").is_file()]
    findings = _system_findings(args.python, closure_script, args.active_root)
    evidence = rf"D:\agents\run-evidence\system-provenance-repair-{dt.datetime.now():%Y%m%d-%H%M}"
    plan = rf"{evidence}\plan.json"
    if len(missing_source) == len(roots):
        chinese_dominant = _load_chinese_dominant(closure_script)
        display = {name: _display_language(_live_display(root), chinese_dominant) for name, root in roots.items()}
        if all(language == "official" for language in display.values()):
            steps = [
                f"{TOOL_COMMAND} preserve-official --evidence {evidence}",
                f"{MENU_COMMAND} --dry-run，确认只改 .system 后换成 --apply",
            ]
        else:
            steps = [
                f"{TOOL_COMMAND} preserve-official --from-git <刷新后、中文化前的 skills 根提交> --evidence {evidence}"
            ]
        steps += [
            f"{TOOL_COMMAND} plan --evidence {evidence} --out {plan}",
            f"{WRAPPER_COMMAND} --system-provenance-repair-plan {plan} --dry-run；通过后去掉 --dry-run 实际修复（需用户授权）",
            f"{TOOL_COMMAND} status",
        ]
        return {
            "state": "needs-bootstrap",
            "reasons": ["五个 .system skill 都没有 SOURCE.md：Codex 刷新过 .system"],
            "display": display,
            "system_finding_count": len(findings),
            "next": steps,
        }
    provenance = _system_provenance(ledger)
    if missing_source:
        reasons = ["只有部分 .system skill 缺 SOURCE.md：" + ", ".join(missing_source)]
    else:
        reasons = _binding_drift(system_root, provenance)
    reasons += [f"strict closure finding：{item['kind']} {item['skill']} {item['reference']}" for item in findings]
    if reasons:
        return {
            "state": "needs-review",
            "reasons": reasons,
            "next": [f"按 {RUNBOOK} 的 .system 来源修复步骤逐条核对，再重跑 {TOOL_COMMAND} status"],
        }
    creator = next(item for item in provenance["skills"] if item.get("name") == "skill-creator")
    if not _binds_creator_overlay(creator.get("overlay")):
        return {
            "state": "needs-skill-creator-overlay",
            "reasons": ["skill-creator 的 quick_validate 兼容 overlay 还没重放"],
            "next": [
                f"{TOOL_COMMAND} skill-creator-overlay --evidence {evidence}",
                "按它输出的 wrapper 命令先 --dry-run，通过后再更新（需用户授权）",
                f"{TOOL_COMMAND} status",
            ],
        }
    return {"state": "healthy", "reasons": [], "next": []}


def _newline(data: bytes) -> str:
    if b"\r\n" in data and data.count(b"\n") != data.count(b"\r\n"):
        raise PrepareError("文件混用 CRLF 和 LF，补丁目标无法逐字匹配")
    return "\r\n" if b"\r\n" in data else "\n"


def _file_hashes(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): _sha256_file(path)
        for path in root.rglob("*")
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc"
    }


def _build_creator_candidate(live: Path, candidate: Path) -> None:
    """Copy the live skill-creator and replay the reviewed compatibility payload with its own line endings."""
    shutil.copytree(live, candidate, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for relative, old, new in CREATOR_PATCHES:
        path = candidate / Path(*relative.split("/"))
        data = path.read_bytes()
        newline = _newline(data)
        text = data.decode("utf-8")
        target = old.replace("\n", newline)
        if text.count(target) != 1:
            raise PrepareError(f"skill-creator/{relative} 里补丁目标出现 {text.count(target)} 次（应为 1 次）：官方文本变了，先重审补丁")
        path.write_bytes(text.replace(target, new.replace("\n", newline)).encode("utf-8"))
    validator_newline = _newline((candidate / "scripts" / "quick_validate.py").read_bytes())
    test_text = CREATOR_TEST_ASSET.read_bytes().decode("utf-8").replace("\r\n", "\n")
    (candidate / "scripts" / "test_quick_validate.py").write_bytes(
        test_text.replace("\n", validator_newline).encode("utf-8")
    )
    before, after = _file_hashes(live), _file_hashes(candidate)
    changed = sorted(key for key in set(before) | set(after) if before.get(key) != after.get(key))
    if changed != sorted(REPAIR.SKILL_CREATOR_CRITICAL_FILES):
        raise PrepareError(f"候选改动的文件不是兼容 overlay 的三个关键文件：{changed}")


def _command_skill_creator_overlay(args: argparse.Namespace, ledger: Path) -> dict[str, Any]:
    work: Path = args.evidence / "skill-creator-overlay"
    if work.exists():
        raise PrepareError(f"证据目录里已有 skill-creator-overlay，拒绝覆盖：{work}")
    system_root = args.active_root / ".system"
    provenance = _system_provenance(ledger)
    drift = _binding_drift(system_root, provenance)
    if drift:
        raise PrepareError("live .system 与账本不一致，先按 status 修复：" + "；".join(drift))
    record = next(item for item in provenance["skills"] if item.get("name") == "skill-creator")
    if _binds_creator_overlay(record.get("overlay")):
        raise PrepareError("账本里 skill-creator 已绑定兼容 overlay，不需要重放")
    live = system_root / "skill-creator"
    if (live / "scripts" / "test_quick_validate.py").exists():
        raise PrepareError("live skill-creator 已有 scripts/test_quick_validate.py，官方包不带这个文件：先核对它的来历")
    candidate = work / "skill-creator"
    _build_creator_candidate(live, candidate)
    overlay = {
        "schema_version": 1,
        "kind": REPAIR.SKILL_CREATOR_OVERLAY_KIND,
        "skill": REPAIR.SKILL_CREATOR_OVERLAY_SKILL,
        "package_identity_provider_sha256": _sha256_file(args.system_package_provider),
        "official_integrity": record["official_integrity"],
        "effective_integrity": REPAIR.system_skill_integrity(candidate),
        "critical_files": {
            relative: _sha256_file(candidate / Path(*relative.split("/")))
            for relative in REPAIR.SKILL_CREATOR_CRITICAL_FILES
        },
        "contract": REPAIR.SKILL_CREATOR_OVERLAY_CONTRACT,
    }
    REPAIR.validate_skill_creator_compatibility_overlay(overlay)
    manifest = {
        "decision": "update",
        "target_scope": "system",
        "source_status": "source-pass",
        "writing_for_agents": {"status": "no-change"},
        "local_overlay": {
            "status": "replayed",
            "summary": (
                "Replayed the reviewed quick_validate compatibility payload (argument-hint string, "
                "disable-model-invocation boolean, test_quick_validate.py); kept the current menu text and provenance."
            ),
        },
        "skills": ["skill-creator"],
        "candidate_integrity": PAYLOAD.candidate_integrity_payload(candidate),
        "source": {
            "id": SOURCE_GROUP_ID,
            "ref": "unversioned-codex-bundled-system",
            "upstream_path": ".system/skill-creator",
        },
        "system_provenance_overlay": overlay,
    }
    manifest_path = work / "decision-manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    command = (
        f'{WRAPPER_COMMAND} --candidate "{candidate}" --name skill-creator '
        f'--decision-manifest "{manifest_path}" --update'
    )
    return {
        "candidate": str(candidate),
        "decision_manifest": str(manifest_path),
        "next": [f"{command} --dry-run", f"{command}（需用户授权）", f"{TOOL_COMMAND} status"],
    }


def _parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--active-root", type=Path, default=DEFAULT_ACTIVE_ROOT)
    common.add_argument("--ledger", type=Path, help="默认 <active-root>/.downloaded-skills-source-state.json")
    common.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    common.add_argument("--system-package-provider", type=Path, default=DEFAULT_PROVIDER)
    common.add_argument(
        "--closure-script",
        type=Path,
        help="默认 <active-root>/skill-install-guard/scripts/skill_resource_closure.py",
    )
    common.add_argument("--python", type=Path, default=Path(sys.executable))

    parser = argparse.ArgumentParser(
        prog="prepare_system_provenance_repair.py",
        description="为 install-skill-guarded.cmd 准备 .system 来源修复的输入；只读 active root。",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser(
        "status", parents=[common], help="只读：判断 .system 处于哪个修复阶段并给出下一步命令（healthy 时退出 0）"
    )
    preserve = commands.add_parser(
        "preserve-official", parents=[common], help="菜单重放前，把五个 skill 的官方展示原文存进证据目录"
    )
    preserve.add_argument("--evidence", type=Path, required=True)
    preserve.add_argument(
        "--from-git", metavar="REF", help="菜单已中文化时：从刷新后、中文化前的 skills 根提交取官方原文"
    )
    plan = commands.add_parser("plan", parents=[common], help="写出 --system-provenance-repair-plan 用的 bootstrap 计划")
    plan.add_argument("--out", type=Path, required=True)
    plan.add_argument("--evidence", type=Path, required=True, help="preserve-official 写过官方原文的证据目录")
    plan.add_argument("--stability-observations", type=int, default=2)
    plan.add_argument("--stability-interval", type=int, default=10, help="live active root 不得低于 10 秒")
    overlay = commands.add_parser(
        "skill-creator-overlay",
        parents=[common],
        help="bootstrap 之后：写出重放 quick_validate 兼容 overlay 的候选和 decision manifest",
    )
    overlay.add_argument("--evidence", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    ledger = args.ledger or args.active_root / ".downloaded-skills-source-state.json"
    closure_script = args.closure_script or args.active_root / "skill-install-guard" / "scripts" / "skill_resource_closure.py"
    try:
        if args.command == "status":
            result = _command_status(args, ledger, closure_script)
        elif args.command == "preserve-official":
            result = _command_preserve_official(args, closure_script)
        elif args.command == "skill-creator-overlay":
            result = _command_skill_creator_overlay(args, ledger)
        else:
            result = _command_plan(args, ledger)
    except (
        PrepareError,
        REPAIR.SystemProvenanceRepairError,
        GEN.CatalogError,
        OSError,
        ValueError,
        yaml.YAMLError,
    ) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return STATUS_EXIT[result["state"]] if args.command == "status" else 0


if __name__ == "__main__":
    raise SystemExit(main())
