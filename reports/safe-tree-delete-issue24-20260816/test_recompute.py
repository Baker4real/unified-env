"""Tests for issue #24 capture/recompute seams.

Seams:
- transcode_status.decode_status_bytes
- inventory_evidence.compare
- summarize_status.classify_blocking / parse_operation_timestamp
- compare_vs_baseline.build_comparison
- verify_leftover.hash_file / verify
"""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from compare_vs_baseline import build_comparison
from inventory_evidence import compare as compare_inventory
from summarize_status import (
    HISTORICAL_V2_OPERATION_ID,
    LEFTOVER_OPERATION_ID,
    SMOKE_STARTED_UTC,
    classify_blocking,
    classify_groups,
    parse_operation_timestamp,
    summarize,
)
from transcode_status import decode_status_bytes
from verify_leftover import EXPECTED_TRANSACTION_SHA256, hash_file, verify


def _op(**kwargs):
    base = {
        "operationId": "20260801T000000Z-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "lifecycle": "manual-review",
        "transactionStatus": None,
        "transactionSchemaVersion": None,
        "planSchemaVersion": 1,
        "targetPath": None,
        "targetPresent": False,
        "quarantinePresent": False,
        "schemaCompatible": False,
        "policyCompatible": False,
        "errors": [],
    }
    base.update(kwargs)
    return base


class TranscodeTests(unittest.TestCase):
    def test_utf8_json_roundtrips(self):
        payload = {"complete": False, "message": "ok"}
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        text, encoding = decode_status_bytes(raw)
        self.assertEqual(encoding, "utf-8")
        self.assertEqual(json.loads(text)["message"], "ok")

    def test_gb18030_chinese_json_decodes_without_mojibake(self):
        payload = {"errors": ["safe-delete capability root 不在受管 allowlist"]}
        raw = json.dumps(payload, ensure_ascii=False).encode("gb18030")
        text, encoding = decode_status_bytes(raw)
        self.assertEqual(encoding, "gb18030")
        self.assertEqual(json.loads(text)["errors"][0], payload["errors"][0])

    def test_rejects_non_json(self):
        with self.assertRaises(ValueError):
            decode_status_bytes("not-json".encode("utf-8"))


class InventoryCompareTests(unittest.TestCase):
    def test_identical_files_are_zero_write(self):
        before = {
            "entries": [
                {
                    "name": "op-a",
                    "mtimeNs": 1,
                    "files": [{"rel": "op-a/plan.json", "size": 10, "mtimeNs": 5}],
                }
            ]
        }
        after = {
            "entries": [
                {
                    "name": "op-a",
                    "mtimeNs": 1,
                    "files": [{"rel": "op-a/plan.json", "size": 10, "mtimeNs": 5}],
                }
            ]
        }
        result = compare_inventory(before, after)
        self.assertTrue(result["zeroWrite"])
        self.assertEqual(result["addedEntries"], [])
        self.assertEqual(result["changedEntries"], [])

    def test_mutated_file_is_not_zero_write(self):
        before = {
            "entries": [
                {
                    "name": "op-a",
                    "mtimeNs": 1,
                    "files": [{"rel": "op-a/transaction.json", "size": 10, "mtimeNs": 5}],
                }
            ]
        }
        after = {
            "entries": [
                {
                    "name": "op-a",
                    "mtimeNs": 1,
                    "files": [{"rel": "op-a/transaction.json", "size": 11, "mtimeNs": 6}],
                }
            ]
        }
        result = compare_inventory(before, after)
        self.assertFalse(result["zeroWrite"])
        self.assertEqual(result["changedEntries"][0]["mutatedFiles"][0]["rel"], "op-a/transaction.json")

    def test_directory_mtime_only_still_counts_as_zero_write(self):
        before = {
            "entries": [
                {
                    "name": "op-a",
                    "mtimeNs": 1,
                    "files": [{"rel": "op-a/plan.json", "size": 10, "mtimeNs": 5}],
                }
            ]
        }
        after = {
            "entries": [
                {
                    "name": "op-a",
                    "mtimeNs": 99,
                    "files": [{"rel": "op-a/plan.json", "size": 10, "mtimeNs": 5}],
                }
            ]
        }
        result = compare_inventory(before, after)
        self.assertTrue(result["zeroWrite"])
        self.assertEqual(result["dirMtimeOnlyChanges"], ["op-a"])


