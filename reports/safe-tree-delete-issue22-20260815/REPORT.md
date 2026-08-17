# Issue #22 分批归档验收（2026-08-15 快照）

**本目录是本次 live 运维证据，不构成关票、Apply / Purge / Delete、放宽判据、激活 v5 或后续 Archive 授权。** 未改 `scripts/`、`tests/`、`managed/safe-tree-delete/policy.json`、wrapper、spec 或 20260814 旧报告。未执行 `gh issue comment` / `close`。

结论：**DONE_WITH_CONCERNS**。本次 live 合格候选为 **0**，因此**没有**新的 Archive 写入。`complete` 仍为 `false`，这不是本票失败。

## 第一性原理

- 目标：让当前 live 已确认 terminal 的账面噪声退出 `blockingRecords`。
- 约束：只调用既有 `Archive`；每条自带 `ConfirmArchive` + 精确 path + 现场 SHA-256；不新增 `BatchArchive`；不放宽三条判据。
- 事实：#19 已 CLOSED；20260814 收口已声称归档 2191 条；数字过期，必须以本次 Status 为准。
- 失败模式：复用旧快照、把 `complete=false` 当失败、复用确认哈希、手改 evidence。
- 完成标准：候选从本次 Status 推导；若为 0 则停止归档；未终结 v1/v2 仍在；fixture 仍绿。

## Live Status

