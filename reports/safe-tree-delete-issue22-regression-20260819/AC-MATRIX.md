# Issue #22 验收矩阵（AC-MATRIX）

**生成时点**：2026-08-19（回归执行与静态核验当日）  
**代码基线**：HEAD `cd7661f17f6fec06791cf50d53a76548b8718dd0`（本目录 summary.json 记录 `gitHead`）  
**核验人**：#22 唯一实现代理（本目录证据为本次新采集；历史 AC 引用 2026-08-13/14/15/16/18 已入仓证据）  
**结论先行**：12 条 AC 全部可证。AC1–AC6 依赖历史执行证据（2026-08-13/14 两轮逐条归档 + 复检）并逐条给出引用；AC7–AC11 在当前 HEAD 静态实证；AC12 由本目录全量 27 项 fixture 回归新证据支撑。

> 证据目录缩写：`本目录` = `reports/safe-tree-delete-issue22-regression-20260819/`。主轮（2026-08-13）执行证据原目录
> `reports/safe-tree-delete-archive-20260814/` 已被 commit 5f7f597 从分支删除，本目录
> `static-ac-evidence/main-round-archive-20260814-from-git-a557ddb/` 为从 git 历史（a557ddb，HEAD 可达祖先）
> 恢复的逐字节副本，可用 `git show a557ddb:<path>` 复核。

---

## AC1 候选集在执行时重新推导，不复用 #19 快照 — **通过**

| 证据 | 内容 |
| --- | --- |
| `static-ac-evidence/main-round-archive-20260814-from-git-a557ddb/archive-summary.json` | 主轮（2026-08-13T17:32Z 开工）`liveCandidateCount=2191`，候选来自开工前现场 live Status，非 #19 快照 |
| 同目录 `acceptance.json` | `liveBefore.candidateCount=2191`、`candidateDeltaFromBaseline1595=596`；`residualVersusExpected79.explanation` 明文「不得用 #19 快照当候选集。live 从 1980/1674/1595 增至 2300/2290/2191」 |
| `reports/safe-tree-delete-issue22-20260815/status-before.candidates.json` | 复检轮（2026-08-14T17:59Z）「由本次 live Status 推导的归档候选」，`liveCandidateCount=0`、`candidates=[]`——0 候选即停止，未为做事再 Archive |
| `reports/safe-tree-delete-issue22-20260815/blocking-delta-vs-20260814.json` | 「live blocking 相对 20260814 收口后 Status 的增量，不是 #19 快照」 |

## AC2 blockingRecords 从 1674 降至约 79，偏差有解释 — **通过（带偏差解释）**

数字链（每一跳都有落盘证据）：

| 时点 | blocking | 证据 |
| --- | ---: | --- |
| #19 基线（2026-08-10） | 1674（投影残差 79） | `reports/safe-tree-delete-status-baseline-20260810-evidence/status-output.json` |
| 主轮归档前 live（2026-08-13） | 2290（候选 2191） | 主轮 `acceptance.json` `liveBefore` |
| 主轮归档后（2026-08-13T19:06Z） | **109** | 主轮 `acceptance.json` `liveAfter.blockingRecordCount=109`；`residualVersusExpected79.actual=109, baselineExpected=79, delta=30` |
| #22 复检轮 live（2026-08-14T17:59Z） | 110（+1 新 residual） | `reports/safe-tree-delete-issue22-20260815/status-before.summary.json`（`blockingDeltaFrom20260814=1`）；`REPORT.md` 偏差表与 +1 条目解释 |
| #24 快照（2026-08-16） | 110（operations 2356） | `reports/safe-tree-delete-issue-status-20260818/comment-22.md` 引用 |
| #49 三联（2026-08-18） | 116（operations 2482），其中 **42 条 purged+manual-review 属 #48** | `reports/safe-tree-delete-issue-status-20260818-close-criteria/comment-22.md`（「blocking=116，含 #48 的 42 条 purged+manual-review；不要把票面约 79 当成必须打到的数，也不要 Archive 这 42 条」） |

偏差解释（主轮 `acceptance.json` 原文分解）：`109 = 89 未解析/空 status + 5 条 v1 未终结 + 1 条历史 v2 未终结 + 10 条归档窗口内 recoverable→inconsistent + 4 条 v1 purged 仍 manual-review`；归档前 live 投影 99（2290−2191），多出的 10 条是窗口内分类翻转。后续 109→110→116 的增量分别来自新运维 residual（+1，`blocking-delta-vs-20260814.json` 的 `added` 列表）与现场记录自然增长；116 中的 42 条是 #48 观测补丁成功后**必须继续 blocking** 的 purged+manual-review，不属可归档噪声。

## AC3 5 条 v1 与 1 条 v2 未终结仍在视图、未被归档 — **通过**

