from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import os
import socket
import subprocess
import tempfile
import unittest
import urllib.request
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "modules" / "skill-supply-chain" / "implementation" / "generate_skill_catalog.py"
SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
SUBPROCESS_TEXT_ENCODING = "oem" if os.name == "nt" else "utf-8"

try:
    _spec = importlib.util.spec_from_file_location("generate_skill_catalog", SCRIPT)
    if _spec is None or _spec.loader is None:
        raise ImportError(f"无法加载 {SCRIPT}")
    catalog_module = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(catalog_module)
    IMPORT_ERROR = None
except (FileNotFoundError, ImportError) as exc:  # pragma: no cover - initial RED run
    catalog_module = None
    IMPORT_ERROR = exc


def _write_skill(
    root: Path,
    relative_dir: str,
    *,
    name: str,
    description: str,
    disable_model_invocation: bool = False,
    source: str | None = None,
) -> Path:
    skill_dir = root / relative_dir
    skill_dir.mkdir(parents=True, exist_ok=True)
    flag = "disable-model-invocation: true\n" if disable_model_invocation else ""
    (skill_dir / "SKILL.md").write_text(
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        f"{flag}"
        "---\n\n# Skill\n\nUse the skill.\n",
        encoding="utf-8",
    )
    if source is not None:
        (skill_dir / "SOURCE.md").write_text(source, encoding="utf-8")
    return skill_dir


def _write_openai_policy(skill_dir: Path, *, allow_implicit_invocation: bool) -> None:
    agents = skill_dir / "agents"
    agents.mkdir(parents=True, exist_ok=True)
    (agents / "openai.yaml").write_text(
        "interface:\n"
        '  display_name: "测试名称"\n'
        '  short_description: "中文展示 overlay"\n'
        "policy:\n"
        f"  allow_implicit_invocation: {str(allow_implicit_invocation).lower()}\n",
        encoding="utf-8",
    )


def _closure_result(active_root: Path, active_skill_count: int) -> dict:
    return {
        "summary": {
            "root": str(active_root),
            "active_skill_count": active_skill_count,
            "finding_count": 0,
            "missing_resource_count": 0,
            "missing_source_count": 0,
            "missing_ledger_count": 0,
            "duplicate_ledger_count": 0,
            "stale_ledger_count": 0,
        },
        "findings": [],
    }


def _create_directory_alias(alias: Path, target: Path) -> None:
    alias.parent.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        completed = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(alias), str(target)],
            capture_output=True,
            text=True,
            encoding=SUBPROCESS_TEXT_ENCODING,
            errors="replace",
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
        if completed.returncode != 0:
            raise unittest.SkipTest(
                f"当前环境无法创建 junction fixture：{completed.stderr or completed.stdout}"
            )
        return
    try:
        alias.symlink_to(target, target_is_directory=True)
    except OSError as exc:
        raise unittest.SkipTest(f"当前环境无法创建 symlink fixture：{exc}") from exc


if IMPORT_ERROR is not None:

    class SkillCatalogTests(unittest.TestCase):
        def test_catalog_module_is_available(self) -> None:
            self.fail(f"catalog 实现尚未提供：{IMPORT_ERROR}")

