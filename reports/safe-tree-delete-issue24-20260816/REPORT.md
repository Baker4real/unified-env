---
type: snapshot
title: Issue #24 归档后 live Status 判定（2026-08-16）
tags: [safe-tree-delete, issue-24, status]
intent: 在 ProductionSmoke 之后重跑只读 Status，判定 complete / ready 是否合理，并回答 Status 是否还要独立性能立项
---

# Issue #24：归档后重跑 Status 并判定 complete 收敛

本目录是 **2026-08-16T14:23:31Z** 的 live Status 判定快照，不是 Archive / Apply / Purge / Restore 授权，也不是关闭或评论远端 issue 的授权。未 commit / push。#17 / #11 只写了评论草稿，未 `gh issue comment`。

08-14 的 `reports/safe-tree-delete-status-post-archive-20260814/` 与 02:17 的 #23 调查**不是**本次现役计数。

## 结论先行

| 项 | 取值 | 是否合理 |
| --- | --- | --- |
| `complete` | `false` | **合理。** 110 条 blocking 都是真实待处理，足以解释该取值。归档合格 terminal **不蕴含** `complete=true`。leftover `0ab1e1b6` 与一条 `recoverable` 可从 Status 识别，但不在 `blockingRecords`。 |
| `migrationReadiness.evaluated` | `false` | **合理。** 生产 CLI 未传 candidate policy。 |
| `migrationReadiness.ready` | `false` | **合理。** 实现是 `complete && blockingRecords.Count==0`；两者都不满足。 |
| 日常「顺手确认」 | 墙钟 **493.768s**，`elapsedMs=491363` | **不满足。** 不新建票；跟进已存在的 **#49**。#26–#43 不覆盖 Status 冷启动。 |
| ProductionSmoke | 套件 exit **0**，墙钟 407.492s | **已引用** `reports/safe-tree-delete-issue55-20260816/summary.json` 与 `leaf-delete-failed.json`。本票 **未再跑** smoke。判定 Status 是 smoke **之后** 的新跑。 |

`complete=false` 是判定成功，不是缺陷。不要为了翻 `complete` 去 Archive #48 的 purged+manual-review，也不要改 Status 合同。

## 采集事实

- 入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`
- 启动器：PowerShell Core 7.6.4（`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`）
- HEAD：`688c27a5374ce1ee4338b738725068843c76669b`（工作树另有他人 WIP，未回退、未改生产实现）
- wrapper SHA-256：`45aeadf7f758a1cafce106f66e7eaecc5f60176d2017630e2af461a2a37bca12`
- 开始：`2026-08-16T14:15:19.3662907+00:00`；结束：`2026-08-16T14:23:33.1343808+00:00`
- Status `capturedAtUtc`：`2026-08-16T14:23:31.9663166+00:00`
- 退出码 **0**，stderr **0** 字节，stdout **2870000** 字节（GB18030 → UTF-8：`status-raw.json` / `status-utf8.json`）
- 证据根：`D:\Codex\.codex\run-evidence\safe-tree-delete`，Status 前后均为 **2356** 目录 / **6897** 文件，**零写入**（`evidence-status-write-compare.json`）
- leftover transaction SHA-256 前后均为 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`；quarantine 仍在。未 Purge / Restore。

本次 Status 晚于 ProductionSmoke（`generatedAtUtc=2026-08-16T13:43:49Z`）。smoke 开头观测 `statusOperationCount=2350`；本次 live `operations=2356`（+6，全部已是 terminal `purged`，不在 blocking）。

## 与 #19 逐项对比

对比文件：`comparison-vs-baseline-19.json`。基线是 `reports/safe-tree-delete-status-baseline-20260810.json`（墙钟 502s，`elapsedMs=501018`）。

