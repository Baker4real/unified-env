# 10 条 ui-references `quarantined→inconsistent` 旁路源（快照）

**本目录是只读调查快照，不构成 Archive / Apply / Purge / Restore / Delete 授权，也不构成改判 terminal 或放宽「quarantined 必须还能看见 quarantine」的授权。**

调查对象是 #22 归档窗口内 10 条时钟倒计时 `assets\ui-references` v7–v11。未改 scripts / tests / policy / spec / 既有 reports，未执行生产写入。

## 结论先行

**能排除本轮 Archive driver。** 10 条是同一组、同一机制。

| 项 | 判定 |
| --- | --- |
| 胜出假设 | **C + 用户归因**：quarantine 被受管入口之外删掉；用户事后确认 v7–v11 是先前因「好像没用了」而授权删除的 |
| A（本轮 Archive 误动） | **已证伪，可排除** |
| B（同窗口另一次受管 Apply/Purge/BatchPurge 动这 10 条） | **已证伪** |
| D | 精确 argv / 会话 id 仍未从 transcript 找回；**授权来源已由用户确认**，不再当本轮未解事故 |

target 在 Apply 时就已经不在原路径（改名进 sibling quarantine）。归档窗口里弄没的是那 10 个 `.codex-safe-delete-<guid>.quarantine` 目录。磁盘 `transaction.json` 仍是 `status=quarantined`，没有 journal，没有后继 Plan/Purge。

## 一组时间线（10 条共用）

| UTC | 事件 |
| --- | --- |
| 16:23:40–16:30:15 | 受管 `Plan` + `Apply`。entry=`clock-countdown-intermediate-ui-references`。v7–v11 各一条成功 Apply；另有 13 条同目标无事务计划（16:27–16:28）未 Apply |
| 16:26:12–16:30:15 | 各条 `transaction.json` 最后一次写入，`status=quarantined`。run 目录只有 `plan.json` + `transaction.json` |
| 16:33:19 | 时钟倒计时 `04c24fad`：`feat: add v12 UI reference baseline`（unix 1786638799）。此时 quarantine 仍应在：下一档 Status 仍是 recoverable |
| **17:24:48** | `status-before.json`：10 条 `lifecycle=recoverable`，`errors=[]`（quarantine 目录还在） |
| 17:32:37–19:06:02 | #22 逐条 Archive 2191 条。候选与 jsonl **都不含**这 10 个 id。最后一条成功 id 是 `20260813T142850Z-3ef6600a-…` |
| 18:01:20 | 时钟倒计时 `0208b1eb`：`fix: correct day ornament borders and rebuild all decoration PNGs`（unix 1786644080）。落在窗口内，但是 **commit 本身删不掉未跟踪 quarantine** |
| **19:19:32** | `status-after.json`：10 条 `lifecycle=inconsistent`，错误串「prepared/quarantined operation 的 target/quarantine namespace 不一致。」target 与 quarantine 都不在 |

现场 `assets\ui-references`：main 剩 v3/v6/v12，floating 剩 v1/v3/v6/v12。v7–v11 与 10 个 quarantine 目录都不在。

## 假设检验

### A — 本轮 Archive driver：排除

证据：

1. `reports/safe-tree-delete-archive-20260814/candidates.json` 无这 10 个 id。候选条件是 `transactionStatus=purged` 且 `quarantinePresent=false`；它们当时是 `quarantined` 且 quarantine 仍在。
2. `archive-invocation-log.jsonl` 无这 10 个 id。进度 `attempted=2191 succeeded=2191 refused=0 failed=0`。
3. `Invoke-CodexSafeTreeDeleteArchive`（`scripts/lib/CodexSafeTreeDelete.ps1`）在 `status≠purged` 或 quarantine 仍在时直接 `transaction-status-not-purged` / `quarantine-present`，只写 `terminal-archive.json`，不删项目树。
4. 10 个 run 没有 `terminal-archive.json`；`transaction.json` mtime/内容停在 Apply。
5. #22 worker `019ffbfd-8c68-77e3-965e-8a6ef3f70a0b` 自己写明：未调用 Apply/Purge/Delete；10 条漂移「不是本次 Archive 写入那些 run」。

