# 审计汇总：受管安全树删除控制面（issue #11 及子 ticket #12–#17）

审计日期：2026-08-10
审计范围：commit `0cedb49..HEAD`（`3d4c647`、`6d68fb4`）
方法：6 个子代理按 ticket 边界并行只读审计，主 agent 交叉核验关键声明

## 结论

代码实现质量普遍扎实，安全关键路径无漏洞。但生产实测（2026-08-10 23:04–23:13）证明 **#17 的核心目标在生产侧未达成**，且发现一条 spec 承诺在生产链路上失效的缺陷。

| ticket | 主题 | 判定 |
|--------|------|------|
| #12 | Prefactor：抽出单条记录判定 | 功能达成，但 AC 前提描述与事实不符（发现 1） |
| #13 | runbook 两条调用契约 | 6 条 AC 全部通过，文档与代码字面量一致 |
| #14 | Status 双重拒绝收敛 | 11 条 AC 全部通过，**已由生产数据确证** |
| #15 | BatchPurge schema 过滤与错误隔离 | 核心 AC 全部通过，含真实 v1 状态组合 fixture |
| #16 | rebuildable-build-output 区分重建 | **已由生产数据确证**（104 条重建记录正确判为 terminal） |
| #17 | 受管归档 | 代码合格，但**生产侧 AC9 未达成**：归档标记数为 0，`complete` 仍 false |

### 生产 Status 实测（`D:\Codex\temp\status-audit-20260810\status-20260810.json`）

exit 0、无 stderr、耗时 502 秒、输出 2.6 MB。`metrics.elapsedMs=501018`、`entriesScanned=4815`、`bytesHashed=1.63 GB`。

已确证达成：
- 881 条 v1 记录全部输出真实 `transactionStatus`（876 purged / 2 prepared / 1 rolled-back / 1 quarantined / 1 purging），`targetPath` 为 null 的 **0 条**，`schemaCompatible` 一律 false —— #14 达成
- 5 条 v1 未终结事务可直接从受管输出识别，路径可见（4 条在 `时钟倒计时`，1 条在 `统一环境\reports`）
- R1 policy 漂移已降级为字段：730 条含 policy 相关错误但保留完整字段，未再塌缩
- 306 条 terminal 中 104 条 `targetPresent=true` 且全为 `purged` —— #16 的"删除后重建"判定生效；同时 rebuildable 根下仍保留 4 条 inconsistent、3 条 manual-review，放宽未掩盖真实问题
- `physicalReclaimStatus` 取值集合仅 `unknown`，语义未改
- policy `schemaVersion=4`，v5 未激活

未达成：
- `complete = false`，`migrationReadiness.ready = false`，`blockingRecords` 1674 条
- **归档标记数 = 0**，生产环境从未执行过 Archive
- 当前有 **1595 条**记录满足 purged + quarantine 缺席（v1 872 + v2 723），为合格归档候选
- Status 耗时 502 秒 vs ticket 记载基线 267 秒。记录数 1828→1980 只能解释一部分。#11 的 US1"秒级返回"**完全未达成，实际更慢**。父 spec 未设精确耗时断言（只要求 metrics 增长关系合理），严格说不违反验收条件，但与运维者核心诉求相去甚远。

## 已交叉核验的关键安全声明

**只读放宽未泄漏到写入路径**（#14 最高风险项）。`Read-CodexSafeTreeDeleteObservedV1Transaction` 全部三个调用点为 `CodexSafeTreeDelete.ps1:928`（Archive）、`:1364`、`:1442`（均在 Status 路径内）。Purge / Restore 的唯一事务解析入口 `ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument` 在 `:2220` 硬拒绝非 `{2,3}` schema，无旁路。

**归档三条判据不可绕过**（#17 安全关键项）。`Invoke-CodexSafeTreeDeleteArchive`（`:1115`、`:1119`、`:1123`）在 mutex 外检查一次，`:1139`、`:1143`、`:1147` 在 mutex 内再检查一次；AND 关系、提前 return、无开关。quarantine 判据走 `Get-CodexSafeTreeDeleteNamespaceState` 真实磁盘查询，不读事务文档字段，无法伪造。5 条 v1 未终结事务因 status ≠ purged 被 `:1115` 挡住。

**#16 区分能力真实存在**。判据是目录 inode identity（VolumeSerialNumber + FileIndex）：Plan 阶段把目标 FileIndex 存入 `plan.treeManifest.rootIdentity`，Status 阶段比较当前值——不同证明曾删除重建（terminal），相同证明从未删除（throw → manual-review）。`status='purged'` 写入点（`:3408`）位于 leaf 全部删除成功且 postcheck 通过之后，链闭合。

## 发现（按严重性）

### 1. #12 的 AC 前提与事实不符：被"重构"的函数是本轮新建的

