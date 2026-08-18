#!/usr/bin/env python3
"""Read-only evidence sampling for issue #23 groups."""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(r"D:\Codex\projects\统一环境")
AFTER = ROOT / r"reports\safe-tree-delete-archive-20260814\status-after.utf8.json"
BASELINE = ROOT / r"reports\safe-tree-delete-status-baseline-20260810-evidence\status-output.json"
OUT = Path(__file__).resolve().parent
EVIDENCE = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")
POLICY_NOW = ROOT / r"managed\safe-tree-delete\policy.json"


def decode_json(path: Path):
    raw = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            return json.loads(raw.decode(encoding))
        except UnicodeDecodeError:
            continue
    raise RuntimeError(path)


def classify(op: dict) -> str | None:
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


def load_plan_tx(oid: str) -> dict:
    run = EVIDENCE / oid
    out = {
        "operationId": oid,
        "runExists": run.is_dir(),
        "names": sorted(p.name for p in run.iterdir()) if run.is_dir() else [],
        "plan": None,
        "transaction": None,
        "targetExistsNow": None,
        "quarantineExistsNow": None,
    }
    plan_path = run / "plan.json"
    tx_path = run / "transaction.json"
    if plan_path.is_file():
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        target = plan.get("targetPath")
        gen = plan.get("generationId")
        parent = str(Path(target).parent) if target else None
        quarantine = (
            str(Path(parent) / f".codex-safe-delete-{gen}.quarantine")
            if parent and gen
            else None
        )
        out["plan"] = {
            "policyEntryId": plan.get("policyEntryId"),
            "capabilityRoot": plan.get("capabilityRoot"),
            "targetPath": target,
            "policySha256": plan.get("policySha256"),
            "createdAtUtc": plan.get("createdAtUtc"),
            "expiresAtUtc": plan.get("expiresAtUtc"),
            "generationId": gen,
            "derivedQuarantine": quarantine,
            "treeEntryCount": len((plan.get("treeManifest") or {}).get("entries") or []),
            "rootIdentity": (plan.get("treeManifest") or {}).get("rootIdentity"),
        }
        if target:
            p = Path(target)
            out["targetExistsNow"] = p.exists()
            out["targetIsDir"] = p.is_dir() if p.exists() else False
        if quarantine:
            q = Path(quarantine)
            out["quarantineExistsNow"] = q.exists()
    if tx_path.is_file():
        tx = json.loads(tx_path.read_text(encoding="utf-8"))
        out["transaction"] = {
            "schemaVersion": tx.get("schemaVersion"),
            "status": tx.get("status"),
            "targetPath": tx.get("targetPath"),
            "quarantinePath": tx.get("quarantinePath"),
            "updatedAtUtc": tx.get("updatedAtUtc"),
            "keys": sorted(tx.keys()) if isinstance(tx, dict) else None,
        }
        if tx.get("targetPath"):
            p = Path(tx["targetPath"])
            out["txTargetExistsNow"] = p.exists()
        if tx.get("quarantinePath"):
            q = Path(tx["quarantinePath"])
            out["txQuarantineExistsNow"] = q.exists()
    return out


