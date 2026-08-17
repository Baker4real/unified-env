# Issue 55 实现关口可关闭（2026-08-16 live smoke）

本文件只解释本证据目录的 live 结果。不是 GitHub 关单授权，也不是对 leftover `0ab1e1b6` 或生产实现的处置授权。

## 本次运行

- 套件：`tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`
- 入口：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe`（Core 7.6.4）
- 退出码：0
- 墙钟：`summary.json` `wallClockSeconds=382.981`（外层 stopwatch 383.385s）
- live wrapper：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`（cmd/ps1 SHA 与仓库源一致，见 `identity.json`）

## Acceptance criteria 对照

| AC | 结论 | live 证据 |
| --- | --- | --- |
| 重新核验 wrapper/source/identity 与进程树；记录 provenance、墙钟、stdout/stderr、timeout、预期退出码 | 满足（成功/失败路径的树是启动后 400ms 内采样到的 PID，不是全程 commandLine 快照） | `identity.json`；`invocations.json`（16 次）；各 `*.meta.json` 含 invokedVia/arguments/wallClockMs/timeoutMs/expectedExitCode/stdout/stderr。成功例：`status-zero-write.meta.json` trackedPids=`31636,42336` remaining=0。失败例：`fail-purge-leaf-delete.meta.json` remaining=0。带 commandLine 的完整树只在超时 drill：`timeout-drill.json` `treeAtKill` |
| 成功、超时、失败路径进程树收口；非预期超时使 smoke 失败并保留原始证据 | 满足（超时是 **harness 合同**） | 成功 remaining=0。失败 `leaf-delete-failed.json` remainingDescendantCount=0。受控超时：`timeout-drill.json` remainingDescendantCount=0、sawPwshChild=true、`taskkill /F /T`。非预期超时：`Invoke-LiveSafeDeleteTracked` 从不传 `-AllowTimeout`，超时会在已写 stdout/stderr/meta 之后 throw。**本跑 exit 0，因此没有一条 tracked 调用真的走进非预期超时失败**；该失败路径由代码合同 + `timeout-contract.json` 声明，不是本跑的负向 live 击中。**未**给 wrapper 加 timeout 参数：`timeout-contract.json` `wrapperHasTimeoutParameter=false` |
| 真实到达 leaf-delete-failed：结构化 refusal、`purged=false`、非零退出码 | 满足 | `leaf-delete-failed.json`：`productionJsonObtained=true`，`refusalReason=leaf-delete-failed`，`purged=false`，`exitCode=1`，`lockAcquiredMarkerExists=true`，锁策略为 Apply 成功且 transaction 进入 `purging` 后再 `FileShare.Read`。本票 inflight quarantine 已被 resume Purge 清掉（`summary.json` `newInflightQuarantine=null`，该 quarantine 目录已不存在） |
| Status 只读零写入，且有代际绑定 | 满足 | `status-generation-binding.json`：`zeroWrite=true`，policy `policyZeroWrite=true`，`stdoutSha256` 与 pre/post USN digest 成对且相同。`status-pre-usn.json` / `status-post-usn.json` 本次 `ErrorCount=0`。绑定字段是 Status 合同的 `operations[].operationId`：`operationIdCount=2341` 且等于 `operationCount=2341`。`generationIdCount=0` 只观测「Status operations 无 generationId 字段」，不是绑定成功。pre/post 证据是 USN digest + 计数，不是逐文件 tree manifest 表 |
| 不使用 VSS；不改 #49 冷/热缓存与三次冷启动口径 | 满足（套件范围） | `summary.json` `vssUsed=false`、`sla49Untouched=true` 表示本套件未调用 VSS、未跑 #49 协议，不是整机 VSS 普查 |
| 失败时保留原始证据并停止后续关闭动作；不修改生产实现、不弱化合法 exit-zero refusal | 满足 | 本票未改 `CodexSafeTreeDelete.ps1`、`Invoke-CodexSafeTreeDelete.ps1`、live wrappers、`policy.json`。缺确认 Archive 仍为 exit 0 + `confirm-archive-required` |

## 超时合同（harness，不是 wrapper）

`timeout-contract.json` 证明：

- 生产 CLI 入口 `Invoke-CodexSafeTreeDelete.ps1` 参数表无 Timeout（Mode/TargetPath/…/Json）
- live `.ps1` 无 param block，只转发 `@args` 与 `$LASTEXITCODE`
- 非预期超时使 smoke 失败，并保留该次调用的 stdout/stderr/meta（代码在 throw 前已 `Write-Issue55Json` meta）
- 受控 drill 用 `taskkill /F /T` 在约 250ms 后杀掉仍在跑的 Status，证明进程树收口（`timeout-drill.json` remainingDescendantCount=0）

不要据此给 live wrapper 或生产实现加 timeout。`timeout-contract.json` 的 AST 扫的是 wrapper/CLI 入口，不是 `CodexSafeTreeDelete.ps1` 函数体；对该 lib 的 Timeout 参数检索在本关口为 0 命中。

## leftover

`0ab1e1b6` 属 #45/#50 清空集。本次前后 quarantine 仍在、transaction SHA-256 不变：

`4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`

本票未对其 Purge/Restore/Resume。

## 未在本文件关闭的事项

- GitHub #55 仍 OPEN；本目录不构成 comment/close/edit 授权。
- Status `complete=false` 是现场 operations 聚合事实，不是本票缺陷。
- `generationId` 仍不是 Status operations 合同字段；不要回填假装读到。
- 成功/失败 meta 未保存带 commandLine 的全程进程树；非预期超时失败未在本跑 live 击中（与 exit 0 互斥）。
