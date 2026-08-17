# Issue 47 证据索引（只读引用，2026-08-16）

本目录只新增对照文档。live 主证据仍在 #55 / #21 已有目录。不要重跑 wrapper。不要把 `revert-forwarding.json` 的 exit 0 写成非零通过。

## 本目录

| 文件 | 作用 |
| --- | --- |
| `CLOSEABLE.md` | #47 AC 对照与 GitHub 关闭条件（BLOCKED on #50） |
| `evidence-index.md` | 本文件：路径 → 证明什么 |

## Identity（入口 / wrapper / 源是否一致）

| 路径 | 打开后应看到 |
| --- | --- |
| `reports/safe-tree-delete-issue55-20260816/identity.json` | `wrappers.cmdEqual=true`，`wrappers.ps1Equal=true`。live `.cmd` / 仓库 `invoke-codex-safe-tree-delete.cmd` SHA 均为 `45aeadf7f758a1cafce106f66e7eaecc5f60176d2017630e2af461a2a37bca12`。live `.ps1` / 仓库 `invoke-codex-safe-tree-delete-host.ps1` SHA 均为 `636cb140720bf15681364459269c2d5dc4638e339f2589ad2a3a53b6e17b9373`。`generatedAtUtc=2026-08-16T13:37:01.9684638+00:00`。forbidden leftover 注明属 #45/#50，本票不得 Resume/Purge/Restore |

该文件没有比对 `managed/` 下其它副本。不要猜测额外 identity。

## 非零主证据（#52 关 #21 只能引这条）

