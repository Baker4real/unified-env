# 历史 Hook 部署快照

本目录的 `plan.json` 和 `PLAN.md` 于 2026-07-13 生成，记录的是已退役的 ProductionFull 部署方案。即使快照内显示“可执行：True”，也不构成当前生产执行授权。

当前唯一生产入口是 `scripts/Invoke-CodexHostHookReconciliation.ps1`。旧 ProductionFull 与 registration-repair 参数集会返回 `superseded-by-host-hook-reconciler`；历史计划仅保留为 fixture/core 测试和设计追溯材料。
