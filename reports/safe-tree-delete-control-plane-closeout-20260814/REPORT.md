# Issue #18 控制面史诗收口（快照）

**本目录是文档收口快照，不构成关票、归档、Apply / Purge / Delete 或放宽判据授权。** #18 是集成与文档，不是第三条实现路径。本次未改 `scripts/`、`tests/`、`managed/safe-tree-delete/policy.json`、wrapper 或子票已有 reports；未跑生产 Status 或 ProductionSmoke；未执行 `gh issue comment` / `close` / `create`。

数字 2191 / 109 / 322s 只属于子票时间点快照，不是现役合同。权威合同见 `docs/specs/2026-07-24-safe-tree-delete-capability.md`。

## 结论先行

| 项 | 判定 |
| --- | --- |
| 本收口 | **DONE_WITH_CONCERNS**。缺口段落已写回权威 spec；史诗用户可感目标未全部兑现。 |
| `complete` | 归档合格 terminal **不会**自动变为 `true`。#18 评论与 #24 live 已否决该验收。 |
| 退出码传递 | #20 已兑现中间层 `$LASTEXITCODE` 转发。不得声称 #21 live 持锁路径已打出生产 `leaf-delete-failed` JSON。 |
| Status 性能 | 归档消除的是 blocking 噪声，不是全量扫描账。秒级返回不在本史诗验收内。 |
| 远端票 | #17 / #11 已是 CLOSED（结论只写在此与 #24）。**未关** #18 / #20–#24。 |

## 子票 AC

| 票 | 根代理验收 | 兑现 | 被 live 否决或带顾虑 |
| --- | --- | --- | --- |
| #19 | 基线已入仓 | 归档前 Status 基线留在受版本控制位置 | 基线数字（1674 / 79）不得套到本轮 live |
| #20 | **DONE** | 中间层 `exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })`。本收口核验仓库源 `scripts/invoke-codex-safe-tree-delete-host.ps1` SHA-256 为 `636cb140720bf15681364459269c2d5dc4638e339f2589ad2a3a53b6e17b9373`，与已验收源/宿主哈希一致 | 无 |
| #21 | **DONE_WITH_CONCERNS** | `leaf-delete-failed` 非零退出码断言写入 ProductionSmoke；副本探针修前 0 / 修后 1 | **live smoke 未绿**。持锁 Purge 在失败回滚快照上再次 `AcquireSafeTreeDeleteFileLease`，没有打出 `leaf-delete-failed` JSON。未改测试去让它绿 |
| #22 | **DONE_WITH_CONCERNS** | 2191 条逐条 Archive 成功；blocking 2290→109；候选 0。判据未放宽 | 不要用 #19 的 1674→79。`complete` 仍为 false，这不是 #22 失败 |
| #23 | **DONE_WITH_CONCERNS** | 89 条未解析已分类，不再有「不知道是什么」 | 37 条磁盘已 purged 的 v2 因 plan 被当前 allowlist 拒绝后不对 v2 做只读观测而看不见。不放宽判据，不重新登记已撤销 root |
| #24 | **DONE_WITH_CONCERNS** | 2026-08-13T19:59Z Status：`complete=false`，`ready=false`，blocking 109，`elapsedMs=321851`。`complete=false` **合理** | Status 仍不满足顺手确认。#18 原文「归档后 complete=true / 耗时显著下降」被这次 live 再次否决 |

#18 票面里已被子票 live 改写、本收口写进权威 spec 的否决：

- 「归档全部合格 terminal 后 `complete` 必为 true」——错。
- 「归档同时消除 Status 全量扫描账、从而接近秒级」——错。归档不是算法优化。
- 「生产 wrapper 链上 `leaf-delete-failed` 已 live 证明」——只证明了传递修复与断言落点；持锁生产 Purge 失败 JSON 未打出。

#18 已兑现、且不依赖上述错误验收的部分：合格历史记录可逐条 Archive 并退出 `blockingRecords`；evidence 不被删除；单笔确认语义与三条 Archive 判据未放宽；policy 仍为 v4；v1 未终结记录仍可见；未解析记录有稳定分类；seam / purpose 追溯语义现已落在权威 spec。

