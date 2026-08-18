# CLOSEABLE.md — GitHub #42 Phase 3 集成测试和生产验证

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。未 commit / comment / close #42。

## 关口结论

`DONE_WITH_CONCERNS`

A.phase3-prod 阻塞已解除，10k×4KB 生产 Plan→Apply→Purge 跑完。A 合计 **534034ms / 513510ms = 0.962x**，达不到 6x/4x，`metTargetBest=false` / `metTargetTypical=false`。两层数字已分开写，**没有**把 coordinator 4.48x/2.17x 加进生产 Plan→Apply→Purge。

**A. 生产路径**（必须新跑）：10k×4KB 完整 Plan→Apply→Purge。

- baseline（`-DisableApplyHashReuseForTest` + `-DisablePurgeHashReuseForTest` + `-DisablePurgeBatchForTest`）**复用** `baseline-partial.json`：**513510ms**（plan 80303 / apply 247109 / purge 186098）；树已清，未无故重跑。
- phase3-prod（默认哈希复用 + 批量收集，串行 HostSafety Purge）**完成（第 1 次）**：plan 80117ms / apply 252158ms / purge 201759ms / 合计 **534034ms**；`leafDispositions.deleted=10000`。ratio=1.04，speedup=**0.962**。

**B. Coordinator**（`File.Delete` 夹具，不是生产 Purge）：复用 #40 raw。DOP4=13255ms / DOP1=59439ms（**4.48x**）；DOP2=27361ms（**2.17x**）。未计入 A。

未改 HostSafety 删除循环、`ParallelPurgeCoordinator` 接线、policy/hooks、CONTEXT/spec/`modules/manifest.json`。未碰生产 leftover。未伪造 6x/4x。未放宽 `FileShare.None`。

## 修复锚点

- `Get-CodexHookCapabilityDirectoryTreeSnapshot`：有 provider 时不再先 `Dispose` lease；`$lease` 作为第 4 参传入（`scripts/lib/CodexHostSafety.ps1` L916–917）。`finally` 仍 Dispose（L936–938）。删除循环 4 参 `$targetLease` 未改（L1148 / L1170）。
- `Invoke-CodexSafeTreeDeleteApplyFileHash`：可选 `$Lease`（`scripts/lib/CodexSafeTreeDelete.ps1` L1158–1203）。有 lease 时对齐 Purge：核 `FileIdentityV2`，cache hit 不读内容，miss 用同一 lease `ComputeSha256FromHandle()` 写入 `SessionHashCache`。无 lease 仍走 `GetHashSafely`。
- `New-CodexSafeTreeDeleteApplyFileHashProvider`：4 参并把 `$Lease` 传下去（L1205–1223）。
- `Invoke-CodexSafeTreeDeletePurgeFileLeafBatchValidation`：snapshot 已用 lease 填 cache 后，cache hit 只核 identity，不再 `GetHashSafely` `FileShare.None` 重开（L1300–1341）。miss 仍走 PurgeFileHash → GetHashSafely。这是 A 跑通前剩下的 32 窗口（Apply 已过、transaction=`purging` 时 batch 连续 32）。

## 关口证据

