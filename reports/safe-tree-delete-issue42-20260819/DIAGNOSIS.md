# DIAGNOSIS.md — #42 生产 Purge 仍串行的根因与接线后仍可能达不到 4x/6x

## 进入本票时的事实

0817 生产 10k×4KB Plan→Apply→Purge：baseline 513510ms / phase3-prod 534034ms = **0.962x**。
`ParallelPurgeCoordinator` 只打夹具 `File.Delete`（#40 DOP4 = 4.48x），未进 `Invoke-CodexSafeTreeDeletePurge`。

## 为什么夹具 4x 不能当生产 4x

1. 夹具删除是 `File.Delete`，没有 DirectoryGuard、lease、identity、handle-bound POSIX。
2. 票面 4x/6x 的分母是完整 Plan→Apply→Purge。Plan+Apply 在 0817 约占 327s / 513s。
   即使 Purge 瞬间完成，全管线也只有约 1.6x。
3. 生产安全路径不得换成 `File.Delete` 来换数字。

## 接线后仍然受这些成本约束

- Plan 采集与 Apply 隔离仍是串行（#32/#36 未达 3x）。
- 生产叶子删除必须 `AcquireForEmptyDelete` + lease + identity + SHA + `DeleteWithPosixSemantics`。
- empty-project-state 的 freeze/DACL journal 仍走串行 HostSafety（#34）。
- CrashSafety 测试钩子在场时保持串行，避免拆坏既有恢复切片。

## 本票做了什么

按 `FileSystemCapabilities.RecommendParallel` 把门：本地 NTFS/ReFS 才并行（默认 DOP=2，
最佳 AC 显式 DOP=4）。生产删除器是 HostSafety lease，不是 `File.Delete`。
网络/FAT/未知、禁用复用/并行、junction、empty-project-state、叶子测试钩子一律串行。

## 验收态度

全管线达不到 4x/6x 就写 `DONE_WITH_CONCERNS`。不把夹具 `File.Delete` 倍率加进生产墙钟。
Purge 分段倍率和 journal overhead 分开报。
