from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(r"D:\Codex\projects\统一环境")
MODULE_PATH = PROJECT_ROOT / "managed" / "codex-hooks" / "hooks" / "codex-state-policy-guard.py"
FIXTURE_ROOT = PROJECT_ROOT / "reports" / "codex-state-path-inventory-test"
CANONICAL_CANDIDATE_ROOT = Path(r"D:\Documents\Codex")
SOURCE_PREFIX = r"C:\Users\WINDOWS\Documents\Codex"
SAFE_RELATIVE = r"2026-07-13\new-chat"
REPARSE_RELATIVE = r"2026-05-31"
SAFE_FILE_RELATIVE = r"2026-06-03\c\outputs\optimize-c-drive-admin.ps1"


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
        self.candidate_root = CANONICAL_CANDIDATE_ROOT

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

    def _source(self, relative: str) -> str:
        return SOURCE_PREFIX if not relative else f"{SOURCE_PREFIX}\\{relative}"

    def test_root_hint_has_safe_candidate_and_source_hash(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "safe-path": self._source(SAFE_RELATIVE),
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )

        entry = self._entry(inventory, "thread-workspace-root-hints", "safe-path")
        self.assertEqual(entry["value"], state["thread-workspace-root-hints"]["safe-path"])
        self.assertTrue(entry["safe"])
        self.assertEqual(entry["candidate"], str(self.candidate_root / SAFE_RELATIVE))
        self.assertEqual(entry["reason"], "safe")
        self.assertFalse(entry["reparse"])
        self.assertEqual(
            entry["sourceSha256"],
            hashlib.sha256(
                state["thread-workspace-root-hints"]["safe-path"].encode("utf-8")
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
        junction = self.candidate_root / REPARSE_RELATIVE
        try:
            metadata = junction.lstat()
        except FileNotFoundError:
            self.skipTest(f"受控 canonical root 缺少 reparse fixture：{junction}")
        if not bool(getattr(metadata, "st_file_attributes", 0) & self.module.FILE_ATTRIBUTE_REPARSE_POINT):
            self.skipTest(f"受控 canonical root fixture 不是 reparse：{junction}")
        state = {
            "thread-workspace-root-hints": {
                "junction": self._source(REPARSE_RELATIVE + r"\project-b"),
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            SOURCE_PREFIX,
            self.candidate_root,
        )
        entry = self._entry(inventory, "thread-workspace-root-hints", "junction")
        self.assertFalse(entry["safe"])
        self.assertEqual(entry["reason"], "unresolved-reparse")
        self.assertTrue(entry["reparse"])
        self.assertEqual(entry["value"], state["thread-workspace-root-hints"]["junction"])

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
        inventory["unknown"]["unknown-map"]["unknown"] = "mutated"
        self.assertEqual(state["unknown-map"]["unknown"], "preserve")

    def test_rejects_dot_dotdot_and_8dot3_roots(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "project-a": r"C:\Users\WINDOWS\Documents\Codex\project-a",
            }
        }
        with self.assertRaises(self.module.StatePolicyError):
            self.module.build_path_inventory(
                state,
                r"C:\Users\WINDOWS\Documents\Codex\.",
                self.candidate_root,
            )
        with self.assertRaises(self.module.StatePolicyError):
            self.module.build_path_inventory(
                state,
                r"\\server\share\Codex",
                self.candidate_root,
            )
        with self.assertRaises(self.module.StatePolicyError):
            self.module.build_path_inventory(
                state,
                r"C:\Users\WINDOWS\Documents\Codex",
                str(self.candidate_root) + r"\..\candidate",
            )
        with self.assertRaises(self.module.StatePolicyError):
            self.module.build_path_inventory(
                state,
                r"C:\Users\WINDOWS\Documents\Codex",
                r"D:\Users\WINDOWS\DOCUME~1\Codex",
            )

    def test_alternate_lexical_value_is_unresolved_without_candidate(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "extended": r"\\?\C:\Users\WINDOWS\Documents\Codex\project-a",
                "short-name": r"C:\Users\WINDOWS\DOCUME~1\Codex\project-a",
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        for identity in ("extended", "short-name"):
            with self.subTest(identity=identity):
                entry = self._entry(inventory, "thread-workspace-root-hints", identity)
                self.assertFalse(entry["safe"])
                self.assertIsNone(entry["candidate"])
                self.assertEqual(entry["reason"], "unresolved-alternate-lexical")
                self.assertEqual(entry["value"], state["thread-workspace-root-hints"][identity])

    def test_rejects_multi_digit_8dot3_and_dos_device_segments(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "short-many": r"C:\Users\WINDOWS\Documents\Codex\DOCUME~10\project-a",
                "con": r"C:\Users\WINDOWS\Documents\Codex\CON\project-a",
                "nul": r"C:\Users\WINDOWS\Documents\Codex\NUL\project-a",
                "com": r"C:\Users\WINDOWS\Documents\Codex\COM1.txt\project-a",
                "conin": r"C:\Users\WINDOWS\Documents\Codex\CONIN$\project-a",
                "conout": r"C:\Users\WINDOWS\Documents\Codex\CONOUT$\project-a",
                "clock": r"C:\Users\WINDOWS\Documents\Codex\CLOCK$\project-a",
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        self.assertEqual(
            self._entry(inventory, "thread-workspace-root-hints", "short-many")["reason"],
            "unresolved-alternate-lexical",
        )
        for identity in ("con", "nul", "com", "conin", "conout", "clock"):
            with self.subTest(identity=identity):
                entry = self._entry(inventory, "thread-workspace-root-hints", identity)
                self.assertFalse(entry["safe"])
                self.assertIsNone(entry["candidate"])
                self.assertEqual(entry["reason"], "unresolved-device-name")

    def test_uncontrolled_candidate_root_is_structured_unresolved(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "project-a": r"C:\Users\WINDOWS\Documents\Codex\project-a",
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.root,
        )
        self.assertFalse(inventory["candidateRootAllowed"])
        entry = self._entry(inventory, "thread-workspace-root-hints", "project-a")
        self.assertFalse(entry["safe"])
        self.assertIsNone(entry["candidate"])
        self.assertEqual(entry["reason"], "unresolved-candidate-root-not-allowed")

    def test_candidate_root_file_cannot_become_safe_target(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "root": r"C:\Users\WINDOWS\Documents\Codex",
            }
        }
        candidate_file = Path(
            r"D:\Documents\Codex\2026-06-03\c\outputs\optimize-c-drive-admin.ps1"
        )
        self.assertTrue(candidate_file.is_file())
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            candidate_file,
        )
        self.assertFalse(inventory["candidateRootAllowed"])
        entry = self._entry(inventory, "thread-workspace-root-hints", "root")
        self.assertFalse(entry["safe"])
        self.assertIsNone(entry["candidate"])
        self.assertEqual(entry["reason"], "unresolved-candidate-root-not-allowed")

    def test_uncontrolled_source_root_is_structured_unresolved(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "safe-path": self._source(SAFE_RELATIVE),
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"D:\Documents\Codex",
            self.candidate_root,
        )
        self.assertFalse(inventory["sourceRootAllowed"])
        entry = self._entry(inventory, "thread-workspace-root-hints", "safe-path")
        self.assertFalse(entry["safe"])
        self.assertIsNone(entry["candidate"])
        self.assertEqual(entry["reason"], "unresolved-source-root-not-allowed")
        self.assertEqual(entry["value"], state["thread-workspace-root-hints"]["safe-path"])

    def test_safe_result_is_explicitly_advisory_for_repair(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "safe-path": self._source(SAFE_RELATIVE),
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        self.assertTrue(inventory["safeAdvisory"])
        self.assertEqual(inventory["repairContract"], "generation-hash-mutex-cas-reprobe")
        entry = self._entry(inventory, "thread-workspace-root-hints", "safe-path")
        self.assertTrue(entry["safe"])
        self.assertTrue(entry["probe"]["advisoryOnly"])

    def test_invalid_string_values_are_structured_unresolved(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "nul": r"C:\Users\WINDOWS\Documents\Codex\bad\x00".replace("\\x00", "\x00"),
                "surrogate": "C:\\Users\\WINDOWS\\Documents\\Codex\\bad\\\ud800",
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        for identity in ("nul", "surrogate"):
            with self.subTest(identity=identity):
                entry = self._entry(inventory, "thread-workspace-root-hints", identity)
                self.assertFalse(entry["safe"])
                self.assertIsNone(entry["candidate"])
                self.assertEqual(entry["reason"], "unresolved-invalid-path")
                self.assertIsNone(entry["sourceSha256"])

    def test_duplicate_final_identity_is_not_safe_for_either_entry(self) -> None:
        source_value = self._source(SAFE_RELATIVE)
        state = {
            "thread-workspace-root-hints": {"root": source_value},
            "thread-projectless-output-directories": {"output": source_value},
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        for map_name, identity in (
            ("thread-workspace-root-hints", "root"),
            ("thread-projectless-output-directories", "output"),
        ):
            with self.subTest(map_name=map_name):
                entry = self._entry(inventory, map_name, identity)
                self.assertFalse(entry["safe"])
                self.assertEqual(entry["reason"], "unresolved-ambiguous")
                self.assertEqual(entry["value"], source_value)

    def test_casefolded_candidate_aliases_are_also_ambiguous(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "lower": self._source(SAFE_RELATIVE),
                "upper": self._source(SAFE_RELATIVE.upper()),
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        for identity in ("lower", "upper"):
            with self.subTest(identity=identity):
                entry = self._entry(inventory, "thread-workspace-root-hints", identity)
                self.assertFalse(entry["safe"])
                self.assertEqual(entry["reason"], "unresolved-ambiguous")

    def test_safe_entry_contains_handle_bound_probe_identity(self) -> None:
        state = {
            "thread-workspace-root-hints": {
                "safe-path": self._source(SAFE_RELATIVE),
            }
        }
        before_paths = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        entry = self._entry(inventory, "thread-workspace-root-hints", "safe-path")
        self.assertTrue(entry["safe"])
        probe = entry["probe"]
        self.assertIsInstance(probe, dict)
        self.assertTrue(probe["finalPathVerified"])
        self.assertIsInstance(probe["identity"], list)
        self.assertEqual(len(probe["identity"]), 2)
        self.assertEqual(
            before_paths,
            sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")),
        )

    def test_handle_probe_accepts_a_regular_file_target(self) -> None:
        state = {
            "thread-projectless-output-directories": {
                "file": self._source(SAFE_FILE_RELATIVE),
            }
        }
        inventory = self.module.build_path_inventory(
            state,
            r"C:\Users\WINDOWS\Documents\Codex",
            self.candidate_root,
        )
        entry = self._entry(inventory, "thread-projectless-output-directories", "file")
        self.assertTrue(entry["safe"])
        self.assertEqual(entry["reason"], "safe")
        self.assertTrue(entry["probe"]["finalPathVerified"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