## #17 / #11 已关闭后，本史诗还剩什么

远端 #17 / #11 已是 CLOSED。按 #24：#17 可理解为归档控制面交付；#11 的 `complete` 判定价值只是部分兑现。下面这些**不应**靠重开 #17 / #11 或放宽判据解决。

1. **解析器观测**（#23 草稿，未实施）  
   plan 被当前 policy 拒绝后，对历史 v2 做与 v1 对称的只读观测，并填写 `targetPresent` / `quarantinePresent`。卡住的是 Status 观测，不是 Archive 合同。37 条外形已 purged 的记录因此进不了候选。不要重新登记已撤销 root。

2. **Status 性能**（#24 草稿，未实施）  
   秒级返回不在本史诗验收范围内。需要独立立项。不得靠跳过 marker / 内容认证或放宽 Archive 换时间。

3. **#21 smoke 持锁路径**  
   生产 Purge 在叶子删除失败后的 catch 里再次抢 lease，盖住 `ReturnFailureMetrics` 应返回的 `{ purged:false, refusalReason:leaf-delete-failed }`。wrapper 因此没有给出带 `purged` 字段的 JSON。未改测试、未改实现。

4. **10 条 2026-08-13 ui-references `quarantined` 旁路**  
   事务已解析，target 与 quarantine 现在都不在。归档窗口中从 recoverable 翻成 inconsistent。不要改判 terminal，不要放宽「quarantined 必须还能看见 quarantine」。

即使将来做完观测补丁并再归档外形已 purged 的记录，仍会留下 v1 未终结、历史 v2 未终结、上述 10 条旁路、过期无事务计划与 ACL 探测目录。那时 `complete` 仍应是 `false`。

## 权威 spec 改了哪几段

只补缺口短段，未重写全文。未写入 2191 / 109 / 322s 等快照数字。

| 位置 | 补上的合同 |
| --- | --- |
| 固定入口 / `rootDeletionPurpose` 规则之后 | purpose 读**当前 policy entry**；plan 只存 entry 标识，不快照 purpose；改 entry purpose 会追溯翻转引用该 entry 的历史 purged + target-present 判定；与 policy SHA drift 同类 |
| 固定入口 / 测试替身段 | 崩溃注入类子进程 helper 不是竞争性主 seam，不计为第二生产入口；既有 crash fixture 已有先例 |
| 控制面 `Status` | `complete` 聚合语义；归档合格 terminal 不蕴含 `complete=true`；`complete=false` 在仍有 residual 时正确；Archive 消除 blocking 噪声而非全量扫描账；秒级返回不在本史诗验收内 |
| 控制面 `Archive` | 再次写明：合格 terminal 退出 blocking 不等于整次 `complete=true`；禁止把该蕴含当验收 |
| 结果与可观测性 / 退出码 | 保留 JSON `leaf-delete-failed` 非零退出码；受管中间层必须转发 `$LASTEXITCODE`；缺确认的结构化 refusal 仍是 exit 0；未打出该 JSON 的持锁抛错不得冒充已 live 验收 |

## 远端 GitHub

| 票 | 本次动作 |
| --- | --- |
| #18 | 已 `gh issue view`（含评论对 `complete` 的更正）。**未评论、未关闭**。查看时为 OPEN |
| #20–#24 | **未评论、未关闭** |
| #17 / #11 | 未触碰。#24 记录当时已是 CLOSED |

编排禁止关票。tracker 若要诚实反映 #18 原文「归档后 complete=true」，应保留本报告与 spec 更正，而不是重开子票去改判据。

## 风险与未验证

- 本收口未重跑 live Status / ProductionSmoke；子票计数与 `elapsedMs` 绑定各自快照。
- 工作树 `policy.json` 在子票时点有他人未提交条目；本收口未回退、未改写。
- 37 条 allowlist residual 的 Archive 资格仍只是 #23 的磁盘外形推断，从未调用 Archive。
- 10 条 quarantine 在归档窗口中被谁删掉，#23 / #24 均未取证。
- 仓库 wrapper SHA 已核验；宿主副本本次未再哈希（#20 已验收同源哈希）。
- 未把本目录登记进 `modules/manifest.json`，与同日 #22–#24 报告目录一致。
