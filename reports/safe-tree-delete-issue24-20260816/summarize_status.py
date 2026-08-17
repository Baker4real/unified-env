"""Recompute live Status blocking groups. Counts come from the given JSON only."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

LEFTOVER_OPERATION_ID = "20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e"
HISTORICAL_V2_OPERATION_ID = "20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153"
SMOKE_STARTED_UTC = datetime(2026, 8, 16, 13, 37, 1, tzinfo=timezone.utc)
V1_UNTERMINATED_STATUSES = {"prepared", "quarantined", "purging", "rolled-back"}
OPERATION_TS_RE = re.compile(r"^(\d{8}T\d{6}Z)")
BASELINE_V1_UNTERMINATED_PATHS = (
    r"D:\Codex\projects\时钟倒计时\src\MinminCountdown.Verification\bin",
    r"D:\Codex\projects\时钟倒计时\src\MinminCountdown.Core\bin",
    r"D:\Codex\projects\时钟倒计时\src\MinminCountdown\bin",
    r"D:\Codex\projects\时钟倒计时\app",
    r"D:\Codex\projects\统一环境\reports\safe-tree-delete-batch-smoke-d77a341ca599407f82af77a64d7f6253\old-a",
)


def parse_operation_timestamp(operation_id: str | None) -> datetime | None:
    if not operation_id:
        return None
    match = OPERATION_TS_RE.match(str(operation_id))
    if not match:
        return None
    return datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


def compact(op: dict) -> dict:
    return {
        "operationId": op.get("operationId"),
        "lifecycle": op.get("lifecycle"),
        "transactionStatus": op.get("transactionStatus"),
        "transactionSchemaVersion": op.get("transactionSchemaVersion"),
        "planSchemaVersion": op.get("planSchemaVersion"),
        "targetPath": op.get("targetPath"),
        "targetPresent": op.get("targetPresent"),
        "quarantinePresent": op.get("quarantinePresent"),
        "schemaCompatible": op.get("schemaCompatible"),
        "policyCompatible": op.get("policyCompatible"),
        "errors": op.get("errors") or [],
    }


def error_key(errors: list) -> tuple:
    return tuple(str(item) for item in (errors or []))


def classify_blocking(op: dict) -> str:
    oid = str(op.get("operationId") or "")
    ts = op.get("transactionStatus")
    schema = op.get("transactionSchemaVersion")
    errors = [str(item) for item in (op.get("errors") or [])]
    stamp = parse_operation_timestamp(oid)

    if oid == LEFTOVER_OPERATION_ID or "0ab1e1b6" in oid:
        return "leftover-v2-purging"
    if stamp is not None and stamp >= SMOKE_STARTED_UTC:
        return "smoke-new"
    if schema == 1 and ts in V1_UNTERMINATED_STATUSES:
        return "v1-unterminated"
    if oid == HISTORICAL_V2_OPERATION_ID:
        return "historical-v2-unterminated"
    if any("缺少 plan.json" in item for item in errors):
        return "missing-plan"
    if schema is None and ts is None:
        return "plan-only-both-null"
    if ts == "purged":
        return "purged-manual-review"
    if any("不在受管 allowlist" in item for item in errors):
        return "allowlist"
    if any("tree manifest 漂移" in item or "planned tree manifest" in item for item in errors):
        return "manifest-drift"
    if any("最小" in item and "深度" in item for item in errors):
        return "min-depth"
    has_ns = any("namespace" in item for item in errors)
    has_sha = any("policy SHA" in item or "policySha" in item for item in errors)
    if has_ns and has_sha:
        return "namespace+policy-sha"
    if has_ns:
        return "planned-namespace"
    if schema == 2 and ts in V1_UNTERMINATED_STATUSES:
        return "other-v2-unterminated"
    return "other-residual"


def classify_groups(ops: list[dict]) -> dict:
    groups: dict[str, list] = {}
    for op in ops:
        groups.setdefault(classify_blocking(op), []).append(compact(op))
    return {
        name: {
            "count": len(items),
            "operationIds": [item["operationId"] for item in items],
        }
        for name, items in sorted(groups.items(), key=lambda pair: (-len(pair[1]), pair[0]))
    }


def summarize(status: dict, source_path: str, source_sha256: str, source_bytes: int) -> dict:
    ops = status.get("operations") or []
    readiness = status.get("migrationReadiness") or {}
    blocking_ids = list(readiness.get("blockingRecords") or [])
    blocking_id_set = set(blocking_ids)
    blocking = [op for op in ops if op.get("operationId") in blocking_id_set]
    if len(blocking) != len(blocking_id_set):
        missing = sorted(blocking_id_set - {op.get("operationId") for op in ops})
        raise ValueError(f"blockingRecords missing from operations: {missing}")

    unterminated = []
    for op in ops:
        ts = op.get("transactionStatus")
        life = op.get("lifecycle")
        if ts and ts != "purged" and life != "terminal":
            unterminated.append(compact(op))

    v1_u = [item for item in unterminated if item["transactionSchemaVersion"] == 1]
    v2_u = [item for item in unterminated if item["transactionSchemaVersion"] == 2]
    leftover_ops = [
        compact(op)
        for op in ops
        if op.get("operationId") == LEFTOVER_OPERATION_ID or "0ab1e1b6" in str(op.get("operationId") or "")
    ]
    historical_v2 = [
        item for item in v2_u if item["operationId"] == HISTORICAL_V2_OPERATION_ID
    ]
    v1_by_path = {
        item["targetPath"]: item["operationId"]
        for item in v1_u
        if item.get("targetPath")
    }
    both_null = [
        compact(op)
        for op in blocking
        if op.get("transactionSchemaVersion") is None and op.get("transactionStatus") is None
    ]
    classification = classify_groups(blocking)
    class_sum = sum(item["count"] for item in classification.values())
    if class_sum != len(blocking):
        raise ValueError(f"classification sum {class_sum} != blocking {len(blocking)}")

    return {
        "snapshot": True,
        "note": "live Status 摘要。计数只来自本次 JSON，不构成后续授权。",
        "sourceStatusPath": source_path,
        "sourceStatusSha256": source_sha256,
        "sourceStatusBytes": source_bytes,
        "artifactType": status.get("artifactType"),
        "schemaVersion": status.get("schemaVersion"),
        "statusCapturedAtUtc": status.get("capturedAtUtc"),
        "complete": status.get("complete"),
        "policySchemaVersion": status.get("policySchemaVersion"),
        "policySha256": status.get("policySha256"),
        "policyPath": status.get("policyPath"),
        "metrics": status.get("metrics"),
        "migrationReadinessEvaluated": readiness.get("evaluated"),
        "migrationReadinessReady": readiness.get("ready"),
        "operationCount": len(ops),
        "blockingRecordCount": len(blocking),
        "terminalArchiveMarkerHint": sum(1 for op in ops if op.get("lifecycle") == "terminal"),
        "operationsByLifecycle": dict(Counter(str(op.get("lifecycle")) for op in ops)),
        "operationsByPlanSchemaVersion": dict(
            Counter(str(op.get("planSchemaVersion")) for op in ops)
        ),
        "operationsByTransactionSchemaVersion": dict(
            Counter(str(op.get("transactionSchemaVersion")) for op in ops)
        ),
        "blockingByLifecycle": dict(Counter(str(op.get("lifecycle")) for op in blocking)),
        "blockingByTransactionSchemaVersion": dict(
            Counter(str(op.get("transactionSchemaVersion")) for op in blocking)
        ),
        "blockingByTransactionStatus": dict(
            Counter(str(op.get("transactionStatus")) for op in blocking)
        ),
        "blockingByErrorKey": [
            {"count": count, "errors": list(key)}
            for key, count in Counter(error_key(op.get("errors") or []) for op in blocking).most_common()
        ],
        "blockingClassification": classification,
        "classificationSumEqualsBlocking": class_sum == len(blocking),
        "unterminatedCount": len(unterminated),
        "v1UnterminatedCount": len(v1_u),
        "v2UnterminatedCount": len(v2_u),
        "v1Unterminated": v1_u,
        "v2Unterminated": v2_u,
        "leftover0ab1e1b6": leftover_ops,
        "historicalV2Unterminated": historical_v2,
        "planOnlyBothNullCount": len(both_null),
        "knownResidualsStillVisible": {
            "v1UnterminatedCount": len(v1_u),
            "v1UnterminatedIds": [item["operationId"] for item in v1_u],
            "v1BaselinePathsMatched": [
                path for path in BASELINE_V1_UNTERMINATED_PATHS if path in v1_by_path
            ],
            "v1BaselinePathToOperationId": {
                path: v1_by_path[path]
                for path in BASELINE_V1_UNTERMINATED_PATHS
                if path in v1_by_path
            },
            "historicalV2Visible": any(
                item["operationId"] == HISTORICAL_V2_OPERATION_ID for item in v2_u
            ),
            "historicalV2OperationId": HISTORICAL_V2_OPERATION_ID
            if any(item["operationId"] == HISTORICAL_V2_OPERATION_ID for item in v2_u)
            else None,
            "leftoverVisible": any(
                item["operationId"] == LEFTOVER_OPERATION_ID for item in leftover_ops
            ),
            "leftoverOperationId": LEFTOVER_OPERATION_ID,
        },
    }


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: summarize_status.py STATUS.utf8.json OUT-PREFIX")
    status_path = Path(sys.argv[1])
    out_prefix = Path(sys.argv[2])
    raw = status_path.read_bytes()
    status = json.loads(raw.decode("utf-8"))
    summary = summarize(
        status,
        source_path=str(status_path),
        source_sha256=hashlib.sha256(raw).hexdigest(),
        source_bytes=len(raw),
    )
    summary["capturedAtUtc"] = datetime.now(timezone.utc).isoformat()
    blocking_ids = set((status.get("migrationReadiness") or {}).get("blockingRecords") or [])
    blocking = [op for op in (status.get("operations") or []) if op.get("operationId") in blocking_ids]
    summary_path = Path(str(out_prefix) + ".summary.json")
    blocking_path = Path(str(out_prefix) + ".remaining-blocking.json")
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    blocking_path.write_text(
        json.dumps(
            {
                "snapshot": True,
                "note": "本次 live Status remaining blocking 分解。快照，不构成后续授权。",
                "blockingRecordCount": len(blocking),
                "byLifecycle": summary["blockingByLifecycle"],
                "byTransactionSchemaVersion": summary["blockingByTransactionSchemaVersion"],
                "byTransactionStatus": summary["blockingByTransactionStatus"],
                "byClassification": summary["blockingClassification"],
                "records": [compact(op) for op in blocking],
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(
        json.dumps(
            {
                "complete": summary["complete"],
                "ready": summary["migrationReadinessReady"],
                "operationCount": summary["operationCount"],
                "blockingRecordCount": summary["blockingRecordCount"],
                "elapsedMs": (summary.get("metrics") or {}).get("elapsedMs"),
                "v1UnterminatedCount": summary["v1UnterminatedCount"],
                "historicalV2Visible": summary["knownResidualsStillVisible"]["historicalV2Visible"],
                "leftoverVisible": summary["knownResidualsStillVisible"]["leftoverVisible"],
                "classificationCounts": {
                    name: payload["count"]
                    for name, payload in summary["blockingClassification"].items()
                },
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
