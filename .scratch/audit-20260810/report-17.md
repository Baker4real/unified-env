# Issue #17 审计报告：受管归档

**审计时间**：2026-08-10
**审计 commit 范围**：0cedb49..HEAD（3d4c647、6d68fb4）
**整体判定**：AC 全部实现，无已知安全漏洞；两条次要发现，均不影响安全保证。

---

## Acceptance Criteria 逐条判定

| # | 条目 | 判定 | 证据 |
|---|------|------|------|
| 1 | 新增受管归档能力，不删除任何 evidence 文件 | 已验证通过 | `CodexSafeTreeDelete.ps1:1101` Invoke-CodexSafeTreeDeleteArchive；全文无 Remove-Item/File::Delete |
| 2 | 归档标记 create-only，重复归档不改变既有标记 | 已验证通过 | `CodexHostSafety.ps1:2059` New-CodexHookCapabilityJson 以 ExpectedExists=$false 调用原子写；已存在则 throw（CodexHostSafety.ps1:556）；重复走 alreadyArchived=true 分支只读现有标记 |
| 3 | 归档动作留可追溯证据含时点 | 已验证通过 | archivedAtUtc 字段写入 terminal-archive.json，来源 [datetimeoffset]::UtcNow（line 1167）；测试断言字段存在格式合法 |
| 4 | Status 识别标记让记录退出 blockingRecords | 已验证通过 | Resolve-CodexSafeTreeDeleteStatusOperation:1290 检测到标记后调用 Resolve-CodexSafeTreeDeleteArchivedStatusOperation；返回 lifecycle=terminal（1235）；blockingRecords 过滤排除 lifecycle=terminal（1836-1844） |
| 5 | 拒绝 status 不为 purged，5 条 v1 未终结无法归档 | 已验证通过 | 1113+1141 两处检查；测试循环覆盖 prepared/quarantined/purging/restored/rolled-back 五状态 |
| 6 | 拒绝 quarantine 在磁盘上存在 | 已验证通过 | Get-CodexSafeTreeDeleteNamespaceState 查磁盘（1119,1143）；测试断言拒绝且零写入 |
| 7 | 拒绝含 restore journal anchors（Test-CodexSafeTreeDeleteRestore 中断言） | 已验证通过 | restoreJournalAnchorCount!=0 则 restore-journal-anchors-present（1123-1126）；Test-CodexSafeTreeDeleteRestore.ps1:472 断言拒绝+零写入+marker 未写入 |
| 8 | 任一判据不满足时零写入，拒绝原因稳定 | 已验证通过 | 三条判据均在 mutex 前/内 return refusal；测试用文件集对比确认零写入 |
| 9 | 归档全部合格记录后 complete=true 且 migrationReadiness.ready 通过 | 已验证通过（fixture 级） | 控制面测试 944/972 断言通过；无生产 Status 报告（见未验证项） |
| 10 | 三层证据保护未削弱 | 已验证通过 | policy.json schemaVersion=4 未改动；minimumDescendantDepth=2，deniedExactPaths 含 safe-tree-delete；BackupRetentionPolicy.ps1:648 run-evidence Manual=$true 未改动 |
| 11 | policy schema 仍为 v4，未激活 v5 | 已验证通过 | managed/safe-tree-delete/policy.json 第 3 行 schemaVersion=4；diff 确认未改动 |
| 12 | 既有全部测试保持通过 | 已验证通过 | 全部 9 个测试文件 EXIT_CODE=0（详见测试执行结果） |
| 13 | 不新增测试 seam | 部分实现（见发现#1） | 主线测试均通过扩展后的 Invoke-CodexSafeTreeDeleteFixture.ps1；但 commit 3d4c647 新增了两个直调库函数的辅助文件 |


---

## 归档判据安全分析

### 三条判据强制强度

**判据 1：transactionStatus 必须为 purged**
- mutex 外（line 1113）和 mutex 内（line 1141）各做一次强制检查。
- status 来自磁盘实时读取：Read-CodexSafeTreeDeleteArchiveSource 验证 transaction.json 的 ApprovedTransactionSha256（line 909），再通过 Read-CodexSafeTreeDeleteObservedV1Transaction（v1）或 ConvertTo-CodexSafeTreeDeleteStrictTransactionDocument（v2/v3）解析 status 字段。
- 所有三条判据均为提前 return，AND 关系，无短路旁路，无开关可跳过。

**判据 2：quarantine 在磁盘上不存在**
- 通过 Get-CodexSafeTreeDeleteNamespaceState -Path $source.quarantinePath 查磁盘（line 1119 和 1143），返回 .present 布尔值。
- 确认：这是真实文件系统查询，不是读事务文档字段。quarantine 路径由 plan.json 的 targetPath+generationId 推导（line 855-857），不信任 transaction.quarantinePath。
- 无法通过伪造事务文档绕过。

