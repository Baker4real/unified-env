"""Shared parsing for the current record in a skill SOURCE.md file.

SOURCE.md is append-only provenance.  Only the final section after an exact
``---`` separator describes the current installation.  Keeping that rule in
one module prevents the installer and generated catalog from silently using
different historical data.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping


_SECTION_SEPARATOR = re.compile(r"\s*---\s*")
_KEY_VALUE = re.compile(
    r"^\s*(?P<key>[A-Za-z][A-Za-z0-9 _-]*)\s*:\s*(?P<value>.*?)\s*$"
)


def strip_scalar(value: str) -> str:
    """Remove the lightweight quoting convention used by SOURCE.md fields."""

    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"', "`"}:
        return value[1:-1].strip()
    return value


def normalize_field_name(value: str) -> str:
    """Normalize SOURCE.md field labels without changing their stored values."""

    return value.strip().casefold().replace(" ", "_").replace("-", "_")


@dataclass(frozen=True)
class CurrentSourceRecord:
    """Immutable view of the last SOURCE.md provenance section."""

    section_index: int
    fields: Mapping[str, str]
    values: Mapping[str, tuple[str, ...]]
    conflicts: Mapping[str, tuple[str, ...]]
    labels: Mapping[str, str]

    def values_for(self, *field_names: str) -> tuple[str, ...]:
        return tuple(
            value
            for field_name in field_names
            for value in self.values.get(normalize_field_name(field_name), ())
        )

    def conflict_description(self) -> str:
        return "; ".join(
            f"{self.labels.get(key, key)}={list(values)!r}"
            for key, values in self.conflicts.items()
        )


def parse_current_source_record(text: str) -> CurrentSourceRecord:
    """Parse only the final append-only SOURCE.md section.

    Repeated fields with the same scalar value remain valid.  Distinct values
    for the same normalized field are retained as explicit conflicts so each
    caller can fail closed using the same observation.
    """

    sections: list[list[str]] = [[]]
    for line in text.splitlines():
        if _SECTION_SEPARATOR.fullmatch(line):
            sections.append([])
        else:
            sections[-1].append(line)

    values_by_key: dict[str, list[str]] = {}
    labels: dict[str, str] = {}
    for line in sections[-1]:
        match = _KEY_VALUE.match(line)
        if match is None:
            continue
        value = strip_scalar(match.group("value"))
        key = normalize_field_name(match.group("key"))
        values_by_key.setdefault(key, []).append(value)
        labels.setdefault(key, match.group("key").strip())

    values = {key: tuple(entries) for key, entries in values_by_key.items()}
    fields: dict[str, str] = {}
    conflicts: dict[str, tuple[str, ...]] = {}
    for key, entries in values.items():
        unique = tuple(dict.fromkeys(entries))
        if len(unique) == 1 and unique[0]:
            fields[key] = unique[0]
        else:
            conflicts[key] = unique

    if not fields and not conflicts:
        labels["current_record"] = "末尾分段"
        conflicts["current_record"] = ()

    return CurrentSourceRecord(
        section_index=len(sections) - 1,
        fields=MappingProxyType(fields),
        values=MappingProxyType(values),
        conflicts=MappingProxyType(conflicts),
        labels=MappingProxyType(labels),
    )
