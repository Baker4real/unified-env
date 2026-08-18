## 状态回写（2026-08-17）

**实现关口：** DONE（2026-08-16 已回写过传递修复）。
**GitHub：** 保持 OPEN。正式关闭仍走 #52，且 #52 仍被 #50 发布挡住。

受管中间层转发 `$LASTEXITCODE`。`leaf-delete-failed` 经完整 `.cmd` 链为非零；缺确认 Archive 仍是 exit 0 + `confirm-archive-required`。

leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 与 `D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json`。2026-08-17 复读 SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`。属 #45/#50 清空集，不是本票打扫对象。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`。
