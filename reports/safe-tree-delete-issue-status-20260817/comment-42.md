## 状态回写（2026-08-17）

**实现关口：** `DONE_WITH_CONCERNS`
**GitHub：** 保持 OPEN。

Apply 双开阻塞已解：snapshot 有 provider 时不再先放 lease；Apply/Purge 有 lease 时从同一 handle 算哈希。未放宽 `FileShare.None`，未接 coordinator。

生产路径 10k×4KB Plan→Apply→Purge：baseline 513510ms / phase3-prod 534034ms = **0.962x**，`metTargetBest=false`，`metTargetTypical=false`。未达 4x/6x。#40 夹具 4.48x **未计入**本票。

`reports/safe-tree-delete-issue42-20260817/scale-phase3.json`。leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 与 `D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json`。2026-08-17 复读 SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`。属 #45/#50 清空集，不是本票打扫对象。

未进默认分支。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
