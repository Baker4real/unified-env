# Issue 47 实现关口可关闭对照（2026-08-16）

本文件只对照 GitHub #47 的 Acceptance criteria，引用已经存在的 live 证据。不是 GitHub comment/close/edit 授权，不是 leftover `0ab1e1b6` 的清空授权，也不是 commit / push 授权。本关口未跑 live wrapper、未 Purge leftover、未改测试或生产实现。

**实现关口（本地证据）：可关。**  
**GitHub 关闭条件：BLOCKED on #50 publish。** 未满足的 AC 是「closure-grade 证据进入远端默认可读的版本化位置」；#50 禁止本波 commit。

计数、哈希、退出码一律以下列 JSON 原文为准，不要用 `reports/safe-tree-delete-issue55-20260816/CLOSEABLE.md` 的墙钟或 operation 计数（该 Markdown 与当前 JSON 不一致）。

## 判定

| 项 | 结论 |
| --- | --- |
| 入口 / wrapper / 仓库源 identity | **一致**（`cmdEqual=true`，`ps1Equal=true`） |
| 非零主证据（#52 关 #21 时只能引这条） | `leaf-delete-failed.json` **`exitCode=1`**，经 live `.cmd`，`productionJsonObtained=true` |
| `revert-forwarding.json` | **`exitCode=0`**（wrapper 吞掉非零）。证明转发缺失会红，**不是** #47/#52 的非零主证据 |
| suite exit 0 | 只证明 ProductionSmoke 收口，**不能**替代 leaf-delete-failed 非零 |
| leftover `0ab1e1b6` | 仍在；SHA 未变；**不是本票清空对象** |

## #47 Acceptance criteria

| AC | 本地实现关口 | GitHub 关票 | 证据 |
| --- | --- | --- | --- |
| 重新核验运行入口、wrapper、受管 source 与当前生产部署 identity 一致 | **满足** | 引用须等 #50 把本包放到默认分支 | `identity.json`：live `.cmd` SHA `45aeadf7…` = 仓库 `scripts/invoke-codex-safe-tree-delete.cmd`；live `.ps1` SHA `636cb140…` = 仓库 `scripts/invoke-codex-safe-tree-delete-host.ps1`。`cmdEqual=true`，`ps1Equal=true`。运行时 Core 7.6.4，`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`。identity 文件**没有**再比对 `managed/` 其它副本；本关口只报告该文件实际写出的四条路径。 |
| #55 完整进程树在成功、超时、失败路径确定性收口，并记录时点、墙钟、provenance、stdout/stderr、timeout、预期退出码 | **满足（有边界，见下）** | 同上 | 成功：`success-purge.meta.json` `actualExitCode=0`，`remainingDescendantCount=0`，trackedPids `41612,37556`。失败：`fail-purge-leaf-delete.meta.json` `actualExitCode=1`，`remainingDescendantCount=0`，trackedPids `1912,41224`。超时：`timeout-drill.json` `remainingDescendantCount=0`，`sawPwshChild=true`，`taskkillExit=0`，`treeAtKill` 含 cmd→pwsh commandLine。`invocations.json` 全部 20 条 `remainingDescendantCount=0`。`summary.json` `invocationCount=20`，`wallClockSeconds=407.492`。 |
| 经完整受管 wrapper 链真实到达 leaf 删除失败：非零退出码、`purged=false`、稳定 `leaf-delete-failed`；fixture / mock / 仅 suite exit 0 不算 | **满足** | 同上 | **主证据** `leaf-delete-failed.json`：`invokedVia=D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`，`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，`productionJsonObtained=true`，`lockAcquiredMarkerExists=true`。stdout 原文见 `fail-purge-leaf-delete.stdout.txt`（生产 JSON，含 metrics retry `sharing-violation` / `failed-after-retry`）。stderr 空。符合 spec：发出该 JSON 后 `exit 1`，不是抛错未打 JSON 的路径。 |
| 既有合法 exit-zero refusal 保持不变，不为本票统一改成非零 | **满足** | 同上 | `archive-unconfirmed.meta.json` `actualExitCode=0`（`expectedExitCode=0`）。stdout：`{"archived":false,"refusalReason":"confirm-archive-required"}`。stderr 空。 |
| Status pre/post manifest 与 USN 代际证据证明只读观测零写入；不用 VSS；冷/热性能仍由 #49 负责 | **满足** | 同上 | `status-generation-binding.json`：`zeroWrite=true`，`policyZeroWrite=true`，evidence digest 前后均为 `094ffc0f…`，policy digest 前后均为 `a5ae6c01…`。绑定字段是 `operations[].operationId`（`operationCount=2350` = `operationIdCount=2350`）。`generationIdCount=0` 只观测 Status operations **没有** `generationId` 字段，不是绑定成功。`summary.json` `vssUsed=false`，`sla49Untouched=true`（套件未跑 #49，不是整机 VSS 普查）。 |
| closure-grade 证据在任何旧 issue 关闭前进入远端可读取的版本化位置 | **未满足** | **BLOCKED on #50** | 证据仍在本机 `reports/safe-tree-delete-issue55-20260816/` 与本目录。#47 `blocked-by: #50`。#50 要求默认分支可直接读取、引用不依赖本机绝对路径；本波禁止 commit，故本条不能在本关口勾掉。 |
| 若真实链路仍不能满足合同，保留失败证据并停止后续关闭；不以改 smoke/fixture 伪造通过 | **不适用（链路已满足合同）** | 不得用本条提前关 GitHub | 真实 wrapper 已打出 `leaf-delete-failed` + exit 1。本关口未改测试、未改生产、未重跑 smoke。未伪造通过。 |

