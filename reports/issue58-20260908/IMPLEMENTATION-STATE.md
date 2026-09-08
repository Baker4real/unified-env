# N2 实现节点工作状态（上下文压缩恢复用）

## 任务（issue #58 N2）
全量 `-Mode Status -Json` 冷启动 84.6min → <60s，语义完全保持。验收：①fast/slow 每 op 结果+blocking 集等价（基线 `reports/issue58-20260908/cold-run-stdout.json`，4467 ops，statusSha256 eceb290d...）；②非规范输入回退保留；③至少自测 1 轮全量冷启动 <60s（harness `reports/issue58-20260908/cold-run.ps1`，env `CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS=1`）；④evidence root 零写入（`evidence-fingerprint.ps1` 前后对照，自己取一轮）。证据目录 `reports/issue58-20260908/`（N1 文件保留）。禁止：git 写操作、宿主部署、写 `D:\agents\run-evidence\safe-tree-delete\`。

## 已完成
1. **C# 已写入并编译通过**（`scripts/lib/CodexSafeTreeDeleteStatusScan.cs` 尾部，namespace 内）：
   - `public sealed class StatusFastPathFallbackException`（PS 按类型 catch → 回退 PS 参考路径）
   - `StatusTreeSnapshotEntry/StatusTreeSnapshotResult`（Entries/RootIdentityVolume/RootIdentityIndex/ManifestSha256/FileContentBytes/ReparseDataBytes）
   - `internal static StatusCanonicalJson.WriteJsonString`：PS ConvertTo-Json 转义规则已实测确认（.scratch/probe2.out）：仅 `"`→`\"`、`\`→`\\`、\b\t\n\f\r 短转义、其余控制字符 `\u00xx` 小写、非 ASCII 原样。
   - `public static StatusTreeSnapshotScanner.Scan(rootPath, allowHardLinks, allowInternalDirectoryJunctions, junctionTargetRoot)`：DFS 前序、兄弟排序 `StringComparer.Create(CultureInfo.CurrentCulture,true)`（已实测与 `Sort-Object` 等价，392 随机名+tricky 名全等，.scratch/probe3.ps1）；culture 并列但 ordinal 不等 → fallback。目录 CreateFileW(GenericRead, FileShare.Read, BackupSemantics|OpenReparsePoint)+info+finalpath 校验；文件 lease 等价（GenericRead|FileWriteAttributes(0x100)|Delete(0x10000)，FileShare.Read，OpenReparsePoint，reparse/dir/linkcount 检查、finalpath、ADS FileStreamInfo 恰好一个 `::$DATA`、**双验** identity 不变后 RandomAccess 1MB 缓冲 SHA-256）；junction（BackupSemantics|OpenReparsePoint、dir-ADS 检查=调用成功即失败/error!=38 失败、FSCTL_GET_REPARSE_POINT 0x900A8 16KB、tag 必须 0xA0000003、ParseMountPointTarget 逻辑复刻 CodexHookHandleBoundIO.cs:1945-2063、target 必须 D 盘+段校验+within junctionTargetRoot，sha=SHA256(reparseData)）。child 名校验（InvalidFileNameChars/尾随 `.`或空格/保留名 CON|PRN|AUX|NUL|COM1-9|LPT1-9 去扩展名）→ fallback（PS 参考路径抛精确消息）。一切异常 → StatusFastPathFallbackException。Manifest SHA-256 在 walk 中流式生成（schemaVersion=2,rootIdentity,entries 属性序 relativePath/kind/sha256/identity）。
   - `public static StatusPlanManifestSha256.ComputeFromPlanText(planText)`：Utf8JsonReader 找顶层 `treeManifest`（OrdinalIgnoreCase 唯一，大小写重复→fallback），流式重规范化（对象序保持文档序、ordinal 重复属性→fallback、Number 仅规范整数 `^(0|-?[1-9][0-9]*)$`+Int64→raw copy 否则 fallback、深度>100→fallback）→ SHA-256。
   - 编译验证：`.scratch/compile-scan.ps1`（Add-Type -OutputAssembly）→ compile-ok。

