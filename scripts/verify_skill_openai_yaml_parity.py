"""Verify behavioral agents/openai.yaml fields against an upstream skill tree.

Chinese short descriptions and prompts are a local display overlay. Skill names,
display names, policy, and every other field must remain equal to upstream.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml


DISPLAY_OVERLAY_KEYS = {"short_description", "default_prompt"}


def skill_name(skill_md: Path) -> str:
    data = yaml.safe_load(skill_md.read_text(encoding="utf-8-sig").split("---", 2)[1])
    return str(data["name"])


def normalized_behavior(path: Path) -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8-sig")) or {}
    interface = dict(data.get("interface") or {})
    for key in DISPLAY_OVERLAY_KEYS:
        interface.pop(key, None)
    result = dict(data)
    result["interface"] = interface
    return result


def verify(active_root: Path, upstream_root: Path) -> dict:
    findings: list[dict[str, str]] = []
    checked = 0
    for skill_md in sorted(upstream_root.rglob("SKILL.md")):
        if any(part in {"deprecated", "in-progress"} for part in skill_md.parts):
            continue
        upstream_yaml = skill_md.parent / "agents" / "openai.yaml"
        if not upstream_yaml.exists():
            continue
        name = skill_name(skill_md)
        local_yaml = active_root / name / "agents" / "openai.yaml"
        if not local_yaml.exists():
            findings.append({"name": name, "kind": "local-missing"})
            continue
        checked += 1
        if normalized_behavior(local_yaml) != normalized_behavior(upstream_yaml):
            findings.append({"name": name, "kind": "non-display-drift"})
    return {"checked": checked, "finding_count": len(findings), "findings": findings}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--active-root", type=Path, required=True)
    parser.add_argument("--upstream-root", type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.active_root.resolve(), args.upstream_root.resolve())
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
