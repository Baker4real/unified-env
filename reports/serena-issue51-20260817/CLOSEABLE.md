# Issue 51 实现关口可关闭（2026-08-17 Cleanup 验收）

本文件只解释本证据目录与本次 `Test-CodexSerenaBehaviorHooks.ps1` 结果。不是 GitHub 关单授权，也不是提交授权。本关口**未 commit / push / comment / close / edit**。

#46 已把同 session 命名互斥与 Reminder 250ms fail-open 落到工作树。本关口只对照 #51 AC 核验工作树里已有的两条 Cleanup 切片是否足够，并补上超时路径「不改写 session 文件」的直接观察。未改 guard、两份 manifest pin、`managed/safe-tree-delete/policy.json`、`scripts/lib/CodexSafeTreeDelete.ps1`、`modules/manifest.json`、`managed/grok-hooks/`、ProductionSmoke、`reports/serena-issue44-20260817/`、`reports/serena-issue46-20260817/`。

## 本次运行

- 套件：`tests/Test-CodexSerenaBehaviorHooks.ps1`
- 入口：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe -NoProfile -NonInteractive -File D:\Codex\projects\统一环境\tests\Test-CodexSerenaBehaviorHooks.ps1`
- 运行时：PowerShell Core 7.6.4
- 退出码：0
- 墙钟：`Test-CodexSerenaBehaviorHooks.meta.json` `durationMs=27200`
- stdout：`Codex Serena behavior hook tests passed.`（前有既有 `True` 行，与 #44/#46 捕获一致）
- stderr：空（未落盘）
- 本关口未改 guard / 两份 manifest；相对进入本关口时的工作树，只收紧超时切片的 session 指纹断言，并新增本目录

## Pin 核验

当前 `managed/codex-hooks/hooks/serena-behavior-guard.ps1` SHA-256：

`85d78b8533a47f8a9f3419e1bc4db33e3351522d7e8c1fe1aa861c0399f4ea3a`

与下列 pin 字节一致（十六进制大小写不敏感）：

- `managed/codex-hooks/manifest.json` `hooks/serena-behavior-guard.ps1` `sha256`
- `managed/codex-hooks/host-preflight-manifest.json` `hooks/serena-behavior-guard.ps1` `sha256`

本关口未改 guard，因此未重算 pin。

## 既有切片是否足够

工作树进入本关口时已有两条 Cleanup 行为切片，本关口没有另造第三种竞争场景：

1. 真实子进程持锁 5s 后释放：Cleanup 成功删除 session，`< 9500ms`（`tests/Test-CodexSerenaBehaviorHooks.ps1` 约 289-320）
2. 真实子进程持锁 8s：墙钟 `-ge 6000` 且 `< 9500ms`，fail-open 空输出，不删除 session，健康记录 `skipped: session mutex contention`；holder 退出后重试能删除（约 323-369）

对照 #51 七条 AC：这两条已经证明同一把 `Local\` session 锁、6000ms 真超时（不是约 5s 成功取锁）、上限前释放后的成功清理，以及超时让路后锁可再取得。缺口只有「不创建/不改写」只看到目录仍在。本关口把超时切片收成：超时前后 session 相对路径集合与 `tool_use_counter.pkl` SHA-256 必须相同。abandoned / 异常释放仍走既有 Reminder abandoned 切片和 guard 的 success/catch/finally 释放合同，不另写 Cleanup 专属 abandoned 场景。

## Acceptance criteria 对照

对照 GitHub #51 票面 7 条 AC。锚点行号以本关口测试文件为准。

| AC | 结论 | 测试锚点 | 源码锚点 |
| --- | --- | --- | --- |
| Cleanup 与 Reminder 同一把 session 锁；等待上限固定 6000ms；不新增 CLI/环境变量/vendor 字段 | 满足 | 5s/8s holder 都用 `Get-CodexSerenaSessionMutexName`；8s 切片墙钟 `-ge 6000`。源码断言仍只有既有 `-Mode` / 固定 vendor，无 `VendorPath =` | `Get-CodexSerenaSessionMutexName` 共用；`$mutexTimeoutMilliseconds = if ($Behavior -ceq 'Cleanup') { 6000 } else { 250 }`；对外 param 仍只有 `-Mode` |
| 真实子进程持锁并在上限前释放：Cleanup 成功、exit 0、空输出、删除目标 session | 满足 | 持锁 5s 后 Cleanup：`ok/exitCode=0`、空 stdout、session 目录消失 | 拿到锁后 `DeleteKnownSessionState` |
| 上述等待和清理端到端 < 9.5s | 满足 | 同上；`ElapsedMilliseconds -lt 9500` | `WaitOne(6000)`，5s holder 在上限前释放 |
| 持锁超过 6000ms 不释放：Cleanup 在宿主预算内成功空返回，且不创建/删除/改写目标 session | 满足 | 持锁 8s：空输出、目录仍在、相对路径集合不变、`tool_use_counter.pkl` 哈希不变 | mutex 为 null 时在 `Initialize-CodexSerenaSessionDirectoryGuard` 之前返回 |
| 对 6000ms 真超时有直接回归，不以约 5s 成功取锁替代 | 满足 | 8s holder + `-ge 6000 -and -lt 9500`；本次套件该断言通过 | Cleanup 固定 6000，不是 250 |
| 正常/异常/超时/abandoned 均按约定释放，不遗留永久锁；随后新进程可再取得 | 满足（行为 + 源码合同） | 5s 成功后套件继续；超时 finally 杀 holder 后重试删除；abandoned 仍由 Reminder 切片证明可再取得。无单独 Dispose 抛错注入 | `Release-CodexSerenaBehaviorState`：lease → 守卫 → mutex；success/catch/finally 都调用；超时路径从未持锁 |
| 既有 fail-close、安全边界、Activation 回归通过；pin 与 guard 字节一致 | 满足 | 全文件套件 exit 0；pin 见上一节 | 对外仍是既有 Mode；本关口未改 guard 字节 |

## 两轴审查（相对本关口进入时的工作树）

对照点是本关口写入的测试增量与本证据目录，不是一次独立 commit。未改 guard。

### Standards

无硬违规。新断言落在既有公开 seam `Invoke-CodexSerenaBehaviorGuardCore` 和 session 目录文件，不 mock 内部 Dispose，不自引用锁名函数。判断项：超时前后各算一次相对路径集合，形状重复，但只服务这一条「不改写」观察，未抽公共 helper。`git diff --check` 对所有权文件退出码 0；测试文件有既有 CRLF→LF 提示，不是 `--check` 失败。

### Spec

#51 的同锁身份、Cleanup 6000ms 上限、上限前释放后的成功删除、< 9.5s、6000ms 真超时 fail-open 且不碰 session、超时后续进程可再取得、既有回归与 pin 同步，均能在源码与本次绿测中对上。本关口按票面**不提交**、不 comment/close。未把约 5s 成功取锁当成真超时。

## 未在本文件关闭的事项

- GitHub #51 仍 OPEN；本目录不构成 comment / close / edit 授权
- 工作树实现与测试**未 commit**
- 未跑 host-live / ProductionSmoke，也未改 safe-delete 生产实现
- 真超时墙钟只通过 `-ge 6000` 断言；成功路径不会把 `actual=` 打到 stdout
- Cleanup 后 Reminder 可重建 session 状态仍是已知设计边界（tombstone 不在本票）
