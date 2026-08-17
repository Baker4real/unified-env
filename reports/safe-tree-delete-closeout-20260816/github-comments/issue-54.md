## 结论回写（2026-08-16）

结论：**本票功能验收（Plan 写 `leafStreamSetV1`，Apply/Purge 在各自 live freeze 消费并发布 leaf disposition）已满足；保持 OPEN，本次不 close。** 15 条缺 `leafStreamSetV1` 的在途事务按 spec 242–246 是**部署前 / #45/#50 清空门禁**，不是本票功能 AC。

### 已验证

- `tests/Test-CodexSafeTreeDeleteLeafStreamSet.ps1` 4 slices exit 0。
- `tests/Test-CodexSafeTreeDeleteCrashSafety.ps1` 13 scenarios exit 0（含 dispositions 发布后、`purged` 前崩溃的幂等收口）。
- `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` exit 0（60.2 s）：新 Plan → Apply → Purge 生产链仍通。
- 旧 Plan 无 `leafStreamSetV1` 时 Apply/Purge 失败闭锁；Status/Archive 只读路径不受影响。这是合同，不是「必须先把生产 15 条清掉才能证明实现」。

证据：`reports/safe-tree-delete-closeout-20260816/related-fixture-tests.json`、`production-smoke.meta.json`、`legacy-inflight-inventory.json`、`ORCHESTRATION-CLOSE-GAPS.md`。

### 在途事务（部署门禁，未处置）

只读盘点（#20 leftover 之前）：在途 16 条，15 条缺 `leafStreamSetV1`。

- 4 条 transaction schema v1：严格 Purge/Restore reader 不可用。
- 11 条 v2 quarantined（时钟倒计时 verification + 10 条 ui-references）：Purge 因无 stream-set 失败闭锁；Restore 合同上不读 stream-set，**未授权不得执行**。
- 另 1 条已有 stream-set 的 run-evidence quarantined，不是 legacy 缺口。

随后本会话又留下 #20 leftover：`20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e`（`purging`）。它一般带新 Plan/stream-set，计入 #45/#50 清空集，不是本票 15 条那一类。

### 本票不主张

- 不主张生产部署已可切换。部署前仍须 live 重盘并清空在途。
- 不主张 #55 已可完成。关本票会解除 #55 的 blocked-by，但 #55 自己还要打确定性 wrapper 负向 smoke；不要把 15 条清场塞进本票。
- 未 Restore/Purge 任何时钟倒计时路径。

本次未 close、未部署、未 commit/push。
