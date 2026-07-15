from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import socket
import tempfile
import unittest
import urllib.request
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate_skill_catalog.py"

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


if IMPORT_ERROR is not None:

    class SkillCatalogTests(unittest.TestCase):
        def test_catalog_module_is_available(self) -> None:
            self.fail(f"catalog 实现尚未提供：{IMPORT_ERROR}")

else:

    class SkillCatalogTests(unittest.TestCase):
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
                r"D:\Codex\.codex\skills",
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
