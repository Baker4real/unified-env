# 历史实施计划：已被主机钩子协调器取代

本计划记录的五个 SessionStart / ProductionFull 部署架构已经退役，不再是可执行计划，也不提供旧 live apply、restore 或 wrapper 命令。

当前唯一生产权威是 `scripts/Invoke-CodexHostHookReconciliation.ps1`。它通过显式冷路径 `Check`、`Repair` 和受 evidence 约束的 `Restore` 维护 manifest 定义的用户级钩子终态：受管 `hooks.json` lifecycle hooks 严格收敛为 `codex-state-preflight`、`serena-activate`、`serena-cleanup` 和 `serena-reminder`；`Restore` 必须提供同一 Codex home 固定 evidence root 下的绝对直接子目录，不能作为任意目录的回写入口。它不写入 `approval_policy`、`sandbox_mode`、`features.hooks` 或 `unified_exec`；省略 `features.hooks` 时遵循官方默认启用，Windows 上省略 `unified_exec` 时默认关闭，合法的 inline `[hooks]` 保留。

旧 ProductionFull 与 registration-repair CLI 参数集仅为兼容保留，参数绑定后立即以 `superseded-by-host-hook-reconciler` 拒绝。旧 runtime 的 fixture/core 测试继续保留，用于历史安全性质的回归验证，但不得被解释为第二条生产写入或恢复路径；退役 hook 只会删除，Restore 不会将其复活。

当前设计、安全边界与验证方式见 `docs/specs/2026-07-11-host-hook-reconciliation-design.md`。
