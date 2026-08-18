import json
from pathlib import Path

prior = json.loads(Path(
    r"D:\Codex\projects\统一环境\reports\safe-tree-delete-status-post-archive-20260814\evidence-ops-after-smoke.json"
).read_text(encoding="utf-8"))
before = json.loads(Path(
    r"D:\Codex\projects\统一环境\reports\safe-tree-delete-round-leftover-20260814\evidence-ops-before.json"
).read_text(encoding="utf-8"))
prior_names = set(prior["names"])
before_names = set(before["names"])
added = sorted(before_names - prior_names)
removed = sorted(prior_names - before_names)
print(json.dumps({
    "priorCount": prior["count"],
    "beforeThisRoundCount": before["count"],
    "addedBetweenPriorSnapshotAndThisRound": added,
    "removedBetweenPriorSnapshotAndThisRound": removed,
}, ensure_ascii=False, indent=2))