class ClassifyTests(unittest.TestCase):
    def test_leftover_is_not_smoke_new(self):
        op = _op(
            operationId=LEFTOVER_OPERATION_ID,
            transactionStatus="purging",
            transactionSchemaVersion=2,
            lifecycle="inconsistent",
        )
        self.assertEqual(classify_blocking(op), "leftover-v2-purging")
        leftover_ts = parse_operation_timestamp(LEFTOVER_OPERATION_ID)
        self.assertIsNotNone(leftover_ts)
        self.assertLess(leftover_ts, SMOKE_STARTED_UTC)

    def test_smoke_new_operation_after_production_smoke_start(self):
        op = _op(
            operationId="20260816T134343Z-d0de032c-7ed6-44b9-8222-91d2522f99c8",
            transactionStatus="purging",
            transactionSchemaVersion=2,
        )
        self.assertEqual(classify_blocking(op), "smoke-new")
        ts = parse_operation_timestamp(op["operationId"])
        self.assertGreaterEqual(ts, SMOKE_STARTED_UTC)

    def test_plan_only_both_null(self):
        op = _op(
            operationId="20260805T153744Z-58046b4e-fb35-4fe1-9f09-b9e50f62ff4a",
            errors=["safe-delete capability root 不在受管 allowlist"],
        )
        self.assertEqual(classify_blocking(op), "plan-only-both-null")

    def test_purged_manual_review_is_not_archive_candidate_noise(self):
        op = _op(
            operationId="20260805T153928Z-163b53ca-efeb-4b40-b49b-c4acd819882e",
            lifecycle="manual-review",
            transactionStatus="purged",
            transactionSchemaVersion=2,
            errors=["safe-delete capability root 不在受管 allowlist"],
        )
        self.assertEqual(classify_blocking(op), "purged-manual-review")

    def test_v1_unterminated(self):
        op = _op(
            operationId="20260725T010726Z-0609f165-c496-4280-85c4-6bb8a5e9465b",
            lifecycle="manual-review",
            transactionStatus="rolled-back",
            transactionSchemaVersion=1,
            targetPath=r"D:\Codex\projects\时钟倒计时\src\MinminCountdown.Verification\bin",
        )
        self.assertEqual(classify_blocking(op), "v1-unterminated")

    def test_historical_v2_unterminated(self):
        op = _op(
            operationId=HISTORICAL_V2_OPERATION_ID,
            lifecycle="manual-review",
            transactionStatus="quarantined",
            transactionSchemaVersion=2,
        )
        self.assertEqual(classify_blocking(op), "historical-v2-unterminated")

    def test_missing_plan_is_not_lumped_into_both_null(self):
        op = _op(
            operationId="acl-capability-probe-20260801",
            errors=["evidence record 缺少 plan.json"],
        )
        self.assertEqual(classify_blocking(op), "missing-plan")

    def test_groups_are_mutually_exclusive_and_sum_to_blocking(self):
        ops = [
            _op(operationId=LEFTOVER_OPERATION_ID, transactionStatus="purging", transactionSchemaVersion=2),
            _op(
                operationId="20260816T133800Z-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                transactionStatus="purged",
                transactionSchemaVersion=2,
            ),
            _op(transactionStatus="rolled-back", transactionSchemaVersion=1),
            _op(operationId=HISTORICAL_V2_OPERATION_ID, transactionStatus="quarantined", transactionSchemaVersion=2),
            _op(operationId="plan-only-1"),
            _op(
                operationId="purged-mr-1",
                transactionStatus="purged",
                transactionSchemaVersion=2,
                lifecycle="manual-review",
            ),
            _op(
                operationId="acl-capability-probe-20260801",
                errors=["evidence record 缺少 plan.json"],
            ),
            _op(
                operationId="drift-1",
                transactionStatus="planned",
                transactionSchemaVersion=2,
                errors=["safe-delete Status planned tree manifest 漂移"],
            ),
        ]
        blocking_ids = [op["operationId"] for op in ops]
        status = {
            "complete": False,
            "operations": ops,
            "migrationReadiness": {"ready": False, "evaluated": False, "blockingRecords": blocking_ids},
            "metrics": {"elapsedMs": 1, "entriesScanned": 1, "logicalBytes": 1, "bytesHashed": 1},
            "policySchemaVersion": 4,
            "policySha256": "abc",
        }
        summary = summarize(status, source_path="mem", source_sha256="0" * 64, source_bytes=1)
        groups = summary["blockingClassification"]
        self.assertEqual(groups["leftover-v2-purging"]["count"], 1)
        self.assertEqual(groups["smoke-new"]["count"], 1)
        self.assertEqual(groups["v1-unterminated"]["count"], 1)
        self.assertEqual(groups["historical-v2-unterminated"]["count"], 1)
        self.assertEqual(groups["plan-only-both-null"]["count"], 1)
        self.assertEqual(groups["purged-manual-review"]["count"], 1)
        self.assertEqual(groups["missing-plan"]["count"], 1)
        self.assertEqual(groups["manifest-drift"]["count"], 1)
        total = sum(item["count"] for item in groups.values())
        self.assertEqual(total, 8)
        self.assertEqual(summary["blockingRecordCount"], 8)
        self.assertEqual(classify_groups(ops), groups)


