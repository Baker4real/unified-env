# CLOSEABLE.md — GitHub #34 Crash recovery uncertain

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。

## 关口结论

`DONE`

Crash recovery 把尚未 `commit-authorized` 的 `freeze-prepared` 按 `directoryPath` 是否仍在分为 `pendingFiles` / `uncertainFiles`。uncertain 不得收成 `purged`。已 `commit-authorized` 的缺失 quarantine 仍走既有 commit journal 收尾（`FailFastAfterPending` 仍绿）。

未改 guard / policy / hooks。本文不执行 GitHub comment / close；由根 Agent 在提交验证后处理。

## 逐条 AC

1. **通过。** `Get-CodexSafeTreeDeleteInFlightRecovery` 返回 `uncertainFiles` 路径列表；Purge / Status 同字段。
2. **通过。** 分类器检查 pending（无 commit / abort / transaction anchor）项的 `directoryPath` 是否还在。
3. **通过。** 路径仍在 → `pendingFiles`；Status `purge-resumable`。
4. **通过。** 路径不在 → `uncertainFiles`；不得当已删除。
5. **通过。** Purge 恢复返回值与 Status operation 都输出 `uncertainFiles`。
6. **通过。** 单元：pending 存在 → `pendingFiles`。
7. **通过。** 单元：pending 不存在 → `uncertainFiles`。
8. **通过。** 集成：`FailFastAfterFreeze` 后删掉 pending 路径，恢复结果在 `uncertainFiles`；Purge `purged=false`，`refusalReason=uncertain-pending-paths`，transaction 仍 `purging`。
9. **通过。** 集成：同样 crash 但不删 pending 路径，恢复结果在 `pendingFiles`。
10. **通过。** 能力 spec 补了 uncertain 含义与用户处理；本票未改 guard、policy、hooks 或其他模块上下文。

## 两轴审查（相对进入本关口的工作树）

固定点：基线为 `17b45ef`；实现与测试在隔离的 index tree `b67cf1f04de44dfdc4f1735a2be290f5d4813c6f` 快照中验证。审查范围仅本票写入。

### Standards

- 无硬违反仓库编码标准。`git diff --check` 对本票文件通过。
- 判断：分类器跳过畸形/orphan freeze，把 journal 完整性留给既有 abort/anchor 门禁（避免抢先 `FailFastAfterPending` 的 orphan freeze 断言）。
- 判断：未从 `Get-CodexSafeTreeDeleteAbortOperationKeys` 抽共享 reader，避免拆坏既有 journal 语义。
- 未改 `CodexHostSafety.ps1`、policy、hooks。#32/#33 哈希复用未动。

### Spec

- 票面 RecoveryState / UncertainFiles / PendingFiles 落到现役公开 seam，没有抄无人消费的 C# 类。
- pending = 尚未 commit-authorized 的 freeze；committed + 路径不在仍算已删除。
- uncertain 挡住自动 `purged`；文档要求手工核验后再决定重 Plan 或保持 manual-review。
- 没有扩到 #36 并行、#49 Status 冷启动、BatchPurge、生产 leftover Purge/Restore/Archive。

**Standards 0 硬违反 / 2 判断味道；Spec 0 缺失要求。**

## 测试退出码

| 测试 | exit |
| --- | --- |
| `Test-CodexSafeTreeDeleteUncertainRecovery.ps1`（isolated index tree） | 0 |
| `Test-CodexSafeTreeDeleteCrashSafety.ps1`（11 scenarios，isolated index tree） | 0 |

`git diff --check` 对本票文件退出 0。

## 未解决问题

- 生产 CLI 对 uncertain Purge 仍是进程退出 0（与 `confirm-purge-required` 同形）；调用方须读 `purged=false` / `uncertainFiles` / Status `manual-review`。未改生产退出码合同。
- `Validate-ModuleBoundaries.cjs` 仍有进入本关口前就存在的缺文件/无主 reports；本票证据目录已登记，未扩到清理历史债务。
- 未重跑 #32/#33 10k；#33 仍保持 OPEN。未触生产 leftover / Archive 42 条。
