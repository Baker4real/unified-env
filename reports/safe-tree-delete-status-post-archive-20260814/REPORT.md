# Issue #24：归档后重跑 Status 并判定 complete 收敛

**本目录是 2026-08-13T19:59Z 的时间点快照与判定，不构成 Archive / Apply / Purge / Delete 授权，也不构成关闭或评论远端 issue 的授权。**

编排禁止改远端。#17 / #11 的结论只写在本文件。GitHub 上这两张票当前已是 `CLOSED`；本次未执行 `gh issue comment` / `close`。

## 结论先行

| 项 | 取值 | 是否合理 |
| --- | --- | --- |
| `complete` | `false` | **合理**。剩余 109 条都能分类，不是 #19 那种 1674 条账面噪声。 |
| `migrationReadiness.evaluated` | `false` | **合理**。生产 CLI 未传 candidate policy，spec 如此。 |
| `migrationReadiness.ready` | `false` | **合理**。实现是 `complete && blockingRecords.Count==0`；两者都不满足。 |
| 日常「顺手确认」 | 本次 `elapsedMs=321851`（墙钟 324s） | **不满足**。需要独立 Status 性能立项，草稿见同目录 `ticket-draft-status-performance.md`。未 `gh issue create`。 |
| ProductionSmoke | 套件退出码 **1** | **#21 持锁断言未通过**。未改测试。新 5 条 operation 不属于判定集。 |

归档把治理视图从「几乎全是噪声」收成「109 条已分类 residual」。这兑现了 #11「`complete` 恢复判定价值」，**没有**兑现「归档后 `complete=true`」或「Status 秒级返回」。

不要为了翻 `complete` 把 quarantined 改判 terminal，不要重新登记已撤销 root，不要实现 #23 解析器草稿。

## 采集事实

- 入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`
- HEAD：`6310d8d`（`docs: 消除性能优化报告层的过期现役说法`）
- 工作树 `policy.json` SHA：`01a22918150646bc37c5a51c9f4d1392750fa1e44501b5c651ca2d14f4362c90`（schema v4，32 条；比 HEAD `bb80cc85…` 多未提交的 `clock-countdown-intermediate-ui-references`）
- wrapper cmd/ps1 与仓库源 SHA 一致
- 退出码 0，stderr 0 字节
- 原始 stdout 为 GB18030，`status-raw.json`；UTF-8 副本 `status-utf8.json`
- 证据根对照：`2300` 目录 / `6743` 文件，**零写入**（`evidence-status-write-compare.json`）

## 与 #19 逐项对比

| 指标 | #19 归档前 2026-08-10 | 本次 live 2026-08-13T19:59Z | 差 |
| --- | ---: | ---: | ---: |
| `elapsedMs` | 501018 | 321851 | −179167 |
| 墙钟秒 | 502 | 324.196 | −178 |
| `entriesScanned` | 4815 | 6205 | +1390 |
| `logicalBytes` | 1234156276（≈1.23GB） | 1603770905（≈1.60GB） | +0.37GB |
| `bytesHashed` | 1625526811（≈1.63GB） | 1803705569（≈1.80GB） | +0.18GB |
| operations | 1980 | 2300 | +320 |
| `blockingRecords` | 1674 | 109 | −1565 |
| `complete` | false | false | 不变 |
| `migrationReadiness.ready` | false | false | 不变 |
| policy schema | 4 | 4 | 不变 |
| 归档标记 / `lifecycle=terminal` | 0 / 306 | 2191 / 2191 | +2191 terminal |
| lifecycle `manual-review` | 1662 | 86 | −1576 |
| lifecycle `inconsistent` | 12 | 23 | +11 |

#22 窗口内另有一次 Status：`elapsedMs=708080`、同一 `entriesScanned=6205`、同一 `bytesHashed=1803705569`。那是热路径对照，不是最终性能结论。本次哈希量与那次完全相同，耗时却少一半以上，说明 Status 成本主要是反复读同一批证据，对缓存温度敏感。

**不能把 1674→79 当成这次的收敛。** #19 之后 live 已增到 2300 operations、归档时 2290 blocking / 2191 候选；#22 成功归档 2191 后 blocking 109、候选 0。本次 live 与该归档后视图一致。

## 分解验证（数字已变，不套父 spec）

父 spec #11：`1742 = 1661 + 80 + 1`，对象是当时 1828 条。**不适用。**

#19：`1980` 条，`blocking 1674`，预计归档后 residual 79。**不能直接套到 2300 / 109。**

本次 live：

```text
2300 = 2191 terminal + 86 manual-review + 23 inconsistent
109  = 86 + 23
109  = 39 + 17 + 18 + 13 + 10 + 5 + 4 + 1 + 1 + 1
109  = 89(transactionStatus=null) + 20(已解析仍阻塞)
 20  = 10(窗口 quarantined 不一致) + 4(v1 purged 仍 MR) + 5(v1 未终结) + 1(历史 v2)
