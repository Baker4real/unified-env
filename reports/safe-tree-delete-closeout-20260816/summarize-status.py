#!/usr/bin/env python3
"""Summarize a production Status JSON snapshot."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "status-raw.utf8.json"
OUT = ROOT / "status-summary.json"


def main() -> None:
    raw = RAW.read_bytes()
    doc = json.loads(raw.decode("utf-8-sig"))
    ops = list(doc.get("operations") or [])
    readiness = doc.get("migrationReadiness") or {}
    blocking_ids = list(readiness.get("blockingRecords") or [])
    blocking_id_set = set(blocking_ids)
    blocking_ops = [op for op in ops if op.get("operationId") in blocking_id_set]
    archive_candidates = [
        {
            "operationId": op.get("operationId"),
            "lifecycle": op.get("lifecycle"),
            "transactionStatus": op.get("transactionStatus"),
            "journalStatus": op.get("journalStatus"),
            "targetPath": op.get("targetPath"),
        }
        for op in ops
        if op.get("transactionStatus") == "purged"
        and op.get("quarantinePresent") is False
        and op.get("lifecycle") != "terminal"
    ]
    non_terminal = [op for op in ops if op.get("lifecycle") != "terminal"]
    summary = {
        "artifactType": "unified-environment.safe-tree-delete.closeout-20260816.status-summary",
        "schemaVersion": 1,
        "capturedAtUtc": doc.get("capturedAtUtc"),
        "complete": doc.get("complete"),
        "operationCount": len(ops),
        "blockingRecordCount": len(blocking_ids),
        "nonTerminalCount": len(non_terminal),
        "archiveCandidateCount": len(archive_candidates),
        "migrationReadiness": {
            "evaluated": readiness.get("evaluated"),
            "ready": readiness.get("ready"),
            "blockingRecordCount": len(blocking_ids),
        },
        "lifecycleCounts": dict(Counter(str(op.get("lifecycle")) for op in ops)),
        "transactionStatusCounts": dict(Counter(str(op.get("transactionStatus")) for op in ops)),
        "journalStatusCounts": dict(Counter(str(op.get("journalStatus")) for op in ops)),
        "schemaCompatibleCounts": dict(Counter(str(op.get("schemaCompatible")) for op in ops)),
        "policyCompatibleCounts": dict(Counter(str(op.get("policyCompatible")) for op in ops)),
        "blockingLifecycles": dict(Counter(str(op.get("lifecycle")) for op in blocking_ops)),
        "blockingTransactionStatus": dict(Counter(str(op.get("transactionStatus")) for op in blocking_ops)),
        "blockingMissingLeafHints": [
            {
                "operationId": op.get("operationId"),
                "lifecycle": op.get("lifecycle"),
                "transactionStatus": op.get("transactionStatus"),
                "targetPath": op.get("targetPath"),
                "errors": list(op.get("errors") or [])[:3],
            }
            for op in blocking_ops
            if any("leafStreamSet" in str(err) or "stream-set" in str(err).lower() for err in (op.get("errors") or []))
        ],
        "archiveCandidates": archive_candidates,
        "topLevelKeys": sorted(doc.keys()),
    }
    OUT.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: summary[k] for k in summary if k != "blockingMissingLeafHints"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
