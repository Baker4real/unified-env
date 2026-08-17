# Issue #22 评论收口（2026-08-15）：11 条差异解释与剩余 fixture

**本目录是只读调查 + fixture 记录，不构成关票、Archive / Apply / Purge / Status 生产写入、放宽判据或后续授权。** 未改 `scripts/`、`tests/`、`managed/`、`docs/`、policy、hooks、20260814 旧报告，也未改 `reports/safe-tree-delete-issue22-20260815/` 已有文件。未执行 `gh issue comment` / `close`、commit / push / 生产 Archive。

结论：**DONE_WITH_CONCERNS**。11 条 marker 差已经按 operationId 解释清楚。允许的 fixture 里 4 个绿、HashSafely 仍红。本波次按评论要求**没有**重跑生产 Status、**没有**跑 ProductionSmoke、**没有**跑 host-safety 全量。建议票保持 **OPEN**。

权威评论：GitHub #22 最新一条（2026-08-15 代码对齐审查）为 DONE_WITH_CONCERNS；建议补齐上次跳过的测试，并解释磁盘 2200 个 `terminal-archive.json` 对 Status 2211 个 terminal 的 11 条差。

## 11 条差异

对照物：

- Status 快照：`reports/safe-tree-delete-issue22-20260815/status-before.utf8.json`（`capturedAtUtc=2026-08-14T17:59:04.8543069+00:00`，SHA-256 `59cd72358e18201ee0ab66d65f5541bc4aa7a62bb2b7cbcb89094141d49ecec8`，与 summary 一致）
- 现场磁盘（2026-08-15T06:46:51Z 枚举）：`D:\Codex\.codex\run-evidence\safe-tree-delete\*\terminal-archive.json`

| 集合 | 数量 |
| --- | ---: |
| Status `lifecycle=terminal` | 2211 |
| 磁盘 `terminal-archive.json` | 2200 |
| 两边都有 | 2200 |
| 有 terminal、无 marker | **11** |
| 有 marker、无 terminal | **0** |
| 重复 marker | 0 |

Status 2211 条 terminal 的拆分：`journalStatus=archived` 2200（有认证 marker）+ `journalStatus=not-applicable` 11（无 marker 的 live purged）。2211 条全部 `transactionStatus=purged`。磁盘计数现在仍是 2200，与上次报告的声称一致，没有在对照窗口里再写出 marker。

合同含义（只读源码 `Resolve-CodexSafeTreeDeleteStatusOperation`）：

1. run 里若存在可认证的 `terminal-archive.json`，Status 走 Archive 分支，标 `lifecycle=terminal`、`journalStatus=archived`。
2. 没有 marker 时，只要 live 观测到 `purged` 且 namespace 一致（rebuildable-build-output 允许 target 被重建），Status **仍然**标 `lifecycle=terminal`。
3. #22 的 Archive 候选是 `purged ∧ quarantinePresent=false ∧ lifecycle != terminal`。这 11 条已经是 terminal，所以 **不是**候选；上次 live 候选为 0 是对的，不必、也不应靠补写 marker 抹平计数。

11 条共性：transaction schema v2、`directoryCommitAnchors=[]`、quarantine 不在、`errors=[]`、`policyCompatible=true`、`schemaCompatible=true`、现场仍无 `terminal-archive.json`。`journalStatus=not-applicable` 是因为 anchors 为空且当前 policy purpose 不是 `empty-project-state`，不是认证失败。

### 分类表