- 测试：`tests/Test-CodexSafeTreeDeletePhase3Integration.ps1` `-SkipBaseline`
- 运行器：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`
- A/B JSON：`scale-phase3.json`
- baseline：`baseline-partial.json`（复用 513510ms）
- phase3-prod 成功：`phase3-prod-rerun.stdout.txt`（PHASE3_EXIT=0；create-1 一次成功）
- 回归切片：`tests/Test-CodexSafeTreeDeleteHashReuse.ps1` `-SkipScale`（provider 4 参 + 持有 lease 时 Apply 哈希成功）；`tests/Test-CodexSafeTreeDeleteHashSafely.ps1`（7 slices；首次 writer-probe 竞态后复跑绿）
- 切片记录：`apply-lease-reuse-slice.json`
- coordinator journal：`coordinator-journal.json` + `coordinator-journals/`
- leftover：`leftover-guard.json`（两路径仍在，`touched=false`）
- `git diff --check`：`DIFFCHECK_EXIT=0`（`git-diff-check.json`）
- 10k 树已清；`scale-phase3/` 不存在

## 逐条 AC

1. **通过。** 10k+ 小文件套件已建；生产 baseline 与 phase3-prod 都有墙钟；coordinator 对照有数字。
2. **通过。** 生产 baseline 无复用/无批量，513510ms（复用已有证据，未重跑）。
3. **通过（生产墙钟）。** 最佳生产合计 534034ms。coordinator DOP4=13255ms 只在 B。
4. **通过（生产墙钟）。** 典型生产同一条 534034ms。coordinator DOP2=27361ms 只在 B。
5. **未达。** 6x 只按 A 判；0.962x，`metTargetBest=false`。
6. **未达。** 4x 只按 A 判；0.962x，`metTargetTypical=false`。
7. **通过。** 小树 TOCTOU / CrashSafety 引用仍在；本次复跑 HashReuse 小树 IdentityMismatch 与 Phase3 小树 e2e。未对 leftover FailFast。
8. **通过。** 现场 coordinator 多线程 jsonl 可解析；#39 10k journal 仍在。
9. **通过。** Apply/Purge IdentityMismatch 切片未削弱。
10. **通过。** 小树 e2e 与 10k phase3-prod：Purge 后目标/隔离区消失，`deleted=10000`。
11. **通过（引用）。** #41 10k overhead **18.659%**，`IsWithinTarget=false`。未改公式。
12. **通过。** 无就绪 Network 卷；`FromDetection(NTFS, isRemote=true)` → DOP=1。#35 waiver。
13. **通过。** HashReuse `-SkipScale` 与 HashSafely 复跑绿。未整文件重跑 HashReuse 10k Apply 基准。
14. **通过。** A 与 B 对照已写；引 #36 1.02x、#37 0.964x/1.02x、#40 表。没有合成假 6x。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。未开并行子代理；两轴由本实现代理内联完成。

### Standards

- 无硬违反仓库编码标准。本票文件 `git diff --check` 无 trailing whitespace / space-before-tab / conflict marker。
- 未改 HostSafety 删除循环、`modules/manifest.json`、根/host-safety CONTEXT、性能 spec、policy、hooks。
- `File.Delete` 只打在 issue42 coordinator 夹具树。
- 未放宽 `FileShare.None`；未把 `ParallelPurgeCoordinator` 接到生产 Purge。
- 判断：Purge batch 在 cache hit 时不再二次独占打开，是修窗口，不是生产重试绕过 32。
- 判断：HashSafely 首次 writer-probe 竞态失败后复跑通过，未改 `GetHashSafely`。

### Spec

- 票面要求完整优化路径≥6x/4x。A 墙钟已有，倍率为 0.962x，不能声称达标。
- 硬约「两层数字禁止混报」已遵守：B 的 4.48x 没有写进 A。
- snapshot 有 provider 时把仍持有的 lease 交给 Apply/Purge provider；Status/Restore 无 provider 仍走 handle SHA。
- 生产 Purge 仍走 HostSafety 串行删除。

**Standards 0 硬违反 / 2 判断味道；Spec 1 条未达（A 未到 4x/6x）。**

## 未解决问题

- 默认哈希复用 + 批量收集在生产串行 HostSafety 路径上没有加速（0.962x）。Apply/Purge `bytesHashed` 仍与 baseline 同量级（约 130MiB / 138MiB），说明三次 snapshot + 删除前复验仍在读内容。6x 仍要靠生产 Purge 接并行（能力 spec 禁止本票接线）。
- 生产 Purge 仍未接 `ParallelPurgeCoordinator`。
- 未改 `modules/manifest.json`（根 Agent 登记）。
- 未 commit / comment / close #42。
