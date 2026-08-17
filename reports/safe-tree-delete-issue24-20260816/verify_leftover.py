"""Verify leftover 0ab1e1b6 transaction SHA-256 without writing."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

EXPECTED_TRANSACTION_SHA256 = "4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7"
DEFAULT_TRANSACTION_PATH = (
    r"D:\Codex\.codex\run-evidence\safe-tree-delete"
    r"\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json"
)
DEFAULT_QUARANTINE_PATH = (
    r"D:\Codex\projects\统一环境\reports"
    r"\.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine"
)


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(path: Path, expected: str, quarantine_path: Path | None = None) -> dict:
    sha256 = hash_file(path)
    quarantine_exists = None
    if quarantine_path is not None:
        quarantine_exists = quarantine_path.exists()
    matches = path.exists() and sha256.lower() == expected.lower()
    quarantine_ok = True if quarantine_path is None else bool(quarantine_exists)
    return {
        "path": str(path),
        "exists": path.exists(),
        "sha256": sha256,
        "expected": expected,
        "matches": matches,
        "quarantinePath": None if quarantine_path is None else str(quarantine_path),
        "quarantineExists": quarantine_exists,
        "ok": matches and quarantine_ok,
    }


def main() -> int:
    if len(sys.argv) not in {2, 3, 4}:
        raise SystemExit(
            "usage: verify_leftover.py OUT.json [TRANSACTION.json] [QUARANTINE-DIR]"
        )
    out = Path(sys.argv[1])
    transaction = Path(sys.argv[2] if len(sys.argv) >= 3 else DEFAULT_TRANSACTION_PATH)
    quarantine = Path(sys.argv[3] if len(sys.argv) >= 4 else DEFAULT_QUARANTINE_PATH)
    payload = verify(transaction, EXPECTED_TRANSACTION_SHA256, quarantine)
    payload["snapshot"] = True
    payload["note"] = "leftover 0ab1e1b6 只读核验。禁止 Purge/Restore。"
    out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(json.dumps({"ok": payload["ok"], "sha256": payload["sha256"]}, ensure_ascii=False))
    if not payload["ok"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
