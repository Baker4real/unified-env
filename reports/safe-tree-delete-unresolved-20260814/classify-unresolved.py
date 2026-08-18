#!/usr/bin/env python3
"""Classify remaining blocking / unparsed Status records. Snapshot only."""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(r"D:\Codex\projects\统一环境")
AFTER = ROOT / r"reports\safe-tree-delete-archive-20260814\status-after.utf8.json"
BASELINE = ROOT / r"reports\safe-tree-delete-status-baseline-20260810-evidence\status-output.json"
POLICY = ROOT / r"managed\safe-tree-delete\policy.json"
OUT = Path(__file__).resolve().parent
EVIDENCE = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")


def error_head(op: dict) -> str:
    errors = op.get("errors") or []
    return errors[0] if errors else "<none>"


def error_signature(op: dict) -> tuple[str, ...]:
    return tuple(op.get("errors") or [])


def load_status(path: Path) -> dict:
    raw = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            return json.loads(raw.decode(encoding))
        except UnicodeDecodeError:
            continue
    raise RuntimeError(f"unable to decode {path}")


def slim(op: dict) -> dict:
    return {
        "operationId": op.get("operationId"),
        "lifecycle": op.get("lifecycle"),
        "planSchemaVersion": op.get("planSchemaVersion"),
        "transactionSchemaVersion": op.get("transactionSchemaVersion"),
        "transactionStatus": op.get("transactionStatus"),
        "targetPath": op.get("targetPath"),
        "quarantinePath": op.get("quarantinePath"),
        "targetPresent": op.get("targetPresent"),
        "quarantinePresent": op.get("quarantinePresent"),
        "targetEntryType": op.get("targetEntryType"),
        "quarantineEntryType": op.get("quarantineEntryType"),
        "journalStatus": op.get("journalStatus"),
        "policyCompatible": op.get("policyCompatible"),
        "schemaCompatible": op.get("schemaCompatible"),
        "errors": list(op.get("errors") or []),
        "runDirectory": op.get("runDirectory"),
    }


def evidence_facts(operation_id: str) -> dict:
    run = EVIDENCE / operation_id
    plan_path = run / "plan.json"
    tx_path = run / "transaction.json"
    archive_path = run / "terminal-archive.json"
    facts: dict = {
        "operationId": operation_id,
        "runExists": run.is_dir(),
        "planExists": plan_path.is_file(),
        "transactionExists": tx_path.is_file(),
        "archiveExists": archive_path.is_file(),
    }
    if plan_path.is_file():
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        facts["plan"] = {
            "schemaVersion": plan.get("schemaVersion"),
            "policyEntryId": plan.get("policyEntryId"),
            "capabilityRoot": plan.get("capabilityRoot"),
            "targetPath": plan.get("targetPath"),
            "policySha256": plan.get("policySha256"),
            "policyPath": plan.get("policyPath"),
            "generationId": plan.get("generationId"),
            "createdAtUtc": plan.get("createdAtUtc"),
            "expiresAtUtc": plan.get("expiresAtUtc"),
            "treeEntryCount": len(plan.get("treeManifest", {}).get("entries") or [])
            if isinstance(plan.get("treeManifest"), dict)
            else None,
        }
    if tx_path.is_file():
        tx = json.loads(tx_path.read_text(encoding="utf-8"))
        facts["transaction"] = {
            "schemaVersion": tx.get("schemaVersion"),
            "status": tx.get("status"),
            "targetPath": tx.get("targetPath"),
            "quarantinePath": tx.get("quarantinePath"),
            "updatedAtUtc": tx.get("updatedAtUtc"),
        }
    return facts


