from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


sys.dont_write_bytecode = True


SCRIPT = Path(__file__).with_name("quick_validate.py")
SPEC = importlib.util.spec_from_file_location("quick_validate", SCRIPT)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - import guard
    raise ImportError(f"Unable to load {SCRIPT}")
quick_validate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quick_validate)


class QuickValidateTests(unittest.TestCase):
    def validate_fixture(self, frontmatter: str) -> tuple[bool, str]:
        with tempfile.TemporaryDirectory() as temp:
            skill_dir = Path(temp)
            (skill_dir / "SKILL.md").write_text(
                f"---\n{frontmatter}---\n\n# Fixture\n", encoding="utf-8"
            )
            return quick_validate.validate_skill(skill_dir)

    def test_accepts_codex_invocation_frontmatter(self) -> None:
        valid, message = self.validate_fixture(
            "name: explicit-skill\n"
            "description: Explicit invocation fixture.\n"
            "argument-hint: \"What should this skill do?\"\n"
            "disable-model-invocation: true\n"
        )
        self.assertTrue(valid, message)

    def test_rejects_non_boolean_disable_model_invocation(self) -> None:
        valid, message = self.validate_fixture(
            "name: invalid-disable\n"
            "description: Invalid disable fixture.\n"
            "disable-model-invocation: \"true\"\n"
        )
        self.assertFalse(valid)
        self.assertEqual(message, "disable-model-invocation must be a boolean")

    def test_rejects_non_string_argument_hint(self) -> None:
        valid, message = self.validate_fixture(
            "name: invalid-hint\n"
            "description: Invalid hint fixture.\n"
            "argument-hint: 7\n"
        )
        self.assertFalse(valid)
        self.assertEqual(message, "argument-hint must be a string")

    def test_rejects_unknown_frontmatter_field(self) -> None:
        valid, message = self.validate_fixture(
            "name: unknown-field\n"
            "description: Unknown field fixture.\n"
            "version: 3.9.1\n"
        )
        self.assertFalse(valid)
        self.assertIn("Unexpected key(s)", message)
        self.assertIn("version", message)

    def test_rejects_non_string_frontmatter_key(self) -> None:
        valid, message = self.validate_fixture(
            "name: non-string-key\n"
            "description: Non-string key fixture.\n"
            "7: value\n"
        )
        self.assertFalse(valid)
        self.assertEqual(message, "Frontmatter keys must be strings")


if __name__ == "__main__":
    unittest.main()
