"""Assert REPORT live numbers against status-utf8.json. Fail if they disagree."""

from __future__ import annotations

import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
status = json.loads((ROOT / "status-utf8.json").read_text(encoding="utf-8"))
meta = json.loads((ROOT / "status-raw.meta.json").read_text(encoding="utf-8"))
leftover = json.loads((ROOT / "leftover-after.json").read_text(encoding="utf-8"))
compare = json.loads((ROOT / "evidence-status-write-compare.json").read_text(encoding="utf-8"))
baseline_cmp = json.loads((ROOT / "comparison-vs-baseline-19.json").read_text(encoding="utf-8"))
ops = status["operations"]
blocking_ids = set(status["migrationReadiness"]["blockingRecords"])
LEFTOVER = "20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e"
HIST = "20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153"
V1 = {
    "20260725T010726Z-0609f165-c496-4280-85c4-6bb8a5e9465b",
    "20260725T130041Z-a5fd8743-a239-423c-9c44-4cbb5aa6a2cc",
    "20260728T162734Z-c602a5b7-34bb-4469-bf9b-2754cadc5a76",
    "20260729T055433Z-0f0aeb5d-efcc-43cb-973b-a58a9ea748d6",
    "20260730T170848Z-26f7ea53-0578-43c4-b245-9ab5304ca5d6",
}
smoke_start = datetime(2026, 8, 16, 13, 37, 1, tzinfo=timezone.utc)
by_id = {op["operationId"]: op for op in ops}

assert meta["exitCode"] == 0
assert status["complete"] is False
assert status["migrationReadiness"]["ready"] is False
assert len(ops) == 2356
assert len(blocking_ids) == 110
assert status["metrics"]["elapsedMs"] == 491363
assert meta["wallClockSeconds"] == 493.768
assert compare["zeroWrite"] is True
assert leftover["matches"] is True
assert leftover.get("quarantineExists") is True
assert leftover["sha256"] == "4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7"
assert LEFTOVER in by_id
assert by_id[LEFTOVER]["lifecycle"] == "purge-resumable"
assert by_id[LEFTOVER]["transactionStatus"] == "purging"
assert LEFTOVER not in blocking_ids
assert HIST in blocking_ids
assert V1 <= blocking_ids
life = Counter(str(op.get("lifecycle")) for op in ops)
assert life["terminal"] == 2244
assert life["manual-review"] == 87
assert life["inconsistent"] == 23
assert life["recoverable"] == 1
assert life["purge-resumable"] == 1
smoke = []
for op in ops:
    oid = op["operationId"]
    if len(oid) >= 16 and oid[8] == "T":
        try:
            stamp = datetime.strptime(oid[:16], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if stamp >= smoke_start:
            smoke.append(op)
assert len(smoke) == 6
assert all(op["lifecycle"] == "terminal" and op["operationId"] not in blocking_ids for op in smoke)
assert baseline_cmp["deltas"]["blockingRecords"]["delta"] == -1564
assert baseline_cmp["deltas"]["operations"]["current"] == 2356
print("REPORT numbers match status-utf8.json")
