#!/usr/bin/env python3
from pathlib import Path
import json, subprocess

paths = [
    Path(r"D:\Codex\projects\cc-switch\src-tauri\gen"),
    Path(r"D:\Codex\projects\时钟倒计时\verification"),
    Path(r"D:\Codex\projects\时钟倒计时\.codex-safe-delete-1ba06d2f-fbf0-43fe-a57e-7fd57f943153.quarantine"),
    Path(r"D:\claude"),
    Path(r"D:\Codex\projects\雷达天梯"),
    Path(r"D:\Codex\projects\okf-frontmatter"),
    Path(r"D:\Codex\projects\minmin-calendar"),
]
for p in paths:
    print(f"{p} exists={p.exists()} is_dir={p.is_dir() if p.exists() else False}")

repo = Path(r"D:\Codex\projects\统一环境")
for commit in ("51899f9", "5221dae", "8d58c9a", "ec05faf"):
    raw = subprocess.check_output(
        ["git", "-C", str(repo), "show", f"{commit}:managed/safe-tree-delete/policy.json"]
    )
    doc = json.loads(raw.decode("utf-8"))
    for e in doc.get("entries") or []:
        if e.get("id") == "codex-run-evidence":
            print(commit, "run-evidence depth", e.get("minimumDescendantDepth"), "denied", e.get("deniedExactPaths"))