## 关键已核验事实（不用重测）
- PS ConvertTo-Json escaping 实测（probe2）；Sort-Object == StringComparer.Create(CurrentCulture,true)（probe3）。
- 快照 PS 参考路径 `CodexHostSafety.ps1:789-955`；identity 格式 volume `x8` + indexHigh`x8`+indexLow`x8`（CodexHookHandleBoundIO.cs:2118-2131）。
- 热路径调用点：`CodexSafeTreeDelete.ps1:3196-3264` Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot；manifest SHA `Get-CodexSafeTreeDeleteStatusCachedPlanManifestSha256`(:3165, 3 调用点 :3800/:4000/:4083 都有 $planSnapshot.text 在作用域)；live SHA `Get-CodexSafeTreeDeleteStatusLiveManifestSha256`(:3185, 懒挂 statusLiveManifestSha256 属性)。
- **重要**：`Assert-CodexSafeTreeDeletePartialPurgeManifest`(:4427) → `ConvertTo-CodexHookExpectedDirectoryTreeManifest` → exact-properties(schemaVersion,rootIdentity,entries)，所以**不能**无条件给 snapshot 挂 statusLiveManifestSha256：purging 路径调用点(:3900)不加 flag；3 个 SHA 消费调用点(:3788 planned、:3988 restored、:4071 recoverable)加 `-AttachLiveManifestSha256`。
- Status 主循环 `Get-CodexSafeTreeDeleteStatus`(:4186-4419)；fallback resolver `Resolve-CodexSafeTreeDeleteStatusOperation`(:3550-4184)；fast scan `Invoke-CodexSafeTreeDeleteStatusFastScan`(:2928)；DOP=`Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit`(:2919, min(4,cpu-2))。
- metrics observer 语义(:519-536)：每次调用 entriesScanned+1（除 hash-read）；logicalBytes+=L；bytesHashed+=H。树快照参考路径逐 entry 调 observer：dir(0,0)/file(len,len)/junction(0,reparseLen)。快速路径直接在 MetricsState 上加：entriesScanned+=Entries.Length、logicalBytes+=FileContentBytes、bytesHashed+=FileContentBytes+ReparseDataBytes。
- 测试断言依赖 metrics：tests/Test-CodexSafeTreeDeleteStatus.ps1:960-964 bytesHashed 范围 + approvedPlanValidationReuseCount>0（必须合并 worker 计数）。
- native loader/Add-Type 在 worker runspace 安全：类型已进程级加载时跳过编译（CodexHostSafetyNativeLoader.ps1:341-351 compat registry；CodexSafeTreeDelete.ps1:15 类型检查）。
- runspace 并行：无既有先例；pwsh 7.6.5；`& $entryPath` 测试为同进程调用（worker runspace dot-source 两份 lib ≈0.7s/worker）。
- evidence root `D:\agents\run-evidence\safe-tree-delete` 只读；policy `managed\safe-tree-delete\policy.json`。
- cold-run.ps1/evidence-fingerprint.ps1 在 reports/issue58-20260908/。测试入口：直接 `pwsh -File tests/Test-XXX.ps1` 或 node scripts/Run-PowerShellTests.cjs。

## 待做（按 todo）
2-3 已全部完成（见下"恢复后进展"）。剩余：完成并行文件填充 C# 改造 → 重跑 Status 套件 → 全量冷跑+等价 → n2-after 指纹 → git diff --check → IMPLEMENTATION.md → 清理 .scratch 探针（bigtree-scan-probe*.ps1、bigtree-scan-progress.log、stage-bench.ps1）。