**判据 3：不含 restore journal anchors**
- v1 事务：restoreJournalAnchorCount 硬编码 0L（line 926）；Assert-CodexSafeTreeDeleteExactProperties（line 765）强制精确属性集，v1 schema 禁止出现 restoreJournalAnchors 字段——有则 throw。v1 结构上不可能携带 journal anchors，此判据对 v1 恒真。
- v2 事务：schema 无 restoreJournalAnchors 字段，精确属性校验禁止出现，restoreJournalAnchorCount 保持 0L。
- v3 事务：AllowArchiveRestoreAnchorRefusal=$true 允许读取含 anchors 的文档而不立即 throw（line 939），计数后（940-941）由 archiver 判断拒绝。测试：含 anchors 的 purged v3 → 拒绝且零写入（Test-CodexSafeTreeDeleteRestore.ps1:472）。

### 标记可信度

Read-CodexSafeTreeDeleteTerminalArchive 在 Status 读取时验证（line 983-1082）：
1. 标记中 transactionSha256 与磁盘 transaction.json 当前哈希完全匹配。
2. 标记中 planSha256 与磁盘 plan.json 哈希匹配。
3. planIdentity 和 transactionIdentity 与当前磁盘文件 inode/volume identity 匹配（防文件替换）。
4. 当前磁盘 transactionStatus 仍为 purged。
5. quarantine 在磁盘上当前不存在。
6. restoreJournalAnchorCount 当前为 0。

测试验证：伪造 transactionSha256 → Status 返回 manual-review（控制面测试 ~line 1000）；bytes 不变但替换文件 identity → Status 拒绝并报 identity 错误。

### 可绕过路径分析

无已知可绕过路径。证据根三层写保护（policy deniedExactPaths、minimumDescendantDepth=2、BackupRetentionPolicy Manual=$true）从外部封锁任意修改。受管路径内，修改需要通过 ApprovedTransactionSha256，且 mutex 内 double-check 防漂移。

---

## 关键发现

### 发现 #1（低严重性）：两个新 helper 直接调用库函数，违反父 spec no-new-seam 约束

tests/Invoke-CodexSafeTreeDeleteRestoreCrashFixture.ps1 和 tests/Open-CodexSafeTreeDeleteProducerLeaseFixture.ps1 在 commit 3d4c647 新增，直接 dot-source 并调用 Invoke-CodexSafeTreeDeleteRestore 和 New-CodexSafeTreeDeleteProducerLease，绕过 Invoke-CodexSafeTreeDeleteFixture.ps1 主 seam。父 spec（issue-11 Testing Decisions）明确写明不引入第二个 seam。

这两个文件用于崩溃注入和进程间锁测试，主 seam 无法承载（需要子进程在指定阶段阻塞）。功能上合理，但违反 spec 字面约束。**不影响生产行为和安全保证**。

建议：在父 spec Testing Decisions 中补充说明崩溃注入类子进程 helper 不计为受管 seam 的例外条款。

### 发现 #2（信息级）：archivedAtUtc 使用系统壁钟

来源为 [datetimeoffset]::UtcNow（line 1167），非 Get-CodexSafeTreeDeleteTrustedElapsedTimeSample 机制。Issue #17 要求仅为"含归档时点"（可追溯记录），不用于任何计时判决，系统壁钟满足需求。无安全影响。

---

## 测试执行结果

| 测试文件 | 退出码 | 摘要 |
|---------|--------|------|
| Test-CodexSafeTreeDelete.ps1 | 0 | 12 slices |
| Test-CodexSafeTreeDeleteControlPlane.ps1 | 0 | 10 slices（含全部 archive 路径） |
| Test-CodexSafeTreeDeleteRestore.ps1 | 0 | 含 archive 拒绝 restore journal anchors |
| Test-CodexSafeTreeDeleteStatus.ps1 | 0 | 17 slices |
| Test-CodexSafeTreeDeleteSchemaCompatibility.ps1 | 0 | 10 slices |
| Test-CodexSafeTreeDeleteCrashSafety.ps1 | 0 | 11 scenarios |
| Test-CodexSafeTreeDeleteGrace.ps1 | 0 | 10 slices |
| Test-CodexSafeTreeDeleteMetricsEvidence.ps1 | 0 | 2 datasets x 9 stages |
| Test-CodexSafeTreeDeleteBenchmark.ps1 | 0 | 2 datasets |
| Test-CodexSafeTreeDeleteProductionSmoke.ps1 | 未运行 | 需要生产 evidence root |

---

## 未验证项

1. **生产侧 complete=true 和 migrationReadiness.ready**：fixture 级测试通过，但无生产 Status 报告（reports/ 下未见 sdd-status 输出）。主 agent 应运行 -Mode Status 验证生产侧收敛效果。

2. **Test-CodexSafeTreeDeleteProductionSmoke.ps1**：未运行（需要生产 evidence root）。

3. **BackupRetentionPolicy Manual=$true 的端到端有效性**：BackupRetentionPolicy.ps1:648 确认声明存在且未改动，但无法在本次审计中验证 retention 工具是否实际读取并执行该标记（属 backup retention 系统范围）。
