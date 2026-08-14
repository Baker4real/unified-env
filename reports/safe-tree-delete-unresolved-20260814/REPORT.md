# Issue #23 未解析事务记录分类（快照）

**本目录是只读调查快照，不构成 Archive / Apply / Purge / Delete 授权，也不构成放宽判据授权。**

调查起点是 `#22` 归档后的 `reports/safe-tree-delete-archive-20260814/status-after.utf8.json`（`blockingRecords=109`，`complete=false`，policy schema v4，`policySha256=01a22918…`）。该 SHA 与当时工作树 `managed/safe-tree-delete/policy.json` 一致，**不是** git HEAD `bb80cc85…`。工作树比 HEAD 多一条未提交的 `clock-countdown-intermediate-ui-references`。本票未重跑完整生产 Status，也未改任何脚本、policy、evidence。

`acl-capability-probe-20260801` 必须保留原状。本票不建议为了清视图而放宽任何失败关闭判据。

## 结论先行

当前 **89** 条 `transactionStatus=null` 都能解释，不再有“不知道它是什么”的条目。

| 组 | 现条数（票面原） | 成因 | 数据丢失 | 处置 |
| --- | ---: | --- | --- | --- |
| capability root 不在 allowlist | 39（34） | 解析器覆盖缺口：一次性/已撤销 root 上的 **v2 事务读不出来**。磁盘上 37 条已是 `purged` | 无 | 需代码改动后才可能进入 Archive 候选；2 条无事务保留原状 |
| planned tree manifest 漂移 | 17（15） | evidence 完整；可重建 bin/obj/app 树已变，计划未 Apply | 无 | 保留原状 |
| planned namespace 不一致 + policy SHA 漂移 | 18（6） | 无事务；目标已不在；12 条是原 12 条 namespace-only 因后来 policy SHA 变化多了一条错误 | 无 | 保留原状 |
| planned namespace 不一致 | 13（12） | 全是 2026-08-13 新建的 ui-references **无事务**计划，目标已被同波次 Apply/清理拿走 | 无 | 保留原状（同波次旁路交给 #24，但这 13 条本身不是未解析事务） |
| target 未达最小后代深度 | 1（1） | 历史 depth=1 的 run-evidence 计划，现役最小深度=2；无事务 | 无 | 保留原状 |
| 缺 plan.json | 1（1） | 有意保留的 ACL 探测目录，只有 `probe.ps1` | 无 | **保留原状，不删除** |

票面“69 条 schema 与 status 均为 null”不精确：`#19` 基线这 69 条里 **36 条两者都是 null，33 条已是 schema=2 / status=null**（plan 批准失败后解析器只来得及写出 schema）。真正的分组定义是上面 6 个错误串，合计 69。归档后这 69 条全部还在，另外新建 20 条，成为 89。

**10 条 2026-08-13 ui-references `quarantined→inconsistent` 不是本票的“事务文档未解析”。** 它们有完整 v2 事务，`transactionStatus=quarantined`。交给 #24。

**4 条 purged 仍 manual-review 也不是未解析。** 它们是 2026-07-29 的 v1 `purged`，目标都在 `run-evidence` 下 depth=1。Status 已读出 status，但 plan 被当前最小深度拒绝后没有写入 `quarantinePresent`，`#22` 候选推导因此跳过它们。

## 方法与证据边界

- 对照：`#19` `reports/safe-tree-delete-status-baseline-20260810-evidence/status-output.json`（GB18030）与 `#22` `status-after.utf8.json`。
- 只读打开生产 `D:\Codex\.codex\run-evidence\safe-tree-delete\<operationId>\plan.json` / `transaction.json`。
- 对照当前工作树 policy 的 allowlist 与 git 中全部 `policy.json` 提交。
- **未**调用生产 Status / Archive / Apply / Purge。磁盘“像可归档”不等于已经 Archive 成功。

辅助产物：`classification.json`、`baseline-delta.json`、`evidence-samples.json`、`policy-history.json`、`conclusions.json`。

## 89 条逐组

### 1. 39 条 capability root 不在 allowlist

