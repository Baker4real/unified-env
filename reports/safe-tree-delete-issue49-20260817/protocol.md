---
type: snapshot
title: Issue #49 Status 冷/热启动测量协议
tags: [safe-tree-delete, issue-49, status, performance]
intent: 定义可证伪的生产 Status 冷启动与热启动测量合同，并量化成本段
---

# Issue #49 测量协议

本协议先于三次生产冷启动写成。它不是关票授权，不是 Purge/Restore leftover 授权，也不把 Apply/Purge `SessionHashCache` 算进 Status。

## 所有权边界（#26–#43 / #49）

| 工作 | Owner | Status 是否消费 |
| --- | --- | --- |
| Plan/Apply/Purge 性能、`SessionHashCache`、`GetHashSafely`、`leafStreamSetV1`、`ParallelPurgeCoordinator` | #26–#43 / #54 | **否。** Status 不得读取 Apply/Purge 会话缓存，也不得把那次哈希复用写成「Status 已优化」。 |
| 生产 Status 冷启动 SLA、terminal-archive 认证成本、Status 调用内只读复用 | #49 | 本票。 |
| BatchPurge / #52 关票 | 范围外 | 不改。 |

Status 调用内可以有**随进程死亡**的只读复用（例如同一 live 树在一次 Status 里被多条 planned 记录指向）。这不是 `SessionHashCache`，不落盘，冷启动换新进程即失效。

## 什么算冷启动

一次冷启动必须同时满足：

1. 新的 `D:\Codex\tools\PowerShell\7.6.4\pwsh.exe` 进程（`-NoProfile`）。
2. 只走 live 入口 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`。
3. 上一轮 Status 的 child PID 已退出；本轮不复用该进程。
4. 不存在 Status 自有的跨进程磁盘缓存。本次实现不写这类文件。
5. 不把同进程连跑三次当作三次冷启动。
6. 不使用 VSS，不调用 `EmptyStandbyList`。

**明确未失效的缓存：** Windows standby / 文件系统页缓存。协议不声称 OS 级 cold。因此 cold-1 通常比 cold-2/3 更接近磁盘。三次都必须各自 <60s；若只有后两次因 OS 缓存过线，记 `metTarget=false`。

热启动：另起一次新进程、在 OS 缓存已暖的情况下再跑 Status，只作对照，**不能**替代三次冷启动。

## 成本段

每次测量（生产 JSON + 包装器 meta）必须能量化：

| 段 | 含义 | 493s 基线里还在吗 |
| --- | --- | --- |
| `directoryEnumeration` | evidence root 目录枚举 | 还在，现场约 2ms / 2382 个 run，不是主因 |
| `planTransactionRead` | 句柄绑定读取 plan.json / transaction.json | 还在。2200 条已归档 managed 合计约 175MB，不再走 `ConvertTo-CodexHookExpectedDirectoryTreeManifest` |
| `terminalArchiveAuth` | marker 内容认证 + 与 plan/tx SHA/identity/generation/path/status 绑定 + 现场 namespace | 还在，**不跳过**。不再为已归档记录重走 directory journal / 整棵 treeManifest 物化 |
| `treeMaterialization` | 未归档记录的 live tree snapshot | 还在。现行合同要求 planned/recoverable/restored 复核 tree manifest。同一 Status 调用内按 path+capability+flags+root identity 复用，避免把同一个 `bin` 树哈希 6–8 次 |
| `sha256` | 上述读取的 SHA-256 | 还在。认证靠重算文件字节，不靠 marker 自报 |

#24（2026-08-16T14:23:31Z）墙钟 493.768s、`bytesHashed≈1.81GB` 的构成（本票 2026-08-17 复测，只读）：

- 已归档 run 的 plan+tx+marker ≈ **175MB**，不是 1.81GB。
- leftover `0ab1e1b6` quarantine = 1 文件 / 37 字节；directory journal = 4 文件 / 11KB。
- 1.81GB 主要来自**未归档** planned 记录对同一 live 树（尤其 `MinminCountdown\bin`，约 189MB × 多条）的重复物化，加上 2200 条归档路径上的 PowerShell 祖先 walk + `ConvertFrom-Json` 整棵 treeManifest。
- 当前 `Read-CodexSafeTreeDeleteTerminalArchive` 抽样 10 条平均 61.3ms，外推 2200 条 ≈ **135s**（未含未归档树）。

## 三次冷启动怎么跑

包装器：`invoke-status-cold.ps1`。每次：

1. 记录 launcher/child PID、pwsh 路径、wrapper SHA、开始/结束 UTC、墙钟秒、`$LASTEXITCODE`。
2. 把 stdout 收到 `cold-N.stdout.json`（再转 UTF-8 为 `cold-N.status.json` 如有需要）。
3. 从 Status JSON 抽出 `operations` 数、`entriesScanned`、`bytesHashed`、`elapsedMs`、`complete`、`blockingRecords` 数、leftover 与 #48 42 条是否仍在。
4. 若设置了 `CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS=1`，读取顶层 `statusSegments`（不进 `metrics` 固定属性集）。

三次之间只做：确认上一 child 已退出、换新 pwsh、写明「为何算冷」。不做 Purge/Archive/VSS。

## 零写入

Status 前后对比 evidence 根：

- run 目录数、文件数
- leftover transaction SHA-256，期望仍为 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`
- 禁止 Purge/Restore leftover，禁止 Archive 那 42 条 #48 purged+manual-review

## 2026-08-17 三次冷启动结果（优化前基线）

| 次 | 墙钟 s | elapsedMs | operations | entriesScanned | bytesHashed | leftover SHA |
| ---: | ---: | ---: | ---: | ---: | --- | --- |
| 1 | 189.179 | 187074 | 2383 | 3539 | 757262247 | `4e73aedc…339d7` 不变 |
| 2 | 184.361 | 182578 | 2383 | 3539 | 757262247 | 同上 |
| 3 | 181.586 | 179135 | 2383 | 3539 | 757262247 | 同上 |

当时 `metTarget=false`。未归档约 185 条对同一 `plan.json` 两次 `ConvertFrom-Json`。

## 2026-08-18 三次冷启动结果（#49 实现后）

入口与 pwsh 不变。OS standby **未**刷。本三联之前同会话已跑过 Status，因此三次都偏 OS-warm；仍是独立新进程。

| 次 | 墙钟 s | elapsedMs | operations | entriesScanned | bytesHashed | leftover SHA | zeroWrite |
| ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 1 | 142.286 | 139627 | 2482 | 3952 | 912539936 | `4e73aedc…339d7` 不变 | true |
| 2 | 141.992 | 139162 | 2482 | 3952 | 912539936 | 同上 | true |
| 3 | 145.850 | 142979 | 2482 | 3952 | 912539936 | 同上 | true |

`metTarget=false`。现场未归档 281 条（基线 185），operations 2482（基线 2383）。未归档改为一次读盘 + 一次 `ConvertFrom-Json` + 已加载 policy；归档 plan 顶层字段用 `Utf8JsonReader` Skip 掉 `treeManifest` DOM。#48 仍 42 条 purged+manual-review。详见 `CLOSEABLE.md`。

## 判定

- `metTarget=true`：三次独立冷启动墙钟均 <60s，认证与判定语义保持，零写入。
- `metTarget=false`：数字照实记录；说明哪一段仍贵、为什么不能再砍（认证合同或 HostSafety 树物化）。
