"""Declared bundled skills: specs, staged validation and source-record proofs.

Part of the guarded skill installer; ``install_skill_guarded.py`` is the entry point.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any, NamedTuple, Sequence
from urllib.parse import urlparse

import install_skill_guarded_base as _base
import install_skill_guarded_payload as _payload
import install_skill_guarded_source_record as _source_record
from install_skill_guarded_base import SAFE_SKILL_NAME, SHA256_HEX, InstallError
from install_skill_guarded_payload import CANDIDATE_EXCLUDED_DIRECTORIES


class BundledSkillProof(NamedTuple):
    """The bound identity and staged provenance of one bundled skill."""

    top_level_name: str
    path: str
    name: str
    skill_md_sha256: str | None = None
    source_md_sha256: str | None = None

    @property
    def ledger_key(self) -> str:
        return f"{self.top_level_name}/{self.path}"

    def with_staged_integrity(
        self,
        *,
        skill_md_sha256: str,
        source_md_sha256: str,
    ) -> "BundledSkillProof":
        return self._replace(
            skill_md_sha256=skill_md_sha256,
            source_md_sha256=source_md_sha256,
        )

    def require_staged_integrity(self) -> tuple[str, str]:
        if (
            not isinstance(self.skill_md_sha256, str)
            or not isinstance(self.source_md_sha256, str)
            or not SHA256_HEX.fullmatch(self.skill_md_sha256)
            or not SHA256_HEX.fullmatch(self.source_md_sha256)
        ):
            raise InstallError("bundled skill 缺少暂存期 provenance 哈希")
        return self.skill_md_sha256, self.source_md_sha256

    def ledger_projection(self) -> dict[str, str]:
        return {"path": self.ledger_key, "name": self.name}

    def staged_projection(self) -> dict[str, str]:
        skill_md_sha256, source_md_sha256 = self.require_staged_integrity()
        return {
            "path": self.path,
            "name": self.name,
            "ledger_key": self.ledger_key,
            "skill_md_sha256": skill_md_sha256,
            "source_md_sha256": source_md_sha256,
        }

    @classmethod
    def from_staged_projection(cls, value: Any) -> "BundledSkillProof":
        expected_fields = {
            "path",
            "name",
            "ledger_key",
            "skill_md_sha256",
            "source_md_sha256",
        }
        if not isinstance(value, dict) or set(value) != expected_fields:
            raise InstallError("bundled skill 暂存期证明对象不合法")
        path = value.get("path")
        name = value.get("name")
        ledger_key = value.get("ledger_key")
        if (
            not isinstance(path, str)
            or not isinstance(name, str)
            or not isinstance(ledger_key, str)
            or not ledger_key.endswith(f"/{path}")
        ):
            raise InstallError("bundled skill 暂存期证明对象不合法")
        top_level_name = ledger_key[: -(len(path) + 1)]
        if (
            not top_level_name
            or not SAFE_SKILL_NAME.fullmatch(top_level_name)
            or not SAFE_SKILL_NAME.fullmatch(name)
            or not path
            or "\\" in path
            or any(not part or part in {".", ".."} for part in path.split("/"))
        ):
            raise InstallError("bundled skill 暂存期证明对象不合法")
        proof = cls(
            top_level_name=top_level_name,
            path=path,
            name=name,
            skill_md_sha256=value.get("skill_md_sha256"),
            source_md_sha256=value.get("source_md_sha256"),
        )
        proof.require_staged_integrity()
        return proof


def bundled_skill_specs(
    *,
    args: argparse.Namespace,
    decision: dict[str, Any],
    names: list[str],
) -> tuple[BundledSkillProof, ...]:
    raw = decision.get("bundled_skills")
    if raw is None:
        return ()
    if not args.candidate:
        raise InstallError("bundled_skills 只允许绑定本地 --candidate 安装载荷")
    if len(names) != 1:
        raise InstallError("bundled_skills 只支持单个顶层安装目标")
    if not isinstance(raw, list) or not raw:
        raise InstallError("bundled_skills 必须是非空数组")

    result: list[BundledSkillProof] = []
    seen_paths: set[str] = set()
    seen_names: set[str] = set()
    top_level_name_keys = {name.casefold() for name in names}
    for index, item in enumerate(raw):
        if not isinstance(item, dict) or set(item) != {"path", "name"}:
            raise InstallError(
                f"bundled_skills[{index}] 字段必须精确为 path、name"
            )
        relative_path = item.get("path")
        skill_name = item.get("name")
        if not isinstance(relative_path, str) or not relative_path.strip():
            raise InstallError(f"bundled_skills[{index}].path 必须是非空字符串")
        if relative_path != relative_path.strip() or any(
            not character.isprintable() for character in relative_path
        ):
            raise InstallError(
                f"bundled_skills[{index}].path 必须是规范的可打印相对路径"
            )
        parts = relative_path.split("/")
        if (
            "\\" in relative_path
            or "`" in relative_path
            or relative_path.startswith("/")
            or re.match(r"^[A-Za-z]:", relative_path)
            or any(
                not part
                or part in {".", ".."}
                or part.casefold() in CANDIDATE_EXCLUDED_DIRECTORIES
                for part in parts
            )
        ):
            raise InstallError(
                f"bundled_skills[{index}].path 必须是 candidate 内安全的 POSIX 相对路径"
            )
        if not isinstance(skill_name, str) or not SAFE_SKILL_NAME.fullmatch(skill_name):
            raise InstallError(f"bundled_skills[{index}].name 不是合法 skill name")
        path_key = relative_path.casefold()
        name_key = skill_name.casefold()
        if path_key in seen_paths:
            raise InstallError(f"bundled_skills[{index}].path 重复：{relative_path}")
        if name_key in seen_names or name_key in top_level_name_keys:
            raise InstallError(f"bundled_skills[{index}].name 重复：{skill_name}")
        seen_paths.add(path_key)
        seen_names.add(name_key)
        result.append(
            BundledSkillProof(
                top_level_name=names[0],
                path=relative_path,
                name=skill_name,
            )
        )
    return tuple(result)


def validate_staged_bundled_skills(
    *,
    stage_root: Path,
    active_root: Path,
    top_level_name: str,
    bundled_proofs: Sequence[BundledSkillProof],
    args: argparse.Namespace,
) -> tuple[BundledSkillProof, ...]:
    verified: list[BundledSkillProof] = []
    for proof in bundled_proofs:
        if proof.top_level_name != top_level_name:
            raise InstallError("bundled skill 证明对象的顶层名称不一致")
        target = stage_root / top_level_name / Path(*proof.path.split("/"))
        if not target.is_dir() or _base.is_reparse(target):
            raise InstallError(f"bundled skill 路径不是安全目录：{target}")
        _base.ensure_tree_no_reparse(target, label=f"bundled skill {proof.name}")
        skill_md = target / "SKILL.md"
        if not skill_md.is_file() or _base.is_reparse(skill_md):
            raise InstallError(f"bundled skill 缺少安全的 SKILL.md：{skill_md}")
        actual_name = _payload.read_skill_name(skill_md)
        if actual_name != proof.name:
            raise InstallError(
                "bundled skill name 与 manifest 不一致："
                f"{actual_name!r} != {proof.name!r}"
            )
        _payload.validate_openai_display_name(target, label=f"bundled skill {proof.name}")
        _payload.validate_chinese_display_metadata(target, label=f"bundled skill {proof.name}")
        source_md = target / "SOURCE.md"
        if not source_md.is_file() or _base.is_reparse(source_md):
            raise InstallError(f"bundled skill 缺少安全的 SOURCE.md：{source_md}")
        source_label = f"bundled skill {proof.name} SOURCE.md"
        _source_record.reject_source_control_characters(_source_record.read_source_text(source_md), label=source_label)
        # No wrapper record is appended here, so this record stays current.
        _source_record.validate_source_record_paths(
            _source_record.current_source_record(source_md),
            label=source_label,
            local_path=active_root / top_level_name / Path(*proof.path.split("/")),
            active_root=active_root,
        )
        recorded_names = _source_record.source_record_values(source_md, "Skill")
        if not recorded_names or any(value != proof.name for value in recorded_names):
            raise InstallError(
                f"bundled skill SOURCE.md identity 不一致：{recorded_names!r}"
            )
        source_repo = _source_record.source_record_unique_value(
            source_md,
            ("Source repository",),
            label=f"bundled skill {proof.name}",
        )
        parsed_repo = urlparse(source_repo)
        if (
            parsed_repo.scheme != "https"
            or not parsed_repo.hostname
            or not parsed_repo.path.strip("/")
            or parsed_repo.username
            or parsed_repo.password
            or parsed_repo.query
            or parsed_repo.fragment
        ):
            raise InstallError(
                f"bundled skill {proof.name} SOURCE.md 必须记录不含凭据的 HTTPS source repository"
            )
        _source_record.source_record_unique_value(
            source_md,
            ("Upstream path",),
            label=f"bundled skill {proof.name}",
        )
        _source_record.source_record_unique_value(
            source_md,
            ("Ref",),
            label=f"bundled skill {proof.name}",
        )
        _source_record.source_record_unique_value(
            source_md,
            ("Commit or revision", "Commit"),
            label=f"bundled skill {proof.name}",
        )
        _source_record.validate_durable_source_record(
            source_md,
            durable_fields={},
            transient_paths=[Path(args.candidate), Path(args.decision_manifest)],
        )
        verified.append(
            proof.with_staged_integrity(
                skill_md_sha256=_base.sha256_file(skill_md),
                source_md_sha256=_base.sha256_file(source_md),
            )
        )
    return tuple(verified)
