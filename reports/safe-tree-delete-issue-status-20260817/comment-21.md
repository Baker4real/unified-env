## 状态回写（2026-08-17）

**实现关口：** DONE（本机 live）。
**GitHub：** 保持 OPEN。关票评论必须等 #50 把证据放到默认分支后再由 #52 发出。

**非零主证据只有这一条：** `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，经 live `.cmd`）。

不能用 fixture、套件 `ok=true`、或 `revert-forwarding.json`（`exitCode=0`，负向：wrapper 吞掉非零）冒充这条证明。

leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 与 `D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json`。2026-08-17 复读 SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`。属 #45/#50 清空集，不是本票打扫对象。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