| operationId | 集合 | 分类 | 子类 | policyEntryId | 当前 purpose | targetPresent |
| --- | --- | --- | --- | --- | --- | --- |
| `20260814T020720Z-7fe528f4-5f51-4990-9818-ba3b99e96a69` | 有 terminal 无 marker | live purged，namespace 已空 | 收口后 reports/smoke 清理 | `environment-reports` | `none` | false |
| `20260814T022358Z-84436ddd-b95d-4608-beda-410897d3cec3` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-app-build` | `rebuildable-build-output` | true |
| `20260814T022434Z-f0c6f9ec-d42b-40a6-9a94-4637319d8d7f` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-verification-build` | `rebuildable-build-output` | true |
| `20260814T022509Z-32c3ebd7-2083-4db4-a65f-e9d32dae719f` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-core-bin` | `rebuildable-build-output` | true |
| `20260814T022544Z-5abb4a9d-d885-4e8f-9a7c-94f0845d8c63` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-core-obj` | `rebuildable-build-output` | true |
| `20260814T022650Z-83de648e-cfaf-4c51-83e6-a40f84b54e96` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-app-bin` | `rebuildable-build-output` | true |
| `20260814T022826Z-aa6ba336-40ab-439e-a9ef-d5dedbe21097` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-app-obj` | `rebuildable-build-output` | true |
| `20260814T022920Z-a447bd4a-2951-4570-8658-9d9bdd0d61c7` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-verification-bin` | `rebuildable-build-output` | true |
| `20260814T023016Z-9d982bb3-a5e8-46b4-bc78-93dd4648ca9a` | 有 terminal 无 marker | live purged，rebuildable 已重建 | 时钟倒计时可重建批量 | `clock-countdown-verification-obj` | `rebuildable-build-output` | true |
| `20260814T090756Z-54246ac3-9bd5-4ed0-b07d-cce9249e4700` | 有 terminal 无 marker | live purged，namespace 已空 | run-evidence 后代清理 | `codex-run-evidence` | `none` | false |
| `20260814T170159Z-cf25c042-24c4-4c30-b1e6-fd3a49f52964` | 有 terminal 无 marker | live purged，namespace 已空 | scratch fixture 清理 | `environment-scratch` | `none` | false |

这 11 条**不是**：窗口旁路（那 10 条 ui-references 仍是 `quarantined`/`inconsistent` 且无 marker）、policy 拒绝后的观测、无效 marker、未终结事务。purpose 来自当前生产 policy 对应 entry，不来自 plan 快照。

时间线：20260814 收口声称 archived=2191；随后 leftover 又 Archive 了 9 条（2191+9=2200 marker）。这 11 条都是 2026-08-14T02:07Z 之后的新 purged 记录，Status 直接标 terminal，因此从未进入 #22 候选。

## Fixture

入口：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe -NoProfile -NonInteractive -File …`（Core 7.6.4）。未跑 ProductionSmoke，未跑 `Run-PowerShellTests.cjs --module host-safety`。

| 测试 | 退出码 | 墙钟 |
| --- | ---: | ---: |
| `tests/Test-CodexSafeTreeDeleteIdentityV2.ps1` | **0** | 0.967 s（6 slices） |
| `tests/Test-CodexSafeTreeDeletePlanIdentityV2.ps1` | **0** | 3.758 s（3 slices） |
| `tests/Test-CodexSafeTreeDeleteHashSafely.ps1` | **1** | 2.047 s |
| `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` | **0** | 1.838 s（4 slices） |
| `tests/Test-CodexSafeTreeDeleteStatus.ps1` | **0** | 54.431 s（18 slices；工作树含他人 #48 补丁，只跑不改） |

HashSafely 原文（stderr）：

```text
Get-CodexSafeTreeDeleteHashSafely: D:\Codex\projects\统一环境\tests\Test-CodexSafeTreeDeleteHashSafely.ps1:283
Line |
 283 |              [void](Get-CodexSafeTreeDeleteHashSafely `
     |                     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | Exception calling "GetHashSafely" with "3" argument(s): "Failed to open path exclusively for hash reuse without
     | following reparse points."
```

失败点是 sharing-probe 占住文件后的 exclusive hash-open。工作树 `scripts/lib/CodexSafeTreeDeleteFileIdentity.cs` 相对 HEAD **+312**，另有他人未提交的 `CodexSafeTreeDelete.ps1`（+561）和 Status 测试（+365）。本票未回退、未改实现、未改测试。

## 仍建议 OPEN

- 11 条差已解释，本身不再需要靠 Archive / 补 marker 关账。
- HashSafely 仍红，且绑定他人 identity WIP。
- 前一条审计要求的稳定工作树后生产 Status、全量 host-safety、ProductionSmoke、发布前后证据：本波次明确不跑，仍未验证。
- 上次 live Status 仍是 `complete=false`、`blockingRecords=110`、5 条 v1 + 1 条历史 v2 未终结。那些不是本波次验收项。