**票面 34，现 39。** 全部 `lifecycle=manual-review`，`targetPath` 在 Status 里为 null，`journalStatus=not-evaluated`。

现场打开 plan 后，这些记录的 `capabilityRoot` / `policyEntryId` **都不在当前 allowlist**。git 里从 `51899f9` 到 `ec05faf` 的 `policy.json` **从未提交过**这些 entry，只见过只增不减。它们是现场一次性 policy，用完后从工作树撤销，没有留下 git 记录。

按 plan 的 entry 分类：

| 子集 | 条数 | 含义 |
| --- | ---: | --- |
| `reference-cleanup-20260805-*` | 22 | serena pycache/cache、i-have-adhd pycache、cc-switch `.codegraph` / `src-tauri\gen`、sub2api web dist |
| `clock-countdown-cleanup-*` | 6 | 把某一版 ui-references 或 `1ba06d2f` quarantine 本身登记成 root |
| `minmin-calendar-*` | 5 | 2026-08-12 清理子目录（其中 4 条是 +20 里的新记录） |
| `claude-code-stale-state-cleanup` | 3 | `D:\claude` 下 `.local` / `.claude` / `.legacy-root-state-cleanup` |
| `retired-project-radar-ladder` | 1 | `D:\Codex\projects\雷达天梯`（目录现已不存在） |
| `okf-frontmatter-retired-project-root` | 1 | `D:\Codex\projects\okf-frontmatter`（目录现已不存在） |
| `npm-global-anthropic-cleanup` | 1 | `D:\Codex\tools\npm-global\node_modules\@anthropic-ai` |

**是否已退役项目？** 只有雷达天梯、okf-frontmatter 是整棵退役项目根被删掉。其余是仍在的项目里的一次性清理根（pycache、某一版 ui-references、minmin-calendar 子目录、`D:\claude` 子路径）。**根因是现场 policy 撤销登记，不是这些项目今天还该出现在 allowlist 里。**

**evidence 残缺还是解析器缺口？** 解析器缺口。37/39 条磁盘上有完整 v2 `transaction.json`，`status=purged`，`directoryCommitAnchors=[]`，目标与 quarantine 现都不在。样本：

- `20260807T011336Z-7a5c38c6-…`：okf-frontmatter，`transaction.status=purged`
- `20260805T082602Z-ea62c9f2-…`：雷达天梯，`transaction.status=purged`

Status 路径：`Read-CodexSafeTreeDeleteApprovedPlan` → `Resolve-CodexSafeTreeDeleteTarget` 因当前 allowlist 没有该 root 抛出；随后只对 **v1** 做只读观测（`CodexSafeTreeDelete.ps1` 约 1654–1688 行），v2 直接再抛。于是 `transactionStatus` 保持 null，`quarantinePresent` 保持 null。`#22` 候选要求 `transactionStatus=purged` 且 `quarantinePresent=false`，这 37 条进不了归档。

这与 spec 并不冲突：Archive 源读取**不查**当前 allowlist（约 1175–1265 行）。卡住的是 Status 观测，不是 Archive 合同本身。本票未调用 Archive，不能声称这 37 条今天直接 Archive 一定成功。

2 条无事务，不是“已完成但看不见”：

- `20260805T153744Z-58046b4e-…`：计划删 `1ba06d2f` 的 quarantine，未 Apply。同 root 的 `20260805T153928Z-163b53ca-…` 后来 purged 了那个 quarantine。
- `20260812T155917Z-484e4708-…`：minmin-calendar skill-state 计划未 Apply；同目标稍后 `20260812T155931Z-d436eaec-…` 已 purged。

1 条 purged 后目标又在：`20260805T160553Z-11f6ef91-…`，`cc-switch\src-tauri\gen` 现仍是目录。这是生成物重建，不是未删除。当前 committed policy 也没有把 `src-tauri\gen` 登记为 root。

**真实不一致？** 不需要为这 39 条做人工恢复。不要把一次性 root 重新写回 policy 只为了骗过 Status。

