import hashlib
import json
from pathlib import Path

ROOT = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")
REPORT = Path(r"D:\Codex\projects\统一环境\reports\safe-tree-delete-round-leftover-20260814")
KNOWN = [
    "20260813T200503Z-56d5dd42-5f0f-429c-87da-15e8518e4af9",
    "20260813T200508Z-791fecd8-67af-49ce-95ae-891b42adf4c5",
    "20260813T200545Z-ec5af9d0-035a-4213-8033-9b1432225e14",
    "20260813T200547Z-087a6e03-6f19-4711-b8b4-5e4177cdedf9",
    "20260813T200553Z-03b8b4af-b466-4cce-9ff8-c977f3f48d93",
]
UI_REFERENCES_NEEDLE = "ui-references"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def inspect(op: str, source: str) -> dict:
    d = ROOT / op
    txp = d / "transaction.json"
    planp = d / "plan.json"
    marker = d / "terminal-archive.json"
    rec = {
        "operationId": op,
        "source": source,
        "dirExists": d.is_dir(),
        "txExists": txp.is_file(),
        "planExists": planp.is_file(),
        "markerExists": marker.is_file(),
        "files": sorted(p.name for p in d.iterdir()) if d.is_dir() else [],
        "uiReferences": False,
        "archiveEligible": False,
    }
    if planp.is_file():
        rec["planSha256"] = sha256_file(planp)
        try:
            plan = json.loads(planp.read_text(encoding="utf-8"))
            rec["planTargetPath"] = plan.get("targetPath")
            rec["planCapabilityRoot"] = plan.get("capabilityRoot")
            rec["policyEntryId"] = plan.get("policyEntryId")
            blob = json.dumps(plan, ensure_ascii=False)
            rec["uiReferences"] = UI_REFERENCES_NEEDLE in blob
        except Exception as exc:
            rec["planParseError"] = str(exc)
    if not txp.is_file():
        rec["skipReason"] = "no-transaction"
        return rec
    rec["transactionSha256"] = sha256_file(txp)
    rec["transactionPath"] = str(txp)
    tx = json.loads(txp.read_text(encoding="utf-8"))
    rec["status"] = tx.get("status")
    rec["schemaVersion"] = tx.get("schemaVersion")
    rec["quarantinePath"] = tx.get("quarantinePath")
    rec["targetPath"] = tx.get("targetPath")
    rec["restoreJournalAnchors"] = tx.get("restoreJournalAnchors")
    q = tx.get("quarantinePath")
    t = tx.get("targetPath")
    rec["quarantinePresent"] = bool(q) and Path(q).exists()
    rec["targetPresent"] = bool(t) and Path(t).exists()
    anchors = tx.get("restoreJournalAnchors")
    rec["restoreJournalAnchorsEmpty"] = anchors in (None, [], {})
    rec["uiReferences"] = rec["uiReferences"] or (
        UI_REFERENCES_NEEDLE in json.dumps(tx, ensure_ascii=False)
    )
    rec["archiveEligible"] = (
        rec.get("status") == "purged"
        and not rec["quarantinePresent"]
        and rec["restoreJournalAnchorsEmpty"]
        and not rec["markerExists"]
        and not rec["uiReferences"]
    )
    return rec


def main() -> int:
    before = json.loads((REPORT / "evidence-ops-before.json").read_text(encoding="utf-8"))
    after = json.loads((REPORT / "evidence-ops-after.json").read_text(encoding="utf-8"))
    before_set = set(before["names"])
    after_set = set(after["names"])
    added = sorted(after_set - before_set)
    removed = sorted(before_set - after_set)
    extra_before_vs_2305_note = {
        "beforeCount": before["count"],
        "afterCount": after["count"],
        "added": added,
        "removed": removed,
    }
    rows = [inspect(op, "prior-round-listed") for op in KNOWN]
    rows.extend(inspect(op, "this-round-smoke-new") for op in added)
    payload = {
        "snapshot": True,
        "note": "Archive 候选现场核验。ui-references 不进入候选。",
        "delta": extra_before_vs_2305_note,
        "candidates": rows,
        "eligibleOperationIds": [r["operationId"] for r in rows if r.get("archiveEligible")],
    }
    out = REPORT / "archive-candidates.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({
        "added": added,
        "removed": removed,
        "eligible": payload["eligibleOperationIds"],
        "out": str(out),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