| 指标 | #19 归档前 2026-08-10 | 本次 live 2026-08-16T14:23Z | 差 |
| --- | ---: | ---: | ---: |
| `elapsedMs` | 501018 | 491363 | −9655 |
| 墙钟秒 | 502 | 493.768 | −8.232 |
| `entriesScanned` | 4815 | 6622 | +1807 |
| `logicalBytes` | 1234156276（≈1.23GB） | 1604575452（≈1.60GB） | +0.37GB |
| `bytesHashed` | 1625526811（≈1.63GB） | 1808098606（≈1.81GB） | +0.18GB |
| operations | 1980 | 2356 | +376 |
| `blockingRecords` | 1674 | 110 | −1564 |
| `complete` | false | false | 不变 |
| `migrationReadiness.ready` | false | false | 不变 |
| policy schema | 4 | 4 | 不变 |
| policy SHA-256 | `62bbb4bf…` | `01a22918…` | 已漂移（基线后登记过新 root） |
| 归档标记 / `lifecycle=terminal` | 0 / 306 | 2244 / 2244 | +2244 terminal |
| lifecycle `manual-review` | 1662 | 87 | −1575 |
| lifecycle `inconsistent` | 12 | 23 | +11 |
| lifecycle `recoverable` | 0 | 1 | +1 |
| lifecycle `purge-resumable` | 0 | 1 | +1 |

## 分解验证（数字已变，不套父 spec）

父 spec #11：`1742 = 1661 + 80 + 1`，对象是当时 1828 条。**不适用。**

#19：`1980` 条，`blocking 1674`，预计归档后 residual **79**。**不能**写成 1674→79 或 1674→110 的现役算式。

本次 live（独立复算 `live-recount.json` / `live-inspect.json`，与 `status-utf8.json` 一致）：

```text
2356 = 2244 terminal + 87 manual-review + 23 inconsistent + 1 recoverable + 1 purge-resumable
110  = 87 + 23
110  = 51 plan-only-both-null + 1 missing-plan + 42 purged-manual-review
       + 10 planned-namespace + 5 v1-unterminated + 1 historical-v2
2244 + 110 + 2 = 2356
```

`2` 是有受支持下一步、因此**不在** `blockingRecords` 里的未终结事务：`recoverable` `b24f3245` 与 leftover `0ab1e1b6`。Status 输出没有逐条 `complete` 字段；本次 `complete=false` 已由 110 条 blocking 充分解释，不依赖这两条来「凑」假阳性。

both-null 在 blocking 里一共 **52**（51 plan-only + `acl-capability-probe-20260801`）。不要把票面「69 条」或 02:17 的分组抄成本次事实。

## 剩余 blocking 为何是真实待处理

110 条全部可分类。没有「不知道是什么」的账面噪声。按合同它们都不该被当成 terminal 清掉。

### 1. leftover `0ab1e1b6`（不在 blocking，但必须识别）

- operationId：`20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e`
- `lifecycle=purge-resumable`，`transactionStatus=purging`，schema v2
- `quarantinePresent=true`，`targetPresent=false`，`schemaCompatible=true`，`policyCompatible=true`，`errors=[]`
- 不在 `blockingRecords`：`lifecycle=purge-resumable`（`nextActions` 字段为 `null`），不是 `manual-review`
- **本票禁止 Purge/Restore。** 属 #45/#50 清空集

### 2. #48 purged + manual-review（42，继续 blocking，不要 Archive）

`transactionStatus=purged` 且仍 `manual-review`。这是 #48 只读观测成功，不是归档候选。其中 38 条错误为 allowlist 拒绝 + 只读观测；4 条是 v1 purged 且夹带最小深度拒绝。

### 3. plan-only both-null（51）+ 缺 plan（1）

`transactionSchemaVersion` 与 `transactionStatus` 均为 null 的 blocking 共 52 条：

| 条数 | 错误 |
| ---: | --- |
| 18 | planned namespace 不一致 + plan policy SHA 漂移 |
| 17 | planned tree manifest 漂移 |
| 13 | planned namespace 不一致 |
| 2 | capability root 不在受管 allowlist（含 `20260805T153744Z-58046b4e-…`） |
| 1 | 未达最小后代深度 |
| 1 | 缺少 `plan.json` → `acl-capability-probe-20260801`（**不得删**） |

这些是过期计划或有意残缺，不是「事务在但解析器读不出来」。扩 Archive 去吞 plan-only 会放宽合同，禁止。