### B — 同窗口另一次受管 Apply/Purge/BatchPurge：排除（针对这 10 条）

证据：

1. 受管 Purge/Restore 会改 `transaction.status` 并更新 `updatedAtUtc`。10 份事务仍是 `quarantined`，时间戳仍是 16:26–16:30。
2. 证据根在 `20260813T163013Z-6db8957f-…` 之后、归档后 smoke 之前，没有新的 ui-references / 指向这 10 个 quarantine 路径的 Plan。
3. 对这 10 个 `.codex-safe-delete-<这10个guid>.quarantine` 的全文检索，只命中它们自己的 `transaction.json`。
4. `Build-CountdownApplication.ps1 -Clean` 的 BatchPurge 白名单只有 `app` / `verification` / 各项目 `bin`/`obj`，不含 `ui-references`。
5. 现场没有后继 operation 把 `1165x1350` / `520x390` / `ui-references` 整棵当 target。

因此不是「时钟倒计时 v12 又走了一轮受管 Purge 清掉这 10 个 quarantine」。

### C — 受管入口之外：胜出

剩下的机制是：有人在 **17:24:48Z–19:19:32Z** 用非 `invoke-safe-tree-delete` 的方式删掉那 10 个未跟踪 quarantine 目录。

支持：

- 事务与 evidence 未被控制面推进。
- `.gitignore` **没有**忽略 `.codex-safe-delete*`，这些目录是未跟踪的；`git clean -fd` 或 `Remove-Item -Recurse` 都能一次清掉 10 个，且不会改 `transaction.json`。
- 同窗口时钟倒计时仓库仍在写：16:33 提交 v12，18:01 提交装饰图重建。v7–v11 本来就从未进 `origin/main`（基线 `1be2dd0`）。

**用户更正（2026-08-14，本编排会话）：** v7–v11 是用户先前授权删除的，理由是这些中间版好像没有用了。这解释了授权意图，也把「本轮 Archive 误伤」彻底关掉。磁盘仍显示删除未走受管 Purge：事务停在 `quarantined`，所以 Status 报 inconsistent 是合同行为，不是还要再删一遍。

精确 argv / 会话 id 仍未从现役 transcript 找回。不能把 18:01 的 `0208b1eb` 说成删除动作本身：普通 `git commit` 不会删除未跟踪 quarantine。

## 10 条对照

| operationId | 目标 | Apply 完成 UTC |
| --- | --- | --- |
| `20260813T162340Z-8a1c1553-…` | main `2026-08-13-v7` | 16:26:12 |
| `20260813T162931Z-53cd598e-…` | main v8 | 16:29:33 |
| `20260813T162935Z-56700506-…` | main v9 | 16:29:38 |
| `20260813T162942Z-2745b2a3-…` | main v10 | 16:29:48 |
| `20260813T162951Z-df0419e7-…` | main v11 | 16:29:55 |
| `20260813T162956Z-215e2c23-…` | floating v7 | 16:29:59 |
| `20260813T163000Z-54d37307-…` | floating v8 | 16:30:03 |
| `20260813T163004Z-03b96fc4-…` | floating v9 | 16:30:07 |
| `20260813T163008Z-1d1ca8df-…` | floating v10 | 16:30:11 |
| `20260813T163013Z-6db8957f-…` | floating v11 | 16:30:15 |

不要把同波次 13 条无事务计划算进这 10 条。

## 未知项

- 删除命令 argv 与当时会话 id（授权意图已由用户确认，不再阻塞本轮收口）。
- 未读 USN / 回收站 / 父目录 live mtime。
- 未重跑生产 Status；路径存在性以 #23 抽查与本次目录列举为准。
- 这 10 条仍会留在 blocking 里，直到另有授权决定是否用控制面收尾；本轮不改判 terminal，也不补 Purge。

## 报告路径

- `D:\Codex\projects\统一环境\reports\safe-tree-delete-window-bypass-20260814\REPORT.md`
- `D:\Codex\projects\统一环境\reports\safe-tree-delete-window-bypass-20260814\findings.json`