## 恢复后进展（第二轮）
- **4 套件已全绿**：Status 39 slices（新增 slice 35-39：快照等价+metrics parity、未授权 reparse 回退同错误、junction 等价+越界回退、plan-text SHA 等价集、并行 vs 串行全等+接管计数）、UncertainRecovery、Restore、SchemaCompatibility(10)。
- **修复 worker 启动 bug**：worker runspace dot-source 两份 lib 时第二次 Invoke-CodexHostSafetyNativeLoad 命中 compat registry（loadedVariant=$null）→ 抛"未知转移： -> default"→ 并行静默回退串行。修复：主 runspace 把真实 registry（loadedVariant/compositeSha/assemblySha/assembly/requestedAlgorithm）经 $context.NativeRegistry* 传入，worker 在 dot-source 前预置 `$global:CodexHostSafetyNativeLoaderRegistry`（CodexSafeTreeDelete.ps1 `Invoke-CodexSafeTreeDeleteStatusParallelFallback` 内，~4332 行区域）。修复后探针验证并行真正接管（resolved=2）。
- **共享树去重合同钉串行**：并行下 worker 各有独立树缓存，共享 target 会多哈希（实测 bytesHashed 70774→135792）。Test-CodexSafeTreeDeleteStatus.ps1 共享树断言块已钉 `PARALLEL_FALLBACK='0'`（~948 行，含注释）；slice 39 覆盖并行/串行语义全等+metrics 一致（互斥 target）。
- **manifest.json**：host-safety ownership.prefixes 末尾加 `"reports/issue58-20260908/"`（在 issue58-20260906 后）。`node scripts/Validate-ModuleBoundaries.cjs` PASS（清理探针后）。
- **证据状态核验**：N1 after 指纹 == 我的 n2-before 指纹（manifestSha 8f25b06f…、4467 ops、25863 entries、policySha 一致）→ 我的冷跑输出 semanticSha256 必须等于 N1 `88d4b67943d7d451931c024ad031a591efcffd528df9acbcb5e0d566d5938ad6`（cold-run.ps1 输出 cold-run-result-n2.json/cold-run-stdout-n2.json，勿覆盖 N1 文件）。n2-before 指纹：evidence-fingerprint-n2-before.json。
- **全量冷跑首轮 >600s 被任务超时 kill**（bash-70gl4ub2）。根因已实测定位：

## 根因：冷盘 IO 延迟（非 PS 开销）
- `.scratch/bigtree-scan-probe2.ps1`（逐树计时，日志 `.scratch/bigtree-scan-progress.log`，后台 task bash-j2ofalvj/pwsh pid 33652 可能仍在跑，恢复后先停它取日志尾部）：C# Scan 冷盘实测 2.6-5.1ms/entry；**81,855-entry 树 417s**（单树串行即超预算）；两棵 68K 树（TencentDB-Agent-Memory 下）各需 ~5-6min → 全量 >600s 成立。
- 同树热盘 stage-bench（`.scratch/stage-bench.ps1`，512 files/189MB）：open(lease 全掩码)+info 21ms、+finalpath 30ms、+streaminfo 29ms、+全量读 77ms；只读掩码无差别 → **syscall/掩码/AV 均非主因，冷盘队列深度 1 的打开+首读延迟才是**。 lease 双验是参考语义（CodexHookHandleBoundIO.cs:2285 ComputeSha256FromHandle→VerifyCurrentHandle 与 acquire 各验一次），保留。
- **修复方向（进行中）**：`StatusTreeSnapshotScanner` 文件处理改并行填充——串行 DFS 只追加 skeleton entry（kind=file, sha/identity 空）+ 本目录 PendingFile 批次；目录 children 循环结束后（目录句柄仍开）Parallel.ForEach 填充（度=min(32,max(4,2*cpu))，<8 个文件串行）；每 slot 捕异常，串行按 DFS 序抛首个（Scan() 统一包成 typed fallback → PS 重放精确错误）；manifest JSON 改在 ScanCore 尾部对 Entries 做最终串行拼装（格式逐字节同前）。junction 仍内联串行。
- **已完成第一步**：ScanContext 去掉 Manifest 字段、新增 PendingFile 类（CodexSafeTreeDeleteStatusScan.cs ~2749-2773）。
- **待写**：WalkDirectory 文件分支改 QueueFile + 循环末 FillPendingFiles（pending 列表必须**每目录局部**，否则递归串扰）；ProcessFile 改 FillFile（写 file.Entry/file.SizeBytes/file.Failure，不再 AppendEntry/不加 context.FileContentBytes）；AppendEntry 只加 Entries（删 manifest 增量）；ScanCore 末尾串行 manifest 拼装（{"relativePath":..,"kind":..,"sha256":..,"identity":[v,i]}，逗号分隔）；FillPendingFiles 尾循环累加 FileContentBytes 并抛首个 Failure。
- 改完 .cs 无需手工清缓存（源 SHA sidecar 自动重编）；重跑 Status 套件（slice 35-37 直接覆盖等价）→ 全量冷跑。
- 预测：68K 树填充 68K×5ms/32≈11s + PS 侧逐 entry pscustomobject 物化（142K×~0.2ms≈28s 分摊到 4 worker，大树 worker ~14-20s）+ fast scan 22s 冷 + resolver 余项 ~40s → 全量 70-90s 风险仍在；若超 60s 再议（fast scan 流式化可放弃并记录）。PS 物化若成瓶颈，候选：C# 侧直接产出有序 JSON 字符串缓存或批量 New-Object。
- 杂项：junction 条目 kind 是 `directory-junction`（CodexHostSafety.ps1:870），slice 已按此断言。互斥 target 并行/串行 bytesHashed/entriesScanned 必须相等（slice 39 已断言）。

