# Issue 21 实现关口可关闭（2026-08-16 live smoke）

本文件只解释本证据目录与本次 ProductionSmoke 的 live 结果。不是 GitHub 关单授权，也不是对 leftover `0ab1e1b6` 或生产实现的处置授权。未 commit / push / comment / close。

## 本次运行

- 套件：`tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`（并入既有 ProductionSmoke，未新建测试文件）
- 入口：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe -NoProfile -NonInteractive -File …\Test-CodexSafeTreeDeleteProductionSmoke.ps1`
- 退出码：0
- 墙钟：`summary.json` `wallClockSeconds=407.492`（外层 stopwatch 407893 ms）
- live wrapper 最终 SHA：`636cb140720bf15681364459269c2d5dc4638e339f2589ad2a3a53b6e17b9373`（与 backup / 仓库 host 源一致，含 `LASTEXITCODE` 转发）

## Acceptance criteria 对照

| AC | 结论 | live 证据 |
| --- | --- | --- |
| 经真实受管 wrapper 链验证 `leaf-delete-failed` 返回非零 | 满足 | 恢复转发后 `fail-purge-leaf-delete.meta.json` `actualExitCode=1`；`leaf-delete-failed.json` `exitCode=1`、`refusalReason=leaf-delete-failed`、`purged=false`、`productionJsonObtained=true`、`lockAcquiredMarkerExists=true`。stdout 为生产 JSON（含 metrics retry sharing-violation） |
| 该断言在撤转发后会红、恢复后通过 | 满足（按本票指定的 exit 0 证明，而不是让 `ExpectedExitCode 1` 在变异窗口内 throw） | 只改 live `.ps1`，仍调用同一生产脚本、去掉 `exit $LASTEXITCODE`。`revert-forwarding.json`：`exitCode=0`、`wrapperSwallowedNonzero=true`、JSON 仍 `refusalReason=leaf-delete-failed` 且 `purged=false`。`revertedPs1Sha256=d3155a23…` ≠ 转发 SHA。try/finally 从 backup 字节恢复后 `restoredPs1Sha256=636cb140…`。随后既有非零断言仍在 |
| 同时断言 `exit 0` + `refusalReason` 既有契约未被破坏 | 满足 | `archive-unconfirmed.meta.json` `actualExitCode=0`；stdout `{"archived":false,"refusalReason":"confirm-archive-required"}` |
| 不新增测试 seam，并入既有 ProductionSmoke | 满足 | 只改 `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`。调用仍走 `Invoke-LiveSafeDeleteTracked` → live `.cmd`。未改生产脚本、仓库 host 源、`.cmd`、`policy.json`、hooks |
| 不对生产证据根做写操作，或明确说明依赖与隔离 | 满足（选后者：live 链必然写生产 evidence 根） | 见下一节 |
| 既有全部 safe-tree-delete 测试保持通过 | 部分：本票必跑的 ProductionSmoke 为 exit 0。host-safety 默认 fixture 未重跑；已知 #35 FileSystem 红记为范围外 waiver，未改生产实现去“修” |

## 对生产证据根的依赖与隔离

live 入口是 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`。任何真实 Plan/Apply/Purge 都会在 `D:\Codex\.codex\run-evidence\safe-tree-delete\<run-id>\` 留下新 operation。这不是 mock，也不能改成只写 `reports/`。

本次 #21 负向路径新 operation：

- `20260816T134336Z-fc1d1a90-885d-4535-bd15-4cfc8af3701b`（撤转发 fail Purge，随后 resume `purged=true`）
- 恢复后 #55 路径另有 `20260816T134343Z-d0de032c-7ed6-44b9-8222-91d2522f99c8`（非零 `leaf-delete-failed`，同样 resume 清掉）

隔离方式：

- capability 目标只在 `reports/` 下独立 guid 目录（`safe-tree-delete-issue21-livefail-*` / `safe-tree-delete-issue55-livefail-*`），不是 leftover 或 #22 候选
- 本票 fixture quarantine 经受管 resume Purge 清掉（`issue21-fail-purge-resume.stdout.txt` `purged=true`；现场只剩 leftover `0ab1e1b6` 目录）
- `Invoke-LiveSafeDeleteTracked` 拒绝把 leftover transaction/quarantine 当作参数
- Status 只读观测不写入 policy；不读写 #22 的 Status/Archive 候选
- 禁止对 leftover `0ab1e1b6` 做 Purge/Restore/Resume

整套 ProductionSmoke 会覆盖 `reports/safe-tree-delete-issue55-20260816/` 下同名 JSON（#50 要最新 live 包）。本目录不覆盖那些文件名；#21 专有证据是 backup、`revert-forwarding.json`、本 CLOSEABLE。

## 临时撤转发窗口

- 变异对象：仅 live `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1`
- backup：`invoke-safe-tree-delete.ps1.backup`（218 字节，SHA `636cb140…`）
- 锁窗口：`lock-holder.log` 为 `lock-holder-start` → `saw-purging` → `acquired` → `released`（Purge 已启动且 transaction 进入 `purging` 后才 `FileShare.Read`）
- 恢复失败合同：inner `finally` 从 backup 字节恢复并比对 SHA；失败则 `BLOCKED` 且 outer `finally` 跳过后续 live 调用（含 inflight resume）

## leftover

`0ab1e1b6` 属 #45/#50 清空集。本次前后 quarantine 仍在、transaction SHA-256 不变：

`4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`

## 两轴审查（相对 HEAD 工作树 diff）

对照点是 `HEAD` 工作树，不是一次独立 commit。`Test-CodexSafeTreeDeleteProductionSmoke.ps1` 相对 HEAD 还包含未提交的 #55 ProductionSmoke 扩写；本票只在其上增加撤转发切片，未回退他人 WIP。

### Standards

无硬违规。live 调用仍走受管 `.cmd`；leftover 被参数拦截并做前后 SHA 比对；live `.ps1` 只在 try/finally 里按 backup 字节恢复；缺确认 Archive 仍为 exit 0；`leaf-delete-failed` 恢复后为 exit 1。判断项：issue21/issue55 两条负向路径形状重复（为保住独立锁窗口，未抽新 seam）；`Write-Issue55Json` 也写 issue21 JSON。

### Spec

GitHub #21 的 wrapper 链非零、撤转发证明、Archive exit 0、并入 ProductionSmoke 均有 live JSON。缺口：全量 safe-tree-delete fixture 未在本票重跑（#35 FileSystem 按父任务 waiver）。生产 evidence 根写入已在测试头注释与本节写明。撤转发窗口用 `ExpectedExitCode 0` 证明“没有转发时非零断言会红”，而不是在变异窗口内让 `ExpectedExitCode 1` 失败；这与本票纵向切片的 exit 0 合同一致。

## 未在本文件关闭的事项

- GitHub #21 仍 OPEN；本目录不构成 comment/close/edit 授权
- 未重跑 host-safety 默认 fixture；#35 FileSystem 红为范围外 waiver
- leftover `0ab1e1b6` 与缺 `leafStreamSetV1` 的在途事务仍属 #45/#50
- 未 commit
