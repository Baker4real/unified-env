# Issue #49 实现关口（2026-08-23 第二轮）

**判定：`DONE`。`metTarget=true`。** 对抗复核（无 HIGH、2 MED 已修、LOW 项留档）后结论不变。未 commit、未 push、未 `gh issue comment|close|edit`。未 Purge/Restore leftover，未 Archive 任何记录，未改 `managed/safe-tree-delete/policy.json`、live wrapper、Apply/Purge 语义与 `ParallelPurgeCoordinator`。

协议：`protocol.md`（复用并从属 `reports/safe-tree-delete-issue49-20260817/protocol.md`）。三次冷启动：`cold-1/2/3.json`，汇总 `cold-summary.json`，基线复跑 `cold-0.json`。

## 关口

| 项 | 结果 |
| --- | --- |
| 冷/热测量协议已记录且可复核 | 是。本轮复用 20260817 协议，差异与等价性验证记于 `protocol.md` |
| 三次独立冷启动墙钟 <60s | **是（正式 AC 三联 = MED 修复后三联 cold-5/6/7）。** 9.762 / 9.791 / 9.237 s；修复前三联 cold-1/2/3 为 13.279 / 13.378 / 13.256 s（保留为历史样本）；修复前同日基线复跑 199.357s |
| 每次记录 operations / entries / bytesHashed / elapsedMs / 墙钟 / identity | 是。见下表与各 `cold-N.json`（childPid、launcherPid、wrapper SHA、UTC 时间戳） |
| terminal-archive 内容认证 + 现场 namespace | 是。fast scan 逐条复刻 marker 内容认证（archive 17 字段精确属性、plan/tx SHA+identity+generation+path 绑定、现场 namespace probe）；不靠 marker 存在 |
| `complete` / blocking / 未终结判定语义 | 是。与 slow 路径全量等价（见等价性验证）；purged+manual-review 计数与 slow 一致 |
| 未放宽 allowlist / 最小深度 / quarantined-to-terminal；纯 Status 零写入 | 是。`policy.json` 未改；三次 evidence 计数不变（2956/9465）；leftover SHA 三次均为 `4e73aedc…339d7` |
| 与 #26–#43 边界 | 是。未消费 `SessionHashCache`。fast scan 为调用内、随进程死亡；`consumptionBoundary=status-invocation-local-not-session-hash-cache` |
| 不用 VSS | 是 |

## 三次冷启动

### 正式 AC 三联（MED 修复后，cold-5/6/7，汇总 `cold-summary-post-fix.json`）