## 最终状态（第五轮收口，已完成）
- **结果：DONE_WITH_CONCERNS**。84.6min → 207.8s（24.4x），<60s 目标未达。语义完全等价。
- **验收证据**（reports/issue58-20260908/）：
  - 等价：semanticSha256 == N1 `88d4b679…`（n2b/n2c/n2d 三轮均中）；equivalence-n2c/n2d.json 4467/4467 identical + topLevel/blocking equal。
  - 冷启动最终态：cold-run-result-n2c.json elapsedMs=207,820（分段：fastScan 20.5s / treeMaterialization 66.7s / activeResolve 545.5s 跨 4 worker）。度 64 试验（n2d）207,973ms 无差异，已回退 32。
  - 零写入：evidence-fingerprint-n2-before/after 的 evidence+policy 子树逐字段一致（manifestSha 8f25b06f…、4467 ops、25,863 entries）。
  - 套件：最终代码态 4 套件全绿（Status 39 / UncertainRecovery / Restore / SchemaCompat 10）。
  - 门禁：Validate-ModuleBoundaries PASS（3090 files）、git diff --check PASS。
- **逐 op 计时**（debugOpTimings，env `CODEX_SAFE_TREE_DELETE_STATUS_DEBUG_OP_TIMING=1` 已落地为 env-gated 诊断）：top 热 op idx4059 node_modules 112s / idx4106 hindsight 103s / idx4100 venv-new 69s / idx4149 zz-purge 49s / idx4062 父树 33s。关键路径=TencentDB 超组 worker。
- **未达标根因与后续路径**：大 plan（5-60.5MB）的 PS ceremony（receipt 路径仍 ConvertFrom-Json 60MB≈1.7s + ComputeFromPlanText 3.9s + tree-policy 管道）+ 嵌套树双扫（合同禁跨树哈希复用）+ 4-worker 争用放大 ~2-3x。后续：①receipt 携带已解析 plan 数据跳过 PS parse（预估减半热 op ceremony，风险中高）；②超组内嵌套扫描 lease 安全交错；③fastScan dop 上限评估。详见 IMPLEMENTATION.md 末节。
- **杂项**：.scratch 探针已收口（留存的移到 .scratch/safe-tree-delete-perf/issue58-probes/，临时 dll/log 已删）。注意 `docs/environments/zi-xi-shi.md` 是**他人既有脏改**，非本任务触碰，勿动。
- IMPLEMENTATION.md 已写完（改动清单/性能证据链表/两个根因/剩余瓶颈/复现入口）。本文件为最终状态，无需再续作，除非继续做上述后续路径。