基线 `0cedb49` 的入口 `ValidateSet` 只有 `Plan`/`Apply`/`Purge`/`BatchPurge`，**没有 `Status` 模式**，也不存在 `Get-CodexSafeTreeDeleteStatus`（已核验）。ticket #12 描述的"今天是约 460 行单函数含 17 个 throw"指的是 `3d4c647` 中新建的函数，提取动作发生在 `6d68fb4`。

后果：#12 的 AC2（"对当前生产证据根跑 Status，与重构前基线比对"）和 AC5（"写入路径未被本次重构改动"）在逻辑上都无法成立——不存在重构前基线，而写入路径（`Invoke-CodexSafeTreeDeleteQuarantine`、`Read-CodexSafeTreeDeleteApprovedTransaction`、`Invoke-CodexSafeTreeDeletePurge` 净增 600+ 行，`Invoke-CodexSafeTreeDeleteRestore`、`ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument` 全新）的改动可合理归属 #13/#15/#16，但两个混合 commit 使归因无法从 diff 单独证伪。AC3（判定单元隔离、失败不清空已解析字段）本身**技术上成立**。

### 2. `leaf-delete-failed` 的非零退出码在生产 wrapper 链上丢失（新发现，spec 承诺失效）

`docs/specs/2026-07-24-safe-tree-delete-capability.md:207` 明文承诺「JSON `leaf-delete-failed` 以非零退出码返回结构化 metrics」。实测该承诺在生产链路上不成立。

用一次性临时探针精确复刻三层 wrapper 形态（已清理），结果：

| 形态 | 退出码 |
|------|--------|
| `pwsh -File inner.ps1`（内层直调，含 `exit 1`） | **1** 正确 |
| `pwsh -File middle.ps1`（`& inner.ps1 @args`，复刻 `invoke-safe-tree-delete.ps1`） | **0** 丢失 |
| `.cmd` → `pwsh -File middle.ps1` → `& inner.ps1`（完整生产链） | **0** 丢失 |
| `& inner.ps1 @args` 后加 `exit $LASTEXITCODE` | **1** 修复有效 |

