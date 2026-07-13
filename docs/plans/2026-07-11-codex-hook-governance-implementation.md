# 历史实施计划：已被主机钩子协调器取代

本计划记录的五个 SessionStart / ProductionFull 部署架构已经退役，不再是可执行计划，也不提供 live apply、restore 或 wrapper 命令。

当前唯一生产权威是 `scripts/Invoke-CodexHostHookReconciliation.ps1`。它只通过显式冷路径 `Check` / `Repair` 维护用户级钩子终态：`hooks.json` 中 lifecycle hooks 为 0，`features.hooks=true` 保留给项目级和 skill 级 hooks。

旧 ProductionFull 与 registration-repair CLI 参数集仅为兼容保留，参数绑定后立即以 `superseded-by-host-hook-reconciler` 拒绝。旧 runtime 的 fixture/core 测试继续保留，用于历史安全性质的回归验证，但不得被解释为第二条生产写入或恢复路径。

当前设计、安全边界与验证方式见 `docs/specs/2026-07-11-host-hook-reconciliation-design.md`。
