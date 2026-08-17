# 控制面关闭门槛复跑（2026-08-16）

本目录是带源码 SHA/mtime 配对的现场快照，不是关票、Archive、部署或清理他人在途事务的授权。

运行时：PowerShell Core 7.6.4（`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`）。生产入口始终是 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`。

源码身份：`source-identity.json`（`generatedAtUtc=2026-08-16T02:09:46Z`）。wrapper 仓库源与宿主副本仍一致：middle `636CB140720BF15681364459269C2D5DC4638E339F2589AD2A3A53B6E17B9373`，`.cmd` `45AEADF7F758A1CAFCE106F66E7EAECC5F60176D2017630E2AF461A2A37BCA12`。`CodexSafeTreeDelete.ps1` SHA-256 `84E8A419…`，mtime `2026-08-15T14:26:48Z`。

## 总表

| Issue | 本次结果 | 是否可关 |
| --- | --- | --- |
| #20 wrapper 退出码 | **生产 Purge 已打出** `purged=false` + `leaf-delete-failed` + metrics + exit 1 | 证据门槛已满足；工作树仍脏，且留下一条本会话 quarantine |
| #22 terminal 归档 | Status 已重跑；HashSafely 现为绿；ProductionSmoke 绿 | 仍 OPEN：`complete=false`，blocking 110，归档 marker 仍 2200 |
| #46 Serena 互斥 | 定向互斥测试绿；live/managed guard pin 一致 | 仍 OPEN：完整 inventory fixture 红，host-live 配置里没有互斥项 |
| #48 policy 拒绝后观测 | Status fixture 18 slices 绿；ProductionSmoke 绿 | 仍 OPEN：生产 Status 里 42 条 purged+manual-review 仍 blocking |
| #54 stream-set | LeafStreamSet 4 / CrashSafety 13 / ProductionSmoke 绿 | 仍 OPEN：15 条 legacy 在途事务缺 `leafStreamSetV1`，未清理、未部署 |

已执行：六票结论评论（未 close）。链接见 `ORCHESTRATION-CLOSE-GAPS.md`。

未执行：`gh issue close`、commit/push、policy v5 激活、对时钟倒计时等项目树的 Restore/Purge。

编排复审（只读六票 + 主 Agent 回读 #45/#52）见同目录 `ORCHESTRATION-CLOSE-GAPS.md`。它纠正本表把 #23/#24 的 `complete`、#48 的 42 条 blocking、#54 的部署门禁误写成各票关闭门槛的表述。实现关口与 `gh close` 不是一回事：正式关 #20–#24 属于仍被 #47/#50 阻塞的 #52。

## #20：真实受管 Purge 失败 smoke

策略：不改生产实现。Apply 之后用子进程监视 `transaction.json` 变为 `purging`（locked preflight 已放租约并写盘），再对 quarantine 文件持 `FileShare.Read`。这不是 Purge 开始前持锁，因此不会在 JSON 发出前被预检 lease 盖住。

经 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Purge -Json`：

```text
exit=1
{"purged":false,"refusalReason":"leaf-delete-failed",...,"metrics":{"schemaVersion":1,"phase":"purge","elapsedMs":933,...,"retry":{"attempts":2,"result":"failed-after-retry"}}}
```

对照物：

- `issue20-production-purge-fail.json`
- `purge-fail.stdout.txt`
- operation `20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e`

缺确认 Archive 仍由 ProductionSmoke 证明：exit 0 + `confirm-archive-required`。

