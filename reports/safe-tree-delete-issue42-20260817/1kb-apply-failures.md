# 1KB production Apply failures (attempt 1–2)

Not a 6x claim. Production leftover untouched.

Both 10k × 1KB phase3-prod Apply runs failed the same way after baseline succeeded:

- `GetHashSafely` exclusive open: `Failed to open path exclusively for hash reuse without following reparse points.`
- Then quarantine rollback `RenameToSibling` also failed.

Attempt 1: trees created together; phase3 tree idle ~8 min during baseline.
Attempt 2: sequential create; phase3 tree fresh; still failed ~7 min into Plan→Apply.

Retry uses 4KB (same small-file class as #32/#37 Apply hash-reuse, not the #36 1.526 GiB tree).