| 路径 | 打开后应看到 |
| --- | --- |
| `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` | `exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，`productionJsonObtained=true`，`invokedVia` live `.cmd`，`lockAcquiredMarkerExists=true` |
| `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.meta.json` | `actualExitCode=1`，`expectedExitCode=1`，`remainingDescendantCount=0`，`lastExitCodeCheckedImmediately=true`，`startedAtUtc=2026-08-16T13:43:45.3120554+00:00` |
| `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.stdout.txt` | 生产 JSON：`purged=false`，`refusalReason=leaf-delete-failed`，metrics `failed-after-retry` / `sharing-violation` |
| `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.stderr.txt` | 空 |

spec（`docs/specs/2026-07-24-safe-tree-delete-capability.md`）：`leaf-delete-failed` 在发出该 JSON 后 `exit 1`。本条 `productionJsonObtained=true`，属于已证明的生产 Purge 失败观测。

## 不得当作非零主证据

| 路径 | 打开后应看到 | 用途 |
| --- | --- | --- |
| `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json` | **`exitCode=0`**，`wrapperSwallowedNonzero=true`，`refusalReason=leaf-delete-failed`，`purged=false`，`productionJsonObtained=true` | #21：撤转发后 wrapper 吞非零。#52 关 #21 **不能**把这条写成 wrapper 非零 |
| `reports/safe-tree-delete-issue55-20260816/issue21-fail-purge-revert-forwarding.stdout.txt` | 生产 JSON 仍是 `leaf-delete-failed` / `purged=false` | 证明吞掉的是真实失败 JSON，不是空输出 |
| `reports/safe-tree-delete-issue55-20260816/summary.json` | `ok=true`，`leafDeleteFailedObtained=true`，`revertForwardingProved=true` | 套件收口。`ok=true` **不能**替代 exit 1 |

## exit-zero refusal 未被破坏

| 路径 | 打开后应看到 |
| --- | --- |
| `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.meta.json` | `actualExitCode=0`，`expectedExitCode=0`，`remainingDescendantCount=0`，`invokedVia` live `.cmd`，`-Mode Archive -Json` |
| `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.stdout.txt` | `{"archived":false,"refusalReason":"confirm-archive-required"}` |
| `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.stderr.txt` | 空 |

缺少确认的结构化 refusal 仍是 exit 0。本跑没有把它改成非零。

## 成功 / 超时 / 失败进程树

| 路径 | 路径种类 | 打开后应看到 |
| --- | --- | --- |
| `reports/safe-tree-delete-issue55-20260816/success-purge.meta.json` | 成功 | `actualExitCode=0`，`remainingDescendantCount=0`，trackedPids `41612,37556` |
| `reports/safe-tree-delete-issue55-20260816/success-purge.stdout.txt` / `.stderr.txt` | 成功 | 配对 stdout/stderr |
| `reports/safe-tree-delete-issue55-20260816/timeout-contract.json` | 超时合同 | `wrapperHasTimeoutParameter=false`；超时是 harness 合同；`controlledDrill.evidence=timeout-drill.json` |
| `reports/safe-tree-delete-issue55-20260816/timeout-drill.json` | 超时收口 | `remainingDescendantCount=0`，`sawPwshChild=true`，`taskkillExit=0`，`treeAtKill` cmd 4452 → pwsh 39408（唯一带 commandLine 的树） |
| `reports/safe-tree-delete-issue55-20260816/timeout-status.stdout.txt` / `.stderr.txt` | 超时原始输出 | stderr 空 |
| `reports/safe-tree-delete-issue55-20260816/fail-purge-leaf-delete.meta.json` | 失败 | 见上；`remainingDescendantCount=0` |
| `reports/safe-tree-delete-issue55-20260816/invocations.json` | 全表 | 20 条调用，每条 `remainingDescendantCount=0` |
| `reports/safe-tree-delete-issue55-20260816/summary.json` | 汇总 | `invocationCount=20`，`wallClockSeconds=407.492`，`startedAtUtc=2026-08-16T13:37:01.5183122+00:00`，`generatedAtUtc=2026-08-16T13:43:49.0100671+00:00` |

成功/失败 meta 没有保存带 commandLine 的全程进程树。

## Status USN 零写入 + operationId 绑定

| 路径 | 打开后应看到 |
| --- | --- |
| `reports/safe-tree-delete-issue55-20260816/status-generation-binding.json` | `zeroWrite=true`，`policyZeroWrite=true`，`operationCount=2350`，`operationIdCount=2350`，`generationIdCount=0`，`bindingField=operations[].operationId`。evidence digest 前后 `094ffc0fd7a5b30064a978e398785fbdeeab85e822ce9c7fe50f4d515e9fe2f6`。policy digest 前后 `a5ae6c0147b2779b004f2992c3fc122d1c0df5488d270a43a391ef7b997524a5` |
| `reports/safe-tree-delete-issue55-20260816/status-pre-usn.json` | `ErrorCount=0`，FileCount 6879，DirectoryCount 2351，同上 digest |
| `reports/safe-tree-delete-issue55-20260816/status-post-usn.json` | 同上 digest；`evidenceChangedCount=0`，`policyChangedCount=0` |
| `reports/safe-tree-delete-issue55-20260816/status-zero-write.meta.json` | Status 调用 `actualExitCode=0`，`remainingDescendantCount=0`，墙钟 `340537.8` ms |
| `reports/safe-tree-delete-issue55-20260816/summary.json` | `statusZeroWrite=true`，`vssUsed=false`，`sla49Untouched=true` |

USN 窗口覆盖 Status 观测（约 13:37:02–13:42:44）。其后的 Plan/Apply/Purge 会写生产 evidence 根，不在这条「Status 零写入」证明范围内。

## leftover（明确排除）

| 路径 | 打开后应看到 |
| --- | --- |
| `identity.json` `forbiddenLeftover` | quarantine `reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 开始时存在；transaction SHA `4e73aedc…` |
| `summary.json` | `leftover0ab1e1b6Untouched=true`，`leftover0ab1e1b6StillPresent=true`，SHA 与开始时相同 |

不是本票清空对象。不要 Purge。

## 被 #50 挡住、因此不在本索引宣称「远端可读」的东西

下列路径目前只在本机工作树 / `reports/`，**不在**仓库默认分支的版本化位置：

- `reports/safe-tree-delete-issue55-20260816/`（smoke 产出、identity、stdout/stderr、USN、leaf-delete-failed）
- `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json`（#21 负向；仍须随 #50 包审查是否纳入）
- 本目录 `CLOSEABLE.md` / `evidence-index.md`

#50 AC 要求：旧 issue 评论将引用的证据在默认分支上可直接读取，且引用不依赖本机绝对路径。本波禁止 commit，故 #47 最后一条 closure-grade 远端位置 AC 未满足。

## 不要当真相源

| 路径 | 原因 |
| --- | --- |
| `reports/safe-tree-delete-issue55-20260816/CLOSEABLE.md` | 墙钟写成 `382.981`、operation 写成 2341；当前 JSON 是 `407.492` / 2350 |
| fixture / mock / 仅 suite exit 0 | #47 AC 明文排除 |
| `revert-forwarding.json` 的 exit 0 | 不是 wrapper 非零 |
