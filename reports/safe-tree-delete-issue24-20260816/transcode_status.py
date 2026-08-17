"""Decode production Status stdout that may be GB18030 into UTF-8 JSON text."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def decode_status_bytes(raw: bytes) -> tuple[str, str]:
    if raw.startswith(b"\xef\xbb\xbf"):
        candidates = ("utf-8-sig", "utf-8", "gb18030", "cp936")
    else:
        candidates = ("utf-8", "utf-8-sig", "gb18030", "cp936")
    last_error: Exception | None = None
    for encoding in candidates:
        try:
            text = raw.decode(encoding)
        except UnicodeDecodeError as exc:
            last_error = exc
            continue
        try:
            json.loads(text)
        except json.JSONDecodeError as exc:
            last_error = exc
            continue
        return text, encoding
    raise ValueError(f"unable to decode status bytes as JSON: {last_error}")


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: transcode_status.py SRC.json DST.utf8.json")
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    raw = src.read_bytes()
    text, encoding = decode_status_bytes(raw)
    dst.write_text(text, encoding="utf-8", newline="\n")
    print(
        json.dumps(
            {
                "source": str(src),
                "bytes": len(raw),
                "hasUtf8Bom": raw.startswith(b"\xef\xbb\xbf"),
                "nulCount": raw.count(b"\x00"),
                "decodedAs": encoding,
                "destination": str(dst),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
