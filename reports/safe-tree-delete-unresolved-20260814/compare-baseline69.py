#!/usr/bin/env python3
"""Compare after-archive unparsed records with the #19 ticket 69 groups."""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(r"D:\Codex\projects\统一环境")
AFTER = ROOT / r"reports\safe-tree-delete-archive-20260814\status-after.utf8.json"
BASELINE = ROOT / r"reports\safe-tree-delete-status-baseline-20260810-evidence\status-output.json"
OUT = Path(__file__).resolve().parent


def decode_json(path: Path) -> dict:
    raw = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            return json.loads(raw.decode(encoding))
        except UnicodeDecodeError:
            continue
    raise RuntimeError(path)


def error_sig(op: dict) -> tuple[str, ...]:
    return tuple(op.get("errors") or [])


def classify_ticket_group(op: dict) -> str | None:
    errors = list(op.get("errors") or [])
    if not errors:
        return None
    head = errors[0]
    if head.startswith("safe-delete capability root 不在受管 allowlist"):
        return "allowlist"
    if head.startswith("safe-delete Status planned tree manifest 漂移"):
        return "manifest-drift"
    if head.startswith("planned operation 的 target/quarantine namespace 不一致"):
        if any(e.startswith("plan policy SHA 已漂移") for e in errors):
            return "namespace+policy-sha"
        return "planned-namespace"
    if head.startswith("safe-delete target 未达到策略要求的最小后代深度"):
        return "min-depth"
    if head.startswith("evidence record 缺少 plan.json"):
        return "missing-plan"
    return None


def slim(op: dict) -> dict:
    return {
        "operationId": op.get("operationId"),
        "lifecycle": op.get("lifecycle"),
        "planSchemaVersion": op.get("planSchemaVersion"),
        "transactionSchemaVersion": op.get("transactionSchemaVersion"),
        "transactionStatus": op.get("transactionStatus"),
        "targetPath": op.get("targetPath"),
        "targetPresent": op.get("targetPresent"),
        "quarantinePresent": op.get("quarantinePresent"),
        "journalStatus": op.get("journalStatus"),
        "policyCompatible": op.get("policyCompatible"),
        "errors": list(op.get("errors") or []),
    }