## 非零主证据 vs 不得当作非零的证据

#52 规定：关 #21 的评论**只能**引用 **#47** 的真实 wrapper 非零退出码证据，不能引用 fixture 或仅 suite exit 0。

| 文件 | exitCode | 能否作为 #52 关 #21 的非零主证据 |
| --- | --- | --- |
| `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` | **1** | **能。这是唯一主证据。** 配对 meta/stdout：`fail-purge-leaf-delete.meta.json` / `fail-purge-leaf-delete.stdout.txt` |
| `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json` | **0** | **不能。** `wrapperSwallowedNonzero=true`。JSON 仍是 `leaf-delete-failed` / `purged=false`，但 wrapper 把非零吞成 0。这是 #21 的负向切片，不是 #47 的非零证明 |
| `summary.json` `ok=true` / 套件 exit 0 | 0 | **不能。** 只证明 smoke 套件收口 |

## 进程树收口路径（成功 / 超时 / 失败）

成功与失败 meta 记录的是 tracked PID 与结束后 `remainingDescendantCount=0`，不是带 commandLine 的全程树。带 commandLine 的树只在超时 drill。

| 路径 | 证据 | 收口事实 |
| --- | --- | --- |
| 成功 Purge | `success-purge.meta.json`（stdout/stderr 同 stem） | `actualExitCode=0`，`remainingDescendantCount=0`，`wallClockMs=1829.3`，`invokedVia` live `.cmd` |
| 超时（harness 合同，不是 wrapper 参数） | `timeout-contract.json`，`timeout-drill.json`，`timeout-status.stdout.txt` / `.stderr.txt` | `wrapperHasTimeoutParameter=false`。drill：`timeoutMs=250`，`taskkill /F /T`，`remainingDescendantCount=0`，`actualExitCode=1`（被杀），`treeAtKill` = cmd 4452 → pwsh 39408 |
| 失败 leaf-delete-failed | `fail-purge-leaf-delete.meta.json` + `leaf-delete-failed.json` | `actualExitCode=1`，`remainingDescendantCount=0`，`lastExitCodeCheckedImmediately=true` |

未在本跑 live 击中的边界：非预期超时使 smoke 失败（`timeout-contract.json` `unexpectedTimeoutFailsSmoke=true`）。本跑 `summary.json` `ok=true`，因此没有一条 tracked 调用走进该负向超时失败；由 harness 合同声明，不是本跑负向 live 击中。

## leftover

`0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e` 属 #45/#50 清空集，不是本票对象。`identity.json` 与 `summary.json`：quarantine 仍在，transaction SHA-256 前后均为

`4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`

本关口未对其 Purge / Restore / Resume。

## 未解决问题

- GitHub #47 仍 OPEN；本目录不构成 comment / close / edit。
- **被 #50 挡住的 AC：closure-grade 证据进入远端默认可读的版本化位置。** 在 #50 把将引用的证据提交到默认分支并独立回读之前，不得关 #47，也不得进入 #52 关 #20/#21。
- leftover `0ab1e1b6` 与缺 `leafStreamSetV1` 的在途事务仍属 #45/#50。
- Status `complete=false` 是现场 operations 聚合事实，不是本票缺陷；日常性能属 #49。
- `generationId` 不是 Status operations 合同字段；绑定用 `operationId`。
