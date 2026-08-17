import hashlib
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


HISTORICAL_V1_UNTERMINATED = (
    "20260725T010726Z-0609f165-c496-4280-85c4-6bb8a5e9465b",
    "20260725T130041Z-a5fd8743-a239-423c-9c44-4cbb5aa6a2cc",
    "20260728T162734Z-c602a5b7-34bb-4469-bf9b-2754cadc5a76",
    "20260729T055433Z-0f0aeb5d-efcc-43cb-973b-a58a9ea748d6",
    "20260730T170848Z-26f7ea53-0578-43c4-b245-9ab5304ca5d6",
)
HISTORICAL_V2_UNTERMINATED = "20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153"


def compact(op: dict) -> dict:
    return {
        "operationId": op.get("operationId"),
        "runDirectory": op.get("runDirectory"),
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


def is_archive_candidate(op: dict) -> bool:
    return (
        op.get("transactionStatus") == "purged"
        and op.get("quarantinePresent") is False
        and op.get("lifecycle") != "terminal"
    )


def decode_status_bytes(raw: bytes) -> tuple[str, str]:
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16"), "utf-16"
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw.decode("utf-8-sig"), "utf-8-sig"
    try:
        return raw.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return raw.decode("gb18030"), "gb18030"


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: summarize-status.py STATUS.json OUT-PREFIX")
    status_path = Path(sys.argv[1])
    out_prefix = Path(sys.argv[2])
    raw = status_path.read_bytes()
    decoded_text, decoded_as = decode_status_bytes(raw)
    status = json.loads(decoded_text)
    ops = status.get("operations") or []
    readiness = status.get("migrationReadiness") or {}
    blocking_ids = [str(item) for item in (readiness.get("blockingRecords") or [])]
    blocking_id_set = set(blocking_ids)
    ops_by_id = {str(op.get("operationId")): op for op in ops}
    missing_blocking = sorted(blocking_id_set - set(ops_by_id))
    blocking = [ops_by_id[oid] for oid in blocking_ids if oid in ops_by_id]

    candidates = [op for op in ops if is_archive_candidate(op)]
    unterminated = [
        op
        for op in ops
        if op.get("transactionStatus")
        and op.get("transactionStatus") != "purged"
        and op.get("lifecycle") != "terminal"
    ]
    v1_unterminated = [
        op
        for op in unterminated
        if op.get("transactionSchemaVersion") == 1
    ]
    v2_unterminated = [
        op
        for op in unterminated
        if op.get("transactionSchemaVersion") == 2
    ]

    classification = Counter()
    for op in blocking:
        classification[str(op.get("lifecycle") or "None")] += 1

    summary = {
        "snapshot": True,
        "note": "由本次 live Status 推导，不复用 #19 / 20260814 快照，不构成后续授权。",
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "sourceStatusPath": str(status_path),
        "sourceStatusSha256": hashlib.sha256(raw).hexdigest(),
        "sourceStatusBytes": len(raw),
        "sourceStatusDecodedAs": decoded_as,
        "artifactType": status.get("artifactType"),
        "schemaVersion": status.get("schemaVersion"),
        "statusCapturedAtUtc": status.get("capturedAtUtc"),
        "complete": bool(status.get("complete")),
        "policySchemaVersion": status.get("policySchemaVersion"),
        "policySha256": status.get("policySha256"),
        "policyPath": status.get("policyPath"),
        "metrics": status.get("metrics"),
        "migrationReadinessEvaluated": readiness.get("evaluated"),
        "migrationReadinessReady": readiness.get("ready"),
        "operationCount": len(ops),
        "blockingRecordCount": len(blocking_ids),
        "missingBlockingFromOperations": missing_blocking,
        "candidateCount": len(candidates),
        "historicalIssue19CandidateCount": 1595,
        "historicalIssue19BlockingAfterArchive": 79,
        "historical20260814Archived": 2191,
        "historical20260814Blocking": 109,
        "candidateCountDeltaFromIssue19": len(candidates) - 1595,
        "blockingDeltaFromIssue19Residual": len(blocking_ids) - 79,
        "blockingDeltaFrom20260814": len(blocking_ids) - 109,
        "operationsByLifecycle": dict(Counter(str(op.get("lifecycle")) for op in ops)),
        "operationsByTransactionSchemaVersion": dict(
            Counter(str(op.get("transactionSchemaVersion")) for op in ops)
        ),
        "operationsByTransactionStatus": dict(
            Counter(str(op.get("transactionStatus")) for op in ops)
        ),
        "blockingByLifecycle": dict(classification),
        "blockingByTransactionStatus": dict(
            Counter(str(op.get("transactionStatus")) for op in blocking)
        ),
        "blockingByTransactionSchemaVersion": dict(
            Counter(str(op.get("transactionSchemaVersion")) for op in blocking)
        ),
        "unterminatedCount": len(unterminated),
        "v1UnterminatedCount": len(v1_unterminated),
        "v2UnterminatedCount": len(v2_unterminated),
        "v1Unterminated": [compact(op) for op in v1_unterminated],
        "v2Unterminated": [compact(op) for op in v2_unterminated],
        "historicalResidualsStillVisible": {
            "v1UnterminatedIds": list(HISTORICAL_V1_UNTERMINATED),
            "v1UnterminatedVisible": all(
                oid in ops_by_id for oid in HISTORICAL_V1_UNTERMINATED
            ),
            "v1UnterminatedMissing": [
                oid for oid in HISTORICAL_V1_UNTERMINATED if oid not in ops_by_id
            ],
            "historicalV2Id": HISTORICAL_V2_UNTERMINATED,
            "historicalV2Visible": HISTORICAL_V2_UNTERMINATED in ops_by_id,
            "historicalV2StillUnterminated": any(
                str(op.get("operationId")) == HISTORICAL_V2_UNTERMINATED
                for op in v2_unterminated
            ),
        },
        "candidateOperationIds": [op.get("operationId") for op in candidates],
    }
    candidates_document = {
        "snapshot": True,
        "note": "由本次 live Status 推导的归档候选；每条 Archive 必须现场重算 transaction SHA-256。",
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "sourceStatusPath": str(status_path),
        "sourceStatusSha256": hashlib.sha256(raw).hexdigest(),
        "liveCandidateCount": len(candidates),
        "blockingRecordCount": len(blocking_ids),
        "statusComplete": bool(status.get("complete")),
        "statusPolicySchemaVersion": status.get("policySchemaVersion"),
        "candidates": [
            {
                **compact(op),
                "transactionPath": str(Path(str(op.get("runDirectory") or "")) / "transaction.json"),
            }
            for op in candidates
        ],
    }
    remaining = {
        "snapshot": True,
        "note": "本次 Status 的 blocking 记录摘要。",
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "blockingRecordCount": len(blocking_ids),
        "blocking": [compact(op) for op in blocking],
    }

    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    (out_prefix.with_suffix(".summary.json")).write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    (out_prefix.with_suffix(".candidates.json")).write_text(
        json.dumps(candidates_document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    (out_prefix.with_suffix(".remaining-blocking.json")).write_text(
        json.dumps(remaining, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(
        json.dumps(
            {
                "complete": summary["complete"],
                "operationCount": summary["operationCount"],
                "blockingRecordCount": summary["blockingRecordCount"],
                "candidateCount": summary["candidateCount"],
                "v1UnterminatedCount": summary["v1UnterminatedCount"],
                "v2UnterminatedCount": summary["v2UnterminatedCount"],
                "policySchemaVersion": summary["policySchemaVersion"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
