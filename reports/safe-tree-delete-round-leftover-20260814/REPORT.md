# ProductionSmoke 持锁测法修正与本轮残留 Archive

**本目录是时间点证据快照，不构成后续 Apply / Purge / Delete / BatchArchive、关票或放宽判据授权。** 未改 `scripts/lib/CodexSafeTreeDelete.ps1`、ControlPlane、wrapper、`managed/safe-tree-delete/policy.json`、spec、#22/#23/#24/#18 旧报告；未触碰 10 条 ui-references v7–v11。

## 结论先行

| 项 | 结果 |
| --- | --- |
| 总评 | **DONE_WITH_CONCERNS** |
| live ProductionSmoke | 退出码 **0** |
| live 仍断言 | 缺确认 Archive → exit 0 + `confirm-archive-required`；以及既有 Plan/Apply/Purge 与 BatchPurge 收尾 |
| live 不再断言 | Purge 开始前持 `FileShare.Read` 打出 `leaf-delete-failed` |
| 归档 | 9/9 逐条 `Archive` 成功；`alreadyArchived=0`；`refusalReason` 均为空 |
| 未跑 | 完整 host-safety 模块；生产 `Status` 全量扫描 |

## 测试改动

`tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` 删除「先锁 quarantine 再 Purge」段。

生产 Purge 在 delete catch 之前会走 `Get-CodexHookCapabilityDirectoryTreeSnapshot`（`scripts/lib/CodexSafeTreeDelete.ps1` 约 3847 行，`name=safe-delete purge locked preflight`）。Purge **开始前** 的 `FileShare.Read` 卡在该预检，到不了 delete catch，也打不出 `leaf-delete-failed`。生产 CLI 没有 `FixtureBeforeDirectoryTreeDelete`。

`leaf-delete-failed` 结构化 JSON 由 ControlPlane Retry 切片 `rollback-snapshot-lock-candidate` 在 preflight 之后持锁覆盖。live 文件只留注释指向该 fixture，不假装 live 持锁已证明生产 Purge 失败 JSON。

`git diff --check -- tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` 通过。

## live smoke

```text
pwsh -NoProfile -NonInteractive -File tests\Test-CodexSafeTreeDeleteProductionSmoke.ps1
SMOKE_EXIT=0
```

仍通过：

- live/source wrapper SHA-256 一致
- 缺 `-ConfirmArchive`：`exitCode=0`，`refusalReason=confirm-archive-required`
- reports/ readonly fixture Plan → Apply → Purge
- BatchPurge：`purgedCount=2`，`recoveredCount=1`，随后受管清理 batch 父目录

证据根在本次 smoke 前后：2306 → 2310（+4，无 leaf-fail fixture）。

## 归档

入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`。每条现场重算 transaction SHA-256，带自己的 `-ConfirmArchive`。未新增 BatchArchive。归档前 wrapper 宿主/仓库 SHA-256 均为 `636cb140720bf15681364459269c2d5dc4638e339f2589ad2a3a53b6e17b9373`。

现场判据：`status=purged`、quarantine 当前不在、`restoreJournalAnchors` 空、无 `terminal-archive.json`、非 ui-references。

| operationId | 来源 | 结果 | refusalReason |
| --- | --- | --- | --- |
| `20260813T200503Z-56d5dd42-5f0f-429c-87da-15e8518e4af9` | 上轮 listed | archived | （空） |
| `20260813T200508Z-791fecd8-67af-49ce-95ae-891b42adf4c5` | 上轮 listed | archived | （空） |
| `20260813T200545Z-ec5af9d0-035a-4213-8033-9b1432225e14` | 上轮 listed | archived | （空） |
| `20260813T200547Z-087a6e03-6f19-4711-b8b4-5e4177cdedf9` | 上轮 listed | archived | （空） |
| `20260813T200553Z-03b8b4af-b466-4cce-9ff8-c977f3f48d93` | 上轮 listed | archived | （空） |
| `20260814T013149Z-b926e9a9-5e9f-4135-b83b-db9463dd7d81` | 本轮 smoke | archived | （空） |
| `20260814T013209Z-874602a3-4ac7-41f3-8e5f-1b78457eddab` | 本轮 smoke | archived | （空） |
| `20260814T013338Z-a8b25145-25ff-4d05-8d97-8309a5c42d1b` | 本轮 smoke | archived | （空） |
| `20260814T013344Z-c8018649-73b5-49ad-833a-4e94cfef5784` | 本轮 smoke | archived | （空） |

归档后核验：9 个 create-only `terminal-archive.json` 都在；对应 `transaction.json` SHA-256 未改；quarantine 仍不在。

## 明确未动

- 10 条时钟倒计时 `assets\ui-references` v7–v11：未 Archive / Purge / 改判 terminal
- `20260814T012818Z-4f9b7a0c-f090-4609-9625-c0f03896290d`：上轮 Status 快照之后、本轮 smoke 之前多出的 `i-have-adhd` 退役根 purged 记录。不在授权名单，未 Archive
- 他人已脏的 `policy.json`、Serena hook、wrapper、`CodexSafeTreeDelete.ps1`、ControlPlane：未回退、未改写

## 风险与未验证

- `reports/safe-tree-delete-production-smoke-5849ef763f1d42bab1341272288a672d/` 仍在（仅 `readonly-payload.txt`）。证据根没有指向它的 plan/transaction。它不是 purged 记录，本次无权 Purge/Delete，故保留
- 未重跑生产 `Status`，因此没有新的 blockingRecords / `complete` 数字。Archive 只证明 create-only marker 落地
- 本目录未登记进 `modules/manifest.json`，与同日其他 leftover 报告一致
