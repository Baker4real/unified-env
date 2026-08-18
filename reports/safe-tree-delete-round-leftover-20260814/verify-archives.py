import hashlib
import json
from pathlib import Path

REPORT = Path(r"D:\Codex\projects\统一环境\reports\safe-tree-delete-round-leftover-20260814")
ROOT = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")
summary = json.loads((REPORT / "archive-summary.json").read_text(encoding="utf-8"))
candidates = json.loads((REPORT / "archive-candidates.json").read_text(encoding="utf-8"))
cand_by_id = {c["operationId"]: c for c in candidates["candidates"]}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


rows = []
for item in summary["results"]:
    op = item["operationId"]
    d = ROOT / op
    marker = d / "terminal-archive.json"
    txp = d / "transaction.json"
    rec = {
        "operationId": op,
        "driverArchived": item.get("archived"),
        "driverAlreadyArchived": item.get("alreadyArchived"),
        "driverRefusalReason": item.get("refusalReason"),
        "driverExitCode": item.get("exitCode"),
        "markerExists": marker.is_file(),
        "transactionShaUnchanged": False,
        "quarantineStillAbsent": None,
        "uiReferences": cand_by_id[op]["uiReferences"],
    }
    if txp.is_file() and op in cand_by_id:
        rec["transactionShaUnchanged"] = sha256_file(txp) == cand_by_id[op]["transactionSha256"]
        q = cand_by_id[op].get("quarantinePath")
        rec["quarantineStillAbsent"] = not (q and Path(q).exists())
    if marker.is_file():
        rec["markerSha256"] = sha256_file(marker)
        rec["markerBytes"] = marker.stat().st_size
    rows.append(rec)

leftover_reports = sorted(
    p.name
    for p in Path(r"D:\Codex\projects\统一环境\reports").iterdir()
    if p.is_dir()
    and (
        p.name.startswith("safe-tree-delete-production-smoke-")
        or p.name.startswith("safe-tree-delete-batch-smoke-")
        or p.name.startswith("safe-tree-delete-leaf-fail-smoke-")
    )
)
payload = {
    "snapshot": True,
    "allMarkersPresent": all(r["markerExists"] for r in rows),
    "allTransactionsUnchanged": all(r["transactionShaUnchanged"] for r in rows),
    "anyUiReferencesTouched": any(r["uiReferences"] for r in rows),
    "leftoverReportDirs": leftover_reports,
    "rows": rows,
}
(REPORT / "archive-verify.json").write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
    newline="\n",
)
print(json.dumps({
    "allMarkersPresent": payload["allMarkersPresent"],
    "allTransactionsUnchanged": payload["allTransactionsUnchanged"],
    "anyUiReferencesTouched": payload["anyUiReferencesTouched"],
    "leftoverReportDirs": leftover_reports,
    "count": len(rows),
}, ensure_ascii=False, indent=2))
