#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

src = Path(__file__).with_name("evidence-samples.json")
doc = json.loads(src.read_text(encoding="utf-8"))
print("NO_TX_ALLOWLIST")
for row in doc["allowlistRecords"]:
    if not row["hasTransaction"]:
        print(row["operationId"], row["policyEntryId"], row["targetPath"])
print("NEW_ALLOWLIST")
for row in doc["allowlistRecords"]:
    if row["newAfterBaseline"]:
        print(row["operationId"], row["txStatus"], row["policyEntryId"], row["targetPath"])
print("PLANNED_NS")
for row in doc["plannedNamespaceRecords"]:
    print(row["operationId"], row["targetPath"])
print("MANIFEST_NEW")
for row in doc["manifestDriftRecords"]:
    if row["newAfterBaseline"]:
        print(row["operationId"], row["policyEntryId"], row["targetPath"])
