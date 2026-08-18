import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: diff-evidence-ops.py BEFORE.json AFTER.json OUT.json")
    before = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    after = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    before_set = set(before["names"])
    after_set = set(after["names"])
    payload = {
        "snapshot": True,
        "note": "ProductionSmoke 新增的 evidence operation 不属于 #24 归档收敛判定集。",
        "beforeCount": before["count"],
        "afterCount": after["count"],
        "added": sorted(after_set - before_set),
        "removed": sorted(before_set - after_set),
    }
    Path(sys.argv[3]).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(json.dumps({"added": payload["added"], "removed": payload["removed"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