根因：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1:4` 用 `& '...ps1' @args` 调用生产实现，**没有 `exit $LASTEXITCODE` 转发**；退出码丢在这一层，与 `.cmd` 的 `exit /b %ERRORLEVEL%` 无关（对照组已排除）。全仓 `.ps1` 中 `exit $LASTEXITCODE` 命中数为 0。

影响：经受管入口调用时，真实的 leaf 删除失败会以 `exit 0` 返回。按 `host-runbook.md:343-346` 的契约，调用方必须同时检查业务字段才能发现失败——runbook 这条要求恰好兜住了这个缺陷，所以**没有已知调用方因此出错**（子代理已逐个核验：ProductionSmoke 与三个 CatalogGuard 测试都只走成功路径或"exit≠0 即 throw"）。但 spec:207 在生产链路上是空头承诺，且 `exit 1` 本身零测试覆盖（控制面测试打的是 fixture，fixture 文件内无任何 `exit`）。

注意：这不是本轮 commit 引入的回归。基线 `0cedb49` 完全没有 `leaf-delete-failed`、`ReturnFailureMetrics`、retry 特性（子代理用 `git log -S` 确认全为 `3d4c647` 新增），所以不存在被改坏的既有契约——是新特性上线时未验证端到端退出码传递。

### 3. #12 / #17 的生产验收结果（原"三项无证据"已由实测替代）

- #12 AC2（重构前 Status 基线快照）：**依然无法满足**，基线不存在该函数，无从比对
- #16 AC7（误报消除）：**已达成**，见上方生产数据
- #17 AC9（归档后 complete=true）：**未达成**，归档标记数 0

父 spec 的对账算式（1742 = 1661 + 80 + 1）针对基线 1828 条记录；当前 1980 条，不能直接套用。实测对应量为：blockingRecords 1674 = v1 非 terminal 881 + 含 policy 错误 730 + 其他 73（存在交叉，非严格互斥）。

### 3. 新增两个测试 seam，违反父 spec 字面约束（#12/#15/#17 三方独立发现）

`tests/Invoke-CodexSafeTreeDeleteRestoreCrashFixture.ps1` 与 `tests/Open-CodexSafeTreeDeleteProducerLeaseFixture.ps1`（均由 `3d4c647` 新增）直接 dot-source 调用 `Invoke-CodexSafeTreeDeleteRestore` 和 `New-CodexSafeTreeDeleteProducerLease`，绕过唯一允许的 `Invoke-CodexSafeTreeDeleteFixture.ps1`。父 spec Testing Decisions 明确"不引入第二个 seam"。

功能上合理：崩溃注入与进程间锁测试需要子进程在指定阶段阻塞，主 seam 无法承载；`Invoke-CodexSafeTreeDeleteCrashFixture.ps1` 已有同等先例。不影响生产行为。建议在父 spec 补例外条款而非删除文件。

### 4. `rootDeletionPurpose` 读当前 policy，非事务快照（#16）

`:1537-1539` 经 `Read-CodexSafeTreeDeleteApprovedPlan` → `Resolve-CodexSafeTreeDeleteTarget` 查**当前** policy entry；plan.json 只存 `policyEntryId`，不快照 purpose 值。把某 entry 的 purpose 从 `rebuildable-build-output` 改成别的，会**追溯性地**把所有引用该 entry 的历史 purged+target-present 记录从 terminal 翻转为 manual-review，反向修改同样会追溯放宽。

与既有 policy SHA drift 模式一致，ticket 未要求快照，但父 spec 称"判定依据是事务自身记录的完成事实"与此有偏差。建议在运维文档注明。

### 5. `-Json` stdout 扩展：已查明为有意设计且被 spec 覆盖（原判断已更正）

此前记为"未声明的静默扩展"，经调查**该判断错误**，已更正。事实：基线 `0cedb49` 根本不存在 `leaf-delete-failed` 这个 refusalReason（整个 retry + 失败指标特性由 `3d4c647` 新增），因此不存在被改变的既有 stdout 契约。同一 commit 同时写入 spec 明文（`docs/specs/2026-07-24-safe-tree-delete-capability.md:207`）。#11 的 out-of-scope 是"不改退出码值"，退出码值确实未变，未违背。

产生点 `scripts/lib/CodexSafeTreeDelete.ps1:3781-3790`（仅 Purge 分支）；`exit 1` 仅在 `-Json` + Purge + `leaf-delete-failed` 三重条件下可达。无需改代码或补文档——但见发现 2，该 exit 在 wrapper 链上实际到不了调用方。

### 6. `archivedAtUtc` 使用系统壁钟（#17，信息级）

`:1167` 用 `[datetimeoffset]::UtcNow`，非 `Get-CodexSafeTreeDeleteTrustedElapsedTimeSample`。AC 只要求"含归档时点"用于追溯，不参与计时判决，无安全影响。

## 测试执行情况

子代理实际运行并取得 exit 0 的套件：

| 套件 | 结果 |
|------|------|
| Test-CodexSafeTreeDeleteControlPlane | exit 0，10 slices（含 archive 全路径、ProducerFencing 4 scenarios / 22 checks） |
| Test-CodexSafeTreeDeleteStatus | exit 0，17 slices |
| Test-CodexSafeTreeDeleteSchemaCompatibility | exit 0，10 slices（v1 transaction 双向断言真实构造 `schemaVersion=1L`） |
| Test-CodexSafeTreeDeleteRestore | exit 0（含归档拒绝 journal anchors 断言） |
| Test-CodexSafeTreeDeleteCrashSafety | exit 0，11 scenarios |
| Test-CodexSafeTreeDeleteGrace | exit 0，10 slices |
| Test-CodexSafeTreeDelete | exit 0，12 slices |
| Test-CodexSafeTreeDeleteMetricsEvidence | exit 0 |
| Test-CodexSafeTreeDeleteBenchmark | exit 0 |
| Test-CodexSafeTreeDeleteProductionSmoke | **未运行**（需生产 evidence root） |

## 建议的后续动作

可关闭：**#13、#14、#15、#16**（#14/#16 已有生产数据确证）。
**#12** 附一条更正说明后关闭（AC2/AC5 因前提不成立不可满足，AC3 已达成）。
**#17 不应关闭**：代码合格但生产侧目标未达成。

需要单独授权才能推进的事项：
1. **批量归档 1595 条合格记录**，然后重跑 Status 确认 `complete` 翻转。`host-runbook.md:355` 明确"生产批量写入归档 marker 需要单独授权，不能用调用方循环把单笔确认扩大成批量授权"——超出常规授权范围。归档不删文件，但 create-only 不可撤销。

无需授权的修复项：
2. **修 `invoke-safe-tree-delete.ps1:4` 的退出码转发**（发现 2）。改动是加一行 `exit $LASTEXITCODE`，修复有效性已实测。这是宿主脚本，属 `D:\Codex\.codex\scripts\`，改前需确认是否属本项目 ownership。
3. 为生产入口层的 `exit 1` 补一条断言（当前零覆盖）。
4. 父 spec Testing Decisions 补崩溃注入 helper 的 seam 例外条款。
5. 运维文档注明 `rootDeletionPurpose` 读当前 policy 的追溯性语义。

值得单独决策：
6. **Status 性能**。502 秒不属任何现有 ticket 的验收失败，但 #11 的 US1 目标完全未达成且实际更慢。若要处理，是一个新工作项。
