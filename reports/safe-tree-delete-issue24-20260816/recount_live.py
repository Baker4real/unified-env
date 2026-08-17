"""Independent recount of live Status JSON. Does not trust summarize_status.py."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
status = json.loads((ROOT / "status-utf8.json").read_text(encoding="utf-8"))
ops = status["operations"]
blocking_ids = list(status["migrationReadiness"]["blockingRecords"])
blocking_set = set(blocking_ids)
blocking = [op for op in ops if op["operationId"] in blocking_set]
both_null = [
    op
    for op in blocking
    if op.get("transactionSchemaVersion") is None and op.get("transactionStatus") is None
]


def err_key(op):
    return tuple(op.get("errors") or [])


payload = {
    "complete": status["complete"],
    "ready": status["migrationReadiness"]["ready"],
    "operations": len(ops),
    "blocking": len(blocking),
    "blockingIdsUnique": len(blocking_set),
    "lifecycleAll": dict(Counter(str(op.get("lifecycle")) for op in ops)),
    "lifecycleBlocking": dict(Counter(str(op.get("lifecycle")) for op in blocking)),
    "bothNullBlocking": len(both_null),
    "bothNullErrorKeys": [
        {"count": count, "errors": list(key)}
        for key, count in Counter(err_key(op) for op in both_null).most_common()
    ],
    "purgedBlocking": sum(1 for op in blocking if op.get("transactionStatus") == "purged"),
    "aclInBlocking": any(op.get("operationId") == "acl-capability-probe-20260801" for op in blocking),
    "formula": {
        "opsEqualsLifecycleSum": len(ops)
        == sum(Counter(str(op.get("lifecycle")) for op in ops).values()),
        "blockingEqualsMrPlusInconsistent": len(blocking)
        == sum(1 for op in blocking if op.get("lifecycle") in {"manual-review", "inconsistent"}),
    },
}
(ROOT / "live-recount.json").write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print(json.dumps(payload, ensure_ascii=False, indent=2))
