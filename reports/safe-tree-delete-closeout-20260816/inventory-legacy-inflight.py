#!/usr/bin/env python3
"""Read-only inventory of evidence runs missing leafStreamSetV1 or still in-flight."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

EVIDENCE = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")
OUT = Path(__file__).resolve().parent / "legacy-inflight-inventory.json"


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        return {"_readError": str(exc)}


def main() -> None:
    runs = []
    for run in sorted(p for p in EVIDENCE.iterdir() if p.is_dir()):
        plan_path = run / "plan.json"
        tx_path = run / "transaction.json"
        archive_path = run / "terminal-archive.json"
        rec = {
            "operationId": run.name,
            "planExists": plan_path.is_file(),
            "transactionExists": tx_path.is_file(),
            "archiveExists": archive_path.is_file(),
        }
        if plan_path.is_file():
            plan = load_json(plan_path)
            rec["planSchemaVersion"] = plan.get("schemaVersion")
            rec["policyEntryId"] = plan.get("policyEntryId")
            rec["targetPath"] = plan.get("targetPath")
            rec["hasLeafStreamSetV1"] = isinstance(plan.get("leafStreamSetV1"), dict)
            rec["planReadError"] = plan.get("_readError")
        if tx_path.is_file():
            tx = load_json(tx_path)
            rec["transactionSchemaVersion"] = tx.get("schemaVersion")
            rec["transactionStatus"] = tx.get("status")
            rec["quarantinePath"] = tx.get("quarantinePath")
            rec["transactionReadError"] = tx.get("_readError")
        runs.append(rec)

    missing_stream = [
        r
        for r in runs
        if r.get("planExists")
        and not r.get("hasLeafStreamSetV1")
        and r.get("transactionStatus") not in (None, "purged", "restored", "rolled-back")
        and not r.get("archiveExists")
    ]
    inflight = [
        r
        for r in runs
        if r.get("transactionStatus") in ("prepared", "quarantined", "purging", "applying")
    ]
    missing_any_nonterminal = [
        r
        for r in runs
        if r.get("planExists")
        and not r.get("hasLeafStreamSetV1")
        and r.get("transactionStatus") not in ("purged", "restored", "rolled-back")
    ]

    document = {
        "artifactType": "unified-environment.safe-tree-delete.closeout-20260816.legacy-inflight-inventory",
        "schemaVersion": 1,
        "evidenceRoot": str(EVIDENCE),
        "runCount": len(runs),
        "transactionStatusCounts": dict(Counter(r.get("transactionStatus") or "<none>" for r in runs)),
        "missingLeafStreamSetV1InflightCount": len(missing_stream),
        "missingLeafStreamSetV1NonTerminalCount": len(missing_any_nonterminal),
        "inflightCount": len(inflight),
        "missingLeafStreamSetV1Inflight": missing_stream,
        "inflight": inflight,
        "note": "只读盘点。不是 Restore/Purge/Archive 授权。",
    }
    OUT.write_text(json.dumps(document, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "runCount": document["runCount"],
        "inflightCount": document["inflightCount"],
        "missingLeafStreamSetV1InflightCount": document["missingLeafStreamSetV1InflightCount"],
        "missingLeafStreamSetV1NonTerminalCount": document["missingLeafStreamSetV1NonTerminalCount"],
        "transactionStatusCounts": document["transactionStatusCounts"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
