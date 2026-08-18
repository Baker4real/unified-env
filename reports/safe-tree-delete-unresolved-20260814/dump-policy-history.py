#!/usr/bin/env python3
"""Dump historical policy entry IDs from git. Read-only."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

REPO = Path(r"D:\Codex\projects\统一环境")
OUT = Path(__file__).resolve().parent / "policy-history.json"

commits = (
    subprocess.check_output(
        ["git", "-C", str(REPO), "log", "--format=%h %ci %s", "--", "managed/safe-tree-delete/policy.json"],
        text=True,
    )
    .strip()
    .splitlines()
)

history = []
seen_ids: dict[str, str] = {}
for line in commits:
    sha, rest = line.split(" ", 1)
    raw = subprocess.check_output(
        ["git", "-C", str(REPO), "show", f"{sha}:managed/safe-tree-delete/policy.json"]
    )
    doc = json.loads(raw.decode("utf-8"))
    entries = []
    for entry in doc.get("entries") or []:
        item = {
            "id": entry.get("id"),
            "capabilityRoot": entry.get("capabilityRoot"),
            "minimumDescendantDepth": entry.get("minimumDescendantDepth"),
            "rootDeletionPurpose": entry.get("rootDeletionPurpose"),
        }
        entries.append(item)
        if item["id"] not in seen_ids:
            seen_ids[item["id"]] = sha
    history.append(
        {
            "commit": sha,
            "meta": rest,
            "schemaVersion": doc.get("schemaVersion"),
            "entryCount": len(entries),
            "ids": [e["id"] for e in entries],
            "entries": entries,
        }
    )

# Newest first from git log. Compute removals vs previous (newer) commit.
removals = []
for newer, older in zip(history, history[1:]):
    gone = sorted(set(older["ids"]) - set(newer["ids"]))
    added = sorted(set(newer["ids"]) - set(older["ids"]))
    if gone or added:
        removals.append({"from": older["commit"], "to": newer["commit"], "removed": gone, "added": added})

# Also compare worktree
worktree = json.loads(
    (REPO / "managed/safe-tree-delete/policy.json").read_text(encoding="utf-8")
)
head_ids = set(history[0]["ids"])
wt_ids = {e["id"] for e in worktree["entries"]}
payload = {
    "snapshot": True,
    "commits": [
        {"commit": h["commit"], "meta": h["meta"], "schemaVersion": h["schemaVersion"], "ids": h["ids"]}
        for h in history
    ],
    "transitions": removals,
    "headVersusWorktree": {
        "removedInWorktree": sorted(head_ids - wt_ids),
        "addedInWorktree": sorted(wt_ids - head_ids),
        "worktreeIds": sorted(wt_ids),
    },
    "allIdsEver": sorted(seen_ids),
}
OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(payload["transitions"] + [payload["headVersusWorktree"]], ensure_ascii=False, indent=2))
print("commits", len(history))
