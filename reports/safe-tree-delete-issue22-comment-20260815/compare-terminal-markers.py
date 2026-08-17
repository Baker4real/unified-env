# -*- coding: utf-8 -*-
"""Read-only compare of Status lifecycle=terminal vs disk terminal-archive.json."""
from __future__ import annotations

import hashlib
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

STATUS_PATH = Path(
    r"D:\Codex\projects\统一环境\reports\safe-tree-delete-issue22-20260815\status-before.utf8.json"
)
SUMMARY_PATH = Path(
    r"D:\Codex\projects\统一环境\reports\safe-tree-delete-issue22-20260815\status-before.summary.json"
)
EVIDENCE_ROOT = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")
OUT_DIR = Path(
    r"D:\Codex\projects\统一环境\reports\safe-tree-delete-issue22-comment-20260815"
)

COMPACT_KEYS = (
    "operationId",
    "lifecycle",
    "journalStatus",
    "transactionStatus",
    "transactionSchemaVersion",
    "planSchemaVersion",
    "targetPath",
    "targetPresent",
    "targetEntryType",
    "quarantinePath",
    "quarantinePresent",
    "quarantineEntryType",
    "namespaceAbsent",
    "logicalCompletion",
    "physicalReclaimStatus",
    "physicalReclaimReason",
    "policyCompatible",
    "schemaCompatible",
    "candidatePolicyCompatible",
    "safeActions",
    "errors",
    "runDirectory",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compact(op: dict) -> dict:
    return {key: op.get(key) for key in COMPACT_KEYS}


def read_json_if_present(path: Path) -> tuple[object | None, str | None]:
    if not path.is_file():
        return None, "absent"
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except UnicodeDecodeError:
        return json.loads(path.read_text(encoding="utf-8-sig")), None
    except Exception as exc:  # noqa: BLE001 - classify later from raw
        return None, f"{type(exc).__name__}: {exc}"


def marker_summary(path: Path) -> dict:
    payload, error = read_json_if_present(path)
    if error:
        return {"path": str(path), "readable": False, "error": error}
    if not isinstance(payload, dict):
        return {
            "path": str(path),
            "readable": False,
            "error": f"unexpected-type:{type(payload).__name__}",
        }
    return {
        "path": str(path),
        "readable": True,
        "artifactType": payload.get("artifactType"),
        "schemaVersion": payload.get("schemaVersion"),
        "generationId": payload.get("generationId"),
        "transactionStatus": payload.get("transactionStatus"),
        "transactionSchemaVersion": payload.get("transactionSchemaVersion"),
        "transactionUpdatedAtUtc": payload.get("transactionUpdatedAtUtc"),
        "targetPath": payload.get("targetPath"),
        "quarantinePath": payload.get("quarantinePath"),
        "quarantineAbsent": payload.get("quarantineAbsent"),
        "restoreJournalAnchorCount": payload.get("restoreJournalAnchorCount"),
        "archivedAtUtc": payload.get("archivedAtUtc"),
    }


def transaction_summary(run_dir: Path) -> dict:
    path = run_dir / "transaction.json"
    payload, error = read_json_if_present(path)
    if error:
        return {"path": str(path), "present": path.is_file(), "readable": False, "error": error}
    if not isinstance(payload, dict):
        return {
            "path": str(path),
            "present": True,
            "readable": False,
            "error": f"unexpected-type:{type(payload).__name__}",
        }
    return {
        "path": str(path),
        "present": True,
        "readable": True,
        "schemaVersion": payload.get("schemaVersion"),
        "status": payload.get("status"),
        "updatedAtUtc": payload.get("updatedAtUtc"),
        "targetPath": payload.get("targetPath"),
        "generationId": payload.get("generationId"),
    }


def plan_summary(run_dir: Path) -> dict:
    path = run_dir / "plan.json"
    payload, error = read_json_if_present(path)
    if error:
        return {"path": str(path), "present": path.is_file(), "readable": False, "error": error}
    if not isinstance(payload, dict):
        return {
            "path": str(path),
            "present": True,
            "readable": False,
            "error": f"unexpected-type:{type(payload).__name__}",
        }
    target = payload.get("target") if isinstance(payload.get("target"), dict) else {}
    return {
        "path": str(path),
        "present": True,
        "readable": True,
        "schemaVersion": payload.get("schemaVersion"),
        "generationId": payload.get("generationId"),
        "targetPath": payload.get("targetPath"),
        "policyEntryId": payload.get("policyEntryId") or target.get("policyEntryId"),
        "rootDeletionPurpose": target.get("rootDeletionPurpose"),
        "capabilityRoot": target.get("capabilityRoot"),
    }


def classify_terminal_without_marker(op: dict, txn: dict, plan: dict) -> dict:
    txn_status = op.get("transactionStatus")
    journal = op.get("journalStatus")
    errors = op.get("errors") or []
    purpose = plan.get("rootDeletionPurpose") if plan.get("readable") else None
    if txn_status == "purged" and journal in {"complete", "not-applicable"}:
        if purpose == "rebuildable-build-output" and op.get("targetPresent") is True:
            bucket = "live-purged-rebuildable-target-present"
        elif purpose == "rebuildable-build-output":
            bucket = "live-purged-rebuildable"
        elif journal == "complete":
            bucket = "live-purged-journal-complete"
        else:
            bucket = "live-purged-no-archive-marker"
        return {
            "bucket": bucket,
            "why": (
                "Status 在无 terminal-archive.json 时，凭 live purged 观测把 lifecycle 标成 terminal。"
                "Archive 候选要求 lifecycle != terminal，因此这些记录不会进入 Archive。"
            ),
        }
    if txn_status in {"restored", "rolled-back"}:
        return {
            "bucket": f"live-{txn_status}-terminal",
            "why": (
                "Status 对 restored/rolled-back 且 namespace 一致的记录直接标 terminal，"
                "不要求 terminal-archive.json。"
            ),
        }
    if txn_status != "purged":
        return {
            "bucket": "terminal-but-not-purged",
            "why": "lifecycle=terminal 但 transactionStatus 不是 purged；对照 live 观测分支。",
        }
    return {
        "bucket": "unclassified-terminal-without-marker",
        "why": (
            f"transactionStatus={txn_status!r}, journalStatus={journal!r}, "
            f"errors={errors!r}, txnReadable={txn.get('readable')}"
        ),
    }


def classify_marker_without_terminal(op: dict | None, marker: dict) -> dict:
    if op is None:
        return {
            "bucket": "marker-run-absent-from-status-operations",
            "why": "磁盘有 terminal-archive.json，但 Status 快照 operations 没有该 operationId。",
        }
    lifecycle = op.get("lifecycle")
    errors = op.get("errors") or []
    if lifecycle != "terminal":
        return {
            "bucket": "marker-present-status-not-terminal",
            "why": (
                f"磁盘有 marker，但 Status 把 lifecycle 标成 {lifecycle!r}。"
                f"若 marker 认证失败，Status 会落入 catch 并标 manual-review。errors={errors!r}"
            ),
        }
    return {
        "bucket": "unclassified-marker-without-terminal",
        "why": f"unexpected lifecycle={lifecycle!r}",
    }


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    status_bytes = STATUS_PATH.stat().st_size
    status_sha = sha256_file(STATUS_PATH)
    status = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
    summary = json.loads(SUMMARY_PATH.read_text(encoding="utf-8"))
    ops = status.get("operations") or []
    ops_by_id = {str(op.get("operationId")): op for op in ops}

    terminal_ops = [op for op in ops if op.get("lifecycle") == "terminal"]
    terminal_ids = {str(op.get("operationId")) for op in terminal_ops}

    marker_paths = sorted(EVIDENCE_ROOT.glob("*/terminal-archive.json"))
    marker_ids = []
    duplicate_marker_ids = []
    seen = set()
    for path in marker_paths:
        operation_id = path.parent.name
        if operation_id in seen:
            duplicate_marker_ids.append(operation_id)
        seen.add(operation_id)
        marker_ids.append(operation_id)
    marker_id_set = set(marker_ids)

    both = sorted(terminal_ids & marker_id_set)
    terminal_without_marker = sorted(terminal_ids - marker_id_set)
    marker_without_terminal = sorted(marker_id_set - terminal_ids)

    journal_of_terminal = Counter(str(op.get("journalStatus")) for op in terminal_ops)
    txn_of_terminal = Counter(str(op.get("transactionStatus")) for op in terminal_ops)
    schema_of_terminal = Counter(str(op.get("transactionSchemaVersion")) for op in terminal_ops)

    classified_terminal_without_marker = []
    for operation_id in terminal_without_marker:
        op = ops_by_id[operation_id]
        run_dir = Path(str(op.get("runDirectory") or (EVIDENCE_ROOT / operation_id)))
        marker_path = run_dir / "terminal-archive.json"
        txn = transaction_summary(run_dir)
        plan = plan_summary(run_dir)
        classification = classify_terminal_without_marker(op, txn, plan)
        classified_terminal_without_marker.append(
            {
                **classification,
                "operationId": operation_id,
                "status": compact(op),
                "diskMarkerExistsNow": marker_path.is_file(),
                "transaction": txn,
                "plan": plan,
            }
        )

    classified_marker_without_terminal = []
    for operation_id in marker_without_terminal:
        marker_path = EVIDENCE_ROOT / operation_id / "terminal-archive.json"
        op = ops_by_id.get(operation_id)
        classification = classify_marker_without_terminal(op, marker_summary(marker_path))
        classified_marker_without_terminal.append(
            {
                **classification,
                "operationId": operation_id,
                "status": compact(op) if op else None,
                "marker": marker_summary(marker_path),
                "transaction": transaction_summary(EVIDENCE_ROOT / operation_id),
                "plan": plan_summary(EVIDENCE_ROOT / operation_id),
            }
        )

    bucket_counts = Counter(
        item["bucket"]
        for item in classified_terminal_without_marker + classified_marker_without_terminal
    )

    snapshot_delta = (
        int(summary["operationsByLifecycle"]["terminal"]) - 2200
    )

    payload = {
        "snapshot": True,
        "note": (
            "只读对照：#22 20260815 Status 快照的 lifecycle=terminal "
            "与当前磁盘 terminal-archive.json。未 Archive、未改 marker、未改判据。"
        ),
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "inputs": {
            "statusPath": str(STATUS_PATH),
            "statusBytes": status_bytes,
            "statusSha256": status_sha,
            "statusCapturedAtUtc": status.get("capturedAtUtc"),
            "summaryPath": str(SUMMARY_PATH),
            "summarySourceStatusSha256": summary.get("sourceStatusSha256"),
            "evidenceRoot": str(EVIDENCE_ROOT),
        },
        "counts": {
            "statusOperations": len(ops),
            "statusLifecycleTerminal": len(terminal_ids),
            "historicalDiskMarkerClaim": 2200,
            "historicalClaimedDelta": snapshot_delta,
            "diskMarkerFilesNow": len(marker_paths),
            "diskMarkerOperationIdsNow": len(marker_id_set),
            "duplicateMarkerOperationIds": duplicate_marker_ids,
            "bothTerminalAndMarker": len(both),
            "terminalWithoutMarker": len(terminal_without_marker),
            "markerWithoutTerminal": len(marker_without_terminal),
        },
        "statusTerminalBreakdown": {
            "journalStatus": dict(journal_of_terminal),
            "transactionStatus": dict(txn_of_terminal),
            "transactionSchemaVersion": dict(schema_of_terminal),
        },
        "bucketCounts": dict(bucket_counts),
        "terminalWithoutMarkerIds": terminal_without_marker,
        "markerWithoutTerminalIds": marker_without_terminal,
        "classifiedTerminalWithoutMarker": classified_terminal_without_marker,
        "classifiedMarkerWithoutTerminal": classified_marker_without_terminal,
        "bothIdsSha256": hashlib.sha256("\n".join(both).encode("utf-8")).hexdigest(),
        "bothCount": len(both),
    }
    out_path = OUT_DIR / "terminal-marker-diff.json"
    out_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(
        json.dumps(
            {
                "out": str(out_path),
                "counts": payload["counts"],
                "bucketCounts": payload["bucketCounts"],
                "terminalWithoutMarkerIds": terminal_without_marker,
                "markerWithoutTerminalIds": marker_without_terminal,
                "statusTerminalBreakdown": payload["statusTerminalBreakdown"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