**数据丢失？** 无。37 条按事务已经 purged；重建的 `gen` 是后来生成的。

**处置：** 需后续代码改动（见草稿），让 Status 在 plan 被当前 policy 拒绝后仍只读观测 v2，并填写 namespace 标志。在此之前保留原状。**不要**重新登记已撤销 root，**不要**放宽 allowlist。

### 2. 17 条 Status planned tree manifest 漂移

无 `transaction.json`。`targetPresent=true`，`quarantinePresent=false`，`journalStatus=not-started`。目标全是时钟倒计时的 `bin` / `obj` / `app` / `verification`，这些 root **仍在**当前 allowlist。计划过期后工程重建，树哈希与 plan 不一致。Status 按合同失败关闭，行为正确。

+20 里的 2 条是 2026-08-12 对 `MinminCountdown\bin` 的新计划，随后再次编译，同样漂移。

**处置：** 保留原状。不是 Archive 候选（从未 purged）。不是人工事故。

### 3. 18 条 planned namespace 不一致 + policy SHA 漂移

无事务。目标与 quarantine 现在都不在。根仍在 allowlist，但 plan 的 `policySha256` 不是 `01a22918…`。

构成：

- 原 6 条：`clock-countdown-deploy\*`、replicator skills 备份/staging、`skills\nodesek-image-generation\scripts\__pycache__`、tmp 下 skill-install 残留。基线时就已经带 SHA 漂移。
- 另 12 条：基线时只报 namespace 不一致（计划 SHA=`62bbb4bf…`，即 `#19` 当时 policy）。归档后 Status 使用工作树 `01a22918…`，多出“plan policy SHA 已漂移”。记录没变，错误串变了。

**处置：** 保留原状。过期计划，目标早已不在，没有可恢复载荷。

### 4. 13 条 planned namespace 不一致（无 SHA 漂移）

**全部是 +20 里 2026-08-13 新建的记录**，不是原 12 条。`policyCompatible=true`，entry=`clock-countdown-intermediate-ui-references`，无事务。目标是 `assets\ui-references\…\2026-08-13-v7` 到 `v11`（部分版本重复 Plan）。目标与 quarantine 现在都不在，因为同波次稍后的 Apply 把目录隔离走了。

这些是**无事务的过期计划**，按票面定义算进 89，但不是“事务文档解析失败”。同波次 10 条已 Apply 的 quarantined 记录见下文，交给 #24。

**处置：** 保留原状。不要把它们和那 10 条混成一类。

### 5. 1 条最小后代深度

`20260729T074213Z-34f4b598-…`：计划删 `D:\Codex\.codex\run-evidence\safe-tree-delete-smoke-a41322da0e924752a9b3a61c88fc6987`（depth=1）。无事务。现役 `codex-run-evidence` 从首个 git 版本起就是 `minimumDescendantDepth=2`。该 plan 的 policy SHA=`7bdf6c96…` 不在当前 git 提交里。无论当时是代码尚未强制深度还是现场 policy 较松，当前 Status 用现役语义拒绝是正确的。

同目标稍后的 v1 `20260729T074219Z-f91a4f79-…` 已经 purged（见下面 4 条）。这条只是未 Apply 的前一次计划。

**处置：** 保留原状。不要把最小深度改回 1。

### 6. 1 条缺 plan.json

`acl-capability-probe-20260801` 目录里只有 `probe.ps1`。这是 spec 登记的 ACL freeze 探测基线。

**处置：** 保留原状，不删除，不归档。

## 69 → 89 的 20 条

原 69 条一条都没消失。20 条全是 `#19` 基线（2026-08-10）之后新建的 operation，且都不在基线 `operations` 里：

| 条数 | 时间 | 现分组 | 内容 |
| ---: | --- | --- | --- |
| 5 | 2026-08-12T15:59Z | allowlist | minmin-calendar 一次性清理。4 条磁盘已 purged，1 条计划未 Apply |
| 2 | 2026-08-12T19:21Z / 20:30Z | manifest 漂移 | `MinminCountdown\bin` 新计划，随后树又变了 |
| 13 | 2026-08-13T16:27–16:28Z | planned-namespace | ui-references v7–v11 的无事务计划 |

