"""One-shot live Status inspector. Reads status-utf8.json; does not write production state."""

from __future__ import annotations

import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATUS_PATH = ROOT / "status-utf8.json"
LEFTOVER_ID = "20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e"
HIST_ID = "20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153"
SMOKE_START = datetime(2026, 8, 16, 13, 37, 1, tzinfo=timezone.utc)
KEYS = [
    "operationId",
    "lifecycle",
    "transactionStatus",
    "transactionSchemaVersion",
    "planSchemaVersion",
    "targetPath",
    "targetPresent",
    "quarantinePresent",
    "schemaCompatible",
    "policyCompatible",
    "nextActions",
    "errors",
]


def compact(op: dict) -> dict:
    return {key: op.get(key) for key in KEYS}


def parse_ts(oid: str | None):
    if not oid or len(oid) < 16 or oid[8] != "T":
        return None
    try:
        return datetime.strptime(oid[:16], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def main() -> int:
    status = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
    ops = status["operations"]
    ready = status["migrationReadiness"]
    blocking = set(ready["blockingRecords"])
    by_id = {op["operationId"]: op for op in ops}
    leftover = by_id.get(LEFTOVER_ID)
    hist = by_id.get(HIST_ID)
    v1_u = [
        op
        for op in ops
        if op.get("transactionSchemaVersion") == 1
        and op.get("transactionStatus") in {"prepared", "quarantined", "purging", "rolled-back"}
    ]
    smoke = [
        op
        for op in ops
        if (stamp := parse_ts(op.get("operationId"))) is not None and stamp >= SMOKE_START
    ]
    non_term = [op for op in ops if op.get("lifecycle") != "terminal"]
    both_null = [
        op
        for op in ops
        if op.get("transactionSchemaVersion") is None and op.get("transactionStatus") is None
    ]
    purged_mr = [
        op
        for op in ops
        if op.get("transactionStatus") == "purged" and op.get("lifecycle") == "manual-review"
    ]
    payload = {
        "complete": status["complete"],
        "ready": ready["ready"],
        "evaluated": ready["evaluated"],
        "policySchemaVersion": status["policySchemaVersion"],
        "policySha256": status["policySha256"],
        "capturedAtUtc": status["capturedAtUtc"],
        "metrics": status["metrics"],
        "operationCount": len(ops),
        "blockingCount": len(blocking),
        "leftoverPresent": leftover is not None,
        "leftoverInBlocking": LEFTOVER_ID in blocking,
        "leftover": compact(leftover) if leftover else None,
        "historicalV2Present": hist is not None,
        "historicalV2InBlocking": HIST_ID in blocking,
        "historicalV2": compact(hist) if hist else None,
        "v1Unterminated": [compact(op) for op in v1_u],
        "v1UnterminatedIdsInBlocking": [
            op["operationId"] for op in v1_u if op["operationId"] in blocking
        ],
        "smokeCount": len(smoke),
        "smoke": [{**compact(op), "inBlocking": op["operationId"] in blocking} for op in smoke],
        "nonTerminalLifecycle": dict(Counter(str(op.get("lifecycle")) for op in non_term)),
        "nonTerminalNotBlocking": [
            compact(op) for op in non_term if op["operationId"] not in blocking
        ],
        "bothNullAll": len(both_null),
        "bothNullBlocking": sum(1 for op in both_null if op["operationId"] in blocking),
        "purgedManualReviewAll": len(purged_mr),
        "purgedManualReviewBlocking": sum(
            1 for op in purged_mr if op["operationId"] in blocking
        ),
        "lifecycleSum": 2244 + 87 + 23 + 1 + 1,
    }
    out = ROOT / "live-inspect.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"out": str(out), "leftoverLifecycle": None if leftover is None else leftover.get("lifecycle"), "leftoverInBlocking": LEFTOVER_ID in blocking, "smokeCount": len(smoke), "nonTerminalNotBlocking": [op.get("operationId") for op in non_term if op["operationId"] not in blocking]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
