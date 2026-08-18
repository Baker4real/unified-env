## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

Apply 已接 invocation-local `SessionHashCache` + `GetHashSafely`。#42 之后，snapshot 有 provider 时不再先放 lease，有 lease 时从同一 handle 算哈希。

10k×4KB Apply：reuse 349164ms / baseline 302992ms = **0.868x**，未达 1.5–2x。`reports/safe-tree-delete-issue32-20260817/scale-10000.json`。

未进默认分支。未关票。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