另外，原 12 条 planned-namespace 仍在 89 里，但因工作树 policy SHA 变化，现计入“namespace+policy SHA”（6+12=18）。这不是新记录。

## 不是 89、但 #22 分解里会出现的条目

### 10 条 2026-08-13 ui-references quarantined → inconsistent

**不是 #23 范围。** `transactionSchemaVersion=2`，`transactionStatus=quarantined`，事务读得出来。样本 `20260813T162340Z-8a1c1553-…` 的事务仍是 `quarantined`，但 target 与 quarantine 现在都不存在。`#22` 已记录它们在归档窗口中从 recoverable 翻成 inconsistent。

这是归档窗口旁路 / 隔离目录被控制面外删掉，不是事务文档未解析。交给 **#24**。不要为了清视图把它们改判 terminal，也不要放宽 “quarantined 必须还能看见 quarantine”。

### 4 条 purged 仍 manual-review

| operationId | 目标 |
| --- | --- |
| `20260729T074247Z-cc78cd84-…` | `run-evidence\desktop-shortcut-windows-terminal-20260729T065358Z` |
| `20260729T074250Z-fe0c62fd-…` | `run-evidence\desktop-shortcut-windows-terminal-alias-fix-20260729T070216Z` |
| `20260729T074244Z-11c87c5a-…` | `run-evidence\desktop-shortcut-icon-name-fix-20260729T071110Z` |
| `20260729T074219Z-f91a4f79-…` | `run-evidence\safe-tree-delete-smoke-a41322da0e924752a9b3a61c88fc6987` |

四条都是 v1、`status=purged`，磁盘上 target/quarantine 都不在。Status 错误是「plan 当前语义拒绝：未达到最小后代深度」+「v1 只读观测」。因为 plan 批准失败，`quarantinePresent` 保持 null，`#22` 候选脚本跳过。

它们**已经解析**。若后续补上“plan 拒绝后仍探测 namespace”，形态上可以进入 Archive 候选。本票未 Archive。

### 5 条 v1 未终结 + 1 条历史 v2 quarantined

不在 89 内。5 条 v1 按父 spec 只能只读观测。历史 v2 `20260805T083256Z-1ba06d2f-…` 仍报 policy 漂移、`quarantined`；其 quarantine 已被上面那条已撤销 root 的 purged 操作删掉，`verification` 目录现已重建。这是真实残留，交给 #24 / 人工，不要假装是未解析文档。

## 对 #24 的含义

`complete=false` 仍然合理，因为至少还有：

- 5 条 v1 未终结（父 spec 预期）
- 1 条历史 v2 quarantined，quarantine 已被旁路删掉
- 10 条窗口内 ui-references quarantined 不一致
- 本票分类清楚、但尚未 Archive 的历史 purged / 过期计划 residual

把 89 条解释清楚 **不会**让 `complete` 自动变 true，也不应该靠放宽判据去翻它。

## 是否建议后续代码 ticket

建议，草稿在 `ticket-draft-status-observe-after-plan-reject.md`。**不要在本票实施，也不要 `gh issue create`。**

要点：plan 被当前 policy 拒绝后，对历史 v2 做与 v1 对称的只读观测，并填写 `targetPresent` / `quarantinePresent`。不放宽 allowlist / 最小深度，不让 Purge/Restore 执行这些记录。

不建议把“过期且无事务的计划”扩成 Archive 对象。

## 风险与未验证

- 计数绑定 `#22` status-after 快照，不是本票此刻的 live Status。
- 37 条 allowlist 的 Archive 资格只按磁盘外形推断，未调用 Archive 做 journal/anchor 认证。
- 一次性 policy 的原始 bytes 不在 git 里；撤销是用 plan 内 entry id 对照当前 allowlist 与 git 历史推出的。
- 10 条 quarantine 在归档窗口中被谁删掉，本票未取证。
- 工作树 `policy.json` 有他人未提交改动；本票未回退、未改写。