def main() -> None:
    after = load_status(AFTER)
    baseline = load_status(BASELINE)
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
    allow_roots = {
        str(entry["capabilityRoot"]).casefold(): entry["id"] for entry in policy["entries"]
    }

    blocking_ids = set((after.get("migrationReadiness") or {}).get("blockingRecords") or [])
    after_ops = {op["operationId"]: op for op in after.get("operations") or []}
    remaining = [after_ops[oid] for oid in blocking_ids if oid in after_ops]
    unparsed = [op for op in remaining if op.get("transactionStatus") is None]

    baseline_ops = {op["operationId"]: op for op in baseline.get("operations") or []}
    baseline_blocking = set(
        (baseline.get("migrationReadiness") or {}).get("blockingRecords") or []
    )
    baseline_unparsed = [
        op
        for op in baseline_ops.values()
        if op.get("operationId") in baseline_blocking
        and op.get("transactionStatus") is None
        and op.get("transactionSchemaVersion") is None
    ]

    after_unparsed_ids = {op["operationId"] for op in unparsed}
    baseline_unparsed_ids = {op["operationId"] for op in baseline_unparsed}
    added = sorted(after_unparsed_ids - baseline_unparsed_ids)
    disappeared = sorted(baseline_unparsed_ids - after_unparsed_ids)

    groups: dict[tuple[str, ...], list[dict]] = defaultdict(list)
    for op in unparsed:
        groups[error_signature(op)].append(op)

    grouped = []
    for sig, ops in sorted(groups.items(), key=lambda item: (-len(item[1]), item[0])):
        samples = []
        roots = Counter()
        entry_ids = Counter()
        dates = Counter()
        tx_files = Counter()
        for op in ops:
            facts = evidence_facts(op["operationId"])
            plan = facts.get("plan") or {}
            root = plan.get("capabilityRoot")
            if root:
                roots[root] += 1
                entry_ids[plan.get("policyEntryId") or "<none>"] += 1
            dates[str(op["operationId"])[:8]] += 1
            tx_files["present" if facts["transactionExists"] else "absent"] += 1
            if len(samples) < 4:
                samples.append({"status": slim(op), "evidence": facts})
        grouped.append(
            {
                "count": len(ops),
                "errors": list(sig),
                "operationIds": sorted(op["operationId"] for op in ops),
                "lifecycle": dict(Counter(str(op.get("lifecycle")) for op in ops)),
                "schemaVersions": dict(
                    Counter(str(op.get("transactionSchemaVersion")) for op in ops)
                ),
                "journalStatus": dict(Counter(str(op.get("journalStatus")) for op in ops)),
                "policyCompatible": dict(
                    Counter(str(op.get("policyCompatible")) for op in ops)
                ),
                "targetPathVisible": sum(1 for op in ops if op.get("targetPath")),
                "targetPresentTrue": sum(1 for op in ops if op.get("targetPresent") is True),
                "quarantinePresentTrue": sum(
                    1 for op in ops if op.get("quarantinePresent") is True
                ),
                "dates": dict(dates),
                "transactionFiles": dict(tx_files),
                "capabilityRoots": dict(roots),
                "policyEntryIds": dict(entry_ids),
                "rootsOnCurrentAllowlist": {
                    root: (root.casefold() in allow_roots) for root in roots
                },
                "samples": samples,
            }
        )

    added_detail = []
    for oid in added:
        op = after_ops[oid]
        facts = evidence_facts(oid)
        added_detail.append({"status": slim(op), "evidence": facts})

    disappeared_detail = []
    for oid in disappeared:
        op = baseline_ops[oid]
        after_op = after_ops.get(oid)
        disappeared_detail.append(
            {
                "baseline": slim(op),
                "afterPresent": after_op is not None,
                "afterBlocking": oid in blocking_ids,
                "after": slim(after_op) if after_op else None,
            }
        )

    purged = [slim(op) for op in remaining if op.get("transactionStatus") == "purged"]
    ui_refs = [
        slim(op)
        for op in remaining
        if "ui-references" in str(op.get("targetPath") or "")
        and op.get("transactionStatus") == "quarantined"
    ]
    v1 = [
        slim(op)
        for op in remaining
        if op.get("transactionSchemaVersion") == 1 and op.get("transactionStatus")
    ]
    hist_v2 = slim(after_ops.get("20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153") or {})

    # Sample extra evidence for +20 and for each original group representative.
    extra_samples = []
    for item in added_detail:
        extra_samples.append(item)

    summary = {
        "snapshot": True,
        "note": "issue #23 只读分类快照。不构成执行授权，也不改变生产 evidence。",
        "sources": {
            "statusAfter": str(AFTER),
            "baseline": str(BASELINE),
            "policy": str(POLICY),
            "currentPolicySchemaVersion": policy.get("schemaVersion"),
            "currentPolicyEntryCount": len(policy.get("entries") or []),
            "currentAllowlistIds": [entry["id"] for entry in policy["entries"]],
        },
        "counts": {
            "blockingAfter": len(remaining),
            "unparsedAfterStatusNone": len(unparsed),
            "baselineBothNull": len(baseline_unparsed),
            "addedVsBaseline69": len(added),
            "disappearedVsBaseline69": len(disappeared),
        },
        "unparsedGroups": grouped,
        "addedVersusBaseline69": {
            "count": len(added),
            "operationIds": added,
            "errorHeads": dict(Counter(error_head(after_ops[oid]) for oid in added)),
            "schemaVersions": dict(
                Counter(str(after_ops[oid].get("transactionSchemaVersion")) for oid in added)
            ),
            "records": added_detail,
        },
        "disappearedVersusBaseline69": {
            "count": len(disappeared),
            "operationIds": disappeared,
            "records": disappeared_detail,
        },
        "outOfUnparsedScopeButInBlocking109": {
            "v1Unterminated": v1,
            "historicalV2Quarantined": hist_v2,
            "windowUiReferencesQuarantined": ui_refs,
            "purgedStillManualReview": purged,
        },
    }

    out_path = OUT / "classification.json"
    out_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "blockingAfter": len(remaining),
                "unparsedAfter": len(unparsed),
                "baselineBothNull": len(baseline_unparsed),
                "added": len(added),
                "disappeared": len(disappeared),
                "groups": [
                    {
                        "count": g["count"],
                        "errors": g["errors"],
                        "txFiles": g["transactionFiles"],
                        "roots": g["capabilityRoots"],
                        "allowlist": g["rootsOnCurrentAllowlist"],
                    }
                    for g in grouped
                ],
                "addedErrorHeads": summary["addedVersusBaseline69"]["errorHeads"],
                "disappearedIds": disappeared,
                "purgedCount": len(purged),
                "uiRefCount": len(ui_refs),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
