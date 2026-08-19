# AC#2 临时回退验证

不是关单授权。未改仓库源 wrapper、未改 `.cmd`、未改生产 policy。变异窗口只动 live `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1`，finally 从 backup 字节恢复。

## 回退了什么

- 对象：live PowerShell wrapper（#20 退出码转发）
- 操作：删掉 `exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })`
- 变异前 SHA-256：`636cb140720bf15681364459269c2d5dc4638e339f2589ad2a3a53b6e17b9373`
- 撤转发后 SHA-256：`d3155a23184e531aa8f8c5e981eeea98ce3f4d4ddfc649773e7f830e7cba2772`
- 仍调用同一生产脚本 `Invoke-CodexSafeTreeDelete.ps1`

## 断言红（#20 修复前会失败）

经真实 `invoke-safe-tree-delete.cmd` → 变异后的 live `.ps1` → 生产脚本，对 `leaf-delete-failed` fixture：

| 字段 | 值 |
| --- | --- |
| exitCode | **0**（wrapper 吞掉非零） |
| purged | false |
| refusalReason | leaf-delete-failed |
| metricsPresent | true |
| wrapperSwallowedNonzero | true |
| lockAcquiredMarkerExists | true |

证据：`production-smoke/issue21/revert-forwarding.json`

这证明：若没有 #20 的 `$LASTEXITCODE` 转发，现有「非零退出码」断言会红。

## 恢复后绿

- 从 backup 原字节写回 live `.ps1`
- 恢复后 SHA-256：`636cb140720bf15681364459269c2d5dc4638e339f2589ad2a3a53b6e17b9373`
- wrapperRestored = true
- 同一 seam 再打真实 fail fixture：`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`

证据：`production-smoke/issue55/leaf-delete-failed.json`

## 既有 exit 0 + refusalReason 未破坏

缺确认 Archive：`unconfirmedArchiveExitCode=0`，`refusalReason=confirm-archive-required`。
