import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: list-evidence-ops.py ROOT NOTE OUT.json")
    root = Path(sys.argv[1])
    note = sys.argv[2]
    out = Path(sys.argv[3])
    names = sorted(
        (item.name for item in root.iterdir() if item.is_dir()),
        key=str.casefold,
    )
    payload = {
        "snapshot": True,
        "note": note,
        "root": str(root),
        "count": len(names),
        "names": names,
    }
    out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(json.dumps({"count": len(names), "out": str(out)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
