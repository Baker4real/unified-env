# AC9 / AC8 静态核验记录（HEAD cd7661f，2026-08-19）

## AC9：证据根三层保护未改动

三层保护在 HEAD 的位置与现状：

1. **policy denylist**：`managed/safe-tree-delete/policy.json` 的 `codex-run-evidence` 条目
   `deniedExactPaths: ["D:\\Codex\\.codex\\run-evidence\\safe-tree-delete"]`（现场读取确认）。
2. **最小后代深度**：同条目 `minimumDescendantDepth: 2`。
3. **retention 的 Manual 标记**：`scripts/lib/BackupRetentionPolicy.ps1` 第 648 行
   `@{ Relative = 'run-evidence'; Reason = '运行证据根不得自动清理。'; Manual = $true }`。

未改动证据（git 历史命令与结果）：

```text
$ git log --oneline -3 -- managed/safe-tree-delete/policy.json
5f7f597 wip: park remaining host-safety and host WIP off main   <- 2026-08-18
ec05faf feat: govern .NET bundle cache cleanup
af25faf ...

$ git show 5f7f597 -- managed/safe-tree-delete/policy.json   # diff 仅新增无关条目
  "clock-countdown-intermediate-ui-references"（capabilityRoot=D:\Codex\projects\时钟倒计时\assets\ui-references,
  minimumDescendantDepth=3）；codex-run-evidence 条目与 schemaVersion 均未出现在 diff 中。

$ git log --format='%h %ad %s' --date=short -5 -- scripts/lib/BackupRetentionPolicy.ps1
d54ef60 2026-07-22 fix: reconcile upgraded host governance   <- 最后变更，早于 #22 执行（2026-08-13/14）
```

即：#22 归档执行时点（2026-08-13/14，见 acceptance.json startedAtUtc=2026-08-13T17:32:37Z）至今，
denylist、最小后代深度、retention Manual 三者代码与配置均无变更；5f7f597..HEAD（4 个 commit）
零文件触碰。执行时点核验另见 `reports/safe-tree-delete-issue22-20260815/protection-check.json`
（policySchemaVersion=4、evidenceEntry 三件套、retentionManual.manual=true）。

## AC8：归档判据代码未被改动

判据函数：`scripts/lib/CodexSafeTreeDelete.ps1` 的 `Invoke-CodexSafeTreeDeleteArchive`（#17 引入于
commit 6d68fb4，2026-08-10「feat: complete safe tree delete control plane follow-ups」；#17 票面即
「受管归档：让已确认 terminal 的记录退出 blockingRecords」，GitHub state=CLOSED）。

三条判据在函数内出现两份（mutex 外预检 + mutex 内复验），文本：

```powershell
if ([string]$initial.transactionStatus -cne 'purged') {
    return New-CodexSafeTreeDeleteArchiveRefusal -Reason 'transaction-status-not-purged' ...
}
if ([bool](Get-CodexSafeTreeDeleteNamespaceState -Path $initial.quarantinePath).present) {
    return New-CodexSafeTreeDeleteArchiveRefusal -Reason 'quarantine-present' ...
}
if ([long]$initial.restoreJournalAnchorCount -ne 0L) {
    return New-CodexSafeTreeDeleteArchiveRefusal -Reason 'restore-journal-anchors-present' ...
}
```

逐字节对比（提取命令见下，diff 副本在同目录 `ac8-archive-function-6d68fb4-vs-HEAD.diff`、
`ac8-archive-helpers-6d68fb4-vs-HEAD.diff`）：

```text
$ git show 6d68fb4:scripts/lib/CodexSafeTreeDelete.ps1 | sed -n '1101,1211p' > fn-6d68fb4.ps1
$ sed -n '2387,2497p' scripts/lib/CodexSafeTreeDelete.ps1                  > fn-HEAD.ps1
$ diff -u fn-6d68fb4.ps1 fn-HEAD.ps1
（零差异；两版本函数体 111 行逐字节一致。注：函数体为 111 行——6d68fb4 位于 1101–1211、HEAD 位于
2387–2497，行 1212/2498 是函数与下一函数之间的空行；本目录归档的
ac8-archive-function-6d68fb4-vs-HEAD.diff 生成时窗口含该尾随空行（1101–1212 / 2387–2498 共 112 行），
含空行仍逐字节一致，结论不变）

判据支撑函数：
$ git show 6d68fb4:scripts/lib/CodexSafeTreeDelete.ps1 | sed -n '830,1086p' > helpers-6d68fb4.ps1
$ sed -n '2121,2386p' scripts/lib/CodexSafeTreeDelete.ps1                  > helpers-HEAD.ps1
$ diff -u helpers-6d68fb4.ps1 helpers-HEAD.ps1
唯一实质差异：Read-CodexSafeTreeDeleteArchiveSource 内联的 plan 属性断言被替换为共享 helper
Assert-CodexSafeTreeDeletePlanDocumentProperties（e2064a3，2026-08-13，#27-#31 统一所有 plan 读取）。
该 helper 要求的 12 个必备属性与旧内联清单完全相同，另允许 2026-08-13/15 落地的可选字段
fileIdentitiesV2 / leafStreamSetV1（spec 2026-07-24 第 25 行明文）。这是 plan 文档 schema 的统一
演进，不是 Archive 判据变化：三条判据读取的是 transaction 的 transactionStatus / quarantine
namespace / restoreJournalAnchors，与 plan 属性集无关。
New-CodexSafeTreeDeleteArchiveRefusal 两版本逐字节一致（diff-exit=0）。
```

行区间历史（`git log -L`）显示 6d68fb4 之后仅 e2064a3（上述 helper 替换）与 4d9b979（2026-08-18，
#33/#39 把整个函数在文件内原位搬移，`git show 4d9b979` 的 +/- 两侧判据文本逐字相同）触过该函数
所在行；16a3b48、4c80415、3198989、cd7661f（5f7f597..HEAD）零触碰。
