import json
import os
import sys
from pathlib import Path


def walk_inventory(root: Path) -> dict:
    entries = []
    file_count = 0
    for entry in sorted(root.iterdir(), key=lambda item: item.name.casefold()):
        st = entry.stat()
        files = []
        if entry.is_dir():
            for dirpath, _dirnames, filenames in os.walk(entry, followlinks=False):
                for name in filenames:
                    path = Path(dirpath) / name
                    try:
                        fst = path.stat()
                    except OSError:
                        continue
                    files.append(
                        {
                            "rel": str(path.relative_to(root)),
                            "size": int(fst.st_size),
                            "mtimeNs": int(fst.st_mtime_ns),
                        }
                    )
                    file_count += 1
        files.sort(key=lambda item: item["rel"].casefold())
        entries.append(
            {
                "name": entry.name,
                "isDir": entry.is_dir(),
                "mtimeNs": int(st.st_mtime_ns),
                "fileCount": len(files),
                "files": files,
            }
        )
    return {
        "root": str(root),
        "entryCount": len(entries),
        "directoryCount": sum(1 for item in entries if item["isDir"]),
        "fileCount": file_count,
        "entries": entries,
    }


def compare(before: dict, after: dict) -> dict:
    before_map = {item["name"]: item for item in before["entries"]}
    after_map = {item["name"]: item for item in after["entries"]}
    added = sorted(set(after_map) - set(before_map))
    removed = sorted(set(before_map) - set(after_map))
    changed = []
    for name in sorted(set(before_map) & set(after_map)):
        left = before_map[name]
        right = after_map[name]
        left_files = {item["rel"]: item for item in left["files"]}
        right_files = {item["rel"]: item for item in right["files"]}
        added_files = sorted(set(right_files) - set(left_files))
        removed_files = sorted(set(left_files) - set(right_files))
        mutated = []
        for rel in sorted(set(left_files) & set(right_files)):
            lf = left_files[rel]
            rf = right_files[rel]
            if lf["size"] != rf["size"] or lf["mtimeNs"] != rf["mtimeNs"]:
                mutated.append(
                    {
                        "rel": rel,
                        "beforeSize": lf["size"],
                        "afterSize": rf["size"],
                        "beforeMtimeNs": lf["mtimeNs"],
                        "afterMtimeNs": rf["mtimeNs"],
                    }
                )
        dir_mtime_changed = left["mtimeNs"] != right["mtimeNs"]
        if added_files or removed_files or mutated or dir_mtime_changed:
            changed.append(
                {
                    "name": name,
                    "dirMtimeChanged": dir_mtime_changed,
                    "addedFiles": added_files,
                    "removedFiles": removed_files,
                    "mutatedFiles": mutated,
                }
            )
    return {
        "addedEntries": added,
        "removedEntries": removed,
        "changedEntries": changed,
        "zeroWrite": not added and not removed and not any(
            item["addedFiles"] or item["removedFiles"] or item["mutatedFiles"]
            for item in changed
        ),
        "dirMtimeOnlyChanges": [
            item["name"]
            for item in changed
            if item["dirMtimeChanged"]
            and not item["addedFiles"]
            and not item["removedFiles"]
            and not item["mutatedFiles"]
        ],
    }


def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit("usage: inventory-evidence.py capture|compare ...")
    command = sys.argv[1]
    if command == "capture":
        if len(sys.argv) != 4:
            raise SystemExit("usage: inventory-evidence.py capture ROOT OUT.json")
        root = Path(sys.argv[2])
        out = Path(sys.argv[3])
        payload = walk_inventory(root)
        out.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        print(
            json.dumps(
                {
                    "root": payload["root"],
                    "entryCount": payload["entryCount"],
                    "directoryCount": payload["directoryCount"],
                    "fileCount": payload["fileCount"],
                    "out": str(out),
                },
                ensure_ascii=False,
            )
        )
        return 0
    if command == "compare":
        if len(sys.argv) != 5:
            raise SystemExit(
                "usage: inventory-evidence.py compare BEFORE.json AFTER.json OUT.json"
            )
        before = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
        after = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
        payload = compare(before, after)
        Path(sys.argv[4]).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        print(
            json.dumps(
                {
                    "zeroWrite": payload["zeroWrite"],
                    "addedEntries": len(payload["addedEntries"]),
                    "removedEntries": len(payload["removedEntries"]),
                    "changedEntries": len(payload["changedEntries"]),
                    "dirMtimeOnlyChanges": len(payload["dirMtimeOnlyChanges"]),
                    "out": sys.argv[4],
                },
                ensure_ascii=False,
            )
        )
        return 0
    raise SystemExit(f"unknown command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
