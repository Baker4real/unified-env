## #22 关票结论（2026-08-19 证据 + 2026-08-20 执行时复核，基于 HEAD cd7661f）

**结论：12 条 AC 全部可证，关闭。** `reports/safe-tree-delete-issue22-regression-20260819/` 是 2026-08-18 审核遗留的唯一实质阻塞——「既有全部 safe-tree-delete 测试保持通过」缺少当前代码状态全绿证据——的补齐证据。归档执行本体（2191 条逐条 Archive + 复检 0 候选）于 2026-08-13/14 完成，证据链见该目录 AC-MATRIX.md。独立对抗审查（未参与实现的只读 reviewer）判定 **EVIDENCE_SUPPORTS_CLOSE、无 HIGH 发现**；其唯一 MED 发现（"Phase3Integration 绿轮未重演 metTarget=true 路径"）经仲裁推翻——守护哈希与时间戳链证明绿轮窗口（17:22–17:39Z）内 issue36 快照仍为写脏的 true 版本、恢复发生在其后约 17:55Z，绿轮实际重演了触发首红的路径并通过（`unexpected-reds.md` 透明性节）。

### 执行时 live 复核（2026-08-20T00:48:29Z，关闭当刻重跑生产只读 Status）

| 项 | 值 |
| --- | ---: |
| operations | 2833 |
| `blockingRecords` | 118 |
| `lifecycle=terminal` | 2713 |
| `journalStatus=archived` | 2200 |
| `complete` | false（合理终态，票面明确不要求翻 true） |
| `policySchemaVersion` | 4 |

- 相对 #49 三联（2482/116）的增量来自后续运维记录自然增长与 2026-08-13/19 新 residual（v2 quarantined/inconsistent），符合 AC「实际剩余条数与预期偏差有解释」；票面「约 79」是 #19 过期投影，不以此为口径。
- 5 条 v1 未终结（`0609f165`/`a5fd8743`/`c602a5b7`/`0f0aeb5d`/`26f7ea53`）与历史 v2 `20260805T083256Z-1ba06d2f-…` 全部仍在视图且 blocking，未被归档。
- #48 的 42 条 `purged+manual-review` 继续 blocking，未为凑数 Archive。
- leftover `0ab1e1b6` 全程未动（transaction SHA-256 `4e73aedc…` 前后一致），属 #53 清空集。

### 全量回归（AC12）

- 代码基线 HEAD `cd7661f`（summary.json `gitHead`），pwsh Core 7.6.4，逐测试独立进程，stdout/stderr 全量落盘本目录。
- **manifestCount=27、completedCount=27、passCount=26、failCount=1、unexpectedFailCount=0、acVerdict=通过**。
- 唯一 fail：`tests/Test-CodexSafeTreeDeleteFileSystem.ps1`（exit=1，known waiver **GitHub #35**：未提权 diskpart 无法创建一次性 FAT32 VHD 实卷，stderr 原文「Program 'diskpart.exe' failed to run … 请求的操作需要提升」）。未修不跳，保持 expected-red。
- host-live（ProductionSmoke、Phase3Production）不在本票范围（#24 管辖）。

### 本次回归的意外红与修复（2 处，均为测试侧过期断言，修复 diff 见 static-ac-evidence/unexpected-red-fixes.diff）

1. `Test-CodexSafeTreeDeletePhase3Integration.ps1`（exit=1，10s 早期失败）：断言 `#36 metTarget 必须仍是 false（未达 3x）`。根因：套件内 `Test-CodexSafeTreeDeletePhase1Integration.ps1`（manifest 序在前）会用**当前生产管线**重写 `reports/safe-tree-delete-issue36-20260817/scale-phase1.json`——#42 于 2026-08-19 把 `ParallelPurgeCoordinator` 接入生产 Purge 后，本轮实测 speedup=3.845、metTarget=true（git HEAD 提交版为 0.633/false），历史钉住过期。#42 自己的回归（iteration-2-full-regression.stdout.txt 34 行）同样 exit=1，其处置为 checkout 后复跑。本次修复：三个同类钉住（#36/#37 metTarget、#41 IsWithinTarget）改为「字段存在且为 bool」检查，与同文件既有「不钉历史 1.02 / 不钉 0.964 / 不钉 18.659」设计一致；#42 团队当日也遇到同一红（其 GROK-FINAL-REPORT 第 95 行），修复后该测试重跑 exit=0（16.4 分钟）。
2. `Test-CodexSafeTreeDeleteParallelismBenchmark.ps1`（exit=1）：断言 `FromDetection optimize 必须等于本机小文件峰值效率 DOP`，把**实现常量**（#40 2026-08-19 复测钉定的 2/2/2，`CodexSafeTreeDeleteFileIdentity.cs` 常量 + 性能 spec 操作者指南背书）与**现场实测峰值**（随机器状态浮动：#42 当轮测 2、本轮测 4）做等值断言，inherently flaky。本次修复：五处等值断言改为钉 #40 复测合同值 2/2/2，实测峰值保留在 analysis.json 的 `fromDetectionMatchesMeasuredPeaks` 作证据记录。修复后重跑 exit=0（3.1 分钟）。

