# 六票关口编排结论（2026-08-16）

Matt 路由：六张都是现成 ticket，走 `/implement` 关口核对；#46 inventory 红走 `/diagnosing-bugs`。
编排分支：**只读并行，主 Agent 单点写入**。六票共享 `CodexSafeTreeDelete.ps1`、hooks、工作树和 evidence 根，不能完整分发写入 worker。

本文件纠正 `REPORT.md` 里把后续票条件误写成关票门槛的几处。不构成 `gh issue close`、Archive、Purge 或部署授权。

调度 id（只读 explore）：

| 票 | subagent_id |
| --- | --- |
| #20 | `01a00882-26bd-7c92-8598-60f16c43870c` |
| #22 | `01a00882-26c2-7913-8372-49adab8c23ee` |
| #35 | `01a00882-26c7-79d3-821c-06d0c3e1aa33` |
| #46 | `01a00882-26cb-7d22-b6d5-d33110e0cd85` |
| #48 | `01a00882-26d0-7d70-8fb4-fef4bf5cee12` |
| #54 | `01a00882-26d5-74c3-9fd3-dc66c994828c` |

主 Agent 已用 `D:\Codex\tools\bin\gh.exe` 读过 #20/#22/#35/#45/#46/#47/#48/#50/#52/#54 正文；#35 最新评论即 waiver。worker 自己拉私仓 404，其票面对照由主 Agent 回读补齐。

## 关票 DAG（#45 / #52，live）

- 控制面关票顺序：`#19 → #22 → #23 → #24`，`#20 → #21`，`#21 + #24 → #18`。
- `#52` 负责把 #20–#24 回写并关闭，但 **blocked-by #47 与 #50（均仍 OPEN）**。
- `#52` 写明：#21 只能引用 **#47** 的真实 wrapper 非零退出码证据，不能引用 fixture 或仅 suite exit 0。
- 因此：**实现关口已满 ≠ 现在执行 `gh close`。** 本编排达到的是实现/验收关口；GitHub 关闭仍要另授评论权，且 #20–#24 的正式关票动作属于 #52。

## 逐票

| 票 | 实现关口 | 现在能否 `gh close` | 剩余 |
| --- | --- | --- | --- |
| #20 | **传递修复已满**；生产 JSON 已打出且符合 spec 277–278 | 否。要结论评论；正式关 #20–#24 走仍被 #47/#50 挡住的 #52。08-15 评论曾把生产 JSON 记给 #55/#47，关票评论必须区分：#20 只主张传递，不吞并 #47/#55 | leftover 是新的 `purging` 在途事务，不是可选打扫；02:17 Status 不含该 op |
| #22 | **归档执行已完成**（marker 2200；未终结 v1/v2 仍在；`complete=false` 正确） | 否。走 #45/#52。票面「既有测试保持通过」未在干净树证明；本波次 FileSystem 红属 #35 waiver，不能写成整票只差代发评论 | 不要补 12 条 not-applicable marker；不要 Archive 42 条 #48 观测。02:17 Status 在 leftover/Smoke 之前 |
| #35 | **已满 + waiver**。Detect/`DeletionAllowed` 已接入 Plan/Apply/Purge | 否。只要结论评论；未授权 close | 未提升 FileSystem 红不阻塞本票 |
| #46 | **互斥 AC 已满**。定向测试绿；live/managed pin 一致 | 否。要结论评论 | HookInventory 红不属于本票 |
| #48 | **已满**。42 条 purged+manual-review **是观测成功**，且必须继续 blocking | 否。要结论评论 | 不要为清 blocking 再改 Status |
| #54 | **功能 AC 已满**（Plan 写 stream-set，Apply/Purge 消费，ProductionSmoke 绿） | 否。要结论评论。15 条缺 `leafStreamSetV1` 的在途事务按 spec:242-246 是**部署/#45/#50 门禁**，不是 leafStreamSet 功能 AC。关 #54 会解开 #55，但 #55 自己还要打确定性负向 smoke，不能把 15 条清场塞进 #54 | 未授权不得 Restore/Purge 时钟倒计时。leftover 是第 17 条在途，属 #45/#50 清空集 |

## 纠正 `REPORT.md`

1. 「#22 仍 OPEN：complete=false，blocking 110」——那是 #23/#24/#18 条件，不是 #22 AC。
2. 「#48 仍 OPEN：42 条仍 blocking」——与 Status 合同相反；未归档的 policy 拒绝记录必须继续 blocking。
3. 「#54 仍 OPEN：15 条 legacy」——spec:242-246 写的是部署前清空，不是关 #54。

## 主 Agent 核过的源码锚点

- wrapper 转发：`scripts/invoke-codex-safe-tree-delete-host.ps1:5`，宿主副本同哈希。
- 生产 `exit 1`：`scripts/Invoke-CodexSafeTreeDelete.ps1:135-139`。
- #20 生产 JSON：`issue20-production-purge-fail.json`；leftover quarantine 仍在。
- #48 观测：`scripts/lib/CodexSafeTreeDelete.ps1:2237-2323`（plan 拒绝后填 status/namespace，再 throw 只读）。
- #35 闭锁：`Assert-CodexSafeTreeDeleteDeletionAllowed` 在 `CodexSafeTreeDelete.ps1:892-910`。
- #46 inventory 红：脏 `managed/codex-hooks/manifest.json` 把 `codex-state-policy` 标 active，wrapper 指向已存在的 `codex-projectless-root-d.cmd`。未改该文件。

## 独立复核

- reviewer `01a0088b-26cc-7623-a5e8-8f71e479e102`：未把「关口已满」偷换成现在 `gh close`；高影响项是 leftover 使 02:17 Status 作废、以及勿把 #20 生产 JSON 写成吞并 #47/#55。
- verifier `01a0088b-26d0-7871-83c7-9f3064b65d9f`：源码/磁盘锚点 1–7 确认；其 #47/#50 live 查询未跑。主 Agent 本回合 `gh.exe issue view`：#47 OPEN，#50 OPEN，#21 OPEN。leftover quarantine 目录仍在。
- `Assert-CodexSafeTreeDeleteDeletionAllowed` 调用点：Plan `:931`，Apply `:2960`，Purge `:4518`。

## GitHub 结论评论（2026-08-16，已发，未 close）

| 票 | 评论 |
| --- | --- |
| #20 | https://github.com/Baker4real/unified-env/issues/20#issuecomment-5305572165 |
| #22 | https://github.com/Baker4real/unified-env/issues/22#issuecomment-5305572346 |
| #35 | https://github.com/Baker4real/unified-env/issues/35#issuecomment-5305572485 |
| #46 | https://github.com/Baker4real/unified-env/issues/46#issuecomment-5305572614 |
| #48 | https://github.com/Baker4real/unified-env/issues/48#issuecomment-5305572747 |
| #54 | https://github.com/Baker4real/unified-env/issues/54#issuecomment-5305572872 |

正文副本：`reports/safe-tree-delete-closeout-20260816/github-comments/`。

## 本编排未做

- 未改生产实现、测试、policy、hooks。
- 未 Purge leftover，未 Restore/Purge 15 条 legacy。
- 未 `gh issue close`，未 commit/push。
