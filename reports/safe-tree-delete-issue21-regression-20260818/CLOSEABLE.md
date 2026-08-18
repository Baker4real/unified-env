# Issue 21 fixture 全量回归（2026-08-18）

本文件只解释本证据目录与本次 host-safety **fixture** 全量结果。不是 GitHub 关单授权，也不是对 leftover `0ab1e1b6` 或生产实现的处置授权。未 commit / push / comment / close。未改 `scripts/`、`tests/`、`policy.json`、hooks、`managed/`。未跑 ProductionSmoke（host-live）。

## 本次运行

- 清单真源：`modules/manifest.json` → `host-safety.tests.fixture.powershell`（27 项）
- 官方 runner `--list` 与清单一致（27 个 `Test-*.ps1`）
- 调用：`D:\Codex\tools\PowerShell\7.6.4\pwsh.exe` Core 7.6.4，`-NoProfile -NonInteractive -File <test>`
- 失败继续：官方 `Run-PowerShellTests.cjs` 遇非零会停；本目录 `run-fixture-regression.cjs` 逐项跑完同一清单
- 墙钟：`summary.json` `totalElapsedMs=10553047`（约 2.93 h）；外层 runner `elapsed_ms=10558927`
- leftover `0ab1e1b6` transaction SHA-256 前后均为 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`；quarantine 仍在。未 Purge / Archive

## Acceptance criteria 对照（本节点只补 fixture 全量）

| AC | 结论 | 证据 |
| --- | --- | --- |
| 既有全部 safe-tree-delete 测试保持通过 | **部分** | fixture 27/27 都有 exit。24 绿。3 红：2 条意外红 + 1 条 #35 waiver。未跑 host-live ProductionSmoke；wrapper 非零仍以 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` 为准 |

### 红项

| 测试 | exit | elapsedMs | 归类 | 原始错误（脱敏） |
| --- | ---: | ---: | --- | --- |
| `tests/Test-CodexSafeTreeDelete.ps1` | 1 | 18518 | 意外红 | `purging transaction 内容漂移必须返回稳定原因`（`Assert-True ($partialDriftError -match '漂移')` 失败） |
| `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` | 1 | 7786 | **#35 waiver** | 无法创建一次性 FAT32 VHD；`diskpart.exe` Win32 740「请求的操作需要提升」。本机 C–F 均为 NTFS。未改 `DetectFileSystem` |
| `tests/Test-CodexSafeTreeDeletePhase3Integration.ps1` | 1 | 10969 | 意外红 | `#40 DOP4 wallClockMs 必须仍是 13255`。本轮先跑的 `ParallelismBenchmark` 把 `reports/safe-tree-delete-issue40-20260817/raw/small-10k-1kb-dop04.json` 写成 `wallClockMs=15356`。未回写 issue40 |

### Waiver（记录，不当失败去改码）

- GitHub #35：FAT32 / 网络实卷 e2e 维护者 waiver。FileSystem 红是未提权 diskpart/VHD，不是本票要实现的 DetectFileSystem 修复。

## 未在本文件关闭的事项

- GitHub #21 仍 OPEN；本目录不构成 comment / close / edit 授权
- 两条意外红未修生产实现、未改测试
- 未跑 ProductionSmoke；未 Purge leftover `0ab1e1b6`；未 Archive
- `git diff --check` 对本目录：`DIFFCHECK_EXIT=0`（intent-to-add 后检查，随后 `git restore --staged`，未 commit）
- 未 commit