class ComparisonTests(unittest.TestCase):
    def test_comparison_emits_required_delta_fields(self):
        baseline = {
            "capturedAtUtc": "2026-08-10T15:04:00Z",
            "codeRevision": {"commit": "6d68fb4"},
            "invocation": {"wallClockSeconds": 502},
            "metrics": {
                "elapsedMs": 501018,
                "entriesScanned": 4815,
                "logicalBytes": 1234156276,
                "bytesHashed": 1625526811,
            },
            "governanceVerdict": {
                "complete": False,
                "policySchemaVersion": 4,
                "policySha256": "old",
                "migrationReadinessReady": False,
                "blockingRecordCount": 1674,
                "terminalArchiveMarkerCount": 0,
            },
            "operations": {
                "total": 1980,
                "byLifecycle": {"manual-review": 1662, "terminal": 306, "inconsistent": 12},
            },
        }
        current_status = {
            "capturedAtUtc": "2026-08-16T14:00:00Z",
            "complete": False,
            "policySchemaVersion": 4,
            "policySha256": "new",
            "migrationReadiness": {"ready": False, "evaluated": False, "blockingRecords": ["a", "b"]},
            "metrics": {
                "elapsedMs": 400000,
                "entriesScanned": 7000,
                "logicalBytes": 2000000000,
                "bytesHashed": 2100000000,
            },
            "operations": [
                {"operationId": "a", "lifecycle": "manual-review"},
                {"operationId": "b", "lifecycle": "inconsistent"},
                {"operationId": "c", "lifecycle": "terminal"},
            ],
        }
        meta = {"wallClockSeconds": 401.5, "exitCode": 0, "wrapperSha256": "ffff"}
        comparison = build_comparison(
            baseline=baseline,
            current_status=current_status,
            current_meta=meta,
            current_path="status-utf8.json",
            current_commit="deadbeef",
        )
        deltas = comparison["deltas"]
        self.assertEqual(deltas["elapsedMs"]["baseline"], 501018)
        self.assertEqual(deltas["elapsedMs"]["current"], 400000)
        self.assertEqual(deltas["elapsedMs"]["delta"], -101018)
        self.assertEqual(deltas["operations"]["baseline"], 1980)
        self.assertEqual(deltas["operations"]["current"], 3)
        self.assertEqual(deltas["blockingRecords"]["baseline"], 1674)
        self.assertEqual(deltas["blockingRecords"]["current"], 2)
        self.assertEqual(deltas["blockingRecords"]["delta"], -1672)
        self.assertEqual(deltas["complete"]["current"], False)
        self.assertEqual(deltas["migrationReadinessReady"]["current"], False)
        self.assertEqual(deltas["policySchemaVersion"]["current"], 4)
        self.assertEqual(deltas["policySha256"]["current"], "new")
        self.assertEqual(deltas["terminalArchiveMarkers"]["current"], 1)
        self.assertEqual(deltas["lifecycle"]["terminal"]["current"], 1)
        self.assertEqual(deltas["wallClockSeconds"]["baseline"], 502)


class LeftoverHashTests(unittest.TestCase):
    def test_hash_file_matches_known_sha256(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transaction.json"
            path.write_bytes(b'{"status":"purging"}')
            digest = hash_file(path)
            self.assertEqual(digest, hashlib.sha256(b'{"status":"purging"}').hexdigest())

    def test_verify_accepts_expected_literal(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transaction.json"
            payload = b"leftover-bytes"
            path.write_bytes(payload)
            expected = hashlib.sha256(payload).hexdigest()
            result = verify(path, expected)
            self.assertTrue(result["matches"])
            self.assertTrue(result["ok"])
            self.assertEqual(result["sha256"], expected)

    def test_verify_fails_closed_when_quarantine_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transaction.json"
            path.write_bytes(b"leftover-bytes")
            expected = hashlib.sha256(b"leftover-bytes").hexdigest()
            missing = Path(tmp) / "missing-quarantine"
            result = verify(path, expected, missing)
            self.assertTrue(result["matches"])
            self.assertFalse(result["quarantineExists"])
            self.assertFalse(result["ok"])

    def test_expected_leftover_sha_literal_is_unchanged(self):
        self.assertEqual(
            EXPECTED_TRANSACTION_SHA256,
            "4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7",
        )


if __name__ == "__main__":
    raise SystemExit(unittest.main())