### 4. 5 条 v1 未终结（全部在 blocking，路径与 #19 基线一致）

| operationId | status | targetPath |
| --- | --- | --- |
| `20260725T010726Z-0609f165-c496-4280-85c4-6bb8a5e9465b` | rolled-back | `时钟倒计时\src\MinminCountdown.Verification\bin` |
| `20260725T130041Z-a5fd8743-a239-423c-9c44-4cbb5aa6a2cc` | quarantined | `reports\safe-tree-delete-batch-smoke-d77a341ca599407f82af77a64d7f6253\old-a` |
| `20260728T162734Z-c602a5b7-34bb-4469-bf9b-2754cadc5a76` | prepared | `时钟倒计时\src\MinminCountdown.Core\bin` |
| `20260729T055433Z-0f0aeb5d-efcc-43cb-973b-a58a9ea748d6` | purging | `时钟倒计时\app` |
| `20260730T170848Z-26f7ea53-0578-43c4-b245-9ab5304ca5d6` | prepared | `时钟倒计时\src\MinminCountdown\bin` |

无受支持写路径。留在视图里等人决策是预期行为。

### 5. 1 条历史 v2 未终结

`20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153`：`quarantined`，target `时钟倒计时\verification` 仍在、quarantine 不在，policy 漂移。在 blocking。

### 6. smoke 新 operation（6 条，全部 terminal，0 条 blocking）

判定 Status 里 `operationId >= 20260816T133701Z` 的 6 条均为 `lifecycle=terminal` / `purged`。包括 smoke 的 leaf-delete-failed 样本 `20260816T134343Z-d0de032c-…`，事后已 purged 并 terminal。它们增加 operations 与归档标记，**不**增加 blocking。

### 7. 其余 10 条 planned-namespace

全部是 2026-08-13 时钟倒计时 `assets\ui-references\…` 的 `quarantined` 记录：target 与 quarantine 都不在，报 namespace 不一致。真实不一致，不是噪声。

### 另：一条非 leftover 的 `recoverable`

`20260815T150506Z-b24f3245-e2c9-409c-8da4-d7a04f5e4cb5`（smoke 之前）：`quarantined`，quarantine 仍在，不在 blocking。不是本票处置对象。

## 耗时与 #49

墙钟约 **8.2 分钟**，比 #19 的 502s 略快，但扫描量更大（entries 6622 vs 4815，哈希 ≈1.81GB vs 1.63GB，terminal 认证 2244 vs 0）。Archive 去掉的是治理视图噪声，不是每次全量重读重哈希的扫描账。

这不满足 #11 的「秒级 / 日常清理前顺手确认」。主要成本是对已有 evidence 与 terminal-archive marker 的全量认证，不是这 110 条 blocking。独立性能工作已在 **#49**（OPEN）。不要 `gh issue create`。#26–#43 是 Plan/Apply/Purge 性能系列，不覆盖 Status 冷启动。

## ProductionSmoke 引用（满足「运行生产 smoke」AC，未重跑）

- `reports/safe-tree-delete-issue55-20260816/summary.json`：`ok=true`，墙钟 407.492s，`generatedAtUtc=2026-08-16T13:43:49Z`，`leftover0ab1e1b6TransactionSha256` 与本次相同
- `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`：真实 wrapper 上拿到 `leaf-delete-failed` / `purgeResumable=true`

本票只读 Status 在该 smoke **之后**（14:15–14:23Z）。再跑 smoke 会造新 operation，污染判定集。

## 对 #17 / #11 的判定（草稿，未发 GitHub）

归档能力已兑现：合格 purged 已标 terminal 并退出 blocking（2244 条）。`complete=false` 与 `ready=false` 是合理终态，因为剩余项是真实待处理，而不是 1674 条账面噪声。#17 原文「归档后 complete 必为 true」已被权威 spec 否定。Status 日常可用交给 #49。

## 未做

- 未 `gh issue comment|close|edit|create`
- 未 commit / push / 建 branch
- 未改生产实现、ProductionSmoke、policy.json、hooks、leftover
- 未调用 Archive / Apply / Purge / Restore
