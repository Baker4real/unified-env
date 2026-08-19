# DESIGN.md — #42 生产 Purge 接入 ParallelPurgeCoordinator

这不是 GitHub 关单授权。本文只记录生产接线设计，供本票实现与验收对照。

## 缺口

`ParallelPurgeCoordinator` 已在夹具树上证明目录级并行 + group-commit journal。
生产 `Invoke-CodexSafeTreeDeletePurge` 仍调用串行
`Remove-CodexHookCapabilityDirectoryTree`。0817 生产墙钟 0.962x，未达 4x/6x。

夹具 `File.Delete` 不得进入生产。生产删除必须保持 HostSafety
freeze/handle-bound POSIX disposition、allowlist、最小深度、fail-closed、
identity 校验、pending 落盘。

## 门控

并行只在同时满足时开启：

1. `FileSystemCapabilities.RecommendParallel`（本地 NTFS/ReFS + FILE_ID_INFO）
2. 未设 `-DisablePurgeHashReuseForTest`（baseline 同时关复用与并行）
3. 未设 `-DisableParallelPurgeForTest`
4. `rootDeletionPurpose` 不是 `empty-project-state`（freeze/commit journal 仍走串行 HostSafety，兼容 #34）
5. 计划树没有 `directory-junction`
6. 未注入 `LeafDeleteCheckpointForTest` / `LeafDeleteFaultForTest` /
   `DirectoryDeleteCheckpointForTest`（既有 CrashSafety 保持串行 HostSafety）

网络 / FAT32 / exFAT / 未知文件系统：`RecommendParallel=false` → DOP=1，走原串行 HostSafety。
不把夹具 `File.Delete` 当成降级路径。

DOP 默认取 `RecommendedMaxParallelism`（#40 现役推荐 2）。
`-PurgeMaxDegreeOfParallelismForTest` 只改推荐值，不把 `RecommendParallel=false` 强行打开。
最佳场景 AC 用显式 DOP=4。

## 接线

生产 Purge 在 locked preflight、batch 验证之后：

1. 解析 capabilities（`FileSystemCapabilitiesForTest` 或 `DetectFileSystem`）。
2. 若门控失败：原 `Remove-CodexHookCapabilityDirectoryTree`，行为与接线前相同。
3. 若门控通过：
   - journal 根：`<runDirectory>\parallel-purge-journal`
   - 5 参构造：target=quarantine，journal=上述目录，
     `allowedTargetRoot=quarantineCapabilityRoot`，`allowedJournalRoot=runDirectory`
   - `CreateLeafDeleter` 是 C# `Func`（不是 PowerShell scriptblock），每组一个
     `HostSafetyParallelPurgeLeafDeleter`
   - 协调器仍按顶级目录 `Parallel.ForEach` + B=32 group-commit：
     pending 批量 Flush → 第二句柄可见 → HostSafety 删除 → commit 批量 Flush
   - 任一失败：不标 `purged`，不收口空目录；已删叶子记入 `committedLeaves`
   - 全成功后：按 manifest 自底向上 `AcquireForEmptyDelete` + `DeleteEmptyDirectory`
     清空目录（含 quarantine 根）
   - 返回对象带 `parallelPurge`（used/DOP/journal 计数与 overhead）

## 生产删除器

每个文件：

1. 父目录 `VerifiedDirectoryChainGuard.AcquireForEmptyDelete`（组内按父路径缓存）
2. `AcquireSafeTreeDeleteFileLease`（不跟随 reparse，拒未授权 hardlink / ADS）
3. `FileIdentityV2` 与计划比对；不等则 `IdentityMismatchException`，不删
4. 64-bit handle identity 与 treeManifest 比对
5. `SessionHashCache` 命中则不读内容；未命中则同一 lease `ComputeSha256FromHandle`
6. SHA-256 必须等于计划；然后 `DeleteWithPosixSemantics`

缓存在 batch 验证后只读为主。并行 `TryGet`/`Set` 在删除器内加锁，不改 `SessionHashCache` 合同。

## Crash / #34

`Get-CodexSafeTreeDeleteInFlightRecovery` 继续扫描 `directory-delete-*-freeze.json`
（empty-project-state 语义不变）。

新增：若存在 `parallel-purge-journal\*.thread-*.jsonl` 且提供了 quarantine 路径：

| journal 末态 | 路径仍在 | 分类 |
| --- | --- | --- |
| pending 无 commit | 是 | `pendingFiles`（可继续 Purge） |
| pending 无 commit | 否 | `uncertainFiles`（不得收成 purged） |
| pending+commit | 否 | 已删 |
| pending+commit | 是 | 失败闭锁 |

畸形 journal 行失败闭锁。uncertain 非空时 Purge 仍返回 `uncertain-pending-paths`。

## 错误传播

协调器组间失败不回滚已成功组。生产层 `FailedCount>0` 或 overhead/journal
解析失败都不得写 `purged`。零 commit 且 quarantine 仍完整时，保留既有
回滚到 `quarantined` 的窗口。

## 基准口径

- 规格：10k × 4KB（1KB 有 exclusive-open 失败史）
- baseline：`-DisableApplyHashReuseForTest` + `-DisablePurgeHashReuseForTest`
- 典型：默认优化，DOP=2
- 最佳：默认优化，`-PurgeMaxDegreeOfParallelismForTest 4`
- 每组 ≥2 次取样；不叠加其他负载
- 完整 Plan→Apply→Purge 墙钟判 4x/6x；Purge 分段与 journal overhead 另报
- Phase1/Phase2 数字引用既有版本化证据，不重跑
- 达不到就 `DONE_WITH_CONCERNS`，不混报夹具 `File.Delete` 倍率

## 非目标

- 不改 empty-project-state freeze/DACL 合同
- 不把协调器接到 Apply
- 不改 `modules/manifest.json`、性能 spec、policy
- 不 commit / comment / close #42
