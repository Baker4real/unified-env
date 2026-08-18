import hashlib
import json
from pathlib import Path

op = "20260814T012818Z-4f9b7a0c-f090-4609-9625-c0f03896290d"
d = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete") / op
txp = d / "transaction.json"
planp = d / "plan.json"
marker = d / "terminal-archive.json"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


rec = {
    "operationId": op,
    "files": sorted(p.name for p in d.iterdir()) if d.is_dir() else [],
    "markerExists": marker.is_file(),
}
if planp.is_file():
    plan = json.loads(planp.read_text(encoding="utf-8"))
    rec["planTargetPath"] = plan.get("targetPath")
    rec["planCapabilityRoot"] = plan.get("capabilityRoot")
    rec["policyEntryId"] = plan.get("policyEntryId")
    rec["planSha256"] = sha256_file(planp)
if txp.is_file():
    tx = json.loads(txp.read_text(encoding="utf-8"))
    rec["status"] = tx.get("status")
    rec["schemaVersion"] = tx.get("schemaVersion")
    rec["targetPath"] = tx.get("targetPath")
    rec["quarantinePath"] = tx.get("quarantinePath")
    rec["restoreJournalAnchors"] = tx.get("restoreJournalAnchors")
    rec["targetPresent"] = bool(tx.get("targetPath")) and Path(tx["targetPath"]).exists()
    rec["quarantinePresent"] = bool(tx.get("quarantinePath")) and Path(tx["quarantinePath"]).exists()
    rec["transactionSha256"] = sha256_file(txp)
print(json.dumps(rec, ensure_ascii=False, indent=2))
(Path(r"D:\Codex\projects\统一环境\reports\safe-tree-delete-round-leftover-20260814\extra-op-before-this-round.json")
 .write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n"))
