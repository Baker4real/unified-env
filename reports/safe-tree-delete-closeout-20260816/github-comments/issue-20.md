## 结论回写（2026-08-16）

结论：**传递修复已满足本票验收；保持 OPEN，本次不 close。**

本票只主张：受管中间层转发 `$LASTEXITCODE`，缺确认的结构化 refusal 仍是 exit 0，`leaf-delete-failed` 经完整 `.cmd` 链为非零。正式关闭 #20–#24 仍走 #52，且 #52 仍被 #47、#50 挡住。本评论不吞并 #47/#55，也不把本票生产 JSON 写成那两张票已完成。

### 已验证

- 宿主 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1` 与仓库 `scripts/invoke-codex-safe-tree-delete-host.ps1` 第 5 行均为 `exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })`。双方 SHA-256：`636CB140720BF15681364459269C2D5DC4638E339F2589AD2A3A53B6E17B9373`；`.cmd` 双方 `45AEADF7F758A1CAFCE106F66E7EAECC5F60176D2017630E2AF461A2A37BCA12`。
- 生产脚本仅在 `-Json` 且 `refusalReason=leaf-delete-failed` 时 `exit 1`（`scripts/Invoke-CodexSafeTreeDelete.ps1:135-139`）。缺确认 Archive 取值未改。
- 2026-08-16 经 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Purge -Json` 打出：`purged=false`，`refusalReason=leaf-delete-failed`，metrics schema v1，`$LASTEXITCODE=1`。锁策略是 `transaction.json` 进入 `purging`（locked preflight 已结束）后再 `FileShare.Read`，符合 spec 277–278，不是 JSON 发出前的 lease 抛错。
- ProductionSmoke 再证缺确认 Archive：exit 0 + `confirm-archive-required`。

证据：`reports/safe-tree-delete-closeout-20260816/issue20-production-purge-fail.json`、`purge-fail.stdout.txt`、`production-smoke.meta.json`、`ORCHESTRATION-CLOSE-GAPS.md`。

### 本票不主张

- 不主张 #47 的失败合同复核已完成。
- 不主张 #55 的确定性进程收口 / 代际核验已完成。
- 不主张 #21 可用本条 JSON 关票；#52 要求 #21 只引用 #47。

### 未完成 / 卫生

- leftover 仍在：`D:\Codex\projects\统一环境\reports\.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine`（operation `20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e`，`status=purging`）。这是新的在途事务，属 #45/#50 清空集，不是可选打扫；未再 Purge。
- 2026-08-16T02:17Z 的生产 Status 快照早于本 leftover 与随后的 ProductionSmoke，不能给 leftover 之后的计数背书。
- 工作树仍有他人 WIP。wrapper 四入口本身干净，但不能用脏树证明「全仓只改了传递」。

本次未 `gh issue close`，未 commit/push。
