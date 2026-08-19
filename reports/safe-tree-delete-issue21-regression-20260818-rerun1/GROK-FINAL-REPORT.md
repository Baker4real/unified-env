# GROK-FINAL-REPORT — GitHub issue #21

状态：`DONE_WITH_CONCERNS`

会话：`41033955-9c4a-4ef9-bd31-241dafb13ee4`。仓库 `D:\Codex\projects\统一环境`，分支 `wip/2026-08-18-host-and-safe-delete`。未 commit / push / 建分支 / worktree / PR / `gh` / 关 issue。

## AC 逐项结论

| AC | 结论 | 证据 |
| --- | --- | --- |
| 1. 经真实受管 wrapper 链断言 `leaf-delete-failed` 返回非零退出码 | **成立** | `production-smoke/issue55/leaf-delete-failed.json`：`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`。调用链 `.cmd` → live `.ps1` → 生产脚本。 |
| 2. 该断言在 #20 修复前会失败、修复后通过 | **成立** | 见 `AC-REGRESSION-PROOF.md`。撤转发后 exit=0 且 JSON 仍是 `leaf-delete-failed`；恢复后 exit=1。 |
| 3. `exit 0` + `refusalReason` 既有契约未破坏 | **成立** | ProductionSmoke：缺确认 Archive `exit=0` + `confirm-archive-required`。 |
| 4. 不新增测试 seam，优先并入既有 ProductionSmoke | **成立** | AC#1/#2/#3 都在 `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`。未新增生产入口。 |
| 5. 测试不对生产证据根做写操作，或说明依赖与隔离 | **成立（有说明）** | live 链固有写入 `D:\Codex\.codex\run-evidence\safe-tree-delete\`。Harness 证据写到本目录 `production-smoke/`，不改写 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（SHA 前后均为 `6e451a91…`）。capability 目标用 reports/ 下 guid 目录；fixture 事后受管 resume Purge；leftover `0ab1e1b6` 未触碰。 |
| 6. 既有全部 safe-tree-delete 测试保持通过 | **成立（含 #35 waiver）** | fixture 27/27 完成：26 绿 + 1 条 #35 waiver。`unexpectedFailCount=0`。 |

## 改动文件清单

允许范围内的工作树改动：

- `tests/Test-CodexSafeTreeDeleteControlPlane.ps1` — Status metrics 由 `2*policy+2*plan+32` 改为一次 policy + 一次 plan + live payload（对齐 Status prefetch / LoadedPolicy）。
- `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` — harness 证据根与历史 issue55/issue21 快照隔离；禁止写入冻结 `leaf-delete-failed.json`。
- `reports/safe-tree-delete-issue21-regression-20260818-rerun1/` — 本票证据（新建）。

HEAD 已有、本轮未再改：

- `tests/Test-CodexSafeTreeDelete.ps1` — `IdentityMismatch\|漂移` / `fileIdentitiesV2 缺少\|漂移`
- `tests/Test-CodexSafeTreeDeletePhase3Integration.ps1` — `wallClockMs -gt 0`，不钉 #40 精确墙钟

`git checkout` 恢复（仅这些快照）：

- `reports/safe-tree-delete-issue32-20260817/scale-1000.json`
- `reports/safe-tree-delete-issue32-20260817/scale-10000.json`
- `reports/safe-tree-delete-issue42-20260817/baseline-partial.json`
- `reports/safe-tree-delete-issue42-20260817/coordinator-journal.json`
- `reports/safe-tree-delete-issue42-20260817/filesystem-probe.json`
- `reports/safe-tree-delete-issue42-20260817/scale-phase3.json`

`git diff --check`（上述两个测试文件）：退出码 0。

## 回归计数

| 项 | 值 |
| --- | --- |
| manifestCount | 27 |
| completedCount | 27 |
| incomplete | false |
| passCount | 26 |
| failCount | 1（仅 FileSystem） |
| unexpectedFailCount | 0 |
| knownWaivers | `tests/Test-CodexSafeTreeDeleteFileSystem.ps1`（GitHub #35） |
| leftover 0ab1e1b6 | 前后 SHA 均为 `4e73aedc…`，quarantine 仍在，`leftoverUntouched=true` |
| totalElapsedMs | 8563395（约 2.38 h；含沿用的前 21 项） |

ProductionSmoke：退出码 **0**，elapsedMs=239786。`revertForwardingProved=true`，`leafDeleteFailed=true`，`wrapperRestored=true`，`frozenSnapshotsUntouched=true`。

证据目录：`reports/safe-tree-delete-issue21-regression-20260818-rerun1/`

## 快照恢复清单

已用 `git checkout -- <path>` 恢复下列 tracked 文件到 HEAD。未删除这些目录里的未跟踪夹具/work 树。

第一批（上一轮）：

- `reports/safe-tree-delete-issue32-20260817/scale-1000.json`
- `reports/safe-tree-delete-issue32-20260817/scale-10000.json`
- `reports/safe-tree-delete-issue42-20260817/baseline-partial.json`
- `reports/safe-tree-delete-issue42-20260817/coordinator-journal.json`
- `reports/safe-tree-delete-issue42-20260817/filesystem-probe.json`
- `reports/safe-tree-delete-issue42-20260817/scale-phase3.json`

第二批（本轮，补跑最后 6 项后再次覆写）：

- `reports/safe-tree-delete-issue33-20260817/scale-1000.json`
- `reports/safe-tree-delete-issue33-20260817/scale-10000.json`
- `reports/safe-tree-delete-issue34-20260817/integration-results.json`
- `reports/safe-tree-delete-issue36-20260817/filesystem-probe.json`
- `reports/safe-tree-delete-issue36-20260817/scale-phase1.json`
- `reports/safe-tree-delete-issue37-20260817/scale-10000.json`
- `reports/safe-tree-delete-issue39-20260817/scale-10000.json`
- `reports/safe-tree-delete-issue41-20260817/journal-performance-report-10k.json`
- `reports/safe-tree-delete-issue41-20260817/scale-10000.json`
- `reports/safe-tree-delete-parallelism-benchmark/REPORT.md`
- `reports/safe-tree-delete-parallelism-benchmark/analysis.json`
- `reports/safe-tree-delete-parallelism-benchmark/preflight.json`
- `reports/safe-tree-delete-parallelism-benchmark/smoke.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/large-1k-1mb-dop01.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/large-1k-1mb-dop02.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/large-1k-1mb-dop04.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/large-1k-1mb-dop08.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/large-1k-1mb-dop16.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/medium-5k-10kb-dop01.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/medium-5k-10kb-dop02.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/medium-5k-10kb-dop04.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/medium-5k-10kb-dop08.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/medium-5k-10kb-dop16.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/small-10k-1kb-dop01.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/small-10k-1kb-dop02.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/small-10k-1kb-dop04.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/small-10k-1kb-dop08.json`
- `reports/safe-tree-delete-parallelism-benchmark/raw/small-10k-1kb-dop16.json`

恢复后 `git status --short` 去掉 `??` 只剩两个测试文件的 `M`。

## 已知耦合债务（本票不修）

以下测试把 `evidenceHome` 硬编码到历史 `reports/` 快照（或同目录工作树），跑测会覆写 tracked 证据：

| 测试 | 硬编码写入根 |
| --- | --- |
| `tests/Test-CodexSafeTreeDeleteHashReuse.ps1` | `reports/safe-tree-delete-issue32-20260817/` |
| `tests/Test-CodexSafeTreeDeletePurgeHashReuse.ps1` | `reports/safe-tree-delete-issue33-20260817/` |
| `tests/Test-CodexSafeTreeDeleteUncertainRecovery.ps1` | `reports/safe-tree-delete-issue34-20260817/` |
| `tests/Test-CodexSafeTreeDeletePhase1Integration.ps1` | `reports/safe-tree-delete-issue36-20260817/` |
| `tests/Test-CodexSafeTreeDeletePurgeBatch.ps1` | `reports/safe-tree-delete-issue37-20260817/` |
| `tests/Test-CodexSafeTreeDeleteThreadJournal.ps1` | `reports/safe-tree-delete-issue38-20260817/`（本轮该目录无 tracked `M`） |
| `tests/Test-CodexSafeTreeDeleteParallelPurgeCoordinator.ps1` | `reports/safe-tree-delete-issue39-20260817/` |
| `tests/Test-CodexSafeTreeDeleteJournalPerformance.ps1` | `reports/safe-tree-delete-issue41-20260817/` |
| `tests/Test-CodexSafeTreeDeletePhase3Integration.ps1` | `reports/safe-tree-delete-issue42-20260817/`（并只读引用 #36/#37/#39/#40/#41 快照） |
| `tests/Test-CodexSafeTreeDeleteParallelismBenchmark.ps1` | 写入 `reports/safe-tree-delete-parallelism-benchmark/`；只读核 `#40` 历史 raw，并拒绝覆盖它 |

## 风险与未决项

- #35 FileSystem 仍红：本机无提权 diskpart/VHD，C–F 均为 NTFS。未改 DetectFileSystem。
- leftover `0ab1e1b6` 仍在，本票未 Purge/Archive。
- ProductionSmoke 会在生产 evidence 根留下新 operation（live 链固有）；本票 fixture 已 resume Purge。
- 历史 issue 目录里仍有未跟踪夹具/journal，属测试耦合残留，未在本票清理。
- 未关闭、未评论 GitHub issue。
