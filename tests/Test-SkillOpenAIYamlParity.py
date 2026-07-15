from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify_skill_openai_yaml_parity.py"
SPEC = importlib.util.spec_from_file_location("verify_skill_openai_yaml_parity", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SkillOpenAIYamlParityTests(unittest.TestCase):
    def test_allows_chinese_description_but_not_name_or_policy_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            upstream = root / "upstream" / "skills" / "engineering" / "demo"
            active = root / "active" / "demo"
            for directory in (upstream / "agents", active / "agents"):
                directory.mkdir(parents=True)
            (upstream / "SKILL.md").write_text(
                "---\nname: demo\ndescription: Demo\n---\n", encoding="utf-8"
            )
            upstream_yaml = (
                'interface:\n  display_name: "Demo"\n'
                '  short_description: "Upstream"\n'
                'policy:\n  allow_implicit_invocation: false\n'
            )
            (upstream / "agents" / "openai.yaml").write_text(upstream_yaml, encoding="utf-8")
            (active / "agents" / "openai.yaml").write_text(
                upstream_yaml.replace('short_description: "Upstream"', 'short_description: "中文说明"'),
                encoding="utf-8",
            )
            self.assertEqual(MODULE.verify(root / "active", root / "upstream")["finding_count"], 0)

            (active / "agents" / "openai.yaml").write_text(
                upstream_yaml.replace('display_name: "Demo"', 'display_name: "演示"'),
                encoding="utf-8",
            )
            result = MODULE.verify(root / "active", root / "upstream")
            self.assertEqual(result["findings"], [{"name": "demo", "kind": "non-display-drift"}])


if __name__ == "__main__":
    unittest.main()
