import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: transcode-status.py SRC.json DST.utf8.json")
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    raw = src.read_bytes()
    report = {
        "source": str(src),
        "bytes": len(raw),
        "hasUtf8Bom": raw.startswith(b"\xef\xbb\xbf"),
        "nulCount": raw.count(b"\x00"),
        "decodedAs": None,
    }
    text = None
    for encoding in ("utf-8-sig", "utf-8", "gb18030", "cp936"):
        try:
            text = raw.decode(encoding)
            report["decodedAs"] = encoding
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        raise SystemExit(f"unable to decode {src}")
    json.loads(text)
    dst.write_text(text, encoding="utf-8", newline="\n")
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
