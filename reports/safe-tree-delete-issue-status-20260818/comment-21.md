## 状态回写（2026-08-18）

**实现关口：** 非零 wrapper 证据 DONE（默认分支）；fixture 全量 AC **部分**。
**GitHub：** 保持 OPEN。

**非零主证据只有这一条（origin/main）：** `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`（`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`，经 live `.cmd`）。fixture / suite `ok=true` 不能替代。

fixture 全量（`reports/safe-tree-delete-issue21-regression-20260818/summary.json`）：27/27 都有 exit；**24 绿 / 3 红**；leftover SHA 前后不变。

| 测试 | 归类 | 现状 |
| --- | --- | --- |
| `Test-CodexSafeTreeDeleteFileSystem.ps1` | #35 waiver | diskpart Win32 740，未提权；不改 DetectFileSystem |
| `Test-CodexSafeTreeDelete.ps1` | 意外红，已修测试 | 现役原因是 `IdentityMismatch`；工作树断言改为 `IdentityMismatch\|漂移`；该文件复跑 exit **0**。未改生产 |
| `Test-CodexSafeTreeDeletePhase3Integration.ps1` | 意外红，已修测试 | 不再钉 #40 `wallClockMs==13255`；只核存在/fileCount/degree/`wallClockMs>0`。该文件复跑 exit **0**。Benchmark 新跑写入 `reports/safe-tree-delete-parallelism-benchmark/`，不再覆盖 #40 raw |

未再跑完整 27 项，未跑 ProductionSmoke。测试修复仍在工作树，未进默认分支。

leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 与 `D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json`。最近 Status 三联 SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`，lifecycle=`purge-resumable`，不在 blocking。属 #45 清空集，不是本票打扫对象。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