- `reports/safe-tree-delete-issue22-20260815/status-before.summary.json`：`v1UnterminatedCount=5`、`historicalResidualsStillVisible.v1UnterminatedVisible=true`、`v1UnterminatedMissing=[]`（五条 operationId 全部在列）；历史 v2 `20260805T083256Z-1ba06d2f-…`（quarantined、manual-review、policy 漂移）仍在 `v2Unterminated` 首位。
- `reports/safe-tree-delete-issue22-20260815/REPORT.md`「仍可见的 5 条 v1 未终结」段逐条列出全部 operationId 与状态（rolled-back / quarantined / prepared / purging / prepared）。
- 主轮 `acceptance.json` `liveAfter.v1UnterminatedCount=5`（归档后仍在）。

## AC4 归档过程零 evidence 文件删除或重写 — **通过**

- 主轮：`reports/safe-tree-delete-status-post-archive-20260814/REPORT.md`「证据根对照：2300 目录 / 6743 文件，零写入（`evidence-status-write-compare.json`）」；marker 本身为 create-only（spec Archive 段：任一判据不满足零写入、重复归档返回首份 marker 不改 bytes）。
- 复检轮：`reports/safe-tree-delete-issue22-20260815/evidence-ops-before-status.json` 与 `evidence-ops-after-status.json` 前后均 2321、addedOps=[]、removedOps=[]（`acceptance.json` `zero-evidence-rewrite` 条目引用）。
- 补充轮：`reports/safe-tree-delete-round-leftover-20260814/archive-verify.json` `allTransactionsUnchanged=true`。

## AC5 单条失败不中断其余；逐条结果可读 — **通过**

- 主轮：`static-ac-evidence/main-round-archive-20260814-from-git-a557ddb/archive-invocation-log.jsonl` 共 **2191 行**，每行一条：`capturedAtUtc / operationId / transactionPath / approvedTransactionSha256（每条现场重算）/ candidateSha256 / sha256MatchedCandidate / archived / alreadyArchived / refusalReason / error / exitCode / archivePath`；`archive-summary.json` `counts={attempted:2191, succeeded:2191, alreadyArchived:0, refused:0, failed:0}`。
- 驱动结构（补充轮 committed 版本，`reports/safe-tree-delete-round-leftover-20260814/invoke-archive-one-by-one.ps1` 52–110 行）：`foreach` 候选逐条 `try/catch`，单条异常写入 `record.error` 后继续下一候选（无 break/throw）；每条独立调用 `-Mode Archive -TransactionPath … -ApprovedTransactionSha256 … -ConfirmArchive`。
- 复检轮 0 候选：`reports/safe-tree-delete-issue22-20260815/acceptance.json` `per-item-results=not-applicable`（候选为 0），错误隔离行为由 AC11 的 fixture 回归覆盖且当轮绿（`tests-summary.json` `controlPlaneStandalone.exitCode=0`）。

## AC6 每条归档留下含时点的可追溯证据 — **通过**

- 每条 marker：主轮 `acceptance.json` `archive.terminalArchiveMarkerCount=2191`；marker 绑定 `archivedAtUtc`、plan/transaction path+SHA+file identity（spec Archive 段合同；本 HEAD 源码 `Invoke-CodexSafeTreeDeleteArchive` 写入 `archivedAtUtc`，见 AC8 定位）。
- 逐条调用日志每行含 `capturedAtUtc` 与 `archivePath`（AC5 所引 jsonl）。
- 补充轮 9 条：`reports/safe-tree-delete-round-leftover-20260814/archive-verify.json` 逐条 `markerExists=true`、`markerSha256`、`markerBytes`、`transactionShaUnchanged=true`。
- 磁盘对账：`reports/safe-tree-delete-issue22-comment-20260815/REPORT.md`（2200 marker = 2191 主轮 + 9 补充轮；11 条 terminal-无-marker 差逐条分类，均非 #22 候选）。

## AC7 未新增 BatchArchive 或任何等价批量入口模式 — **通过（当前 HEAD 实证）**

- `static-ac-evidence/ac7-batcharchive-scan.txt`：`rg -i "batcharchive"` 全仓命中**仅** `tests/Test-CodexSafeTreeDeleteControlPlane.ps1`（AC11 错误隔离 fixture 的测试局部变量名，循环逐条调用单笔 Archive）；`scripts/` 生产代码零命中。
- 历史核验：`reports/safe-tree-delete-issue22-20260815/preflight.json` `containsBatchArchive=false`、modes=Plan/Apply/Purge/BatchPurge/Status/Restore/Archive（BatchPurge 是既有独立票面模式，非 Archive 批量入口）；主轮 `archive-summary.json` `batchArchiveAdded=false`。

## AC8 归档判据代码未被改动 — **通过（当前 HEAD 实证）**

