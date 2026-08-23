---
type: snapshot
title: Issue #49 Status 冷启动测量协议（2026-08-23 第二轮）
tags: [safe-tree-delete, issue-49, status, performance]
intent: 复用 2026-08-17 协议合同，记录 C# StatusScanCoordinator 落地后的三次独立冷启动
---

# Issue #49 测量协议（20260823 轮）

本协议复用并从属于 `reports/safe-tree-delete-issue49-20260817/protocol.md` 的全部合同（冷启动定义、成本段、零写入、判定）。本文件只记录本轮的差异与结果，冲突时以 20260817 协议为准。

## 与 20260817 协议的差异

1. 本轮测量现场规模已增长：operations 2946（8-18 时 2482）、未归档 746、归档 2200、plan.json 共 217MB 且 2945/2946 个 SHA 唯一（按 plan SHA 的调用内缓存已无效）。
2. 本轮实现为 C# 并行 Status fast scan（`scripts/lib/CodexSafeTreeDeleteStatusScan.cs`，纯 C# 线程，POCO 出入，不跨线程传 PSCustomObject；DOP = `Get-CodexSafeTreeDeleteStatusJsonParseThrottleLimit` = min(4, cores-2)）。fast scan 只处理可完整证明结果的记录；其余回退原 PowerShell Resolve（kill switch：`CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0`）。
3. 本轮 baseline（2026-08-23，优化前复跑）为冷启动墙钟 **199.357s**（cold-0.json），分段：activeResolve 76041ms / archivedResolve 103336ms / prefetch 14841ms / planTransactionRead 39429ms / terminalArchiveAuth 19693ms / treeMaterialization 0ms。
4. 观测边界不变：fast scan 为 Status 调用内、随进程死亡的只读复用；不消费 Apply/Purge `SessionHashCache`，不落盘任何哈希缓存。fast scan 的 C# 程序集按 CodexHostSafety 同款 staleness 检查缓存在 `D:\Codex\temp\unified-env-addtype\CodexSafeTreeDeleteStatusScan.dll`（既有模式的新增缓存文件，不在 evidence root，不触碰零写入合同的对象）。

## 什么算冷启动

与 20260817 协议一致：新 pwsh 进程（本 live wrapper 内部实际调用 `D:\Codex\tools\PowerShell\7.6.5\pwsh.exe`，wrapper 内容见 cold-N.json 的 wrapperSha256）、只走 live 入口 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`、上一 child 已退出、无 Status 自有跨进程磁盘缓存、不刷 OS standby、不用 VSS。

## 等价性验证（测量前置）

在三次冷启动前，以同进程函数调用分别跑 fast（默认）与 slow（`CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0`）各一次，对全部 operations 逐条 `ConvertTo-Json -Depth 8 -Compress` 对比：

- 首轮（2946-op 时点，`equivalence-fast.json` / `equivalence-slow.json`）：operation mismatch = 0；`complete`、`policySha256`、`migrationReadiness.blockingRecords` 完全一致；`entriesScanned` 一致；`metrics.logicalBytes` 均为 0（当时无树物化）。`metrics.bytesHashed` fast 比 slow **少 1560 字节**：slow 参考路径对非 UTF-8 plan 自身双计（prefetch 在 UTF-8 解码前先计 bytesHashed，解码抛错后跳过缓存，Resolve 重读再计一次），fast 每文件只计一次——差值来自 slow 的重复计数，非 fast 少读。
- **MED 修复后复跑**（2960-op 时点，`equivalence-fast-after-med-fix.json` / `equivalence-slow-after-med-fix.json`，2026-08-23 对抗复核修复后）：operation mismatch = 0，blockingRecords 一致，且 `bytesHashed`（421725493）与 `logicalBytes`（187788899）**完全相等**。

**等价性边界（对抗复核后收紧）**：fast path 只对 producer 规范形态输入给出最终结果——plan/transaction/treeManifest 的属性名必须与 canonical 键逐字节（ordinal）一致、必需属性齐全、schemaVersion 在 Int32 范围内；否则一律回退 PowerShell 参考路径（复核 MED-1a 缺失必需属性时 StrictMode PropertyNotFoundException 文本、MED-1b 属性名大小写变体（PS 属性检查大小写不敏感）、MED-2 schemaVersion 超出 Int32 时 PS cast 错误消息——三类输入均已由 `tests/Test-CodexSafeTreeDeleteStatus.ps1` 的 MED 回归 slices 钉住 fast==slow 逐字节一致）。

## 零写入

同 20260817 协议：Status 前后对比 evidence root 的 run 目录数、文件数与 leftover transaction SHA-256（期望 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`）。禁止 Purge/Restore leftover，禁止 Archive 42 条 #48 purged+manual-review（本轮现场该计数已自然增长为 664，属 #48 观测合同的正常演化，非本票伪造）。