```

`2191 + 109 = 2300`。归档候选 0，与 #22 归档穷尽合格 purged 一致。

## 剩余 109 条为何仍应阻塞

全部能归入 #23 已分类组，没有「不知道是什么」。按合同它们都不该被当成 terminal 清掉。

### 真实待处理 / 合同要求保留

1. **5 条 v1 未终结**（父 spec 预期，无受支持写路径）  
   - `20260725T010726Z-0609f165-…` `rolled-back` → `时钟倒计时\src\MinminCountdown.Verification\bin`  
   - `20260728T162734Z-c602a5b7-…` `prepared` → `MinminCountdown.Core\bin`  
   - `20260730T170848Z-26f7ea53-…` `prepared` → `MinminCountdown\bin`  
   - `20260729T055433Z-0f0aeb5d-…` `purging` → `时钟倒计时\app`  
   - `20260725T130041Z-a5fd8743-…` `quarantined` → 历史 batch-smoke `old-a`  
   本次 Status 均可直接识别：`transactionStatus` / `targetPath` 非 null。

2. **1 条历史 v2 未终结**  
   `20260805T083256Z-1ba06d2f-…`，`quarantined`，policy 漂移，target=`时钟倒计时\verification` 现已重建，quarantine 不在。不要改判 terminal。

3. **10 条 2026-08-13 ui-references `quarantined` → `inconsistent`**  
   事务已解析。target 与 quarantine 现在都不在。归档窗口旁路，不是文档未解析。不要改判 terminal。

4. **1 条 `acl-capability-probe-20260801`**  
   缺 `plan.json`，spec 有意保留的 ACL 探测基线。不删除。

### 已分类 residual（今天不能当噪声清掉）

5. **39 条 allowlist**  
   解析器缺口：plan 被当前 allowlist 拒绝后不对 v2 做只读观测。#23：37 条磁盘已 purged。**不要重新登记已撤销 root。** 代码草稿只在 #23 目录，本票不实现。

6. **4 条 v1 purged 仍 `manual-review`**  
   `20260729T074219Z-f91a4f79-…` / `…074244Z-11c87c5a-…` / `…074247Z-cc78cd84-…` / `…074250Z-fe0c62fd-…`。status 已是 purged，但 plan 被最小深度拒绝后 `quarantinePresent=null`，进不了 Archive 候选。

7. **17 条 planned tree manifest 漂移**  
   无事务；可重建 bin/obj/app 树已变。Status 失败关闭正确。

8. **18 条 namespace + policy SHA**  
   无事务、过期计划，目标已不在。

9. **13 条 08-13 ui-references 无事务计划**  
   同波次旁路计划，不是那 10 条已 Apply 的 quarantined。

10. **1 条最小深度**  
    `20260729T074213Z-34f4b598-…`，depth=1 的历史计划，现役最小深度=2。不要把深度改回 1。

即使将来做完 #23 的「plan 拒绝后观测 v2」并再归档那 37+4 条外形已 purged 的记录，仍会剩下 5+1+10+过期计划+探测目录，`complete` 还是 false。那仍然合理。

## 对 #17 / #11 的判定（只写在本报告）

### #17 受管归档

- **能力已交付**：#22 归档 2191 条，本次 `lifecycle=terminal` 2191、候选 0、blocking 从 #19 的 1674 降到 109。
- **票面 AC「归档全部合格历史记录后 complete=true 且 ready 可通过」未兑现**，也不应该靠放宽判据兑现。#19 已证伪「归档即可翻 complete」；本次 live 再次确认。
- 证据根三层保护未在本票触碰。policy 仍是 v4。

远端 #17 已是 CLOSED。按本次判定：把它理解为「归档控制面交付」可以；若 tracker 要诚实反映 `complete=true` 那条 AC，应在 #18 收口写明该 AC 被 live residual 否决，而不是重开本票去改判据。

### #11 控制面史诗

| #11 用户可感目标 | 本次判定 |
| --- | --- |
| `complete` 恢复判定价值 | **部分兑现**。false 现在对应 109 条已分类 residual，不再被 876 条已 purged v1 淹没。取值不应被做成 true。 |
| Status 秒级返回 | **未兑现**。#11 写 267s，#19 写 502s，#22 窗口 708s，本次 322s。都不是秒级。 |
| v1 真实 status/path | **兑现**。5 条未终结可直接识别。 |
| `ready` 能真实反映 v5 迁移阻塞 | **字段诚实，迁移仍不通**。`ready=false` 合理；v5 激活仍被 residual 挡住，且本票不激活 v5。 |

远端 #11 已是 CLOSED。未兑现部分应拆走：Status 性能见本目录草稿；解析器观测仍只是 #23 草稿。不要在 #24 扩范围。

## 性能：需要独立立项

不满足「日常清理前顺手确认」。归档降低了 blocking，**没有**降低 Status 每次全量重扫重哈希的成本。

主要成本：

- 每次 Status 仍枚举全部 evidence run（本次 2300）并哈希 plan / transaction / 必要 tree
- `entriesScanned=6205`、`bytesHashed≈1.80GB`，与 #22 窗口完全相同
- terminal 记录仍付全额扫描账；归档标记不能让 Status 跳过历史内容认证
- 同一字节量下 708s → 322s，说明受磁盘缓存支配，冷启动会回到数分钟到十几分钟

这与 #26–#43 的 Plan/Apply/Purge 哈希复用不是同一张票。草稿：`ticket-draft-status-performance.md`。

## 判定集与 smoke 分账

- **判定集**：本次 Status 看到的 2300 条。采集前最新写入仍是 #22 归档标记（`2026-08-13T19:06:02Z`）。
- **smoke**：在本判定落盘之后才跑。它会在 `reports/` 建 fixture，并在生产证据根留下**新** operation。那些新记录**不得**回写进上面的 109 / `complete` 结论。

## 风险与未验证

- 工作树 `policy.json` 有他人未提交条目；Status 用的是工作树 SHA，不是 HEAD。
- 本次 Status 距 #22 全量扫描约 21 分钟，322s 偏热，不能当成冷启动 SLA。
- 37 条 allowlist 的 Archive 资格仍只是 #23 的磁盘外形推断，本票未调用 Archive。
- 10 条 quarantine 在窗口中被谁删掉，本票未取证。
- 未实现任何解析器或 policy 改动。

## 附录：ProductionSmoke

判定报告先于 smoke 落盘。只跑了这一次。跑的是工作树里已有的未提交 ProductionSmoke（相对 HEAD 多了 #21 持锁断言）。本票未改、未回退 `tests/` 或实现。

| 项 | 值 |
| --- | --- |
| 套件 | `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` |
| 开始 / 结束 | 2026-08-13T20:04:59Z / 20:05:59Z |
| 墙钟 | 59.527s |
| 套件退出码 | **1** |
| 最终 pscustomobject | 未打出（中途抛错） |
| `#21` `leaf-delete-failed` 非零退出码 | **未得到结构化结果**，断言未通过 |
| `refusalReason` | 未观测到 `leaf-delete-failed` |

