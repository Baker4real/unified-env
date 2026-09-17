---
type: reference
title: retired-evidence-root 精确退役证据目录
tags: [设计, 安全删除, capability, retired-evidence-root]
intent: 定义 retired-evidence-root 的安全边界、状态机、一次性授权、身份绑定、撤销语义与失败闭锁；不改写现有四种用途
---

# retired-evidence-root

本文件是 `rootDeletionPurpose=retired-evidence-root` 的唯一真源。现役入口、控制面、Apply/Purge 事务以及 `none` / `rebuildable-build-output` / `empty-project-state` / `retired-project-root` 仍以 `docs/specs/2026-07-24-safe-tree-delete-capability.md` 为准。本用途不改变现有构建产物、空项目状态、退役项目根、Archive 和其他删除用途。

本用途解决的问题：用户已批准清理受管 `run-evidence` 下已完成使命的一级目录，但父条目 `minimumDescendantDepth=2` 且 `rootDeletionPurpose=none`，现有三种 root 删除用途都不能合法表达「已批准退役证据目录」。正确路线是增加本精确用途，而不是放宽整个 `run-evidence` 深度或旁路控制面。

## 安全边界

- 新用途只允许登记在受管 run-evidence capability 根 `D:\agents\run-evidence` 之下的明确一级目录。每个获批目录是**独立** capability 条目：`minimumDescendantDepth=0`、`rootDeletionPurpose=retired-evidence-root`，运行目标只允许精确 capability root。
- 解析器识别本用途时，`capabilityRoot` 必须是 run-evidence 父根下的明确一级目录。生产父根是 `D:\agents\run-evidence`；可复现 fixture 必须消费 `tests/New-CodexSafeTreeDeleteRetiredEvidenceRootFixture.ps1` 写出的 `run-evidence-analog` scratch analog。不得把 empty-project-state / retired-project-root 的生产形项目正则套到本用途。生产「只许登记在受管 run-evidence 之下」由生产 policy 与后续撤销票约束，不靠本用途写死唯一绝对父路径。
- 父条目 `codex-run-evidence` 保持 `minimumDescendantDepth=2`、`rootDeletionPurpose=none`，并继续精确拒绝 `D:\agents\run-evidence\safe-tree-delete`。不得把 run-evidence 的默认最小后代深度从 2 改为 1。
- 不得把下列路径登记为本用途：`run-evidence 根`、`safe-tree-delete evidence 根`、任一项目根、workspace 根、其他宽路径，或获批根的后代。同级未登记目录不因邻居获批而获得权限。
- 生产 CLI 仍不接受 policy/evidence override。本用途的 fixture 只存在于测试 scratch，不得把生产 `D:\agents\run-evidence\` 当 fixture。
- 删除仍只走受管 safe-tree-delete 控制面。Remove-Item、Directory.Delete、cmd rmdir 或其他旁路不是本用途的合法实现。

## 精确目标

- 许可只对登记的完整目录生效。Plan / Apply / Purge / Restore / Status 的运行目标必须精确等于该条目的 `capabilityRoot`，只允许精确 capability root，不授权其后代作为独立目标。
- 生产将登记两个已获批、已完成使命的一级 evidence 目录；**本文件不写出这两条生产路径**。路径以当时获授权的 live policy 登记为准，不得从历史报告或本文件猜测。
- 目标解析必须同时检查：capability root、精确目标、祖先保护规则、denylist、reparse point、named stream、file identity、目录 identity 和完整 tree manifest。任一失败则失败闭锁。

## 一次性授权

- 每条 `retired-evidence-root` 条目是绑定本次目录身份和本次删除事务的临时许可，不是该路径的永久授权。
- 完成或取消本次事务后许可不可继续用于同名重建目录。
- 新 Plan 不得消费已经 completed / cancelled / revoked 的许可。过期未 Apply 的 Plan 使该次 operation 失效；若 policy 条目仍在，也必须先按身份绑定复验，不能把过期 Plan 的身份换成重建后的新身份。

## 身份绑定

- Plan 记录授权用途对应的现役 `plan.json` 字段：`policyEntryId`、当时 `policyPath`/`policySha256`、目标目录与各 file 的 `fileIdentitiesV2`（128-bit `FILE_ID_INFO`；目标目录用 `relativePath=.`）、`treeManifest`（含 `rootIdentity` 与各 entry 的 `sha256`/`identity`）和 `generationId`（operation identity）。purpose 值仍从**当前 policy 的对应 entry**读取，不写入 plan。
- Apply / Purge / Restore / Status / crash recovery 必须复验同一套身份、哈希、树清单、事务和日志。身份或策略漂移时保持 manual-review 或失败闭锁。
- Apply 只接受精确 approved Plan（`ConfirmApply` 与 `ApprovedPlanSha256`）。对本用途必须从 `plan.fileIdentitiesV2` 独立读取 `relativePath=.`，经 `ConvertFrom-CodexSafeTreeDeleteFileIdentityV2Record` 解析目标目录 FileIdentityV2，并用 live 目标（`Get-CodexSafeTreeDeleteFileIdentityV2` 或 `ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath` 把 `.` 映回树根）复验；不得把 `.` 交给 `ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative`，也不得把 file-only reader / ApplyFileIdentityMap 当成目标目录复验。`.` 的 FileIdentityV2 与 `treeManifest.rootIdentity` 不一致则失败闭锁。成功 Apply 把目标原子改名到同父 quarantine，并写出可独立回读的 recoverable transaction；中断必须留下 `prepared` / `rolled-back` / `quarantined` 之一，不得进入不可审计的半完成态。
- Purge 只接受精确 approved transaction（`ConfirmPurge` 与 `ApprovedTransactionSha256`）。对本用途必须从 `plan.fileIdentitiesV2` 独立读取 `relativePath=.`，经 `ConvertFrom-CodexSafeTreeDeleteFileIdentityV2Record` 解析目标目录 FileIdentityV2，并用 live quarantine 根（`Get-CodexSafeTreeDeleteFileIdentityV2` 或 `ConvertTo-CodexSafeTreeDeleteLeafAbsolutePath` 把 `.` 映回 TreePath）复验；不得把 `.` 交给 `ConvertTo-CodexSafeTreeDeleteAbsolutePathFromRelative`，也不得把 file-only reader / ApplyFileIdentityMap 当成目标目录复验。`.` 的 FileIdentityV2 与 `treeManifest.rootIdentity` 不一致则失败闭锁。成功 Purge 必须先冻结并发布可回读 `commit-authorized` journal，再按原始 Plan 逐 leaf 删除 quarantine，范围不得超出计划；未登记同级、protected analog 与其他获批根必须仍在。中断仍走现役 `purging` 子集恢复，不得旁路删除。
- 本用途**不得**套用 `rebuildable-build-output` 的「purged 后同路径新 identity 视为预期重建」规则。同名目录重建后不能复用旧授权：新 `FileId128` 是新对象，旧事务已消费，旧条目即使残留也不得批准新 Plan。

## 撤销语义

- 成功 Purge、Restore、显式取消或事务以失败闭锁结束并停止重试之后，许可即消费完毕。
- 生产清理必须在同一受管维护流程中撤销临时 policy 条目，并验证生产 policy 恢复原始语义：`codex-run-evidence` 仍为深度 2 / `none`，且没有残留的 `retired-evidence-root` 条目。
- 删除证据保留在受管 `D:\agents\run-evidence\safe-tree-delete\` 中，不随目标目录消失。撤销的是许可，不是审计记录。
- 撤销后的重放（同一路径、新 identity、旧 Plan/transaction SHA）必须拒绝。

## 状态机

本用途叠加在现役 Plan → Apply → Purge 控制面上，不另开入口。grant 状态：

| grant 状态 | 观察 | 下一步 |
|---|---|---|
| ungranted | 无本用途 policy 条目 | 只在获授权维护流程中登记精确条目 |
| granted | 条目存在且尚未消费 | `Plan`（绑定当前身份与树清单） |
| planned | 受管 plan 仍有效 | `Apply`，或过期/取消 |
| applied | 目标已原子改名到同父 quarantine | `Purge` 或 `Restore` |
| consumed | `purged` / restored / cancelled | 撤销 policy 条目 |
| revoked | 生产 policy 不再含该条目 | 同路径新目录需要全新许可 |
| fail-closed / manual-review | 身份、树清单、policy SHA 或保护规则漂移 | 停止自动推进，不得旁路 |

Restore、Status 和 crash recovery 必须识别本用途。`purging` 中断恢复仍只允许当前树成为原计划的未变子集；其他路径仍要求完整清单。

## 失败闭锁

| Trigger condition | First repair | Still failing fallback |
|---|---|---|
| 未登记同级目标 | 核对 live policy 是否精确登记该 capability root | 拒绝 Plan；不得用父 `run-evidence` 深度或邻居条目放行 |
| 路径重建 | 比较当前目录 FileIdentityV2 与已消费 grant/plan 身份 | 视为新对象并拒绝旧授权；需要新许可 |
| run-evidence 根 | 确认条目 capabilityRoot 不是 `D:\agents\run-evidence` | 解析器失败闭锁 |
| safe-tree-delete evidence 根 | 确认未登记且仍在父 denylist | 解析器失败闭锁；父 denylist 继续生效 |
| 策略 SHA 漂移 | 停止 Apply/Purge/Restore，走 Status | `policyCompatible=false` 或 manual-review，不得按旧 SHA 执行 |
| reparse point | 按现役树清单规则拒绝未授权 reparse | 失败闭锁；本用途不启用内部 directory junction |
| named stream | 文件 named stream 在 Plan 失败闭锁 | 不得把 ADS 当普通 payload 删除 |
| denylist | 目标或其祖先命中 `deniedExactPaths` | 拒绝；父条目对 `D:\agents\run-evidence\safe-tree-delete` 的拒绝仍有效 |

硬门槛：异常 schema、未知路径、reparse point、identity/hash 不一致、覆盖不完整或回滚条件无法证明时失败闭锁，保留原始事实并报告阻断原因。

## Fixture seam

可复现 fixture 由 `tests/New-CodexSafeTreeDeleteRetiredEvidenceRootFixture.ps1` 在 gitignored `.scratch/safe-tree-delete-tests-*` 下合成，覆盖三类路径：

1. **获批目标**：合成一级目录，写入 grant policy，`rootDeletionPurpose=retired-evidence-root`，深度 0，目标等于 capability root。
2. **同级未登记目标**：与获批目标同父的一级目录，磁盘上存在，但不出现在 grant policy。
3. **重建路径**：对其中一个获批目录捕获 FileIdentityV2 后删除并按同路径重建，新 identity 与旧 identity 不同；manifest 同时保留两者。

Fixture 还提供：

- `parent-only-policy.json`：只含现有四种用途（父条目深度 2 / `none`），供证明一级目录默认被拒绝。
- `grant-policy.json`：含 `retired-evidence-root` 条目，供策略解析票消费；测试不得把生产 `D:\agents\run-evidence\` 当 fixture。
- `fixture-manifest.json`：记录路径、policy 路径和身份十六进制，供后续票复用同一 seam。

禁止把 fixture 写进生产 `D:\agents\run-evidence\` 或生产 `D:\agents\run-evidence\safe-tree-delete\`。

后续票（Plan 身份绑定、Apply/Purge、生产登记与撤销）必须消费本 seam，不得另起一套目标布局。策略解析票必须让 parser 接受本 seam 的 `grant-policy.json`。不改生产 policy，不 live Apply/Purge。
