# Issue 46 实现关口可关闭（2026-08-17 Reminder 验收）

本文件只解释本证据目录与本次 `Test-CodexSerenaBehaviorHooks.ps1` 结果。不是 GitHub 关单授权，也不是提交授权。本关口**未 commit / push / comment / close / edit**。

#44 已把 session 命名互斥与 Reminder 250ms fail-open 落到工作树。本关口只补/核验 **Reminder** AC：对照 live 测试与 guard 源码，补上「Activation 在同 session 锁被占用时不拿锁」的行为锚点，再跑全套并核验 pin。未改 guard、两份 manifest pin、`managed/safe-tree-delete/policy.json`、`scripts/lib/CodexSafeTreeDelete.ps1`、`modules/manifest.json`、`managed/grok-hooks/`、ProductionSmoke、`reports/serena-issue44-20260817/`。未新写 #51 专属「Cleanup 真超时 6000ms 不释放仍空返回」切片；同文件里既有的 Cleanup 超时用例随套件跑过，本关口未扩写。

## 本次运行

- 套件：`tests/Test-CodexSerenaBehaviorHooks.ps1`
- 入口：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe -NoProfile -NonInteractive -File D:\Codex\projects\统一环境\tests\Test-CodexSerenaBehaviorHooks.ps1`
- 运行时：PowerShell Core 7.6.4
- 退出码：0
- 墙钟：`Test-CodexSerenaBehaviorHooks.meta.json` `durationMs=28523`
- stdout：`Codex Serena behavior hook tests passed.`（前有既有 `True` 行，与 #44 捕获一致）
- stderr：空
- 本关口未改 guard / 两份 manifest；相对进入本关口时的工作树，只改测试文件并新增本目录

## Pin 核验

当前 `managed/codex-hooks/hooks/serena-behavior-guard.ps1` SHA-256：

`85d78b8533a47f8a9f3419e1bc4db33e3351522d7e8c1fe1aa861c0399f4ea3a`

与下列 pin 字节一致（十六进制大小写不敏感）：

- `managed/codex-hooks/manifest.json` `hooks/serena-behavior-guard.ps1` `sha256`
- `managed/codex-hooks/host-preflight-manifest.json` `hooks/serena-behavior-guard.ps1` `sha256`

本关口未改 guard，因此未重算 pin。

## Acceptance criteria 对照

对照 GitHub #46 票面 7 条 AC。锚点行号以本关口测试文件为准。

| AC | 结论 | 测试锚点 | 源码锚点 |
| --- | --- | --- | --- |
| home / session id 大小写等价 → 同一 `Local\` 锁；不同 session 不同锁且不互阻 | 满足 | `Get-CodexSerenaSessionMutexName` 大小写别名、固定向量 `E783D259…C877`、`/` vs `\`、尾斜杠；不同 session 名不等且 Reminder 仍建立自有 state | `Get-CodexSerenaSessionMutexName`：`GetFullPath` + `TrimEnd` + `ToUpperInvariant`，前缀 `Local\CodexSerenaSession-` |
| Reminder 最多等 250ms；未拿到锁：成功、exit 0、空输出、不创建/修改 session 状态 | 满足 | 真实子进程持锁 5s 后 Reminder：`ok/exitCode=0`、空 stdout、不创建 session 目录、不写 `serena-reminder.json` | Reminder 超时 250ms；`sessionMutex` 为 null 时在 `Initialize-CodexSerenaSessionDirectoryGuard` 之前返回 |
| 真实子进程持锁，Reminder 总耗时 < 3.5s | 满足 | 同上 holder；`ElapsedMilliseconds -lt 3500` | `WaitOne(250)`，不跟 5s holder |
| abandoned mutex 视为已取得，随后走既有路径与计数器身份校验 | 满足 | 杀持锁进程后 Reminder 成功并写出 `tool_use_counter.pkl` | `AbandonedMutexException` → `$held = $true`，然后 Acquire/vendor/`ValidateAfterVendor` |
| 释放顺序 lease → session 守卫 → 命名互斥；释放异常不覆盖原结果 | 满足（源码 + 相邻行为） | 成功路径健康写失败不翻转 vendor 结果（既有 F2）；无单独「Dispose 抛错」注入（会耦内部） | `Release-CodexSerenaBehaviorState` 按 lease → 守卫 → `Exit-CodexSerenaSessionMutex`，每步 `try/catch {}`；success/catch/finally 三条路径都调用 |
| 健康上报在临界区外；Activation 不拿这把锁 | 满足 | 本关口补：同 session holder 仍占用时 Activation 产出 `SessionStart`、`< 3500ms`、不建 session 目录。既有 Activation 协议断言仍在 | Activation 在 mutex 分支之前直接拼 SessionStart JSON；健康写在 `Release-…` 之后 |
| 受影响回归 + pin 与 guard 字节一致 | 满足 | 全文件套件 exit 0，含 vendor remind/cleanup、fail-close、既有守卫竞态；pin 见上一节 | 对外仍是既有 Mode；未改 guard 字节 |

## 两轴审查（相对本关口进入时的工作树）

对照点是本关口写入的测试增量，不是一次独立 commit。未改 guard。

### Standards

无硬违规。新断言落在既有公开 seam `Invoke-CodexSerenaBehaviorGuardCore`，复用已在临界区的真实子进程 holder，不 mock 内部 Dispose，不自引用锁名函数。判断项：释放顺序仍主要靠源码合同，而不是新的调用次序测试——那会变成实现耦合。`git diff --check` 对所有权文件退出码 0；测试文件有既有 CRLF→LF 提示，不是 `--check` 失败。

### Spec

#46 的 session 级 `Local\` 命名互斥、Reminder 250ms fail-open、大小写等价锁名、abandoned 恢复、lease→守卫→mutex 释放、健康在临界区外、Activation 不持锁、pin 同步，均能在源码与本次绿测中对上。本关口按票面**不提交**、不 comment/close。未新写 #51 专属真超时切片。

## 未在本文件关闭的事项

- GitHub #46 仍 OPEN；本目录不构成 comment / close / edit 授权
- 工作树实现与测试**未 commit**
- #51 仍 OPEN；其专属 Cleanup 真超时回归未在本关口扩写
- 未跑 host-live / ProductionSmoke，也未改 safe-delete 生产实现
- Cleanup 后 Reminder 可重建 session 状态仍是已知设计边界（tombstone 不在本票）
