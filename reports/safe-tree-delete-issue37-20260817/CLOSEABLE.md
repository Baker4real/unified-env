# CLOSEABLE.md — GitHub #37 Purge 批量处理优化

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。

## 关口结论

`DONE_WITH_CONCERNS`

功能 AC 已用 live 测试证明：Purge 先把 file leaf 收进 `List<PurgeFileLeaf>`，再按项走现役 `Invoke-CodexSafeTreeDeletePurgeFileHash` / `GetHashSafely`，然后仍由 `Remove-CodexHookCapabilityDirectoryTree` 按目录 freeze/commit、按文件 handle-bound lease 删除。没有全树 pending 再全树 `File.Delete`。10k×4KB 三棵兄弟树实测批量相对 Phase 1 仅 **1.02x**，相对无复用 baseline **0.964x**，未达 1.2–1.5x / 3.5–4x。CrashSafety / Uncertain / LeafStreamSet 仍绿。未碰生产 leftover。未 commit / comment / close #37。

## 逐条 AC

1. **通过。** `New-CodexSafeTreeDeletePurgeFileLeafBatch` 返回 `List<CodexSafeTreeDelete.PurgeFileLeaf>`（`return ,$batch` 防止 PowerShell 拆开）。不是 ArrayList。
2. **通过。** 第一遍遍历 `treeManifest.entries`，收集 `LiteralPath` + `RelativePath` + `FileIdentityV2`。
3. **通过。** 第二遍 `Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation` 对每项调用现役 `Invoke-CodexSafeTreeDeletePurgeFileHash`（无 lease 时即 `GetHashSafely`）。
4. **通过（按现役 seam，不按票面字面全树 journal）。** 第三遍不在 Purge 里攒全树 pending。目录 journal 仍在 HostSafety：每个目录 `publishFreezeIntent` 落盘 `freeze-prepared` 之后才删。
5. **通过（同上）。** 对应 freeze 已落盘后才 `commit-authorized` 并 delete-pending；文件仍是 lease + POSIX disposition，不是裸 `File.Delete`。
6. **通过（有改动，热路径可指出）。** 改前：Purge 在 snapshot 之后直接进入递归 `Remove-CodexHookCapabilityDirectoryTree`，哈希验证与删除交错。改后：`Invoke-CodexSafeTreeDeletePurge` L5111–5136 先 `New-CodexSafeTreeDeletePurgeFileLeafBatch`（L1254）再 `Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation`（L1282），再用同一 `SessionHashCache` 进入删除。删除循环本身未改，避免递归嵌套函数拆坏 freeze journal。
7. **通过。** 同一夹具批量 vs `-DisablePurgeBatchForTest`：都 `purged=true`，`deleted=2`，`streamSetSource=plan.leafStreamSetV1`，quarantine 都消失。
8. **通过。** 单元收集与 Purge observer 都覆盖 2 个 file leaf（`payload.txt`、`nested/child.bin`）。
9. **未达 1.2–1.5x（如实记录）。** 10k×4KB：batch 187157ms / Phase1 190905ms = **1.02x**，`metTargetVsPhase1=false`。
10. **未达 3.5–4x（如实记录）。** batch 187157ms / baseline 180384ms = **0.964x**，`metTargetVsBaseline=false`。#36 完整流水线已是 1.02x，本票无法在 4KB Purge 上乘出 3.5x。
11. **通过。** IdentityMismatch 拒绝并保留 quarantine；empty-project-state 空 List 不再把 Mandatory `Leaves` 绑死（CrashSafety ConcurrentAds 因此恢复）。CrashSafety exit 0（13 scenarios）；UncertainRecovery exit 0；LeafStreamSet exit 0。#34 uncertain 路径未改。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。

### Standards

- 无硬违反仓库编码标准。`git diff --check` 对本票文件通过。
- 未改 `managed/safe-tree-delete/policy.json`、hooks、`managed/grok-hooks/`、ProductionSmoke。未放宽 `FileShare.None`。
- 判断：曾在 HostSafety 用递归嵌套函数做 collect-then-process，CrashSafety 无 freeze journal；已撤回。现役删除循环保持原样。工作树上 `CodexHostSafety.ps1` 仍有进入本关口前的 FileContentHashProvider WIP，不是本票新写。
- 判断：`PurgeFileLeaf` 是被收集/验证实际消费的类型，不是无人调用的 BatchPurge C# 交差。
- 判断：空树 `IList` Mandatory 会拒绝 empty collection；已加 `AllowEmptyCollection` 并在 Count=0 时跳过验证循环。

### Spec

- 票面要的 List 收集、GetHashSafely 验证、批量 vs 逐个、收集覆盖、10k 对照、安全切片都在。
- 没有按票面第四循环改成裸 `File.Delete`，也没有「全树 pending 写完再全树删」。这是能力 spec / 性能 spec「Why immediate journal flush」的硬约束，不是漏做。
- 没有扩到 #38 并行、#49 Status、BatchPurge CLI。没有伪造 1.2x / 3.5x。
- 性能 spec 的额外 1.2–1.5x 与累积 3.5–4x 未达到；数字见 `scale-10000.json`。

**Standards 0 硬违反 / 3 判断味道；Spec 0 缺失要求，最差是 10k 未达加速目标。**

## 未解决问题

- 10k×4KB 批量相对 Phase 1 仅 1.02x，相对 baseline 0.964x。额外 `GetHashSafely` 仍是 `FileShare.None` 二次打开；snapshot dispose lease 再开的味道还在。
- 10k 墙钟是在一度启用 HostSafety collect-then-process 时测的；该路径已撤回。撤回后删除循环与 Phase 1 相同，只多 Purge 收集/验证，加速不会变好到 1.2x，故未再花 25 分钟重跑 10k。
- `bytesHashed` 在 cache hit 时仍按文件长度记账。
- 未改 guard / policy / hooks。未 commit / comment / close #37。
- #38 并行、#49 Status 冷启动不在本票。
