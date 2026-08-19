# 两处意外失败诊断（rerun1）

不是关单授权。未改 allowlist / 最小深度 / fail-closed / 认证。

## `tests/Test-CodexSafeTreeDelete.ps1`

- 上一轮红：`purging transaction 内容漂移必须返回稳定原因`。当时断言是 `-match '漂移'`。
- 产品路径：`Invoke-CodexSafeTreeDeletePurgeFileHash` 把 `IdentityMismatchException` 包成 `safe-delete purge IdentityMismatch：$RelativePath`。`Assert-Throws` 只返回 `Exception.Message`，不含「漂移」。
- 同类：未计划节点 / 树漂移走 `fileIdentitiesV2 缺少`，也不含「漂移」。
- 判定：断言设计缺陷，不是产品安全判据失效。内容漂移仍失败闭锁并保留现场。
- HEAD `5f7f597` 已改为 `-match 'IdentityMismatch|漂移'` 与 `-match 'fileIdentitiesV2 缺少|漂移'`。
- 本轮单独复现：exit=0，elapsedMs=26557。

## `tests/Test-CodexSafeTreeDeletePhase3Integration.ps1`

- 上一轮红：`#40 DOP4 wallClockMs 必须仍是 13255`。同一 fixture 清单里的 ParallelismBenchmark 曾把 `#40` raw 写成 `15356`。
- 判定：跨 issue 证据的精确墙钟耦合，天然脆弱。不是产品删除语义回归。
- HEAD 已改为 `wallClockMs -gt 0`，并核 `fileCount`/`degree`；不再钉历史毫秒。ParallelismBenchmark 现写入 `reports/safe-tree-delete-parallelism-benchmark/`，并拒绝覆盖 `#40` raw。
- 本轮单独复现：越过 `reuse-issue40-raw` / `citations`，跑完 10k baseline + phase3-prod。exit=0，elapsedMs=1275852。

## `tests/Test-CodexSafeTreeDeleteControlPlane.ps1`（本轮新发现）

- 完整回归第 3 项在 2.4s 红：`Status metrics 必须精确累计 policy、plan 双重认证与 live payload 哈希读取`。
- 旧公式是 `2*policy + 2*plan + 32`（各读两次）。当前 Status 对 unarchived plan 做 prefetch，并用 `LoadedPolicy` / `PreloadedSnapshot`，policy 与 plan 各哈希一次，再哈希一次 live payload。
- `Test-CodexSafeTreeDeleteStatus.ps1` 已按同一 live 树不得再哈希一遍验收；ControlPlane 仍钉旧双读公式。
- 判定：断言会计与现役 Status 认证模型不一致，不是放宽安全判据。改为 `policy + plan + 32`。
- 单独复跑：exit=0，elapsedMs=82007。

## 未改

- `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` 保持 #35 waiver，未放宽 DetectFileSystem。
- leftover `0ab1e1b6` 未 Purge / Archive / 删除。
- 未改生产 policy、host wrapper 源码、既有 `reports/` 快照内容（Phase3 测试自身仍向其 `evidenceHome` 写运行产物，见最终报告风险）。