stderr 原文要点：

```text
Exception calling "AcquireSafeTreeDeleteFileLease" with "2" argument(s):
"Unable to acquire a safe-tree-delete file lease."
The property 'purged' cannot be found on this object.
```

前半段（只读 Archive 探测、fixture Plan/Apply/Purge、BatchPurge、batch 父目录清理）按证据已经走完：前 4 条新事务均为 `purged`，对应 fixture / quarantine 现已不在。失败发生在持锁 leaf-fail 段。第 5 条 `20260813T200553Z-03b8b4af-…` 最终也是 `purged`——这是测试 `finally` 释放句柄后的受管收尾，不是持锁路径返回了成功删除。

推断（不是本票要修的实现结论）：Purge 在叶子删除失败后的 catch 里会再扫一遍仍被测试句柄锁住的 quarantine；这次 `AcquireSafeTreeDeleteFileLease` 抛错，盖住了 `ReturnFailureMetrics` 应返回的 `{ purged:false, refusalReason:leaf-delete-failed }`。因此 wrapper 没有给出带 `purged` 字段的 JSON，StrictMode 下测试在读 `.purged` 时失败。

**不要把这 5 条新 operation 并进上面的 2300 / 109 / `complete=false`。** 名单见 `smoke-new-operations.json`。它们现在都是 `purged`，以后再跑 Status 会出现在判定集之外的增量里。

详细机器可读记录：`smoke-run.json`、`smoke-run.stderr.txt`、`smoke-result.json`。
