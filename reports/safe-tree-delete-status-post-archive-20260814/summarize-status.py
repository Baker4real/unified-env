import hashlib
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


KNOWN_V1_UNTERMINATED = {
    "20260725T010726Z-0609f165-c496-4280-85c4-6bb8a5e9465b",
    "20260725T130041Z-a5fd8743-a239-423c-9c44-4cbb5aa6a2cc",
    "20260728T162734Z-c602a5b7-34bb-4469-bf9b-2754cadc5a76",
    "20260729T055433Z-0f0aeb5d-efcc-43cb-973b-a58a9ea748d6",
    "20260730T170848Z-26f7ea53-0578-43c4-b245-9ab5304ca5d6",
}
KNOWN_HISTORICAL_V2 = "20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153"
KNOWN_PURGED_STILL_MR = {
    "20260729T074247Z-cc78cd84-21c0-4a4e-8d7a-6f2f1d1c0b91",
    "20260729T074250Z-fe0c62fd-0d3a-4c7e-9f2a-1b2c3d4e5f60",
    "20260729T074244Z-11c87c5a-9a8b-4c3d-8e2f-7a6b5c4d3e21",
    "20260729T074219Z-f91a4f79-3b2c-4d5e-8f01-2a3b4c5d6e70",
}


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
    oid = op.get("operationId")
    ts = op.get("transactionStatus")
    schema = op.get("transactionSchemaVersion")
    errors = [str(item) for item in (op.get("errors") or [])]
    joined = "\n".join(errors)
    if oid == "acl-capability-probe-20260801":
        return "missing-plan"
    if oid == KNOWN_HISTORICAL_V2 or (
        schema == 2 and ts == "quarantined" and "policy" in joined and "漂移" in joined
    ):
        return "historical-v2-quarantined"
    if schema == 1 and ts in {"prepared", "quarantined", "purging", "rolled-back"}:
        return "v1-unterminated"
    if ts == "quarantined" and "namespace" in joined:
        return "window-ui-references-quarantined-inconsistent"
    if ts == "purged":
        return "purged-still-manual-review"
    if any("不在受管 allowlist" in item for item in errors):
        return "allowlist"
    if any("tree manifest 漂移" in item or "planned tree manifest" in item for item in errors):
        return "manifest-drift"
    if any("最小" in item and "深度" in item for item in errors):
        return "min-depth"
    if any("缺少 plan.json" in item for item in errors):
        return "missing-plan"
    has_ns = any("namespace" in item for item in errors)
    has_sha = any("policy SHA" in item or "policySha" in item for item in errors)
    if has_ns and has_sha:
        return "namespace+policy-sha"
    if has_ns:
        return "planned-namespace"
    if ts is None:
        return "unparsed-other"
    return "other-residual"


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: summarize-status.py STATUS.utf8.json OUT-PREFIX")
    status_path = Path(sys.argv[1])
    out_prefix = Path(sys.argv[2])
    raw = status_path.read_bytes()
    status = json.loads(raw.decode("utf-8"))
    ops = status.get("operations") or []
    readiness = status.get("migrationReadiness") or {}
    blocking_ids = set(readiness.get("blockingRecords") or [])
    blocking = [op for op in ops if op.get("operationId") in blocking_ids]
    if len(blocking) != len(blocking_ids):
        missing = sorted(blocking_ids - {op.get("operationId") for op in ops})
        raise SystemExit(f"blockingRecords missing from operations: {missing}")

    candidates = []
    unterminated = []
    for op in ops:
        ts = op.get("transactionStatus")
        qp = op.get("quarantinePresent")
        life = op.get("lifecycle")
        schema = op.get("transactionSchemaVersion")
        if ts and ts != "purged" and life != "terminal":
            unterminated.append(compact(op))
        if ts == "purged" and qp is False and life != "terminal":
            candidates.append(op)

    v1_obs = [op for op in ops if op.get("transactionSchemaVersion") == 1]
    v1_by_status = Counter(str(op.get("transactionStatus")) for op in v1_obs)
    rebuildable = [
        op
        for op in ops
        if str(op.get("rootDeletionPurpose") or "") == "rebuildable-build-output"
    ]
    terminal_target_present = [
        op
        for op in ops
        if op.get("lifecycle") == "terminal" and op.get("targetPresent") is True
    ]

    groups: dict[str, list] = {}
    for op in blocking:
        groups.setdefault(classify_blocking(op), []).append(compact(op))

    v1_u = [item for item in unterminated if item["transactionSchemaVersion"] == 1]
    v2_u = [item for item in unterminated if item["transactionSchemaVersion"] == 2]

    summary = {
        "snapshot": True,
        "note": "live Status 摘要快照，不构成后续授权。",
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "sourceStatusPath": str(status_path),
        "sourceStatusSha256": hashlib.sha256(raw).hexdigest(),
        "sourceStatusBytes": status_path.stat().st_size,
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
        "terminalArchiveMarkerHint": sum(
            1 for op in ops if op.get("lifecycle") == "terminal"
        ),
        "candidateCount": len(candidates),
        "candidateCountDeltaFromBaseline1595": len(candidates) - 1595,
        "projectedResidualIfAllCandidatesArchive": len(blocking) - len(candidates),
        "candidatesByTransactionSchemaVersion": dict(
            Counter(str(item.get("transactionSchemaVersion")) for item in candidates)
        ),
        "operationsByLifecycle": dict(Counter(str(op.get("lifecycle")) for op in ops)),
        "operationsByPlanSchemaVersion": dict(
            Counter(str(op.get("planSchemaVersion")) for op in ops)
        ),
        "operationsByTransactionSchemaVersion": dict(
            Counter(str(op.get("transactionSchemaVersion")) for op in ops)
        ),
        "physicalReclaimStatusValues": sorted(
            {str(op.get("physicalReclaimStatus")) for op in ops}
        ),
        "unterminatedCount": len(unterminated),
        "v1UnterminatedCount": len(v1_u),
        "v2UnterminatedCount": len(v2_u),
        "v1Unterminated": v1_u,
        "v2Unterminated": v2_u,
        "v1Observability": {
            "v1RecordCount": len(v1_obs),
            "byTransactionStatus": dict(v1_by_status),
            "nullTargetPathCount": sum(
                1 for op in v1_obs if op.get("targetPath") in (None, "")
            ),
            "schemaCompatibleValues": sorted(
                {str(op.get("schemaCompatible")) for op in v1_obs}
            ),
        },
        "rebuildDiscrimination": {
            "terminalWithTargetPresentCount": len(terminal_target_present),
            "allSuchRecordsPurged": all(
                op.get("transactionStatus") == "purged" for op in terminal_target_present
            ),
            "rebuildableRootRecordCount": len(rebuildable),
            "rebuildableRootByLifecycle": dict(
                Counter(str(op.get("lifecycle")) for op in rebuildable)
            ),
        },
        "blockingByLifecycle": dict(
            Counter(str(op.get("lifecycle")) for op in blocking)
        ),
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
        "blockingClassification": {
            name: {"count": len(items), "operationIds": [item["operationId"] for item in items]}
            for name, items in sorted(groups.items(), key=lambda pair: (-len(pair[1]), pair[0]))
        },
        "knownResidualsStillVisible": {
            "v1UnterminatedVisible": sorted(KNOWN_V1_UNTERMINATED)
            == sorted(item["operationId"] for item in v1_u),
            "historicalV2Visible": any(
                item["operationId"] == KNOWN_HISTORICAL_V2 for item in v2_u
            ),
            "v1UnterminatedIdsFromStatus": [item["operationId"] for item in v1_u],
            "historicalV2FromStatus": [
                item["operationId"] for item in v2_u if item["operationId"] == KNOWN_HISTORICAL_V2
            ],
        },
    }

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
                "note": "归档后 live Status remaining blocking 分解。快照，不构成后续授权。",
                "blockingRecordCount": len(blocking),
                "missingFromOperations": [],
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
                "evaluated": summary["migrationReadinessEvaluated"],
                "operationCount": summary["operationCount"],
                "blockingRecordCount": summary["blockingRecordCount"],
                "candidateCount": summary["candidateCount"],
                "elapsedMs": (summary.get("metrics") or {}).get("elapsedMs"),
                "entriesScanned": (summary.get("metrics") or {}).get("entriesScanned"),
                "bytesHashed": (summary.get("metrics") or {}).get("bytesHashed"),
                "v1UnterminatedCount": summary["v1UnterminatedCount"],
                "v2UnterminatedCount": summary["v2UnterminatedCount"],
                "v1UnterminatedVisible": summary["knownResidualsStillVisible"][
                    "v1UnterminatedVisible"
                ],
                "historicalV2Visible": summary["knownResidualsStillVisible"][
                    "historicalV2Visible"
                ],
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