- 判据函数 `Invoke-CodexSafeTreeDeleteArchive`（`scripts/lib/CodexSafeTreeDelete.ps1`）：三条判据（`transactionStatus=purged` / quarantine namespace 缺席 / `restoreJournalAnchors` 为空）在 mutex 外与 mutex 内各一份。引入于 6d68fb4（2026-08-10，#17 归档能力落地）。
- `static-ac-evidence/ac8-archive-function-6d68fb4-vs-HEAD.diff`：函数体 111 行（6d68fb4 的 1101–1211 对 HEAD 的 2387–2497）**逐字节一致**（diff 唯一差异是函数之后新增的无关函数；该 diff 归档时提取窗口含函数尾随空行，即 1101–1212 / 2387–2498 共 112 行，含空行仍逐字节一致，结论不变）。
- `static-ac-evidence/ac8-archive-helpers-6d68fb4-vs-HEAD.diff` + `static-ac-evidence/ac8-ac9-criteria-and-protections.md`：支撑函数 `New-CodexSafeTreeDeleteArchiveRefusal` 逐字节一致；`Read-CodexSafeTreeDeleteArchiveSource` 唯一差异是 plan 属性断言换成共享 helper（e2064a3，必备 12 属性清单相同，另允许 spec 明文的新增可选字段 `fileIdentitiesV2`/`leafStreamSetV1`），判据相关逻辑未动。
- 执行时点核验：`reports/safe-tree-delete-issue22-20260815/criteria-code-watch.json`。

## AC9 证据根三层保护未改动 — **通过（当前 HEAD 实证）**

`static-ac-evidence/ac8-ac9-criteria-and-protections.md` AC9 节：

1. policy denylist：`managed/safe-tree-delete/policy.json` `codex-run-evidence.deniedExactPaths` 含 `D:\Codex\.codex\run-evidence\safe-tree-delete`（现场读取）。
2. 最小后代深度：同条目 `minimumDescendantDepth: 2`。
3. retention Manual：`scripts/lib/BackupRetentionPolicy.ps1:648` `run-evidence … Manual = $true`（「运行证据根不得自动清理」）。

git 历史：policy.json 最后变更 5f7f597（仅新增无关条目，本条目与 schema 未动）；BackupRetentionPolicy.ps1 最后变更 d54ef60（2026-07-22，早于归档执行）。执行时点核验：`reports/safe-tree-delete-issue22-20260815/protection-check.json`。

## AC10 policy schema 仍 v4，未激活 v5 — **通过（当前 HEAD 实证）**

- `static-ac-evidence/ac10-policy-schema-v4.txt`：`managed/safe-tree-delete/policy.json` `"schemaVersion": 4`；`managed/` 全目录无任何 v5 schemaVersion。
- 历史链：主轮/复检轮 `policySchemaVersion=4`（各 acceptance/summary）；`reports/safe-tree-delete-issue22-20260815/protection-check.json` `policySchemaVersion=4`。

## AC11 批量归档错误隔离 fixture 回归 — **通过（当前 HEAD 实证）**

- `static-ac-evidence/ac11-error-isolation-case.md`：`tests/Test-CodexSafeTreeDeleteControlPlane.ps1` 1283–1432 行，good-a / bad / good-b 三明治；断言「其余仍被归档（marker 唯一新增、既有 evidence SHA+identity 不变）」「不合格以稳定原因 `transaction-status-not-purged` 拒绝且零写入（前后文件状态逐字节相等）」「结果按调用顺序可读、单条拒绝不中断」「Status 只把合格项标 terminal」。
- 当前 HEAD 执行证据：本目录 `summary.json` 的 ControlPlane 条目 + `Test-CodexSafeTreeDeleteControlPlane.ps1.stdout.txt/.stderr.txt`。

## AC12 既有全部 safe-tree-delete 测试保持通过 — **通过（本目录新证据）**

- 本目录 `summary.json`：`manifestCount=27`、`completedCount=27`、`passCount=26`、`failCount=1`、`unexpectedFailCount=0`、`acVerdict=通过`；唯一 fail 为 `tests/Test-CodexSafeTreeDeleteFileSystem.ps1`（exit=1，waiver=`github-35-fat32-network-live-volume`，stderr 原文根因=未提权 diskpart 无法创建一次性 FAT32 VHD：`请求的操作需要提升`，见 `Test-CodexSafeTreeDeleteFileSystem.ps1.stderr.txt`）。
- 逐测试 stdout/stderr 落盘本目录；耗时与起止时点见 summary.json `tests[]`。
- 过程说明：首轮全量出现 2 个意外红（ParallelismBenchmark、Phase3Integration），根因与修复见 `static-ac-evidence/unexpected-red-fixes.diff` 与 `comment-22-draft.md`「本次回归的意外红与修复」节；修复后按 runner 续跑机制重跑该两项达标。host-live（ProductionSmoke、Phase3Production）不在本票范围（#24 管辖）。