def main() -> None:
    after = decode_json(AFTER)
    baseline = decode_json(BASELINE)
    after_ops = {op["operationId"]: op for op in after["operations"]}
    baseline_ops = {op["operationId"]: op for op in baseline["operations"]}
    after_blocking = set(after["migrationReadiness"]["blockingRecords"])
    remaining = [after_ops[oid] for oid in after_blocking]
    unparsed = [op for op in remaining if op.get("transactionStatus") is None]

    groups = defaultdict(list)
    for op in unparsed:
        groups[classify(op) or "other"].append(op)

    # representatives: first/last + all new + all no-tx allowlist + missing plan + min-depth
    picks = []
    for name, ops in groups.items():
        ids = sorted(op["operationId"] for op in ops)
        picks.extend(ids[:2])
        picks.extend(ids[-2:])
        if name == "allowlist":
            for op in ops:
                facts = load_plan_tx(op["operationId"])
                if not facts.get("transaction"):
                    picks.append(op["operationId"])

    new_ids = [
        oid
        for oid in sorted(op["operationId"] for op in unparsed)
        if oid not in baseline_ops
    ]
    picks.extend(new_ids)
    picks.append("acl-capability-probe-20260801")

    # 4 purged
    purged = [op for op in remaining if op.get("transactionStatus") == "purged"]
    picks.extend(op["operationId"] for op in purged)
    # 10 ui-ref quarantined
    ui = [
        op
        for op in remaining
        if op.get("transactionStatus") == "quarantined"
        and "ui-references" in str(op.get("targetPath") or "")
    ]
    picks.extend(op["operationId"] for op in ui)
    # historical v2
    picks.append("20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153")
    # original 6 namespace+policy from baseline
    orig_ns_sha = [
        op["operationId"]
        for op in baseline_ops.values()
        if classify(op) == "namespace+policy-sha"
    ]
    picks.extend(orig_ns_sha)

    picks = sorted(set(picks))
    sampled = {oid: load_plan_tx(oid) for oid in picks}

    allowlist_summary = []
    for op in groups["allowlist"]:
        facts = load_plan_tx(op["operationId"])
        plan = facts.get("plan") or {}
        tx = facts.get("transaction")
        allowlist_summary.append(
            {
                "operationId": op["operationId"],
                "newAfterBaseline": op["operationId"] not in baseline_ops,
                "policyEntryId": plan.get("policyEntryId"),
                "capabilityRoot": plan.get("capabilityRoot"),
                "targetPath": plan.get("targetPath"),
                "planPolicySha": plan.get("policySha256"),
                "createdAtUtc": plan.get("createdAtUtc"),
                "hasTransaction": tx is not None,
                "txStatus": None if tx is None else tx.get("status"),
                "txSchema": None if tx is None else tx.get("schemaVersion"),
                "targetExistsNow": facts.get("targetExistsNow"),
                "quarantineExistsNow": facts.get("quarantineExistsNow"),
                "txTargetExistsNow": facts.get("txTargetExistsNow"),
                "txQuarantineExistsNow": facts.get("txQuarantineExistsNow"),
            }
        )

    ns_sha_summary = []
    for op in groups["namespace+policy-sha"]:
        facts = load_plan_tx(op["operationId"])
        plan = facts.get("plan") or {}
        ns_sha_summary.append(
            {
                "operationId": op["operationId"],
                "inBaselineUnparsed": classify(baseline_ops.get(op["operationId"]) or {})
                == "planned-namespace"
                or classify(baseline_ops.get(op["operationId"]) or {})
                == "namespace+policy-sha",
                "baselineGroup": classify(baseline_ops.get(op["operationId"]) or {}),
                "policyEntryId": plan.get("policyEntryId"),
                "capabilityRoot": plan.get("capabilityRoot"),
                "targetPath": plan.get("targetPath"),
                "planPolicySha": plan.get("policySha256"),
                "targetExistsNow": facts.get("targetExistsNow"),
                "quarantineExistsNow": facts.get("quarantineExistsNow"),
                "treeEntryCount": plan.get("treeEntryCount"),
            }
        )

    ns_only_summary = []
    for op in groups["planned-namespace"]:
        facts = load_plan_tx(op["operationId"])
        plan = facts.get("plan") or {}
        ns_only_summary.append(
            {
                "operationId": op["operationId"],
                "newAfterBaseline": op["operationId"] not in baseline_ops,
                "policyEntryId": plan.get("policyEntryId"),
                "capabilityRoot": plan.get("capabilityRoot"),
                "targetPath": plan.get("targetPath"),
                "planPolicySha": plan.get("policySha256"),
                "targetExistsNow": facts.get("targetExistsNow"),
                "quarantineExistsNow": facts.get("quarantineExistsNow"),
                "statusTargetPresent": op.get("targetPresent"),
                "statusQuarantinePresent": op.get("quarantinePresent"),
                "policyCompatible": op.get("policyCompatible"),
            }
        )

    manifest_summary = []
    for op in groups["manifest-drift"]:
        facts = load_plan_tx(op["operationId"])
        plan = facts.get("plan") or {}
        manifest_summary.append(
            {
                "operationId": op["operationId"],
                "newAfterBaseline": op["operationId"] not in baseline_ops,
                "policyEntryId": plan.get("policyEntryId"),
                "targetPath": plan.get("targetPath"),
                "targetExistsNow": facts.get("targetExistsNow"),
                "quarantineExistsNow": facts.get("quarantineExistsNow"),
                "treeEntryCount": plan.get("treeEntryCount"),
                "statusTargetPresent": op.get("targetPresent"),
                "statusQuarantinePresent": op.get("quarantinePresent"),
                "policyCompatible": op.get("policyCompatible"),
            }
        )

    purged_detail = []
    for op in purged:
        facts = load_plan_tx(op["operationId"])
        purged_detail.append(
            {
                "status": {
                    "operationId": op["operationId"],
                    "lifecycle": op.get("lifecycle"),
                    "errors": op.get("errors"),
                    "targetPath": op.get("targetPath"),
                    "targetPresent": op.get("targetPresent"),
                    "quarantinePresent": op.get("quarantinePresent"),
                    "policyCompatible": op.get("policyCompatible"),
                    "schemaCompatible": op.get("schemaCompatible"),
                    "journalStatus": op.get("journalStatus"),
                    "transactionSchemaVersion": op.get("transactionSchemaVersion"),
                },
                "evidence": facts,
            }
        )

    ui_detail = []
    for op in ui:
        facts = load_plan_tx(op["operationId"])
        ui_detail.append(
            {
                "status": {
                    "operationId": op["operationId"],
                    "lifecycle": op.get("lifecycle"),
                    "errors": op.get("errors"),
                    "targetPath": op.get("targetPath"),
                    "targetPresent": op.get("targetPresent"),
                    "quarantinePresent": op.get("quarantinePresent"),
                    "transactionStatus": op.get("transactionStatus"),
                    "transactionSchemaVersion": op.get("transactionSchemaVersion"),
                },
                "evidence": facts,
            }
        )

    payload = {
        "snapshot": True,
        "allowlistByEntryPrefix": dict(
            Counter(
                (row["policyEntryId"] or "").split("-")[0]
                if row["policyEntryId"]
                else "<none>"
                for row in allowlist_summary
            )
        ),
        "allowlistByProjectHint": dict(
            Counter(
                (row["capabilityRoot"] or "").split("\\")[3]
                if row["capabilityRoot"]
                and row["capabilityRoot"].startswith("D:\\Codex\\projects\\")
                else (row["capabilityRoot"] or "<none>")
                for row in allowlist_summary
            )
        ),
        "allowlistTxStatus": dict(Counter(str(row["txStatus"]) for row in allowlist_summary)),
        "allowlistTargetExists": dict(
            Counter(str(row["targetExistsNow"]) for row in allowlist_summary)
        ),
        "allowlistQuarantineExists": dict(
            Counter(str(row["quarantineExistsNow"]) for row in allowlist_summary)
        ),
        "allowlistRecords": allowlist_summary,
        "namespacePolicyShaRecords": ns_sha_summary,
        "plannedNamespaceRecords": ns_only_summary,
        "manifestDriftRecords": manifest_summary,
        "purgedStillBlocking": purged_detail,
        "uiReferencesQuarantined": ui_detail,
        "sampledEvidence": {oid: sampled[oid] for oid in sorted(sampled)},
        "minDepth": load_plan_tx(groups["min-depth"][0]["operationId"])
        if groups.get("min-depth")
        else None,
        "missingPlan": load_plan_tx("acl-capability-probe-20260801"),
    }
    (OUT / "evidence-samples.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "allowlist": len(allowlist_summary),
                "allowlistByProjectHint": payload["allowlistByProjectHint"],
                "allowlistTxStatus": payload["allowlistTxStatus"],
                "allowlistTargetExists": payload["allowlistTargetExists"],
                "allowlistQuarantineExists": payload["allowlistQuarantineExists"],
                "nsSha": len(ns_sha_summary),
                "nsShaBaselineGroups": dict(
                    Counter(str(r["baselineGroup"]) for r in ns_sha_summary)
                ),
                "nsOnly": len(ns_only_summary),
                "nsOnlyNew": sum(1 for r in ns_only_summary if r["newAfterBaseline"]),
                "manifest": len(manifest_summary),
                "manifestNew": sum(1 for r in manifest_summary if r["newAfterBaseline"]),
                "purged": [
                    {
                        "id": r["status"]["operationId"],
                        "errors": r["status"]["errors"],
                        "target": r["status"]["targetPath"],
                        "targetPresent": r["status"]["targetPresent"],
                    }
                    for r in purged_detail
                ],
                "ui": [
                    {
                        "id": r["status"]["operationId"],
                        "target": r["status"]["targetPath"],
                        "targetPresent": r["status"]["targetPresent"],
                        "qPresent": r["status"]["quarantinePresent"],
                        "txQ": r["evidence"].get("txQuarantineExistsNow"),
                        "txT": r["evidence"].get("txTargetExistsNow"),
                    }
                    for r in ui_detail
                ],
                "minDepthTarget": (payload["minDepth"] or {}).get("plan"),
                "missingPlanNames": payload["missingPlan"]["names"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
