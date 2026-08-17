# Issue 44 实现关口可关闭（2026-08-17 测试验收）

本文件只解释本证据目录与本次 `Test-CodexSerenaBehaviorHooks.ps1` 结果。不是 GitHub 关单授权，也不是提交授权。本关口**未 commit / push / comment / close / edit**。

实现（guard 互斥、测试竞争场景、两份 manifest pin）已在工作树；本关口只跑测试、核验 pin，并在所有权报告目录留下证据。未改 `managed/safe-tree-delete/policy.json`、`scripts/lib/CodexSafeTreeDelete.ps1`、`modules/manifest.json`、`managed/grok-hooks/`、ProductionSmoke。

## 本次运行

- 套件：`tests/Test-CodexSerenaBehaviorHooks.ps1`
- 入口：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe -NoProfile -NonInteractive -File D:\Codex\projects\统一环境\tests\Test-CodexSerenaBehaviorHooks.ps1`
- 运行时：PowerShell Core 7.6.4
- 退出码：0
- 墙钟：`Test-CodexSerenaBehaviorHooks.meta.json` `durationMs=32310`
- stdout：`Codex Serena behavior hook tests passed.`
- stderr：空
- 本关口未改 guard / 两份 manifest / 测试文件；相对进入本关口时的工作树，只新增本目录

## Pin 核验

当前 `managed/codex-hooks/hooks/serena-behavior-guard.ps1` SHA-256：

`85d78b8533a47f8a9f3419e1bc4db33e3351522d7e8c1fe1aa861c0399f4ea3a`

与下列 pin 字节一致（十六进制大小写不敏感）：

- `managed/codex-hooks/manifest.json` `hooks/serena-behavior-guard.ps1` `sha256`
- `managed/codex-hooks/host-preflight-manifest.json` `hooks/serena-behavior-guard.ps1` `sha256`

## Acceptance criteria 对照

对照 GitHub #44 的 User Stories、Implementation Decisions 与票面关口要求。#46 / #51 专属超时回归若已写在同一测试文件中则随套件跑过，本关口未再扩写。

| AC | 结论 | 证据 |
| --- | --- | --- |
| 同一 Serena session 的 hook 状态访问被命名互斥串行化 | 满足 | guard `Get-CodexSerenaSessionMutexName` / `Invoke-CodexSerenaSessionMutex`；测试用真实子进程持锁，同 session Reminder 让路、Cleanup 等待后删除 |
| Reminder（PreToolUse）竞争 250ms 后静默 fail-open：空 stdout、exit 0、不碰共享状态 | 满足 | 核心：竞争超时 250ms；测试断言 `< 3500ms`、`ok/exitCode=0`、空 stdout、不创建 session 目录、不写 `serena-reminder.json` |
| Cleanup（Stop）6000ms 有界等待 in-flight Reminder，仍在宿主 10s 预算内 | 满足 | 核心：Cleanup 超时 6000ms；持锁 5s 后 Cleanup 成功删除，耗时 `< 9500ms` |
| 锁名对 home / session id 大小写与路径分隔符等价，且为 `Local\` | 满足 | 名称形如 `Local\CodexSerenaSession-` + SHA-256；大小写、`/` vs `\`、尾部分隔符与固定向量 `E783D259…C877` 断言通过 |
| abandoned mutex 视为取得锁，并继续既有路径与计数器身份校验 | 满足 | `AbandonedMutexException` → `$held = $true`；测试杀持锁进程后 Reminder 成功并写出 `tool_use_counter.pkl` |
| 锁作用域为本机当前 Windows 会话（`Local\`，非 `Global\`） | 满足 | `Get-CodexSerenaSessionMutexName` 固定 `Local\` 前缀 |
| Cleanup 等到锁后删除当前 session 状态 | 满足 | 5s 持锁用例删除目标目录；超时让路后重试同样删除 |
| 互斥在成功 / catch / finally 三条路径确定性释放 | 满足 | 三条路径均调用 `Release-CodexSerenaBehaviorState`；finally 在仍持有 lease/守卫/mutex 时再释放 |
| 释放顺序固定为计数器 lease → session 守卫 → 命名互斥 | 满足 | `Release-CodexSerenaBehaviorState` 按该顺序 best-effort 释放 |
| 健康上报在临界区之外，不延长持锁 | 满足 | 成功与失败路径均先 `Release-…` 再 `Write-CodexHookLatestHealthCore` |
| 释放 best-effort，不产生第二条异常路径 | 满足 | 释放体内 `try/catch {}`；健康写失败被吞掉，不翻转已有返回形态 |
| 两份 manifest / preflight 的脚本 SHA-256 pin 与当前 guard 字节一致 | 满足 | 见上一节 |
| Activation 不拿这把锁、不改变无关路径 | 满足 | `Invoke-CodexSerenaBehaviorGuardCore` 在 `Behavior -ceq 'Activation'` 分支直接拼 SessionStart JSON，不调用 mutex |
| 锁竞争有真实子进程 fixture 回归 | 满足 | Reminder 竞争、Cleanup 等待、Cleanup 超时让路、abandoned、并发 Cleanup 均用独立 pwsh 持锁或跑 guard 核心 |
| 既有 Serena behavior hook 测试保持通过 | 满足 | 全文件套件退出码 0，含 vendor remind/cleanup、fail-close 与既有守卫竞态 |
| 不新增 CLI / 环境变量 / vendor 协议字段 | 满足 | 对外仍是既有 Mode 与 hook 输入输出；测试用的 `CODEX_TEST_SERENA_*` 仅 fixture holder 注入，不是生产契约 |
| 拿不到锁时返回 `ok=true, exitCode=0, stdout 空`，且位于共享状态初始化之前 | 满足 | mutex 为 null 时直接返回该形态；Reminder 不写 health；Cleanup 超时另写可区分 health（同文件已有断言，属 #46 观察面，本关口未新写） |

## 两轴审查（相对 HEAD 工作树 diff）

对照点是 `HEAD` 工作树，不是一次独立 commit。本关口未再改那 4 个实现文件。

### Standards

无硬违规。互斥集中在 guard 内既有 core 函数；测试沿用 dot-source + fixture home/vendor/runtime seam；竞争方是真实子进程。判断项：Cleanup 超时健康记录与 Reminder 完全静默不对称（票面允许 Cleanup 有界等待，健康可观测性已在同文件测试里钉死）。`git diff --check` 对所有权文件退出码 0；测试文件有既有 CRLF→LF 提示，不是 `--check` 失败。

### Spec

#44 的 session 级 `Local\` 命名互斥、Reminder 250ms fail-open、Cleanup 6000ms 有界等待、大小写等价锁名、abandoned 恢复、lease→守卫→mutex 释放、Activation 不持锁、pin 同步，均能在源码与本次绿测中对上。本关口按票面**不提交**；#46 / #51 仍 OPEN，其专属超时回归未在本关口扩写。

## 未在本文件关闭的事项

- GitHub #44 仍 OPEN；本目录不构成 comment / close / edit 授权
- 工作树实现与测试**未 commit**（票面剩余提交工作本关口不做）
- 子票 #46 / #51 未在本关口单独实现或关单
- 未跑 ProductionSmoke，也未改 safe-delete 生产实现
