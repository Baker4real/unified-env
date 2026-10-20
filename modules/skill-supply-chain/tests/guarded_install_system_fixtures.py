"""Fixtures shared by the bundled ``.system`` provenance repair and skill-creator overlay tests."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import shutil
from pathlib import Path

from guarded_install_fixtures import BASE, PAYLOAD, REPAIR, WRAPPER, GuardedInstallTestCase


class SystemRepairTestCase(GuardedInstallTestCase):
    def prepare_system_provenance_repair(self, *, include_creator_scripts: bool = False) -> dict[str, object]:
        names = [
            "imagegen",
            "openai-docs",
            "review-agent",
            "skill-creator",
            "skill-installer",
        ]
        system_root = self.active / ".system"
        if system_root.exists():
            shutil.rmtree(system_root)
        system_root.mkdir()
        marker = system_root / ".codex-system-skills.marker"
        marker.write_bytes(b"fixture-marker-v1\n")

        baseline_skill_bytes: dict[str, bytes] = {}
        for name in names:
            skill_root = system_root / name
            skill_root.mkdir()
            skill_text = (
                f"---\nname: {name}\ndescription: 系统修复夹具技能：{name}。\n"
                "---\n\n"
                f"# {name}\n"
            )
            skill_path = skill_root / "SKILL.md"
            skill_path.write_text(skill_text, encoding="utf-8")
            baseline_skill_bytes[name] = skill_path.read_bytes()
            if name == "skill-creator" and include_creator_scripts:
                scripts = skill_root / "scripts"
                scripts.mkdir()
                (scripts / "quick_validate.py").write_text("# official quick validator\nLEGACY = True\n", encoding="utf-8")
                (scripts / "test_quick_validate.py").write_text("# official quick validator tests\nLEGACY = True\n", encoding="utf-8")
            if name == "review-agent":
                agents = skill_root / "agents"
                agents.mkdir()
                (agents / "openai.yaml").write_text(
                    "interface:\n"
                    '  display_name: "Review Agent"\n'
                    "policy:\n"
                    "  allow_implicit_invocation: false\n",
                    encoding="utf-8",
                )

        source_root = str(system_root).replace("\\", "/")
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-08-18",
                    "notes": [],
                    "sources": [
                        {
                            "id": "codex-bundled-system-skills",
                            "type": "codex-bundled-system",
                            "source_root": source_root,
                            "status": "tracked-bundled-system-skills",
                            "skills": [f".system/{name}" for name in names],
                            "local_changes": [],
                        }
                    ],
                    "unresolved": [],
                    "deleted": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        catalog = self.temp / "catalog.json"
        catalog.write_bytes(b'{"sentinel":"before"}\n')

        package_full_name = "OpenAI.Codex_26.810.7004.0_x64__fixture"
        package_root = self.temp / package_full_name
        if package_root.exists():
            shutil.rmtree(package_root)
        package_root.mkdir()
        manifest_path = package_root / "AppxManifest.xml"
        signature_path = package_root / "AppxSignature.p7x"
        manifest_path.write_bytes(b"<Package fixture='system-provenance' />\n")
        signature_path.write_bytes(b"fixture-valid-store-signature\n")
        package_identity = {
            "schema_version": 1,
            "package_name": "OpenAI.Codex",
            "package_full_name": package_full_name,
            "package_family_name": "OpenAI.Codex_fixture",
            "version": "26.810.7004.0",
            "publisher": "CN=FIXTURE",
            "signature_kind": "Store",
            "signature_status": "Valid",
            "appx_status": "Ok",
            "install_location": str(package_root),
            "appx_manifest_path": str(manifest_path),
            "appx_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            "appx_signature_path": str(signature_path),
            "appx_signature_sha256": hashlib.sha256(signature_path.read_bytes()).hexdigest(),
        }
        provider = self.temp / "fixture_system_package_provider.py"
        provider.write_text(
            "import json\n"
            f"print(json.dumps({package_identity!r}))\n",
            encoding="utf-8",
        )

        skills: list[dict[str, object]] = []
        for name in names:
            skill_root = system_root / name
            official = PAYLOAD.candidate_integrity_payload(skill_root)
            overlay: dict[str, object] = {"kind": "none"}
            effective = dict(official)
            critical_files: dict[str, str] = {}
            if name == "review-agent":
                parity_path = skill_root / "agents" / "openai.yaml"
                critical_files["agents/openai.yaml"] = BASE.sha256_file(parity_path)
                baseline_text = baseline_skill_bytes[name].decode("utf-8")
                newline = "\r\n" if "\r\n" in baseline_text else "\n"
                patched_text = baseline_text.replace(
                    f"---{newline}{newline}# review-agent",
                    f"disable-model-invocation: true{newline}---{newline}{newline}# review-agent",
                    1,
                )
                (skill_root / "SKILL.md").write_bytes(patched_text.encode("utf-8"))
                effective = PAYLOAD.candidate_integrity_payload(skill_root)
                (skill_root / "SKILL.md").write_bytes(baseline_skill_bytes[name])
                overlay = {
                    "kind": "review-agent-invocation-parity",
                    "disable_model_invocation": True,
                    "allow_implicit_invocation": False,
                    "parity_file": "agents/openai.yaml",
                }
            skills.append(
                {
                    "name": name,
                    "source_before_sha256": None,
                    "official_integrity": official,
                    "effective_integrity": effective,
                    "critical_files": critical_files,
                    "overlay": overlay,
                }
            )

        plan = self.temp / "system-provenance-repair-plan.json"
        plan.write_text(
            json.dumps(
                {
                    "artifact_type": "codex.system-skill-provenance-repair",
                    "schema_version": 1,
                    "mode": "atomic-six-skill-bootstrap",
                    "source_group_id": "codex-bundled-system-skills",
                    "package_identity_provider_sha256": hashlib.sha256(
                        provider.read_bytes()
                    ).hexdigest(),
                    "package_identity": package_identity,
                    "marker": {
                        "relative_path": ".system/.codex-system-skills.marker",
                        "sha256": hashlib.sha256(marker.read_bytes()).hexdigest(),
                    },
                    "ledger_before_sha256": hashlib.sha256(
                        self.ledger.read_bytes()
                    ).hexdigest(),
                    "catalog_before_sha256": hashlib.sha256(
                        catalog.read_bytes()
                    ).hexdigest(),
                    "stability_check": {"observations": 2, "interval_seconds": 0},
                    "skills": skills,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        return {
            "names": names,
            "system_root": system_root,
            "marker": marker,
            "provider": provider,
            "package_identity": package_identity,
            "plan": plan,
            "catalog": catalog,
            "baseline_skill_bytes": baseline_skill_bytes,
        }

    def system_provenance_repair_args(
        self,
        state: dict[str, object],
        *,
        generator: Path | None = None,
    ) -> list[str]:
        return [
            "--system-provenance-repair-plan",
            str(state["plan"]),
            "--system-package-provider",
            str(state["provider"]),
            "--active-root",
            str(self.active),
            "--plugin-cache-root",
            str(self.plugin_cache),
            "--ledger",
            str(self.ledger),
            "--catalog",
            str(state["catalog"]),
            "--generator",
            str(generator or self.generator),
            "--closure-script",
            str(self.closure),
            "--python",
            str(self.interpreter),
            "--temp-root",
            str(self.temp / "staging"),
            "--lock-root",
            str(self.temp / "lock"),
            "--evidence-root",
            str(self.temp / "evidence"),
        ]

    def prepare_system_display_bootstrap(self, *, include_creator_scripts: bool = False) -> dict[str, object]:
        """An official refresh dropped every SOURCE.md, then the menu tool translated the display fields."""
        state = self.prepare_system_provenance_repair(include_creator_scripts=include_creator_scripts)
        system_root = Path(state["system_root"])
        plan = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
        parity = next(spec["overlay"] for spec in plan["skills"] if spec["name"] == "review-agent")
        official_texts: dict[str, dict[str, str]] = {}
        official_trees: dict[str, dict[str, object]] = {}
        for spec in plan["skills"]:
            name = spec["name"]
            root = system_root / name
            skill = root / "SKILL.md"
            agent = root / "agents" / "openai.yaml"
            agent.parent.mkdir(exist_ok=True)
            policy = "policy:\r\n  allow_implicit_invocation: false\r\n" if name == "review-agent" else ""
            skill.write_bytes(
                f"---\r\nname: {name}\r\ndescription: Official fixture skill {name}.\r\n---\r\n\r\n# {name}\r\n".encode("utf-8")
            )
            agent.write_bytes(
                (
                    "interface:\r\n"
                    f'  display_name: "{name}"\r\n'
                    '  short_description: "Official menu text"\r\n'
                    '  default_prompt: "Official prompt"\r\n' + policy
                ).encode("utf-8")
            )
            official_texts[name] = {
                "SKILL.md": skill.read_bytes().decode("utf-8"),
                "agents/openai.yaml": agent.read_bytes().decode("utf-8"),
            }
            official_trees[name] = PAYLOAD.candidate_integrity_payload(root)
            skill.write_bytes(
                f'---\r\nname: {name}\r\ndescription: "本夹具的中文展示文本：{name}。"\r\n---\r\n\r\n# {name}\r\n'.encode("utf-8")
            )
            agent.write_bytes(
                agent.read_bytes()
                .replace(b"Official menu text", "中文菜单文本".encode("utf-8"))
                .replace(b"Official prompt", "中文提示词".encode("utf-8"))
            )
            spec["official_integrity"] = official_trees[name]
            spec["effective_integrity"] = PAYLOAD.candidate_integrity_payload(root)
            spec["critical_files"] = {}
            base_overlay: dict[str, object] = {"kind": "none"}
            if name == "review-agent":
                spec["critical_files"] = {"agents/openai.yaml": BASE.sha256_file(agent)}
                localized = skill.read_bytes()
                skill.write_bytes(
                    localized.replace(b"\r\n---\r\n\r\n#", b"\r\ndisable-model-invocation: true\r\n---\r\n\r\n#", 1)
                )
                spec["effective_integrity"] = PAYLOAD.candidate_integrity_payload(root)
                skill.write_bytes(localized)
                base_overlay = dict(parity)
            spec["overlay"] = {
                "kind": "display-only",
                "baseline_files": official_texts[name],
                "base_overlay": base_overlay,
            }
        plan["official_baseline_source"] = "fixture skills snapshot taken before the menu translation"
        Path(state["plan"]).write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")
        state["official_baseline_source"] = plan["official_baseline_source"]
        state["official_texts"] = official_texts
        state["official_trees"] = official_trees
        state["parity_overlay"] = parity
        return state

    def prepare_system_display_reconcile(self, *, include_creator_scripts: bool = False) -> dict[str, object]:
        state = self.prepare_system_provenance_repair(include_creator_scripts=include_creator_scripts)
        bootstrap = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
        for spec in bootstrap["skills"]:
            root = Path(state["system_root"]) / spec["name"]
            agents = root / "agents"
            agents.mkdir(exist_ok=True)
            agent_file = agents / "openai.yaml"
            text = agent_file.read_text(encoding="utf-8") if agent_file.exists() else "interface:\n"
            agent_file.write_text(
                text.replace("interface:\n", 'interface:\n  short_description: "原始菜单文本"\n  default_prompt: "原始提示词"\n'),
                encoding="utf-8",
            )
            spec["official_integrity"] = REPAIR.system_skill_integrity(root)
            spec["effective_integrity"] = spec["official_integrity"]
            if spec["name"] == "review-agent":
                spec["critical_files"]["agents/openai.yaml"] = BASE.sha256_file(agent_file)
                spec["effective_integrity"] = REPAIR._tree_integrity(root, overrides={
                    "SKILL.md": REPAIR._review_overlay_bytes(root / "SKILL.md", (root / "SKILL.md").read_bytes()),
                })
        Path(state["plan"]).write_text(json.dumps(bootstrap), encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(WRAPPER.main(self.system_provenance_repair_args(state)), 0)
        ledger = json.loads(self.ledger.read_text(encoding="utf-8"))
        records = ledger["sources"][0]["system_provenance"]["skills"]
        plan = json.loads(Path(state["plan"]).read_text(encoding="utf-8"))
        plan["mode"] = "atomic-six-skill-display-reconcile"
        for spec, previous in zip(plan["skills"], records):
            root = Path(state["system_root"]) / spec["name"]
            baseline = {"SKILL.md": (root / "SKILL.md").read_bytes().decode("utf-8")}
            if (root / "agents/openai.yaml").exists():
                baseline["agents/openai.yaml"] = (root / "agents/openai.yaml").read_bytes().decode("utf-8")
            (root / "SKILL.md").write_bytes(
                baseline["SKILL.md"].replace(
                    f"description: 系统修复夹具技能：{spec['name']}。",
                    'description: "本夹具已重放的中文展示文本。"',
                ).encode("utf-8")
            )
            agent_file = root / "agents/openai.yaml"
            agent_file.write_bytes(
                agent_file.read_bytes().replace("原始菜单文本".encode("utf-8"), "翻译后的菜单文本".encode("utf-8"))
                .replace("原始提示词".encode("utf-8"), "翻译后的提示词".encode("utf-8"))
            )
            spec["critical_files"] = {
                relative: BASE.sha256_file(root / relative)
                for relative in previous["critical_files"]
            }
            spec["source_before_sha256"] = BASE.sha256_file(root / "SOURCE.md")
            spec["effective_integrity"] = REPAIR.system_skill_integrity(root)
            spec["overlay"] = {
                "kind": "display-only",
                "baseline_files": baseline,
                "base_overlay": previous["overlay"],
            }
        plan["ledger_before_sha256"] = BASE.sha256_file(self.ledger)
        plan["catalog_before_sha256"] = BASE.sha256_file(Path(state["catalog"]))
        Path(state["plan"]).write_text(json.dumps(plan), encoding="utf-8")
        state["previous_records"] = records
        return state

    def system_display_state_bytes(self, state: dict[str, object]) -> dict[Path, bytes]:
        paths = [self.ledger, Path(state["catalog"])]
        paths.extend(p for p in Path(state["system_root"]).rglob("*") if p.is_file())
        return {p: p.read_bytes() for p in paths}
