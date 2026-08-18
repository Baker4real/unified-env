import hashlib
import json
from pathlib import Path

ROOT = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")
IDS = [
    "20260813T200503Z-56d5dd42-5f0f-429c-87da-15e8518e4af9",
    "20260813T200508Z-791fecd8-67af-49ce-95ae-891b42adf4c5",
    "20260813T200545Z-ec5af9d0-035a-4213-8033-9b1432225e14",
    "20260813T200547Z-087a6e03-6f19-4711-b8b4-5e4177cdedf9",
    "20260813T200553Z-03b8b4af-b466-4cce-9ff8-c977f3f48d93",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def inspect(op: str) -> dict:
    d = ROOT / op
    txp = d / "transaction.json"
    marker = d / "terminal-archive.json"
    rec = {
        "operationId": op,
        "dirExists": d.is_dir(),
        "txExists": txp.is_file(),
        "markerExists": marker.is_file(),
        "files": sorted(p.name for p in d.iterdir()) if d.is_dir() else [],
    }
    if not txp.is_file():
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
    rec["archiveEligible"] = (
        rec.get("status") == "purged"
        and not rec["quarantinePresent"]
        and rec["restoreJournalAnchorsEmpty"]
        and not rec["markerExists"]
    )
    return rec


def main() -> int:
    rows = [inspect(op) for op in IDS]
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
    print(json.dumps({"ops": rows, "leftoverReportDirs": leftover_reports}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