## 恢复后进展（第四轮：冷跑 1 轮结果 + 两个新根因修复）
- **冷跑 #1（bash-vokf2zwu）**：elapsedMs=2,595,625（43.3min），exit 0，4467 ops，complete=false。分段：fastScanMs=20s（dop=4，4345 handled/122 fallback）、treeMaterializationMs=2,614s（全部耗时所在）、parallelFallbackWorkers=4/resolved=122（并行真正接管）。
- **语义对照**：4466/4467 ops 全等，topLevel/blocking 等。唯一差异 op `20260902T105854Z-0e2c914c…`（target=TencentDB-Agent-Memory）：base errors=[plan policy SHA 漂移] vs cand errors=[AcquireSafeTreeDeleteFileLease lease 失败]。
- **根因 A（语义差异）**：嵌套树。该 target 下有 node_modules/src/.git/7 个 quarantine 等 ~14 个子树各自是独立 op 的扫描根；精确匹配分组把它们分到不同 worker → 并发扫嵌套树 → lease 冲突。修复：分组改前缀并查（target/quarantine 去尾 \ 后相等或互为目录前缀即同组，确定性首现合并，CodexSafeTreeDelete.ps1 Invoke-...ParallelFallback）。
- **根因 B（速度）**：solo 实测 C# 扫描 68,771-entry 树 104s（非回退，真慢）——目录级并行批次在 node_modules 类树大量 <8 文件目录走串行分支。修复：改**全树一批并行填充**（ScanContext.PendingFiles 树级列表，walk 结束后一次 FillPendingFiles；rootGuard 由 PS wrapper 全程持有 + 每文件 finalpath/identity 双验 fail-closed 不变）。改后 solo 15.3s（6.8x），manifestSha 与串行版逐字节一致（f25c56a3…），物化 537ms。
- 待做：4 套件重跑（后台 bash-wmnrbnef）→ 冷跑 #2（预期 <60s； semanticSha256 == N1 88d4b679… 且 4467/4467 全等）→ n2-after 指纹 → git diff --check + 清 .scratch → IMPLEMENTATION.md。
- 若冷跑 #2 在 60-90s：Parallel.ForEach 度 32→64 重试一轮；仍超则 DONE_WITH_CONCERNS。

## 恢复后进展（第三轮：物化 C# 化 + 共享树路由）
- **SMA 编译可行性已实测**（.scratch/sma-materialize-probe.ps1）：Add-Type 默认引用集含 System.Management.Automation；C# `new PSObject()` + 4 个 PSNoteProperty 与 `[pscustomobject][ordered]` 形状逐属性一致（relativePath/kind/sha256/identity，identity=string[2]，sha256 可为 null），68,507 entry 物化 249ms（含 JIT）vs PS 循环 1050ms。
- **C# 改动**（CodexSafeTreeDeleteStatusScan.cs）：①加 `using System.Management.Automation;`；②`StatusTreeSnapshotResult.MaterializeEntries()` 返回 PSObject[]；③plan-approved fallback 抛出前 best-effort 填充 `result.TargetPath/QuarantinePath`（catch-all，缺失只损失并行度）。
- **PS 改动**（CodexSafeTreeDelete.ps1）：①`Get-CodexSafeTreeDeleteStatusTreeSnapshotFast` 物化循环换成 `$fast.MaterializeEntries()` 一次调用；②fallbackInputs 增 RouteTargetPath/RouteQuarantinePath；③`Invoke-CodexSafeTreeDeleteStatusParallelFallback` 分块从 i%workerCount 改为**按树分组**（T:targetPath / Q:quarantinePath / U:index 键，OrdinalIgnoreCase，组按首现 round-robin），workerCount=min(dop,组数)，返回形状改 `{resultByIndex, workerCount}`，调用方 metrics 用返回的 workerCount；④自包含注释更新（BCL+SMA+P/Invoke）。
- **语义安全网**：分组只是避免 lease 冲突的优化；万一仍有冲突，worker 失败 → 调用方整体回退串行重放（语义不变）。
- **树扫描点确认**：仅 4 处 Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot（planned:target、purging:quarantine、restored:target、recoverable:quarantine），archived flow 不扫活树；quarantine 由 targetPath+generationId 函数派生 → 按 targetPath 分组充分。
- **closure 合同**：CodexSafeTreeDeleteStatusScan.cs 不在 CodexSafeTreeDeleteClosure.ps1 固定清单（自包含独立缓存，源 SHA sidecar 失效自动重编），加 SMA using 不影响 closureSha256。
- **4 套件重跑全绿**：Status 39 / UncertainRecovery / Restore / SchemaCompatibility 10。
- 待做：全量冷跑（后台 bash-vokf2zwu）→ 等价对照（semanticSha256 必须 == N1 88d4b679…）→ n2-after 指纹 → git diff --check + 清 .scratch → IMPLEMENTATION.md。