def main() -> None:
    after = decode_json(AFTER)
    baseline = decode_json(BASELINE)
    after_ops = {op["operationId"]: op for op in after["operations"]}
    baseline_ops = {op["operationId"]: op for op in baseline["operations"]}
    after_blocking = set(after.get("migrationReadiness", {}).get("blockingRecords") or [])
    baseline_blocking = set(baseline.get("migrationReadiness", {}).get("blockingRecords") or [])

    def select(ops: dict, blocking: set[str], predicate) -> list[dict]:
        return [ops[oid] for oid in blocking if oid in ops and predicate(ops[oid])]

    baseline_ticket = select(
        baseline_ops, baseline_blocking, lambda op: classify_ticket_group(op) is not None
    )
    after_ticket = select(
        after_ops, after_blocking, lambda op: classify_ticket_group(op) is not None
    )
    after_status_none = select(
        after_ops, after_blocking, lambda op: op.get("transactionStatus") is None
    )
    baseline_status_none = select(
        baseline_ops, baseline_blocking, lambda op: op.get("transactionStatus") is None
    )
    baseline_both_null = select(
        baseline_ops,
        baseline_blocking,
        lambda op: op.get("transactionStatus") is None
        and op.get("transactionSchemaVersion") is None,
    )

    # The ticket 69 used both-null? Or error groups? Print both.
    def group_counts(ops: list[dict]) -> dict:
        c = Counter(classify_ticket_group(op) or f"other:{error_sig(op)}" for op in ops)
        return dict(c)

    baseline_ticket_ids = {op["operationId"] for op in baseline_ticket}
    after_ticket_ids = {op["operationId"] for op in after_ticket}
    after_none_ids = {op["operationId"] for op in after_status_none}
    baseline_none_ids = {op["operationId"] for op in baseline_status_none}

    added_ticket = sorted(after_ticket_ids - baseline_ticket_ids)
    gone_ticket = sorted(baseline_ticket_ids - after_ticket_ids)
    added_none = sorted(after_none_ids - baseline_none_ids)
    gone_none = sorted(baseline_none_ids - after_none_ids)

    # overlap between after status-none 89 and ticket-group after
    none_not_ticket = sorted(after_none_ids - after_ticket_ids)
    ticket_not_none = sorted(after_ticket_ids - after_none_ids)

    added_detail = []
    for oid in added_none:
        op = after_ops[oid]
        added_detail.append(
            {
                "group": classify_ticket_group(op),
                "inBaselineOps": oid in baseline_ops,
                "inBaselineBlocking": oid in baseline_blocking,
                "baseline": slim(baseline_ops[oid]) if oid in baseline_ops else None,
                "after": slim(op),
            }
        )

    gone_detail = []
    for oid in gone_none:
        b = baseline_ops[oid]
        a = after_ops.get(oid)
        gone_detail.append(
            {
                "group": classify_ticket_group(b),
                "inAfterOps": a is not None,
                "inAfterBlocking": oid in after_blocking,
                "baseline": slim(b),
                "after": slim(a) if a else None,
            }
        )

    # If baseline status-none is not 69, inspect all status-none groups
    payload = {
        "snapshot": True,
        "baselineCounts": {
            "operations": len(baseline_ops),
            "blocking": len(baseline_blocking),
            "statusNone": len(baseline_status_none),
            "bothNull": len(baseline_both_null),
            "ticketErrorGroups": len(baseline_ticket),
            "statusNoneByGroup": group_counts(baseline_status_none),
            "bothNullByGroup": group_counts(baseline_both_null),
            "ticketByGroup": group_counts(baseline_ticket),
            "statusNoneSchema": dict(
                Counter(str(op.get("transactionSchemaVersion")) for op in baseline_status_none)
            ),
            "ticketSchema": dict(
                Counter(str(op.get("transactionSchemaVersion")) for op in baseline_ticket)
            ),
        },
        "afterCounts": {
            "operations": len(after_ops),
            "blocking": len(after_blocking),
            "statusNone": len(after_status_none),
            "ticketErrorGroups": len(after_ticket),
            "statusNoneByGroup": group_counts(after_status_none),
            "ticketByGroup": group_counts(after_ticket),
            "statusNoneSchema": dict(
                Counter(str(op.get("transactionSchemaVersion")) for op in after_status_none)
            ),
            "noneNotTicket": none_not_ticket,
            "ticketNotNone": ticket_not_none,
        },
        "deltaStatusNone": {
            "added": len(added_none),
            "gone": len(gone_none),
            "addedByGroup": dict(Counter(classify_ticket_group(after_ops[oid]) for oid in added_none)),
            "goneByGroup": dict(Counter(classify_ticket_group(baseline_ops[oid]) for oid in gone_none)),
            "addedCreatedAfterBaseline": [
                oid for oid in added_none if oid.startswith("2026081") and oid > "20260810"
            ],
            "addedPresentInBaselineOps": [oid for oid in added_none if oid in baseline_ops],
            "addedNewOperations": [oid for oid in added_none if oid not in baseline_ops],
        },
        "deltaTicketGroups": {
            "added": len(added_ticket),
            "gone": len(gone_ticket),
            "addedIds": added_ticket,
            "goneIds": gone_ticket,
        },
        "addedStatusNoneRecords": added_detail,
        "goneStatusNoneRecords": gone_detail,
    }
    (OUT / "baseline-delta.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "baseline": payload["baselineCounts"],
                "after": {
                    k: v
                    for k, v in payload["afterCounts"].items()
                    if k != "noneNotTicket" and k != "ticketNotNone"
                },
                "deltaStatusNone": payload["deltaStatusNone"],
                "deltaTicket": payload["deltaTicketGroups"],
                "noneNotTicket": payload["afterCounts"]["noneNotTicket"],
                "ticketNotNone": payload["afterCounts"]["ticketNotNone"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