**残留：** quarantine `D:\Codex\projects\统一环境\reports\.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 仍在。首次 resume 用了 `Get-FileHash` 的大写 SHA，生产比对是大小写敏感，失败。清理脚本已写好：`invoke-issue20-cleanup.ps1`。未再 Purge。

## #22 / #48 / #54：Status + 回归 + ProductionSmoke

生产 Status（`status-raw.utf8.json`，SHA-256 `0c7e502359f7335a145238bdfc73d9ea41a4106c704f19d05d2749a78ec1efd9`，墙钟 429.015 s，exit 0）：

| 字段 | 值 |
| --- | ---: |
| operations | 2323 |
| complete | false |
| blockingRecords | 110 |
| terminal | 2212 |
| archived markers | 2200 |
| journalStatus=not-applicable | 12 |
| archive candidates（purged ∧ quarantine 不在 ∧ 非 terminal） | 42 |

blocking 拆分：manual-review 87、inconsistent 23。其中 transactionStatus=purged 的 blocking 正好 42 条，journal 均为 `unavailable`，属于 policy 拒绝后的只读观测（#48），不是新的可静默 Archive 噪声。

相关 fixture（`related-fixture-tests.json`）：

| 测试 | exit | 墙钟 |
| --- | ---: | ---: |
| LeafStreamSet | 0 | 17.1 s |
| Status | 0 | 34.8 s |
| HashSafely | **0**（上次红） | 1.4 s |
| CrashSafety | 0 | 86.7 s |
| FileSystem | 1 | 9.2 s |
| SerenaBehavior | 0 | 33.1 s |
| HookInventory | 1 | 7.6 s |

FileSystem 红是因为 `diskpart.exe` 需要提升（Win32 740），一次性 FAT32 VHD 建不出来。#35 已把真实 FAT32/exFAT/网络 e2e 列为 waiver，不是本波次关票条件。

ProductionSmoke：exit 0，60.224 s。`unconfirmedArchiveExitCode=0`，`confirm-archive-required`，BatchPurge recovered=1，batch 父目录已受管清掉。stdout 见 `production-smoke.stdout.txt`。该套件仍不声称自己覆盖生产 `leaf-delete-failed`；那条由上面的 #20 harness 单独证明。

## #46：完整 fixture 失败与 host-live

`tests/Test-CodexSerenaBehaviorHooks.ps1` 通过，含真实子进程互斥、fail-open、abandoned mutex。

live/managed `serena-behavior-guard.ps1` SHA-256 均为 `85D78B8533A47F8A9F3419E1BC4DB33E3351522D7E8C1FE1AA861C0399F4EA3A`。

`tests/Test-CodexHookInventory.ps1` 失败原文：

```text
已退役 state policy wrapper 必须作为缺失依赖观察，不得假定仍在线
```

原因在当前脏工作树的 `managed/codex-hooks/manifest.json`：`codex-state-policy` 的 `wrapperPath` 被指到已存在的 `D:\Codex\.codex\hooks\codex-projectless-root-d.cmd`，`lifecycle=active`。inventory 因此看到 wrapper 存在，不再是 `pending-or-mismatched` + `wrapperExists=false`。这不是 Serena session 互斥回归，也未改该 manifest。

codex-host 的 host-live profile 只有 launcher / catalog / IFEO / retired-artifact，没有 Serena mutex 项。本次未对生产 Serena session 跑 live Reminder。可用的 live 核验是 guard pin 一致。

## #54：legacy 在途事务（只读盘点）

`legacy-inflight-inventory.json`：2323 个 run，在途 16 条；其中 **15 条缺 `leafStreamSetV1`**。

| 类 | 条数 | 处置 |
| --- | ---: | --- |
| schema v1 reports 批处理残留 | 1 | 严格 Purge/Restore reader 不接受 v1 |
| 时钟倒计时 bin/app/verification（v1/v2） | 4 | 真实项目树，未动 |
| ui-references v7–v11（v2 quarantined） | 10 | 真实资源，未动 |
| 已有 leafStreamSetV1 的 run-evidence quarantined | 1 | 不是 legacy 缺口 |

部署前必须先清空、Restore 或重 Plan 这 15 条。本波次只盘点，没有 Restore/Purge/部署。

另有 66 条非终态 plan 缺 `leafStreamSetV1`（含无 transaction 的 run）。在途 16 条里只有上面那 15 条会挡住 #54 生产切换。

## 未做 / 需要确认

1. **#20 leftover Purge**：确认后可跑 `invoke-issue20-cleanup.ps1`。
2. 15 条 legacy 在途事务的逐条 Restore 或重 Plan。
3. 关票评论、工作树稳定化、policy v5 部署。
4. 完整 `Run-PowerShellTests.cjs --module host-safety`（本次跑的是相关子集 + ProductionSmoke）。
5. 未改 `scripts/lib/CodexSafeTreeDelete.ps1` 业务逻辑，未改 production wrapper。
