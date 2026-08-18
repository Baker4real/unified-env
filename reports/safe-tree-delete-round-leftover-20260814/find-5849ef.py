import json
from pathlib import Path

root = Path(r"D:\Codex\.codex\run-evidence\safe-tree-delete")
needle = "5849ef763f1d42bab1341272288a672d"
hits = []
for d in root.iterdir():
    if not d.is_dir():
        continue
    for name in ("plan.json", "transaction.json"):
        p = d / name
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        if needle not in text:
            continue
        rec = {"operationId": d.name, "file": name}
        try:
            doc = json.loads(text)
            rec["status"] = doc.get("status")
            rec["targetPath"] = doc.get("targetPath")
        except Exception as exc:
            rec["parseError"] = str(exc)
        hits.append(rec)
print(json.dumps({"hits": hits, "hitCount": len(hits)}, ensure_ascii=False, indent=2))