入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`

| 项 | 值 |
| --- | --- |
| 开始 | 2026-08-14T17:48:23Z |
| 结束 | 2026-08-14T17:59:06Z |
| 墙钟 | 643.071 s（`elapsedMs=640347`） |
| 退出码 | 0 |
| 原始输出 | `status-before.json`（GB18030，2814331 bytes，SHA-256 `491f56d1…`） |
| UTF-8 副本 | `status-before.utf8.json` |
| `complete` | **false** |
| policy schema | **4** |
| policy SHA-256 | `01a22918150646bc37c5a51c9f4d1392750fa1e44501b5c651ca2d14f4362c90` |
| operations | 2321 |
| blockingRecords | **110** |
| 合格候选 | **0** |
| lifecycle | terminal 2211 / manual-review 87 / inconsistent 23 |
| v1 未终结 | **5**（全部仍在） |
| 历史 v2 未终结 | **1**（`20260805T083256Z-1ba06d2f-…` 仍在且仍非 terminal） |

候选判据（未放宽）：`transactionStatus=purged` 且 `quarantinePresent=false` 且 `lifecycle != terminal`。

Status 前后 evidence 目录均为 **2321**，无新增、无删除。本票未手改任何 evidence。

## 与历史快照的偏差

| 快照 | 候选 | blocking | 说明 |
| --- | --- | --- | --- |
| #19 / 票面 | 1595 | 1674 → 约 79 | 归档前基线，不是当前事实 |
| 20260814 收口 | 0（已归档 2191） | 2290 → 109 | 过期；当时 operations=2300 |
| 本次 live | **0** | **110** | operations=2321；terminal=2211 |

解释：

1. 1595 / 1674 是 #19 归档前账。20260814 已经把当时合格 terminal 逐条 Archive 完，所以本次再推导候选为 0。不得为了“做事”再 Archive。
2. 票面“降至约 79”是 #19 当时的投影残差。20260814 已证明真实残差是 109（未解析 / allowlist / window-bypass / 未终结），不是 79。
3. 相对 20260814 的 +1 blocking：`20260814T012818Z-4f9b7a0c-f090-4609-9625-c0f03896290d`。`transactionStatus=null`，错误为 capability root 不在 allowlist。**不是** Archive 候选。
4. 相对 20260814：operations 2300→2321（+21），terminal 2191→2211（+20）。这 20 条新 terminal 来自后续 leftover/其他运维，不是本票写入。
5. `complete=false` 正确：仍有 5 条 v1 未终结、1 条历史 v2 未终结、allowlist / namespace / window-bypass 等 residual。

仍可见的 5 条 v1 未终结：

- `20260725T010726Z-0609f165-c496-4280-85c4-6bb8a5e9465b` rolled-back
- `20260725T130041Z-a5fd8743-a239-423c-9c44-4cbb5aa6a2cc` quarantined
- `20260728T162734Z-c602a5b7-34bb-4469-bf9b-2754cadc5a76` prepared
- `20260729T055433Z-0f0aeb5d-efcc-43cb-973b-a58a9ea748d6` purging
- `20260730T170848Z-26f7ea53-0578-43c4-b245-9ab5304ca5d6` prepared

历史 v2 未终结仍在：`20260805T083256Z-1ba06d2f-fbf0-43fe-a57e-7fd57f943153`（policy 漂移，quarantined）。

## Archive 写入

| 项 | 值 |
| --- | --- |
| 新 Archive 调用 | 0 |
| succeeded | 0 |
| alreadyArchived | 0 |
| refused | 0 |
| failed | 0 |
| 新增 `BatchArchive` | 否 |
| 复用确认哈希 | 否 |

## 保护面（只读）

- wrapper 宿主/仓库 SHA-256 均为 `636cb140720bf15681364459269c2d5dc4638e339f2589ad2a3a53b6e17b9373`
- 生产脚本 `Invoke-CodexSafeTreeDelete.ps1` SHA-256 仍为 `c25019805b3b996e9d27c02afb88d7c7553988ec742f0bc694d054fe48ecaff9`，含 `ConfirmArchive`，不含 `BatchArchive`
- policy `schemaVersion` 仍是 JSON integer **4**；`codex-run-evidence` 仍 `minimumDescendantDepth=2`，denylist 含 `D:\Codex\.codex\run-evidence\safe-tree-delete`
- `BackupRetentionPolicy.ps1` 中 `run-evidence` 仍 `Manual = $true`；该文件无 git 改动
- 本票未触碰他人未提交的 `managed/safe-tree-delete/policy.json`

## 测试

| 测试 | 退出码 | 备注 |
| --- | --- | --- |
| `tests/Test-CodexSafeTreeDeleteControlPlane.ps1` | **0** | 155.249 s；含 good-a / bad / good-b 错误隔离 |
| 同上，在 module runner 内第二次 | **0** | 10 slices |
| `node .\scripts\Run-PowerShellTests.cjs --module host-safety` | **1** | 默认 fixture，未跑 ProductionSmoke |
| 失败点 | HashSafely | 他人未提交的 `CodexSafeTreeDeleteFileIdentity.cs`（+86）导致 exclusive hash-open 失败 |
| 补跑 MetricsEvidence / Restore / SchemaCompatibility / UserEnvironmentTransaction / ReportArtifactPublisher | 全部 **0** | |
| `git diff --check` | **0** | 本票无源码 diff |

module runner 在 HashSafely 之前已绿：主测试、Benchmark、ControlPlane、CrashSafety、FileSystem、Grace、HashCache。

未再跑（他人正在改）：`Test-CodexSafeTreeDeleteStatus.ps1`（+365）、IdentityV2、PlanIdentityV2。未跑 ProductionSmoke。

## 两轴复核（本代理，未再派子代理）

### 轴 1：AC / 合同

候选从本次生产 Status 推导；0 候选则停止；未终结记录仍在；未放宽三条判据；未新增 BatchArchive；policy 仍 v4；fixture 错误隔离仍绿。票面 1674→79 只能作为历史投影，已用 live 110 与 +1 新 residual 解释。

### 轴 2：对抗 / 失败模式

- 没有把 20260814 / #19 数字当候选集。
- 没有因为 `complete=false` 误判失败。
- 没有手改 evidence，也没有 invent BatchArchive。
- Status 结束后工作树出现他人 #23 观测补丁（`CodexSafeTreeDelete.ps1`）和 FileIdentity 改动。本票**没有**回退，也**没有**用新观测器重跑 Status 去制造新候选。若用改后的 Status 再推一次，allowlist residual 可能变成可观测，那是 #23 范围。
- HashSafely 红灯归因于他人 identity 改动，不是本票回归。

## 风险与未验证

- 未在他人观测补丁之后重跑生产 Status。本次数字绑定 2026-08-14T17:59Z、判据库 `e4afc6c2…`。
- 未验证 IdentityV2 / PlanIdentityV2 / Status 测试在他人 WIP 上的结果。
- 未跑 ProductionSmoke。
- 磁盘上 `terminal-archive.json` 计数为 2200，Status 的 `lifecycle=terminal` 为 2211。本票未解释该 11 条差，也未改 marker 认证。
- `complete` 仍为 false，属 #23 残差与既有未终结记录，不是本票验收项。
