"""Stable repository adapter for the skill-supply-chain SOURCE.md parser."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


_IMPLEMENTATION = (
    Path(__file__).resolve().parents[1]
    / "modules"
    / "skill-supply-chain"
    / "implementation"
    / "skill_source_record.py"
)
_SPEC = importlib.util.spec_from_file_location("skill_supply_chain_skill_source_record", _IMPLEMENTATION)
if _SPEC is None or _SPEC.loader is None:
    raise ImportError(f"无法加载 skill-supply-chain parser: {_IMPLEMENTATION}")
_MODULE = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _MODULE
_SPEC.loader.exec_module(_MODULE)

for _name in dir(_MODULE):
    if not _name.startswith("__"):
        globals()[_name] = getattr(_MODULE, _name)