## 风险/注意
- Add-Type 缓存：改 .cs 后源 SHA 变化自动重编（CodexSafeTreeDelete.ps1:20-29），无需手工清。
- `ConvertTo-Json` 大对象序列化耗时不进 60s 预算?（最终一次 ConvertTo-Json 229ms，OK）。
- 冷盘 fast scan 22s（首轮验收预算）+ 并行余项 ≈ 45-55s 预测。

## N3 节点最终状态（2026-09-08，本节点已完成收尾）

- **结果**：全量冷启动 207,820ms → **98,050ms**（2.12x；累计较 N1 84.6min 为 51.7x）。<60s 未达，DONE_WITH_CONCERNS。semanticSha256 == N1 `88d4b679…`，equivalence-n3a.json 4467/4467 全等（topLevel/blocking equal）。
- **改动**：receipt 门控快路径 `Resolve-CodexSafeTreeDeleteStatusReceiptFastOperation`（CodexSafeTreeDelete.ps1:4298，提交前零 metrics 副作用、不完全匹配 `$null` 回退）；C# 增 `StatusScanResult.PlanManifestSha256`（无 txn receipt op 并行预算）、`TryExtractPlannedPlanFields`（Utf8JsonReader 提取 plan 四字段）、`TestStatusTransactionV2StrictShape`（v2 严格形状复核）；prefetch 注入 planManifestSha256；dop min(4,cpu-2)→min(8,cpu-2)；观测计数器 parallelFallbackReceiptFastResolved（n3a 接管 68/122）。
- **slice 40 根因**：T1 快路径漏计内层 ApprovedPlan 的 policy 重读（920B/op）；参考 T1 = scan(plan+txn) + txn:3924 + txn 重读:5895 + plan 重读:5287 + policy 重读:5330；op catch :4221 无重读。修复=commit 前 policyVerify live 读（sha==CurrentPolicySha256 才 commit）+ 计数 2*txn+plan+policy。
- **验证**：四套件全绿（Status 40/40、UncertainRecovery、Restore、SchemaCompatibility 10）；evidence-fingerprint-n3-before/after 逐字段一致（8f25b06f…）；Validate-ModuleBoundaries PASS；git diff --check 通过。
- **剩余瓶颈**：TencentDB 嵌套超组单 worker 串行 ~89s（父树+子树双重扫描，合同禁止跨树哈希复用）。下一路径：①嵌套扫描 lease 安全交错（中高险）；②54 个非接管 op 逐类归因扩 receipt 覆盖。预估①后 ~40-55s。
- **已知边界（未触碰）**：N2 遗留 C# TryBuildApprovedMissingTransactionOutcome inconsistent+无 target 分支未应用 :4214 漂移覆盖（生产 evidence 未命中，等价通过）。

## N4 节点最终状态（2026-09-08，本节点已完成收尾）

- **结果：DONE（<60s 达标）**。全量冷启动 98,050ms → **42,683ms**（cold-run-result-n4c.json，净载；n4b 64,531ms 为套件并发争用轮）；累计较 N1 84.6min ≈ 118.8x。semanticSha256 == N1 `88d4b679…`，equivalence-n4b/n4c 均 4467/4467 全等（changed=0、topLevel/blocking equal）。
- **根因**：PowerShell 方法绑定器对大 string 实参整串深拷贝（109M 字符单参 ≈6s/881MB 瞬时分配，双参 ≈12s/1.7GB；ReferenceEquals 同实例也不例外；receiver/byte[]/属性读免费）。`MatchesSnapshot(sha,text)` 对每个大 plan op 征税 ~8-14s，8 worker 下叠加 LOH GC 风暴。
- **修复**：比对收进 C# 同实例（`StatusScanResult.ValidateReceiptAgainstOwnSnapshot()` 无参 + `MatchesPlanSha256` 短串绑定 + ReferenceEquals 短路）；prefetch 注入 `scanResult`/`receiptPlan*` 四字段；删 N3 `TryExtractPlannedPlanFields`；快路径删 ComputeFromPlanText PS 重试；参考路径 :3784 冗余重比对复用 `$statusPlanValidationMatches`。探针 idx4106 14.65s→314ms。
- **latent corner 反转（owner 待裁决）**：N2 注记"生产未命中"证伪——基线内 23 个生产 op 命中。首轮按参考语义修 C# 导致 n4a changed=23（equivalence-n4a.json 存证）；实测纯参考解析器（仅 FAST_SCAN=0 可达）产出 manual-review+双错误，与冻结基线（inconsistent+单错误）分叉。已回退 C# 保持合同语义，slice 41 双侧钉住（管线=基线形状、参考解析器=:4214 形状，任一侧改向变红）。分叉方向（收窄 :4214 / 重建基线）留 issue owner 裁决。
- **验证**：四套件最终代码态全绿（Status 41/41、UncertainRecovery、Restore、SchemaCompatibility 10/10）；evidence-fingerprint-n4-before/after 逐字段一致（8f25b06f…）；Validate-ModuleBoundaries PASS；git diff --check 通过。
- **未做**：①超组 lease 安全交错分组（已达标，不再需要；未来压缩仍看 TencentDB 双扫地板）；②54 个慢 fallback op 归因（预算被 corner 取证消耗，非阻塞）。

