# Self-check for GitHub #50 evidence pack. Does not run Status or ProductionSmoke.
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACK = Path(__file__).resolve().parent


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(rel: str):
    p = ROOT / rel
    with p.open(encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    errors: list[str] = []
    include = json.loads((PACK / "include.json").read_text(encoding="utf-8"))
    exclude = json.loads((PACK / "exclude.json").read_text(encoding="utf-8"))
    staged = [
        line.strip()
        for line in (PACK / "STAGED-FILE-LIST.txt").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]

    include_paths = {item["path"] for item in include["files"]}
    for extra in include["packOutputsToAdd"]:
        include_paths.add(extra)

    for item in include["files"]:
        p = ROOT / item["path"]
        if not p.is_file():
            errors.append(f"missing include {item['path']}")
            continue
        actual = sha256_file(p)
        if actual != item["sha256"]:
            errors.append(f"sha mismatch {item['path']} listed={item['sha256']} actual={actual}")

    for rel in include["packOutputsToAdd"]:
        if not (ROOT / rel).is_file():
            errors.append(f"missing pack output {rel}")

    for cited in include["githubCommentsPosted"]["citedRelativePathsMustStayInInclude"]:
        if cited.endswith("/"):
            if not any(p.startswith(cited) for p in include_paths):
                errors.append(f"cited directory not in include: {cited}")
        elif cited not in include_paths:
            errors.append(f"cited path not in include: {cited}")

    for banned in (
        "reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine/locked-payload.txt",
        "managed/safe-tree-delete/policy.json",
        "scripts/lib/CodexSafeTreeDelete.ps1",
        "docs/env-governance/sub2api-update-policy.md",
    ):
        if banned in include_paths or banned in staged:
            errors.append(f"forbidden path staged/included: {banned}")

    summary24 = load_json("reports/safe-tree-delete-issue24-20260816/status.summary.json")
    utf8_24 = ROOT / "reports/safe-tree-delete-issue24-20260816/status-utf8.json"
    actual_utf8 = sha256_file(utf8_24)
    if actual_utf8 != summary24["sourceStatusSha256"]:
        errors.append(
            "issue24 utf8 sha != status.summary.json sourceStatusSha256 "
            f"{actual_utf8} vs {summary24['sourceStatusSha256']}"
        )

    summary22 = load_json("reports/safe-tree-delete-issue22-20260815/status-before.summary.json")
    utf8_22 = ROOT / "reports/safe-tree-delete-issue22-20260815/status-before.utf8.json"
    actual_22 = sha256_file(utf8_22)
    if actual_22 != summary22["sourceStatusSha256"]:
        errors.append("issue22 utf8 sha != status-before.summary.json sourceStatusSha256")

    meta55 = load_json("reports/safe-tree-delete-issue55-20260816/status-zero-write.meta.json")
    bind55 = load_json("reports/safe-tree-delete-issue55-20260816/status-generation-binding.json")
    stdout55 = ROOT / "reports/safe-tree-delete-issue55-20260816/status-zero-write.stdout.txt"
    actual_55 = sha256_file(stdout55)
    if actual_55 != meta55["stdoutSha256"]:
        errors.append("issue55 stdout sha != status-zero-write.meta.json")
    if actual_55 != bind55["stdoutSha256"]:
        errors.append("issue55 stdout sha != status-generation-binding.json")

    smoke = load_json("reports/safe-tree-delete-issue55-20260816/summary.json")
    if smoke.get("wallClockSeconds") != 407.492:
        errors.append(f"unexpected smoke wallClockSeconds {smoke.get('wallClockSeconds')}")
    if smoke.get("statusOperationIdCount") != 2350:
        errors.append(f"unexpected statusOperationIdCount {smoke.get('statusOperationIdCount')}")

    leaf = load_json("reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json")
    if leaf.get("exitCode") != 1:
        errors.append("leaf-delete-failed exitCode is not 1")

    revert = load_json("reports/safe-tree-delete-issue21-20260816/revert-forwarding.json")
    if revert.get("exitCode") != 0:
        errors.append("revert-forwarding exitCode is not 0")

    must_staged = {
        "tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1",
        "reports/safe-tree-delete-issue24-20260816/status-utf8.json",
        "reports/safe-tree-delete-issue55-20260816/summary.json",
        "reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json",
        "reports/safe-tree-delete-closeout-20260816/github-comments/issue-22.md",
    }
    for rel in must_staged:
        if rel not in staged:
            errors.append(f"STAGED-FILE-LIST missing {rel}")

    if "reports/safe-tree-delete-issue24-20260816/status-raw.json" in staged:
        errors.append("raw #24 status should not be staged")
    if any("heartbeat" in x for x in staged):
        errors.append("heartbeat file staged")

    exclude_paths = {item["path"] for item in exclude["files"]}
    overlap = include_paths & exclude_paths
    if overlap:
        errors.append(f"include/exclude overlap: {sorted(overlap)[:5]}")

    if errors:
        print("FAIL")
        for e in errors:
            print(e)
        return 1
    print(
        "OK",
        f"include={len(include['files'])}",
        f"exclude_files={len(exclude['files'])}",
        f"staged={len(staged)}",
        f"issue24_utf8={actual_utf8}",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
