"""Build #19-shaped comparison from a live Status JSON and capture meta."""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path


def _delta_pair(baseline, current) -> dict:
    payload = {"baseline": baseline, "current": current}
    if isinstance(baseline, (int, float)) and isinstance(current, (int, float)):
        payload["delta"] = current - baseline
    return payload


def _lifecycle_counts(ops: list[dict]) -> dict[str, int]:
    return dict(Counter(str(op.get("lifecycle")) for op in ops))


def build_comparison(
    baseline: dict,
    current_status: dict,
    current_meta: dict,
    current_path: str,
    current_commit: str | None,
) -> dict:
    ops = current_status.get("operations") or []
    readiness = current_status.get("migrationReadiness") or {}
    blocking_ids = readiness.get("blockingRecords") or []
    current_lifecycle = _lifecycle_counts(ops)
    baseline_ops = baseline.get("operations") or {}
    baseline_lifecycle = baseline_ops.get("byLifecycle") or {}
    baseline_verdict = baseline.get("governanceVerdict") or {}
    baseline_metrics = baseline.get("metrics") or {}
    current_metrics = current_status.get("metrics") or {}
    lifecycle_keys = sorted(
        set(baseline_lifecycle) | set(current_lifecycle),
        key=lambda name: (0 if name == "terminal" else 1, name),
    )
    return {
        "snapshot": True,
        "note": "与 #19 归档前基线逐项对比。本次 live Status，不构成后续授权。08-14 与 02:17 快照不得当作本文件的现役计数。",
        "baseline": {
            "issue": 19,
            "path": "reports/safe-tree-delete-status-baseline-20260810.json",
            "capturedAtUtc": baseline.get("capturedAtUtc"),
            "commit": (baseline.get("codeRevision") or {}).get("commit"),
        },
        "current": {
            "issue": 24,
            "path": current_path,
            "capturedAtUtc": current_status.get("capturedAtUtc"),
            "commit": current_commit,
            "exitCode": current_meta.get("exitCode"),
            "wrapperSha256": current_meta.get("wrapperSha256"),
        },
        "staleSnapshotsNotUsedAsFinal": [
            {
                "path": "reports/safe-tree-delete-status-post-archive-20260814/",
                "note": "过期快照，只作格式参考。",
            },
            {
                "path": "reports/safe-tree-delete-issue23-20260816/REPORT.md",
                "note": "02:17 Status 调查，现已过期。",
            },
        ],
        "deltas": {
            "elapsedMs": _delta_pair(
                baseline_metrics.get("elapsedMs"), current_metrics.get("elapsedMs")
            ),
            "wallClockSeconds": _delta_pair(
                (baseline.get("invocation") or {}).get("wallClockSeconds"),
                current_meta.get("wallClockSeconds"),
            ),
            "entriesScanned": _delta_pair(
                baseline_metrics.get("entriesScanned"),
                current_metrics.get("entriesScanned"),
            ),
            "logicalBytes": _delta_pair(
                baseline_metrics.get("logicalBytes"),
                current_metrics.get("logicalBytes"),
            ),
            "bytesHashed": _delta_pair(
                baseline_metrics.get("bytesHashed"),
                current_metrics.get("bytesHashed"),
            ),
            "operations": _delta_pair(baseline_ops.get("total"), len(ops)),
            "blockingRecords": _delta_pair(
                baseline_verdict.get("blockingRecordCount"),
                len(blocking_ids),
            ),
            "complete": {
                "baseline": baseline_verdict.get("complete"),
                "current": current_status.get("complete"),
            },
            "migrationReadinessReady": {
                "baseline": baseline_verdict.get("migrationReadinessReady"),
                "current": readiness.get("ready"),
            },
            "policySchemaVersion": {
                "baseline": baseline_verdict.get("policySchemaVersion"),
                "current": current_status.get("policySchemaVersion"),
            },
            "policySha256": {
                "baseline": baseline_verdict.get("policySha256"),
                "current": current_status.get("policySha256"),
            },
            "terminalArchiveMarkers": _delta_pair(
                baseline_verdict.get("terminalArchiveMarkerCount"),
                sum(1 for op in ops if op.get("lifecycle") == "terminal"),
            ),
            "lifecycle": {
                name: _delta_pair(
                    int(baseline_lifecycle.get(name, 0)),
                    int(current_lifecycle.get(name, 0)),
                )
                for name in lifecycle_keys
            },
        },
        "doNotNaiveMap": {
            "parentSpecFormula": "1742 = 1661 + 80 + 1",
            "issue19ProjectedResidual": 79,
            "reason": "父 spec 与 #19 预计 residual 都不是本次 live 计数。必须用本次 operations/blocking 重算。",
        },
    }


def main() -> int:
    if len(sys.argv) != 6:
        raise SystemExit(
            "usage: compare_vs_baseline.py BASELINE.json STATUS.utf8.json META.json COMMIT OUT.json"
        )
    baseline = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    status = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    meta = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
    commit = sys.argv[4]
    if commit in {"", "-", "HEAD"}:
        commit = None
    out = Path(sys.argv[5])
    payload = build_comparison(
        baseline=baseline,
        current_status=status,
        current_meta=meta,
        current_path=sys.argv[2],
        current_commit=commit,
    )
    out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(json.dumps({"out": str(out), "blockingDelta": payload["deltas"]["blockingRecords"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
