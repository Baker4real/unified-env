from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
MODULE_PATH = PROJECT_ROOT / "managed" / "codex-hooks" / "hooks" / "codex-state-policy-guard.py"
FIXTURE_ROOT = PROJECT_ROOT / "reports" / "codex-state-path-inventory-test"


def load_module():
    spec = importlib.util.spec_from_file_location("codex_state_path_inventory", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("state policy module loader unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


class CodexStatePathInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(FIXTURE_ROOT, ignore_errors=True)
        FIXTURE_ROOT.mkdir(parents=True)
        cls.module = load_module()

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(FIXTURE_ROOT, ignore_errors=True)

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(dir=FIXTURE_ROOT))
        self.source_root = self.root / "source"
        self.candidate_root = self.root / "candidate"
        self.source_root.mkdir()
        self.candidate_root.mkdir()
        (self.candidate_root / "project-a").mkdir()
        (self.candidate_root / "project-a" / "output").mkdir()
        (self.candidate_root / "project-a" / "output" / "result.txt").write_text(
            "fixture", encoding="utf-8"
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def _entry(self, inventory: dict[str, object], map_name: str, identity: str) -> dict[str, object]:
        maps = inventory["maps"]
        self.assertIsInstance(maps, dict)
        entries = maps[map_name]
        self.assertIsInstance(entries, dict)
        entry = entries[identity]
        self.assertIsInstance(entry, dict)
        return entry

    def _create_junction(self, junction: Path, target: Path) -> None:
        junction_literal = str(junction).replace("'", "''")
        target_literal = str(target).replace("'", "''")
        command = (
            "$ErrorActionPreference='Stop';"
            f"New-Item -ItemType Junction -Path '{junction_literal}' "
            f"-Target '{target_literal}' | Out-Null"
        )
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        result = subprocess.run(
            [
                r"D:\Codex\tools\PowerShell\7.6.3\pwsh.exe",
                "-NoProfile",
                "-EncodedCommand",
                encoded,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)

    def test_root_hint_has_safe_candidate_and_source_hash(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "project-a": r"C:\Users\WINDOWS\Documents\Codex\project-a",
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )

        entry = self._entry(inventory, "thread-workspace-root-hints", "project-a")
        self.assertEqual(entry["value"], state["thread-workspace-root-hints"]["project-a"])
        self.assertTrue(entry["safe"])
        self.assertEqual(entry["candidate"], str(self.candidate_root / "project-a"))
        self.assertEqual(entry["reason"], "safe")
        self.assertFalse(entry["reparse"])
        self.assertEqual(
            entry["sourceSha256"],
            hashlib.sha256(
                state["thread-workspace-root-hints"]["project-a"].encode("utf-8")
            ).hexdigest(),
        )

    def test_missing_output_is_unresolved_and_original_value_is_preserved(self) -> None:
        original = r"C:\Users\WINDOWS\Documents\Codex\missing-output"
        state = {"thread-projectless-output-directories": {"missing": original}}
        before = json.dumps(state, ensure_ascii=False, sort_keys=True)

        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )

        entry = self._entry(inventory, "thread-projectless-output-directories", "missing")
        self.assertEqual(entry["value"], original)
        self.assertFalse(entry["safe"])
        self.assertEqual(entry["candidate"], str(self.candidate_root / "missing-output"))
        self.assertEqual(entry["reason"], "unresolved-missing")
        self.assertFalse(entry["reparse"])
        self.assertEqual(json.dumps(state, ensure_ascii=False, sort_keys=True), before)

    def test_junction_is_unresolved_reparse(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "project-b").mkdir()
        junction = self.candidate_root / "junction"
        self._create_junction(junction, outside)
        try:
            state = {
                "thread-workspace-root-hints": {
                    "junction": r"C:\Users\WINDOWS\Documents\Codex\junction\project-b",
                }
            }
            inventory = self.module.build_path_inventory(
                state,
                r"C:\Users\WINDOWS\Documents\Codex",
                self.candidate_root,
            )
            entry = self._entry(inventory, "thread-workspace-root-hints", "junction")
            self.assertFalse(entry["safe"])
            self.assertEqual(entry["reason"], "unresolved-reparse")
            self.assertTrue(entry["reparse"])
            self.assertEqual(
                entry["value"],
                state["thread-workspace-root-hints"]["junction"],
            )
        finally:
            if junction.exists() or junction.is_symlink():
                junction.rmdir()

    def test_legacy_destination_never_becomes_candidate(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "legacy": r"D:\Users\WINDOWS\Documents\Codex\project-a",
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            r"D:\Users\WINDOWS\Documents\Codex",
        )

        entry = self._entry(inventory, "thread-workspace-root-hints", "legacy")
        self.assertFalse(entry["safe"])
        self.assertIsNone(entry["candidate"])
        self.assertEqual(entry["reason"], "unresolved-legacy-destination")
        self.assertEqual(entry["value"], state["thread-workspace-root-hints"]["legacy"])

    def test_unknown_map_and_value_are_retained_verbatim(self) -> None:
        unknown_value = {"keep": [1, 2, 3]}
        state = {
            "unknown-map": {"unknown": "preserve"},
            "thread-workspace-root-hints": {"unknown-value": unknown_value},
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )

        self.assertEqual(inventory["unknown"], {"unknown-map": state["unknown-map"]})
        entry = self._entry(inventory, "thread-workspace-root-hints", "unknown-value")
        self.assertEqual(entry["value"], unknown_value)
        self.assertFalse(entry["safe"])
        self.assertIsNone(entry["candidate"])
        self.assertEqual(entry["reason"], "unresolved-unknown-value")
        self.assertFalse(entry["reparse"])
        self.assertIsNone(entry["sourceSha256"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