## N5 节点最终状态（2026-09-08，本节点已完成收尾）

- **结果：DONE**。处置独立 reviewer 5 条发现（M1/L1/L2/L3/L4）。冷跑 n5a **54,235ms**（<60s 达标；方差对照轮 n5b 88,772ms 超预算但语义等价——同代码族分段求和振荡 N4 50-78s 与 N5 46-79s 区间完全重叠，计数器/stdoutBytes 逐字节一致，环境噪声）；equivalence-n5a/n5b 均 4467/4467、changed=0、semanticSha256 `88d4b679…` 不变；指纹 n5-before/after 逐字段一致（8f25b06f…、4467 ops、25,863 entries）。
- **M1**：并行 fallback 合并改全缓冲（13 个本地缓冲变量，结果数校验通过后一次性合入共享 MetricsState），worker 失败零污染、串行重放不再双计，receiptFastResolved 不自相矛盾。未加专用失败 fixture（无干净注入点，拒绝为测试加生产钩子）；靠代码评审 + slice 39/40 串行腿（即回退后重放路径）+ 成功路径值恒等覆盖。
- **L1**：receipt 快路径主体整体 try/catch + 入口快照 7 个数值 metrics 字段 + catch 回滚并逐出本调用新增树缓存项，任何异常单 op 降级参考重放（不再拖垮 worker 整批）；PlanManifestShaCache 确定性值保留。包装后函数体 297 行模 +4 缩进逐字节不变（node 机械核验）+ ParseFile 零错误。
- **L2**：fallback 分组键改 `ReceiptPlanTargetPath/ReceiptPlanQuarantinePath`（AssertDPath 规范化，与 worker 实际打开路径同源），raw 值仅留 operation payload；null 不参与分组（既有语义，无 lease 风险）。
- **L3**：回滚组合矩阵写入 IMPLEMENTATION.md N5 段。要点：`FAST_SCAN=0` 单独已不等于纯串行（全部 op 作为 fallback 输入走并行 worker）；纯旧串行基线 = FAST_SCAN=0 + PARALLEL_FALLBACK=0 + TREE_FAST=0。
- **L4**：Status slices 41→42。取证修正任务预设：record A 管线 op 经 C# `namespace-entry-type-other` 回退（ProbeNamespace 先于 receipt 签发），由参考重放产出形状；PS 快路径 record A 分支是 TOCTOU 防御、静态管线不可达，用直调钉（先扫描取 receipt 再替换 target 为文件）确定性覆盖。两条 fast/slow 慢腿补钉 PARALLEL_FALLBACK='0'；slice 39 新增 TREE_FAST=0 整轮等价 + metrics parity。
- **验证**：四套件最终代码态全绿（Status 42/42、UncertainRecovery、Restore、SchemaCompatibility 10/10）；Validate-ModuleBoundaries PASS（files=3107 modules=5）；git diff --check 通过。
- **杂项**：`.scratch/safe-tree-delete-perf/` 按仓库 .scratch 惯例入 .gitignore（探针留盘不入库）；N5 调试残留已逐文件删除（无递归删除）。
- **未做/遗留**：M1 专用失败 fixture（上述理由）；N4 latent corner 分叉方向仍待 issue owner 裁决（slice 41 双侧钉住）。