两处修复都在 #22 契约授权的文件清单内（tests/Test-CodexSafeTreeDelete*.ps1），未触碰任何生产实现代码。透明性：Phase3Integration 绿轮重跑期间 issue36 快照仍为套内写脏版（metTarget=true，守护哈希 `048f9ced…`，恢复发生在其后），绿轮实际重演了触发首红的路径；且新断言为「字段存在且为 bool」类型级检查、对 true/false 两路径等价，绿轮效力不依赖快照状态（详见 static-ac-evidence/unexpected-reds.md）。

### 归档数字与偏差（AC2，引用链见 AC-MATRIX.md）

1674（#19 基线）→ 归档前 live 2290 → **归档后 109**（主轮 acceptance.json：109 = 89 未解析 + 5 v1 未终结 + 1 历史 v2 未终结 + 10 窗口内 recoverable→inconsistent + 4 v1 purged 仍 manual-review；对票面投影 79 的 delta=30 逐项可查）→ 复检 110（+1 新 residual，blocking-delta-vs-20260814.json）→ #49 三联 116，其中 **42 条 purged+manual-review 属 #48**（观测成功后必须继续 blocking，不得为凑数 Archive）。`complete=false` 不是本票失败（#23 管辖）。5 条 v1 + 1 条 v2 未终结全程在视图（status-before.summary.json `historicalResidualsStillVisible`）。

### 静态核验（AC7–AC11，证据在 static-ac-evidence/）

- 无 BatchArchive：`rg -i batcharchive` 生产代码零命中（唯一命中为 AC11 fixture 的测试局部变量）；policy schema 仍 v4，managed/ 无 v5。
- 归档判据代码：`Invoke-CodexSafeTreeDeleteArchive` 自 #17 引入 commit 6d68fb4 起 111 行函数体（6d68fb4 位于 1101–1211、HEAD 位于 2387–2497）逐字节未变（含 mutex 外/内两份三条判据）；支撑函数唯一差异是 e2064a3 的 plan 属性断言共享化（必备 12 属性相同）。
- 证据根三层保护：policy denylist（`codex-run-evidence.deniedExactPaths` 含 run-evidence\safe-tree-delete）、最小后代深度 2、`BackupRetentionPolicy.ps1` run-evidence `Manual=$true`，相关文件自 #22 执行日前最后变更（policy 5f7f597 仅加无关条目；retention d54ef60 2026-07-22）。
- 错误隔离 fixture：ControlPlane 1283–1432 行 good-a/bad/good-b 三明治，断言其余仍归档、不合格稳定原因拒绝且零写入、Status 只把合格项标 terminal；本轮该测试 exit=0（100.2s）。

### 残留耦合债务与残留物（声明，不在本票修复）

1. **已知测试写脏 tracked 快照**（本次全量实测的完整清单见 restore-record.json）：HashReuse→issue32 scale-*.json；PurgeHashReuse→issue33/34/37/39；Phase1Integration→issue36 {filesystem-probe,scale-phase1}.json；JournalPerformance→issue41-20260819 journal-performance-report-*.json；Phase3Integration→issue42-20260819 {baseline-partial,coordinator-journal,filesystem-probe,scale-phase3}.json；ParallelismBenchmark→parallelism-benchmark-20260819 全目录。全部已按契约 `git checkout --` 恢复（跑前基线均为 clean）。
2. **未跟踪测试残留目录 6 处**（fixtures-* x4、coordinator-journals、benchmark work/，共约 1050 文件）：fixture 测试输出与中断残留；其中 issue36 fixtures 内含 3 条 fixture 事务（1 条 quarantined 但 quarantine 实体已消失，受管恢复/清理对其实败闭锁）。本票契约禁止生产控制面写操作且全局规则禁止非受管递归删除，故保留在原地并上报——处置需后续经 managed 控制面单独立项（policy `environment-reports` 条目覆盖 reports/ 根）。
3. `reports/.codex-safe-delete-0ab1e1b6-….quarantine/` 与对应 transaction（SHA `4e73aedc…`）全程未动，#53 管辖。
4. Validate-ModuleBoundaries 当前唯一失败为上述 quarantine leftover `no owner`——该失败在 HEAD（未含本票改动）同样存在，属 #53 管辖的先在状态；本票新增文件经 manifest 前缀登记后全部有唯一 owner。

### 关票后继

blocked-by #19 已 CLOSED。#24（host-live ProductionSmoke/Phase3Production）可按其自身验收推进。本评论文本与版本化证据 `reports/safe-tree-delete-issue22-regression-20260819/` 一同进入默认分支后发布，随后执行 `gh issue close 22`；关票序列的下一票是 #24（#52 管辖）。