## 判定

- `metTarget=true`：三次独立冷启动墙钟均 <60s，认证与判定语义保持（等价性验证通过），零写入。
- `metTarget=false`：数字照实记录并说明剩余成本段。

## 2026-08-23 三次冷启动结果

**正式 AC 三联为「MED 修复后三联」**：`cold-5/6/7.json`，汇总 `cold-summary-post-fix.json`（`kind=post-med-fix-official-triple`，采于含 MED-1a/1b/2 回退修复的代码状态；runner `Measure-Issue49ColdStartsPostFix.ps1`）。墙钟 **9.762 / 9.791 / 9.237 s**，`metTarget=true`，`allZeroWrite=true`，`leftoverShaStable=true`。

历史样本（保留可追溯，非正式 AC 判据）：`cold-1/2/3.json`（`cold-summary.json`）为 MED 修复前代码状态的 13.279 / 13.378 / 13.256 s 三联；`cold-4.json` 为修复后单次确认样本（9.308 s）。两组三联均满足 <60s；正式判定采用修复后状态。

## stdout 捕获编码（证据卫生修复，T2）

cold-0 至 cold-7 轮次的 `cold-N.stdout.json` 由 `Start-Process -RedirectStandardOutput` 捕获，child pwsh 以共享控制台的 OEM 代码页（936）编码重定向 stdout，因此这 8 个原文件是合法 GBK、非合法 UTF-8。处置：

- **原文件保留不改**；每份生成 UTF-8 规范化副本 `cold-N.stdout.utf8.json`（GBK 严格解码 → UTF-8 无 BOM 重写，逐份通过 strict UTF-8 与 `ConvertFrom-Json` 验证）。后续消费以 `.stdout.utf8.json` 为准。
- `invoke-status-cold.ps1` 已修复后续捕获：启动前把共享控制台输出代码页切到 65001（结束后还原），捕获文件再经 strict UTF-8 校验，仅在仍非 UTF-8 时从 936 兜底转码并记录 `stdoutStrictUtf8=false` / `stdoutTranscodedFrom=936`（cold-N.json payload 新增这两个字段）。

### T2 确认冷启动（cold-8，2026-08-23 17:42 本地）

`cold-8.json` 为 T2 残留修复（L1/L3 回退、L6 SHA 绑定缓存、L5 捕获编码）后的单次确认运行：exit 0，`stdoutStrictUtf8=true`（原生 UTF-8 捕获、无转码，strict UTF-8 + JSON 解析独立复核通过），leftover SHA 不变，`metTarget=true`。墙钟 **34.745s**：高于 cold-5/6/7 的 ~9.7s，归因于现场增长而非 T2 改动——operations 2960→3082，期间 host hook 新建 ~122 条 planned 记录（fast scan 对 approved plan 一律回退 PS 参考路径，`plan-approved` 回退 16→139，activeResolveMs 5.4s→29.9s）；对 live 3087 run 的直接 fallback tally 中 `ancestor-attribute-query-failed` / `namespace-entry-type-other` 均为 0（T2 新增回退在当前现场零触发）。#49 AC（<60s）仍满足。