入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`（wrapper SHA `62957269bbe6b96417d7959140103f59e737f50337725bc249fd7fef71862310`；wrapper 内部调用 pwsh 7.6.5，launcher 为 pwsh 7.6.4；代码状态 = 含 MED-1a/1b/2 回退修复）。

| 次 | 墙钟 s | elapsedMs | operations | entriesScanned | bytesHashed | exit | childPid | zeroWrite | leftover SHA | #48 型 purged+MR | blocking |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: |
| 5 | 9.762 | 8467 | 2960 | 3467 | 421725493 | 0 | 56272 | true | `4e73aedc…339d7` 不变 | 664 | 747 |
| 6 | 9.791 | 8091 | 2960 | 3467 | 421725493 | 0 | 19424 | true | 同上 | 664 | 747 |
| 7 | 9.237 | 7787 | 2960 | 3467 | 421725493 | 0 | 54300 | true | 同上 | 664 | 747 |

`complete=false`；fastScanMs 1452-1827，handled=2944，fallback=16，DOP=4；treeMaterialization 2626-2876ms（approved-plan 回退记录）。

### 修复前三联（历史样本，cold-1/2/3，汇总 `cold-summary.json`）

| 次 | 墙钟 s | elapsedMs | operations | entriesScanned | bytesHashed | exit | childPid | zeroWrite | leftover SHA | #48 型 purged+MR | blocking |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: |
| 1 | 13.279 | 10862 | 2956 | 3463 | 421492073 | 0 | 33612 | true | `4e73aedc…339d7` 不变 | 664 | 747 |
| 2 | 13.378 | 11406 | 2956 | 3463 | 421492073 | 0 | 17504 | true | 同上 | 664 | 747 |
| 3 | 13.256 | 11210 | 2956 | 3463 | 421492073 | 0 | 52520 | true | 同上 | 664 | 747 |

（`cold-4.json` 为修复后单次确认样本 9.308s。）

`complete=false`。leftover `0ab1e1b6` 现为 `manual-review` 且在 blocking（projects 根迁移后其 plan 被现役 policy 拒绝，属 #48 只读观测合同的正常演化；slow 路径同一判定，见等价性验证）。

现场说明：本轮测量时 evidence root 已由本轮测试套件（live wrapper 系列）自然增长到 2956 run / 3463 entriesScanned（其中 507 为 fallback 记录的树物化事件），比 8-18 的 2482/3952 更大；增长不是本票伪造，三次测量在同一状态下进行。

## 等价性验证（fast vs slow）

同进程函数调用对比（`equivalence-fast.json` / `equivalence-slow.json`，2946-op 时点）：

- 2946 条 operations 逐条 `ConvertTo-Json -Depth 8 -Compress` 对比：**0 差异**。
- `complete`、`policySha256`、`migrationReadiness.blockingRecords` 完全一致。
- `metrics.entriesScanned` 一致；`bytesHashed` fast 比 slow 少 1560 字节：slow 参考路径对非 UTF-8 plan 自身双计（prefetch 在 UTF-8 解码前先计 bytesHashed、解码抛错后跳过、Resolve 重读再计），fast 每文件只计一次——差值来自 slow 的重复计数，非 fast 少读。
- slow 轮墙钟 86851ms（OS-warm）对 fast 2526ms。

**对抗复核修复（MED-1a/1b/2）后复跑**（`equivalence-fast-after-med-fix.json` / `equivalence-slow-after-med-fix.json`，2960-op 时点）：operation mismatch = 0，blockingRecords 一致，`bytesHashed`（421725493）与 `logicalBytes`（187788899）完全相等。

**等价性边界**：fast path 只对 producer 规范形态输入给出最终结果——plan/transaction/treeManifest 属性名与 canonical 键 ordinal 一致、必需属性齐全、schemaVersion 在 Int32 范围内；否则回退 PowerShell 参考路径裁决（覆盖复核发现的 MED-1a StrictMode PropertyNotFound 文本、MED-1b 属性名大小写变体、MED-2 Int32 溢出 cast 错误三类输入；`tests/Test-CodexSafeTreeDeleteStatus.ps1` 的 MED 回归 slices 钉住 fast==slow 逐字节一致）。

## 成本段（cold-1，ms）

| 段 | 基线复跑 cold-0（优化前） | cold-1（优化后） | 说明 |
| --- | ---: | ---: | --- |
| directoryEnumeration | 64 | 41 | 不是主因 |
| prefetch（未归档句柄读） | 14841 | 0 | 被 fast scan 取代 |
| planTransactionRead | 39429 | 540 | C# 并行句柄绑定读 |
| terminalArchiveAuth | 19693 | 373 | marker 认证不跳过，仅换实现 |
| treeMaterialization | 0 | 4554 | 本轮新增的 approved-plan 回退记录走原 PS 路径 |
| sha256 | 58 | 54 | 认证仍重算文件字节 |
| activeResolve（回退） | 76041 | 8241 | 12 条回退（plan-approved 等）走原路径 |
| archivedResolve（回退） | 103336 | 0 | 归档回退 0 条 |
| **fastScan（新）** | — | **1706** | 2944 条 fast 处理，DOP=4 |
| elapsedMs | 196400 | 10862 | |

墙钟 13.3s 中剩余约 2s 为 pwsh 启动 + 程序集加载 + 3.86MB Status JSON 序列化输出。

## 做了什么

1. 新增 `scripts/lib/CodexSafeTreeDeleteStatusScan.cs`（自包含，BCL + 本地 P/Invoke）：`StatusScanCoordinator` 以 `Parallel.For`（DOP = `Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit`，即原已计算未使用的 jsonParseThrottleLimit=4）逐 run 处理：
   - 归档记录：复刻 `Read-CodexSafeTreeDeleteStatusTerminalArchive` 全链（路径验证、三文件句柄绑定读 + SHA + identity、严格 JSON、17 字段精确属性、SHA/identity/generation/path 绑定、v1/v2/v3 判定、quarantine 必须 absent 的现场 probe）。
   - 未归档记录：复刻 `Read-CodexSafeTreeDeleteApprovedPlan` 的拒绝判定顺序（含 plan.json 祖先 reparse walk、policy/allowlist/深度/denylist、treeManifest 全量校验）与 #48 拒绝后只读观测链（tx 读入 + v1/v2/v3 observed 校验 + 现场 namespace probe + 逐条相同错误消息）；plan 被批准或任何不可证明情形 → 回退原 PS 路径。
   - 每条回退记录把已读 plan snapshot 注入 prefetch cache，保持单次读取合同。
2. `scripts/lib/CodexSafeTreeDelete.ps1`：内联 `StatusJsonTopLevelReader` 移入 .cs 批次；新增 `Invoke-CodexSafeTreeDeleteStatusFastScan` / `New-CodexSafeTreeDeleteStatusOperationFromScan`；`Get-CodexSafeTreeDeleteStatus` 主循环接入 fast scan（kill switch：`CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0` 走全原路径）；`statusSegments` 增加 fastScan* 字段。
3. 观测合同（#48）保持：`Resolve-CodexSafeTreeDeleteStatusOperation` 未删未改语义，fast scan 对拒绝 plan 的记录产出与参考路径逐字节相同的 errors/lifecycle/字段。

## 对抗复核修复（2026-08-23 第二轮）

按复核结论修复 2 MED + 1 同类，原则「不可证明逐字节等价即回退」：

- **MED-1a（缺失必需属性 → errors 文本漂移）**：`CodexSafeTreeDeleteStatusScan.cs` 的 `HasCanonicalPlanShape` 要求 12 个必需属性 ordinal 齐全，否则回退（PS 参考在拒绝 catch 内的 StrictMode PropertyNotFoundException 由参考路径原生产出）。
- **MED-1b（属性名大小写变体分叉）**：`HasCanonicalPlanShape` / `HasCanonicalTransactionShape` / manifest 与 entry 的 `HasOnlyCanonicalPropertyNames` 要求所有键与 canonical 名 ordinal 一致（`Summary` 等变体回退，PS 大小写不敏感语义裁决）。
- **MED-2（schemaVersion 超出 Int32）**：plan 与 treeManifest 的 schemaVersion 超出 Int32 范围即回退（PS `[int]` cast 错误消息类归参考路径）。
- `tests/Test-CodexSafeTreeDeleteStatus.ps1` 新增 2 个 MED 回归 slices（22→24）：MED-1a（缺 targetPath + tx，断言 fast==slow 逐字节一致且 slow errors 为 PropertyNotFound 语义）、MED-1b（`Summary` 变体，断言 fast==slow 且 slow 分类 planned）。
- 复核 MED 探针（临时夹具）实测三类输入 fast==slow；fix 后 live 等价性复跑 0 差异且 metrics 完全相等；确认冷启动 cold-4 墙钟 9.308s、metTarget=true。
- 正式 AC 三联在修复后状态重测为 **cold-5/6/7：9.762 / 9.791 / 9.237 s**（`cold-summary-post-fix.json`，`kind=post-med-fix-official-triple`）；修复前三联 cold-1/2/3 保留为历史样本。

## 行为与测试

| 套件 | 结果 |
| --- | --- |
| `tests/Test-CodexSafeTreeDeleteStatus.ps1` | **24 slices**（22 原有 + 2 MED 回归），exit 0 |
| `tests/Test-CodexSafeTreeDeleteSchemaCompatibility.ps1` | 10 slices，exit 0（MED 修复后复跑） |
| `tests/Test-CodexSafeTreeDeleteControlPlane.ps1` | 10 slices，exit 0（MED 修复后复跑） |
| `tests/Test-CodexSafeTreeDeleteMetricsEvidence.ps1` | 2 slices，exit 0 |
| `tests/Test-CodexSafeTreeDeleteUncertainRecovery.ps1` | exit 0 |
| `tests/Test-CodexSafeTreeDeleteRestore.ps1` | exit 0 |
| `tests/Test-CodexSafeTreeDeleteCrashSafety.ps1` | 13 slices，exit 0 |
| `tests/Test-CodexSafeTreeDeletePurgeBatch.ps1` | exit 0（scale10000MetTargetVsBaseline=True） |
| `tests/Test-CodexSafeTreeDeleteHashCache.ps1` | 5 slices，exit 0 |
| `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` | exit 1 = 已知豁免（非提权会话在 FAT32 VHD 实卷段 `diskpart` 需要提升；此前确定性段全部通过才到达该段） |

既有失败（与本票无关，均先于本票改动存在）：
- `tests/Test-CodexSafeTreeDelete.ps1` 生产策略断言：测试期望 `cc-switch-rust-target` 根为 `D:\Codex\projects\...`，受保护 projects 根迁移 WIP 已把 `managed/safe-tree-delete/policy.json` 改为 `D:\agents\projects\...`（21 处）。policy.json 属禁改文件，期望值更新属该 WIP。
- `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`：变异段前置断言要求 live `.ps1` SHA=`636cb140…`（迁移前转发包装），现役 wrapper 已被迁移 WIP 指到 `D:\agents\projects\统一环境`（SHA `ec14e863…`）；另一次运行在 status-zero-write 收口断言遇到 3 个环境 python/conhost 进程被进程树扫描误捕（Status 本身 exit 0、4.7s）。

## `git diff --check`

对本票 hunks 执行，仅 CRLF 将被 git 规范化的警告，无 whitespace error（见实现报告）。

## 未验证

- 未刷 OS standby（协议不要求，且明确非 VSS/EmptyStandbyList）；三次均为独立新进程，同会话此前已跑过 Status（OS-warm 倾向），对 13s 结论无实质影响。
- FAT32/网络实卷 e2e（#35 waiver）与 ProductionSmoke 变异段（WIP SHA 漂移）未在本票修复，见上。
- fast scan 程序集缓存新增 `D:\Codex\temp\unified-env-addtype\CodexSafeTreeDeleteStatusScan.dll`（复用 CodexHostSafety 的 staleness 检查模式；源文件更新自动重编）。不在 evidence root，不触碰零写入合同的度量对象。