else:

    class SkillCatalogTests(unittest.TestCase):
        def test_source_uses_only_final_record_and_marks_current_conflicts(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                source = (
                    "# Historical provenance\n"
                    "Skill: retired-alpha\n"
                    "Status: retired\n"
                    "Repository: https://example.invalid/retired\n"
                    "\n---\n\n"
                    "# Current provenance\n"
                    "Skill: ` alpha `\n"
                    "Status: retained-local\n"
                    "Status: retained-local\n"
                    "Repository: https://example.invalid/current\n"
                )
                skill_dir = _write_skill(
                    active,
                    "alpha",
                    name="alpha",
                    description="current source fixture",
                    source=source,
                )
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"sources": [{"skills": ["alpha"]}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                artifact = catalog["artifacts"][0]
                self.assertEqual(artifact["source"]["fields"]["skill"], "alpha")
                self.assertEqual(
                    artifact["source"]["fields"]["status"],
                    "retained-local",
                )
                self.assertEqual(
                    artifact["source"]["fields"]["repository"],
                    "https://example.invalid/current",
                )
                self.assertEqual(artifact["source"]["conflicts"], [])
                self.assertEqual(catalog["checks"]["ledger"]["status"], "pass")

                (skill_dir / "SOURCE.md").write_text(
                    source.replace(
                        "Status: retained-local\nStatus: retained-local",
                        "Status: retained-local\nStatus: pending-review",
                    ),
                    encoding="utf-8",
                )
                conflicted = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                conflict_artifact = conflicted["artifacts"][0]
                self.assertNotIn("status", conflict_artifact["source"]["fields"])
                self.assertIn(
                    "SOURCE.md 当前记录的 Status 存在冲突",
                    conflict_artifact["source"]["conflicts"][0],
                )
                self.assertEqual(conflicted["checks"]["ledger"]["status"], "conflict")

                (skill_dir / "SOURCE.md").write_text(
                    source.replace("Skill: ` alpha `", "Skill:\nSkill: ` alpha `"),
                    encoding="utf-8",
                )
                empty_field = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                empty_field_artifact = empty_field["artifacts"][0]
                self.assertNotIn("skill", empty_field_artifact["source"]["fields"])
                self.assertIn(
                    "SOURCE.md 当前记录的 Skill 存在冲突",
                    empty_field_artifact["source"]["conflicts"][0],
                )
                self.assertEqual(
                    empty_field["checks"]["ledger"]["status"], "conflict"
                )

                (skill_dir / "SOURCE.md").write_text(
                    source.rstrip() + "\n---\n",
                    encoding="utf-8",
                )
                empty_final_record = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                final_record_artifact = empty_final_record["artifacts"][0]
                self.assertEqual(final_record_artifact["source"]["fields"], {})
                self.assertIn(
                    "SOURCE.md 当前记录的 末尾分段 存在冲突",
                    final_record_artifact["source"]["conflicts"][0],
                )
                self.assertEqual(
                    empty_final_record["checks"]["ledger"]["status"], "conflict"
                )

        def test_nested_active_skill_uses_relative_directory_for_ledger_coverage(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                source = "# Source Provenance\nSkill: parent\nStatus: source-pass\n"
                _write_skill(
                    active,
                    "parent",
                    name="parent",
                    description="parent skill",
                    source=source,
                )
                nested_key = "parent/vendor/runtime/trace"
                _write_skill(
                    active,
                    nested_key,
                    name="runtime-trace",
                    description="nested runtime skill",
                    source=source.replace("parent", "runtime-trace"),
                )
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps(
                        {
                            "sources": [
                                {
                                    "id": "fixture-source",
                                    "skills": ["parent", nested_key],
                                }
                            ]
                        }
                    ),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 2),
                )

                artifacts = {
                    item["relative_path"]: item
                    for item in catalog["artifacts"]
                    if item["scope"] == "active"
                }
                self.assertEqual(
                    artifacts[f"{nested_key}/SKILL.md"]["ledger_coverage"],
                    "pass",
                )
                self.assertEqual(
                    artifacts[f"{nested_key}/SKILL.md"]["ledger"]["records"],
                    ["fixture-source"],
                )

        def test_internal_plugin_cache_alias_is_verified_without_duplicate_artifacts(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(
                    version,
                    "skills/cached",
                    name="cached",
                    description="cached",
                )
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                self.assertTrue(catalog["checks"]["scan_complete"])
                self.assertEqual(cache_root["scan_status"], "complete")
                self.assertEqual(cache_root["skipped_reparse"], [])
                self.assertEqual(len(cache_root["verified_reparse_aliases"]), 1)
                self.assertEqual(cache_root["verified_reparse_aliases"][0]["alias"], str(alias))
                self.assertEqual(cache_root["verified_reparse_aliases"][0]["target"], str(version.resolve()))
                self.assertEqual(
                    [item["name"] for item in catalog["artifacts"] if item["scope"] == "plugin-cache"],
                    ["cached"],
                )

        def test_external_plugin_cache_alias_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                external = base / "external"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(external, "skills/external", name="external", description="external")
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, external)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(cache_root["scan_status"], "partial")
                self.assertEqual(cache_root["skipped_reparse"], [str(alias)])
                self.assertEqual(cache_root["verified_reparse_aliases"], [])
                self.assertNotIn("external", [item["name"] for item in catalog["artifacts"]])

        def test_internal_alias_to_excluded_unvisited_target_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                excluded = cache / "tmp" / "1.0.0"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(excluded, "skills/hidden", name="hidden", description="hidden")
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, excluded)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(cache_root["skipped_reparse"], [str(alias)])
                self.assertEqual(cache_root["verified_reparse_aliases"], [])

        def test_chained_plugin_cache_aliases_keep_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(version, "skills/cached", name="cached", description="cached")
                current = cache / "package" / "current"
                latest = cache / "package" / "latest"
                _create_directory_alias(current, version)
                _create_directory_alias(latest, current)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(
                    {Path(path).name for path in cache_root["skipped_reparse"]},
                    {"current", "latest"},
                )
                self.assertEqual(cache_root["verified_reparse_aliases"], [])
                failures = {Path(item["path"]).name: item["reason"] for item in cache_root["reparse_failures"]}
                self.assertEqual(failures["current"], "unsupported-reparse-name")
                self.assertEqual(failures["latest"], "reparse-chain")

        def test_latest_alias_with_reparse_inside_target_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                nested_target = cache / "package" / "shared"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(version, "skills/cached", name="cached", description="cached")
                nested_target.mkdir(parents=True)
                _create_directory_alias(version / "nested" / "latest", nested_target)
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                self.assertFalse(catalog["checks"]["scan_complete"])
                failures = {item["path"]: item["reason"] for item in cache_root["reparse_failures"]}
                self.assertEqual(failures[str(alias)], "target-tree-contains-reparse")

        def test_alias_identity_change_during_validation_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                _write_skill(version, "skills/cached", name="cached", description="cached")
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                _, reparse_paths, visited = catalog_module._scan_skill_files(
                    cache,
                    scope="plugin-cache",
                )

                original_lstat = Path.lstat
                alias_lstat_count = 0

                def lstat_with_alias_change(path: Path):
                    nonlocal alias_lstat_count
                    result = original_lstat(path)
                    if Path(path) != alias:
                        return result
                    alias_lstat_count += 1
                    if alias_lstat_count == 1:
                        return result

                    class ChangedStat:
                        def __getattr__(self, name):
                            if name == "st_mtime_ns":
                                return result.st_mtime_ns + 1
                            return getattr(result, name)

                    return ChangedStat()

                with mock.patch.object(Path, "lstat", new=lstat_with_alias_change):
                    verified, unsafe, failures = catalog_module._verify_plugin_cache_aliases(
                        root=cache,
                        reparse_paths=reparse_paths,
                        visited_directories=visited,
                    )

                self.assertEqual(verified, [])
                self.assertEqual(unsafe, [str(alias)])
                self.assertEqual(failures[0]["reason"], "alias-changed-during-scan")

        def test_target_replacement_after_scan_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                _write_skill(version, "skills/cached", name="cached", description="cached")
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                _, reparse_paths, visited = catalog_module._scan_skill_files(
                    cache,
                    scope="plugin-cache",
                )

                old_version = cache / "package" / "old-1.2.3"
                version.rename(old_version)
                _write_skill(version, "skills/replacement", name="replacement", description="replacement")
                verified, unsafe, failures = catalog_module._verify_plugin_cache_aliases(
                    root=cache,
                    reparse_paths=reparse_paths,
                    visited_directories=visited,
                )

                self.assertEqual(verified, [])
                self.assertEqual(unsafe, [str(alias)])
                self.assertEqual(failures[0]["reason"], "target-changed-after-scan")

        def test_descendant_added_after_scan_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                _write_skill(version, "skills/cached", name="cached", description="cached")
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                _, reparse_paths, visited = catalog_module._scan_skill_files(
                    cache,
                    scope="plugin-cache",
                )

                _write_skill(version, "skills/new", name="new", description="new")
                verified, unsafe, failures = catalog_module._verify_plugin_cache_aliases(
                    root=cache,
                    reparse_paths=reparse_paths,
                    visited_directories=visited,
                )

                self.assertEqual(verified, [])
                self.assertEqual(unsafe, [str(alias)])
                self.assertEqual(failures[0]["reason"], "target-tree-changed-after-scan")

        def test_reparse_ancestor_in_direct_target_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                versions = cache / "versions"
                version = versions / "1.2.3"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(version, "skills/cached", name="cached", description="cached")
                bridge = cache / "bridge"
                _create_directory_alias(bridge, versions)
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, bridge / "1.2.3")
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                failures = {item["path"]: item["reason"] for item in cache_root["reparse_failures"]}
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(failures[str(alias)], "reparse-chain")

        def test_excluded_named_reparse_inside_target_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                external = base / "external"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(version, "skills/cached", name="cached", description="cached")
                external.mkdir()
                nested = version / "tmp"
                _create_directory_alias(nested, external)
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                failures = {item["path"]: item["reason"] for item in cache_root["reparse_failures"]}
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(failures[str(alias)], "target-tree-contains-reparse")
                self.assertEqual(failures[str(nested)], "unsupported-reparse-name")

        def test_reparse_below_excluded_directory_inside_target_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                external = base / "external"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(version, "skills/cached", name="cached", description="cached")
                external.mkdir()
                nested = version / "tmp" / "nested"
                _create_directory_alias(nested, external)
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                failures = {item["path"]: item["reason"] for item in cache_root["reparse_failures"]}
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(failures[str(alias)], "target-tree-not-scanned")
                self.assertNotIn(str(nested), failures)

        def test_latest_alias_to_parent_directory_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                package = cache / "package"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                _write_skill(package, "skills/cached", name="cached", description="cached")
                alias = package / "latest"
                _create_directory_alias(alias, package)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(cache_root["reparse_failures"][0]["reason"], "target-contains-alias")

        def test_reparse_file_is_not_silently_ignored(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                cache = Path(temp) / "cache"
                candidate = cache / "package" / "latest"
                candidate.parent.mkdir(parents=True)
                candidate.write_text("fixture", encoding="utf-8")
                original_is_reparse = catalog_module._is_reparse

                def fixture_is_reparse(path: Path) -> bool:
                    return Path(path) == candidate or original_is_reparse(path)

                with mock.patch.object(
                    catalog_module,
                    "_is_reparse",
                    side_effect=fixture_is_reparse,
                ):
                    found, reparse_paths, _ = catalog_module._scan_skill_files(
                        cache,
                        scope="plugin-cache",
                    )

                self.assertEqual(found, [])
                self.assertEqual(reparse_paths, [str(candidate)])

        def test_scan_error_fails_closed(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                cache = Path(temp) / "cache"
                cache.mkdir()

                def failing_walk(*_args, **kwargs):
                    kwargs["onerror"](PermissionError("blocked fixture"))
                    return iter(())

                with mock.patch.object(catalog_module.os, "walk", side_effect=failing_walk):
                    with self.assertRaisesRegex(catalog_module.CatalogError, "无法完整扫描"):
                        catalog_module._scan_skill_files(cache, scope="plugin-cache")

        def test_dangling_latest_alias_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                source = "# Source Provenance\nSkill: alpha\nStatus: retained-local\n"
                _write_skill(active, "alpha", name="alpha", description="active", source=source)
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, cache / "package" / "missing")
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                cache_root = next(item for item in catalog["roots"] if item["scope"] == "plugin-cache")
                self.assertFalse(catalog["checks"]["scan_complete"])
                self.assertEqual(cache_root["skipped_reparse"], [str(alias)])
                self.assertEqual(cache_root["verified_reparse_aliases"], [])

        def test_latest_alias_to_regular_file_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                _write_skill(version, "skills/cached", name="cached", description="cached")
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                regular_file = cache / "package" / "target.txt"
                regular_file.write_text("fixture", encoding="utf-8")
                _, reparse_paths, visited = catalog_module._scan_skill_files(
                    cache,
                    scope="plugin-cache",
                )

                with mock.patch.object(
                    catalog_module,
                    "_direct_reparse_target",
                    return_value=regular_file,
                ):
                    verified, unsafe, failures = catalog_module._verify_plugin_cache_aliases(
                        root=cache,
                        reparse_paths=reparse_paths,
                        visited_directories=visited,
                    )

                self.assertEqual(verified, [])
                self.assertEqual(unsafe, [str(alias)])
                self.assertEqual(failures[0]["reason"], "target-not-physical-directory")

        def test_raw_alias_target_change_during_validation_keeps_scan_partial(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                cache = base / "cache"
                version = cache / "package" / "1.2.3"
                _write_skill(version, "skills/cached", name="cached", description="cached")
                alias = cache / "package" / "latest"
                _create_directory_alias(alias, version)
                _, reparse_paths, visited = catalog_module._scan_skill_files(
                    cache,
                    scope="plugin-cache",
                )
                raw_target = os.readlink(alias)
                resolved_version = version.resolve()
                original_resolve = Path.resolve

                def stable_alias_resolve(path: Path, *args, **kwargs):
                    if Path(path) == alias:
                        return resolved_version
                    return original_resolve(path, *args, **kwargs)

                with mock.patch.object(Path, "resolve", new=stable_alias_resolve):
                    with mock.patch.object(
                        catalog_module.os,
                        "readlink",
                        side_effect=[raw_target, raw_target + ".changed"],
                    ):
                        verified, unsafe, failures = catalog_module._verify_plugin_cache_aliases(
                            root=cache,
                            reparse_paths=reparse_paths,
                            visited_directories=visited,
                        )

                self.assertEqual(verified, [])
                self.assertEqual(unsafe, [str(alias)])
                self.assertEqual(failures[0]["reason"], "alias-target-changed-during-scan")

        def test_separates_active_and_cache_and_keeps_duplicate_names_distinct(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                source = (
                    "# Source Provenance\n"
                    "Skill: `alpha`\n"
                    "Status: source-backed\n"
                    "Repository: https://example.invalid/source\n"
                    "Ref: main\n"
                )
                _write_skill(active, "alpha", name="alpha", description="model branch", source=source)
                _write_skill(
                    active,
                    ".system/system-skill",
                    name="system-skill",
                    description="manual branch",
                    disable_model_invocation=True,
                    source=source.replace("alpha", "system-skill"),
                )
                _write_skill(cache, "package/1.0/skills/alpha", name="alpha", description="cached branch")
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"sources": [{"skills": ["alpha", "system-skill"]}]}, ensure_ascii=False),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 2),
                    generated_at="2026-07-13T00:00:00Z",
                )

                artifacts = catalog["artifacts"]
                self.assertEqual(len(artifacts), 3)
                self.assertEqual(len({item["artifact_id"] for item in artifacts}), 3)
                self.assertEqual(
                    {item["scope"] for item in artifacts},
                    {"active", "system", "plugin-cache"},
                )
                cache_alpha = next(
                    item for item in artifacts if item["scope"] == "plugin-cache"
                )
                self.assertTrue(cache_alpha["read_only"])
                self.assertEqual(cache_alpha["runtime_verification"], "unverified")

        def test_system_source_accepts_dot_system_qualified_skill_name(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(
                    active,
                    ".system/imagegen",
                    name="imagegen",
                    description="system skill",
                    source=(
                        "# Source Provenance\n"
                        "Skill: `.system/imagegen`\n"
                        "Status: bundled-system\n"
                    ),
                )
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"sources": [{"skills": [".system/imagegen"]}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                artifact = catalog["artifacts"][0]
                self.assertEqual(artifact["scope"], "system")
                self.assertEqual(artifact["ledger_coverage"], "pass")
                self.assertEqual(artifact["source"]["conflicts"], [])
                self.assertEqual(catalog["checks"]["ledger"]["status"], "pass")

        def test_extracts_invocation_source_and_ledger_facts(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                source = "# Source Provenance\nSkill: `manual`\nStatus: retained-local\n"
                skill_dir = _write_skill(
                    active,
                    "manual",
                    name="manual",
                    description="human-only branch",
                    disable_model_invocation=True,
                    source=source,
                )
                _write_openai_policy(skill_dir, allow_implicit_invocation=False)
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"unresolved": [{"name": "manual"}]}), encoding="utf-8")

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                artifact = catalog["artifacts"][0]

                self.assertEqual(artifact["invocation"]["mode"], "user-invoked")
                self.assertFalse(artifact["invocation"]["allow_implicit_invocation"])
                self.assertEqual(artifact["conflicts"], [])
                self.assertTrue(artifact["invocation"]["description_present"])
                self.assertEqual(artifact["source"]["status"], "retained-local")
                self.assertEqual(artifact["ledger_coverage"], "pass")
                self.assertEqual(artifact["ledger"]["states"], ["unresolved"])
                self.assertEqual(artifact["runtime_verification"], "unverified")

        def test_rejects_split_invocation_policy_between_skill_and_openai_yaml(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                skill_dir = _write_skill(
                    active,
                    "split",
                    name="split",
                    description="model branch",
                    source="# Source Provenance\nSkill: split\nStatus: retained-local\n",
                )
                _write_openai_policy(skill_dir, allow_implicit_invocation=False)
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "split"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )

                self.assertEqual(catalog["checks"]["ledger"]["status"], "conflict")
                self.assertIn("语义冲突", catalog["artifacts"][0]["conflicts"][0])

        def test_build_is_read_only_and_write_catalog_creates_valid_json(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")
                output = base / "reports" / "catalog.json"

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                self.assertFalse(output.exists())

                catalog_module.write_catalog(catalog, output)
                self.assertTrue(output.exists())
                written = json.loads(output.read_text(encoding="utf-8"))
                self.assertEqual(written["schema_version"], 1)
                self.assertEqual(len(written["artifacts"]), 1)

        def test_missing_root_fails_closed(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "missing-active"
                cache = base / "cache"
                cache.mkdir()
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")

                with self.assertRaises(catalog_module.CatalogError):
                    catalog_module.build_catalog(
                        active_root=active,
                        plugin_cache_root=cache,
                        ledger_path=ledger,
                        resource_closure=None,
                    )

        def test_remote_and_disabled_roots_fail_closed(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                cache = base / "cache"
                cache.mkdir()
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")
                for forbidden_root in (
                    Path(r"D:\Codex\.agents\skills"),
                    Path(r"\\server\share\skills"),
                ):
                    with self.assertRaises(catalog_module.CatalogError):
                        catalog_module.build_catalog(
                            active_root=forbidden_root,
                            plugin_cache_root=cache,
                            ledger_path=ledger,
                            resource_closure=None,
                        )

        def test_excludes_legacy_agents_tree_and_preserves_utf8_facts(self) -> None:
            with tempfile.TemporaryDirectory(prefix="技能目录-") as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(
                    active,
                    "中文技能",
                    name="中文技能",
                    description="只读本机目录",
                )
                _write_skill(
                    active,
                    ".agents/legacy",
                    name="legacy",
                    description="must be excluded",
                )
                _write_skill(
                    active,
                    "tmp/legacy",
                    name="tmp-legacy",
                    description="must be excluded",
                )
                _write_skill(
                    active,
                    "run-evidence/legacy",
                    name="evidence-legacy",
                    description="must be excluded",
                )
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"unresolved": [{"name": "中文技能"}]}, ensure_ascii=False),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                self.assertEqual([item["name"] for item in catalog["artifacts"]], ["中文技能"])
                output = base / "catalog.json"
                catalog_module.write_catalog(catalog, output)
                raw = output.read_bytes()
                self.assertEqual(raw.decode("utf-8").encode("utf-8"), raw)
                self.assertIn("中文技能", raw.decode("utf-8"))

        def test_dry_run_prints_summary_without_creating_output(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")
                output = base / "reports" / "catalog.json"
                stdout = io.StringIO()

                with mock.patch.object(
                    catalog_module,
                    "_run_resource_closure",
                    return_value=_closure_result(active, 1),
                ):
                    with contextlib.redirect_stdout(stdout):
                        exit_code = catalog_module.main(
                            [
                                "--dry-run",
                                "--active-root",
                                str(active),
                                "--plugin-cache-root",
                                str(cache),
                                "--ledger",
                                str(ledger),
                                "--output",
                                str(output),
                            ]
                        )

                self.assertEqual(exit_code, 0)
                self.assertFalse(output.exists())
                self.assertFalse(output.parent.exists())
                summary = json.loads(stdout.getvalue())
                self.assertFalse(summary["write"])
                self.assertNotIn("artifacts", summary)
                self.assertEqual(summary["artifact_count"], 1)

        def test_missing_plugin_cache_fails_closed(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "missing-cache"
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")

                with self.assertRaises(catalog_module.CatalogError):
                    catalog_module.build_catalog(
                        active_root=active,
                        plugin_cache_root=cache,
                        ledger_path=ledger,
                        resource_closure=None,
                    )

        def test_deleted_ledger_state_is_preserved_as_a_conflict_fact(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(
                    json.dumps({"deleted": [{"name": "alpha"}]}),
                    encoding="utf-8",
                )

                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                artifact = catalog["artifacts"][0]
                self.assertEqual(artifact["ledger"]["states"], ["deleted"])
                self.assertEqual(artifact["ledger_coverage"], "deleted")

        def test_write_failure_keeps_existing_target_and_cleans_temp_file(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")
                catalog = catalog_module.build_catalog(
                    active_root=active,
                    plugin_cache_root=cache,
                    ledger_path=ledger,
                    resource_closure=_closure_result(active, 1),
                )
                output = base / "catalog.json"
                output.write_text('{"old": true}\n', encoding="utf-8")

                with mock.patch.object(
                    catalog_module.os,
                    "replace",
                    side_effect=OSError("simulated replace failure"),
                ):
                    with self.assertRaises(catalog_module.CatalogError):
                        catalog_module.write_catalog(catalog, output)

                self.assertEqual(output.read_text(encoding="utf-8"), '{"old": true}\n')
                self.assertEqual(list(base.glob(".catalog.json.*.tmp")), [])

        def test_invalid_ledger_frontmatter_and_closure_fail_closed(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                skill_dir = active / "alpha"
                skill_dir.mkdir(parents=True)
                (skill_dir / "SKILL.md").write_text(
                    "---\nname: alpha\ndescription: broken\n",
                    encoding="utf-8",
                )
                ledger = base / "ledger.json"
                ledger.write_text("{not-json", encoding="utf-8")

                with self.assertRaises(catalog_module.CatalogError):
                    catalog_module.build_catalog(
                        active_root=active,
                        plugin_cache_root=cache,
                        ledger_path=ledger,
                        resource_closure=_closure_result(active, 1),
                    )

                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")
                with self.assertRaises(catalog_module.CatalogError):
                    catalog_module.build_catalog(
                        active_root=active,
                        plugin_cache_root=cache,
                        ledger_path=ledger,
                        resource_closure={"findings": []},
                    )

        def test_cli_failure_does_not_create_or_overwrite_output(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")
                output = base / "catalog.json"
                output.write_text('{"old": true}\n', encoding="utf-8")
                stderr = io.StringIO()

                with mock.patch.object(
                    catalog_module,
                    "_run_resource_closure",
                    side_effect=catalog_module.CatalogError("closure failed"),
                ):
                    with contextlib.redirect_stderr(stderr):
                        exit_code = catalog_module.main(
                            [
                                "--write",
                                "--active-root",
                                str(active),
                                "--plugin-cache-root",
                                str(cache),
                                "--ledger",
                                str(ledger),
                                "--output",
                                str(output),
                            ]
                        )

                self.assertNotEqual(exit_code, 0)
                self.assertEqual(output.read_text(encoding="utf-8"), '{"old": true}\n')
                self.assertIn("closure failed", stderr.getvalue())

        def test_closure_findings_fail_closed(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")
                closure = _closure_result(active, 1)
                closure["summary"]["finding_count"] = 1
                closure["findings"] = [{"path": "alpha/SKILL.md"}]

                with self.assertRaises(catalog_module.CatalogError):
                    catalog_module.build_catalog(
                        active_root=active,
                        plugin_cache_root=cache,
                        ledger_path=ledger,
                        resource_closure=closure,
                    )

        def test_dry_run_does_not_use_network(self) -> None:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                active = base / "active"
                cache = base / "cache"
                cache.mkdir()
                _write_skill(active, "alpha", name="alpha", description="branch")
                ledger = base / "ledger.json"
                ledger.write_text(json.dumps({"sources": []}), encoding="utf-8")

                with mock.patch.object(
                    catalog_module,
                    "_run_resource_closure",
                    return_value=_closure_result(active, 1),
                ):
                    with mock.patch.object(socket, "socket", side_effect=AssertionError("network")):
                        with mock.patch.object(
                            urllib.request,
                            "urlopen",
                            side_effect=AssertionError("network"),
                        ):
                            self.assertEqual(
                                catalog_module.main(
                                    [
                                        "--dry-run",
                                        "--active-root",
                                        str(active),
                                        "--plugin-cache-root",
                                        str(cache),
                                        "--ledger",
                                        str(ledger),
                                    ]
                                ),
                                0,
                            )

        def test_defaults_are_d_drive_host_paths(self) -> None:
            self.assertEqual(
                str(catalog_module.DEFAULT_ACTIVE_ROOT),
                r"D:\agents\skills-manager\skills",
            )
            self.assertEqual(
                str(catalog_module.DEFAULT_PLUGIN_CACHE_ROOT),
                r"D:\Codex\.codex\plugins\cache",
            )
            self.assertEqual(
                str(catalog_module.DEFAULT_OUTPUT),
                r"D:\Codex\.codex\skill-catalog\catalog.json",
            )

        def test_output_rejects_non_d_drive(self) -> None:
            with self.assertRaises(catalog_module.CatalogError):
                catalog_module.write_catalog({}, Path(r"C:\Codex\skill-catalog.json"))
            with self.assertRaises(catalog_module.CatalogError):
                catalog_module.write_catalog({}, Path(r"D:\Codex\.agents\skill-catalog.json"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
