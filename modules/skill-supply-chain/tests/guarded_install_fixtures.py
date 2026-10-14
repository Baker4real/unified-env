"""Shared fixtures for the Test-SkillInstallGuarded*.py files.

Loads the installer entry and the system provenance repair module by path, names one handle per
installer family module, and provides ``GuardedInstallTestCase``: a temporary active root and
ledger plus candidate, manifest and argument builders.
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[3]
IMPLEMENTATION_ROOT = PROJECT_ROOT / "modules" / "skill-supply-chain" / "implementation"
WRAPPER_PATH = IMPLEMENTATION_ROOT / "install_skill_guarded.py"
SPEC = importlib.util.spec_from_file_location("install_skill_guarded", WRAPPER_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 wrapper：{WRAPPER_PATH}")
WRAPPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WRAPPER)
REPAIR_PATH = IMPLEMENTATION_ROOT / "system_skill_provenance_repair.py"
REPAIR_SPEC = importlib.util.spec_from_file_location("system_skill_provenance_repair", REPAIR_PATH)
if REPAIR_SPEC is None or REPAIR_SPEC.loader is None:  # pragma: no cover
    raise RuntimeError(f"无法加载 system repair：{REPAIR_PATH}")
REPAIR = importlib.util.module_from_spec(REPAIR_SPEC)
REPAIR_SPEC.loader.exec_module(REPAIR)
SUBPROCESS_CREATION_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
SUBPROCESS_TEXT_ENCODING = "oem" if os.name == "nt" else "utf-8"

# One handle per installer family module: patch a function on the handle of the module that owns
# it, because every caller reaches it through that module.
BASE = sys.modules["install_skill_guarded_base"]
TREE = sys.modules["install_skill_guarded_tree"]
ACTIVATION = sys.modules["install_skill_guarded_activation"]
PAYLOAD = sys.modules["install_skill_guarded_payload"]
SOURCE_RECORD = sys.modules["install_skill_guarded_source_record"]
BUNDLED = sys.modules["install_skill_guarded_bundled"]
CLOSURE = sys.modules["install_skill_guarded_closure"]
DECISION = sys.modules["install_skill_guarded_decision"]
LEDGER = sys.modules["install_skill_guarded_ledger"]
RETIREMENT = sys.modules["install_skill_guarded_retirement"]
STAGING = sys.modules["install_skill_guarded_staging"]


class GuardedInstallTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_parent = Path(r"D:\Codex\tmp")
        self.temp_parent.mkdir(parents=True, exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(prefix="skill-install-guarded-test-", dir=self.temp_parent))
        self.active = self.temp / "active"
        self.plugin_cache = self.temp / "plugin-cache"
        self.active.mkdir()
        self.plugin_cache.mkdir()
        self._grant_active_root_runtime_access()
        self.ledger = self.active / ".downloaded-skills-source-state.json"
        self.ledger.write_text(
            json.dumps(
                {
                    "updated_at": "2026-07-14",
                    "notes": [],
                    "sources": [],
                    "unresolved": [],
                    "deleted": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        self.generator = IMPLEMENTATION_ROOT / "generate_skill_catalog.py"
        self.closure = Path(
            r"D:\agents\skills-manager\skills\skill-install-guard\scripts\skill_resource_closure.py"
        )
        self.interpreter = Path(sys.executable).resolve()

    def _powershell(self) -> str:
        executable = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
        if not executable:
            self.fail("测试需要 PowerShell 读取 Windows ACL")
        return executable

    def _grant_active_root_runtime_access(self) -> None:
        result = subprocess.run(
            [
                "icacls.exe",
                str(self.active),
                "/inheritancelevel:e",
                "/grant:r",
                "*S-1-5-11:(OI)(CI)(M)",
                "*S-1-5-32-545:(OI)(CI)(RX)",
            ],
            capture_output=True,
            text=True,
            encoding=SUBPROCESS_TEXT_ENCODING,
            errors="replace",
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    def create_junction(self, path: Path, target: Path) -> None:
        target.mkdir(parents=True, exist_ok=True)
        script = (
            "$link=[Environment]::GetEnvironmentVariable('SKILL_JUNCTION_PATH','Process');"
            "$target=[Environment]::GetEnvironmentVariable('SKILL_JUNCTION_TARGET','Process');"
            "New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop|Out-Null"
        )
        result = subprocess.run(
            [
                self._powershell(),
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                script,
            ],
            env={
                **os.environ,
                "SKILL_JUNCTION_PATH": str(path),
                "SKILL_JUNCTION_TARGET": str(target),
            },
            capture_output=True,
            text=True,
            encoding=SUBPROCESS_TEXT_ENCODING,
            errors="replace",
            check=False,
            creationflags=SUBPROCESS_CREATION_FLAGS,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertTrue(BASE.is_reparse(path))

    def tearDown(self) -> None:
        def retry_read_only(function: object, path: str, error: BaseException) -> None:
            if not isinstance(error, PermissionError):
                raise error
            target = Path(path)
            target.chmod(target.stat().st_mode | stat.S_IWRITE)
            function(path)

        shutil.rmtree(self.temp, onexc=retry_read_only)

    def write_candidate(self, name: str, description: str) -> Path:
        candidate = self.temp / f"candidate-{name}"
        candidate.mkdir()
        (candidate / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n",
            encoding="utf-8",
        )
        return candidate

    def write_openai_yaml(self, candidate: Path, display_name: str) -> None:
        agents = candidate / "agents"
        agents.mkdir()
        (agents / "openai.yaml").write_text(
            "\n".join(
                [
                    "interface:",
                    f'  display_name: "{display_name}"',
                    '  short_description: "中文说明"',
                    '  default_prompt: "使用 $test-skill-wrapper 完成任务。"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

    def write_bundled_skill(
        self,
        candidate: Path,
        relative_path: str,
        name: str,
        *,
        include_source: bool = True,
    ) -> Path:
        bundled = candidate.joinpath(*relative_path.split("/"))
        bundled.mkdir(parents=True)
        (bundled / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: 捆绑夹具技能描述\n---\n\n# {name}\n",
            encoding="utf-8",
        )
        if include_source:
            (bundled / "SOURCE.md").write_text(
                "\n".join(
                    [
                        "# Source Provenance",
                        "",
                        f"Skill: `{name}`",
                        "Source repository: `https://github.com/example/bundled-runtime`",
                        f"Upstream path: `{relative_path}`",
                        "Ref: `v1.2.3`",
                        "Commit or revision: `0123456789abcdef`",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
        return bundled

    def write_manifest(
        self,
        name: str,
        decision: str,
        source_id: str = "local-test",
        ledger_updates: dict[str, object] | None = None,
        upstream_path: str | None = None,
        include_candidate_integrity: bool = True,
    ) -> Path:
        path = self.temp / f"manifest-{name}-{decision}.json"
        source: dict[str, object] = {"id": source_id, "ref": "local"}
        if ledger_updates is not None:
            source["ledger_updates"] = ledger_updates
        if upstream_path is not None:
            source["upstream_path"] = upstream_path
        payload: dict[str, object] = {
            "decision": decision,
            "source_status": "source-review",
            "writing_for_agents": {"status": "no-change"},
            "skills": [name],
            "source": source,
        }
        if include_candidate_integrity:
            candidate = self.temp / f"candidate-{name}"
            payload["candidate_integrity"] = PAYLOAD.candidate_integrity_payload(candidate)
        path.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )
        return path

    def wrapper_args(
        self,
        candidate: Path,
        manifest: Path,
        *,
        generator: Path | None = None,
        name: str = "test-skill-wrapper",
    ) -> list[str]:
        return [
            "--candidate",
            str(candidate),
            "--name",
            name,
            "--decision-manifest",
            str(manifest),
            "--active-root",
            str(self.active),
            "--plugin-cache-root",
            str(self.plugin_cache),
            "--ledger",
            str(self.ledger),
            "--catalog",
            str(self.temp / "catalog.json"),
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
