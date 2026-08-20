# AC11：批量归档错误隔离 fixture 回归定位（HEAD cd7661f，2026-08-19）

位置：`tests/Test-CodexSafeTreeDeleteControlPlane.ps1` 第 1283–1432 行（属 manifest host-safety
fixture 清单第 3 项，本目录 runner 单独执行，见 summary.json 的
`tests/Test-CodexSafeTreeDeleteControlPlane.ps1` 条目与
`Test-CodexSafeTreeDeleteControlPlane.ps1.stdout.txt` / `.stderr.txt`）。

结构（"多条候选中夹入不合格记录"的三明治）：

```powershell
$batchArchiveSpecs = @(
    [pscustomobject][ordered]@{ name = 'batch-archive-good-a'; eligible = $true },
    [pscustomobject][ordered]@{ name = 'batch-archive-bad';    eligible = $false },
    [pscustomobject][ordered]@{ name = 'batch-archive-good-b'; eligible = $true }
)
```

good-a / good-b 走 Plan→Apply→Purge 成为合格 purged；bad 停在 `quarantined`（status 不是
purged，触发判据一）。随后逐条循环调用单笔 `Mode Archive`（每条自带
`-TransactionPath` + `-ApprovedTransactionSha256` + `-ConfirmArchive`）。

关键断言（原文引用）：

- 其余仍被归档：`'逐条 Archive 必须归档合格项 $($batchCandidate.name)'`（archived=true、
  marker 存在、archivePath 精确匹配）；`'合格项 … 只允许新增一份 Archive marker'`（before+1）；
  `'合格项 … 不得改写既有 evidence'`（逐文件 SHA-256 与 file identity 不变）。
- 不合格被拒且零写入：`'逐条 Archive 必须以稳定原因拒绝不合格项 …'`
  （refusalReason 精确等于 `transaction-status-not-purged`、marker 不存在）；`
  '不合格项 … 必须零写入'`（before/after 文件状态 JSON 逐字节相等）。
- 单条失败不中断其余 + 结果可读：`'批量逐条 Archive 结果必须按调用顺序可读，且单条拒绝不得中断其余合格项'`
  （三条结果按 good-a/bad/good-b 顺序，archived=true/false/true）。
- Status 侧复核：`'Status 必须只把合格归档项标为 terminal，不合格项保持原状态'`
  （合格 2 条 lifecycle=terminal；不合格者仍 quarantined 非 terminal）。

历史佐证：#22 执行波次该测试独立运行 exit=0（155.249s，见
`reports/safe-tree-delete-issue22-20260815/tests-summary.json` 的 controlPlaneStandalone 与
`control-plane-test.stdout.txt`）；本目录 runner 在 HEAD cd7661f 上的结果以本目录
`Test-CodexSafeTreeDeleteControlPlane.ps1.stdout.txt` 与 summary.json 条目为准。
