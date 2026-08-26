---
type: report
title: run-evidence 迁移方案（2026-08-24 v6 执行契约，已执行）
tags: [历史计划, run-evidence, 迁移]
intent: 记录 jia-li 旧根到新根的迁移执行合同与勘误
---

# run-evidence 迁移方案（修订执行契约 v6）

- 日期：2026-08-24
- 状态：v5 在 2026-08-24 追加对抗审查中被判 `no-go`；v6 已把 3 个 P1 与全部伴随 P2 写入执行合同，尚未执行、测试、迁移、注册任务、commit 或 push
- 目标：把 `D:\Codex\.codex\run-evidence\` 整树迁移到 `D:\agents\run-evidence\`，后续所有活跃写方默认写新根，不再写旧根，旧根删除
- 本文档是自包含执行契约；system、developer、用户和项目规则优先。本文只授权后续执行者按已确认边界准备与验收，不替代迁移、递归删除、计划任务、commit/push 或外部状态变更所需的单独授权
- 让步顺序：数据和安全元数据完整 > 可逆回滚 > 写方闭包与告警连续性 > 功能验证 > 速度。文中的“必须/只允许/拒绝”是硬门槛，“建议”可由执行者用更强且有证据的办法替代并在迁移报告中说明
- 断点续作只读写迁移报告目录中的状态机 checkpoint；不新建 `PROGRESS.md`。关键行号以执行时实时文件为准，引用行号均为 2026-08-24 实测

## 勘误（2026-08-26，按 Tailscale 登记核验）

- 本文 :26“本机 hostname=BAKER=zi-xi-shi（自习室/study）”系误标：本机 Tailscale 登记名为 `jia-li`（家里），Windows 主机名 `Baker`；`zi-xi-shi`（自习室）是另一台独立 Windows 设备，不是本机。本文中“本机”均指 `jia-li`。
- 阶段 7 与完成条件中的“home/office 都完成各自迁移”“home/office 均迁移”应读作“`zi-xi-shi`（自习室）与 `ban-gong-shi`（office）各自迁移”；`jia-li`（home，本机）的迁移已完成。
- 设备文档现行版本：统一环境仓库 `docs/environments/jia-li.md`（本机，家里）与 `docs/environments/zi-xi-shi.md`（自习室 stub）。

## 0. 关键事实（已实证）

- 旧根 `D:\Codex\.codex\run-evidence\`：316,234 文件 / 约 109 GiB / 46,959 目录 / 372 顶层条目；与新根同卷 D:（Move-Item 对顶层条目为 rename 语义，O(1)）；3,819 条 >259 字符路径（不影响 rename）；980 个只读文件（不影响 rename）。
- 新根 `D:\agents\run-evidence\` 已存在，v5 基线仅有 `display-debug`、`dwm-debug` 两条目，与旧根顶层零同名冲突；双方都非 junction。执行时必须重测，任何新增同名条目都在第一次 move 前失败闭锁，不做 merge、覆盖、`/XO` 或“较新者优先”裁决。
- 树内已知 7 个 reparse point：6 个 fixture junction 绝对目标指向旧根内部（2 个在 `daily-codex-ecosystem-update\20260723-020447\staging\candidate-validation-root\`，4 个在 `workflow-asset-harvester\` fixture），1 个 `clock-countdown-close-46-49\probe-fixture\app` 的历史目标为 `D:\Codex\projects\时钟倒计时\app`，该目标现已不存在。它们是历史证据的一部分，迁移中不删除、不重建、不改 target；顶层目录同卷 rename 不遍历 target，迁后内部绝对 junction 允许成为登记在册的历史断链。
- 1 个 ACL fixture 目录 `codex-agent-governance-exec-7d55…\owner-fixture` access denied（故意 fixture，不阻塞其父 rename；计数口径需同工具同旗标）。
- 活跃写方通常会自建目录（New-Item -Force / mkdir parents），漏改者不会报错，只会静默重建旧根；v5 的“所有写方已闭合”断言已被现役 `codex-account-switch\docs\environments\windows-dual-host.md` 旧根指针推翻，v6 必须以执行时 writer/default/doc/task 全闭包扫描为准。
- 哈希完整性链（三钉，规则不同）：`managed\codex-hooks\manifest.json` 的 files[].sha256 = **raw 字节** sha256；`host-preflight-manifest.json` = **canonical（CRLF→LF 归一）**；`codex-state-preflight.py:21 EXPECTED_STATE_CORE_SHA256` = policy-guard **raw 字节**。4 个待改 hook 文件当前全 LF（raw==canonical 数值相等），编辑必须保持 LF。
- `managed\codex-hooks\legacy-fixture-manifest.json` 虽保留 legacy 路径/fixture 语义，`Test-CodexHookInventory.ps1:80-89` 仍把其 files[].sha256 当当前 managed source 的 raw-hash oracle；任何被改 managed hook 都必须同步更新这里的 raw hash，不能整份“不动”。
- 4 个 hook 文件 deployed（`D:\Codex\.codex\hooks\`）与 managed（`统一环境\managed\codex-hooks\hooks\`）当前逐字节一致。
- `Invoke-CodexHostHookReconciliation.ps1:756` 硬要求旧根存在（TOML pycache 隔离根，字面量）；`:370` fixture seam、`:3642` Restore 证据根均为 `Join-Path $ResolvedCodexHome` 派生；`CodexHostHookEvidence.ps1:14` 同 pattern 且 capability 锚定 CodexHome。
- reconciler 还有生产可达的 capability 锚点：`Invoke-CodexHostHookReconciliation.ps1:3008-3011` 的 `.claims` 与 `CodexHostHookEvidence.ps1:15,19,21,25,27`。新 evidence 路径若仍用 `$ResolvedCodexHome` 作 capability root，会被 `CodexHostSafety.ps1:544-556` 确定性拒绝。
- `CodexSafeTreeDelete.ps1:3909` 硬要求证据根存在（Status throw）；safe-tree-delete `policy.json` 仅 `统一环境\managed\safe-tree-delete\policy.json` 一份（无 deployed 副本，`Invoke-CodexSafeTreeDelete.ps1:35` 直读）；Status 无计划任务/自动调用方。
- safe-tree-delete policy 换根后旧根无 capability 覆盖，残余只能手工 Move-Item/rmdir（有意决策，空壳 rmdir 不违反 AGENTS.md:37 受管删除规则）。
- `robocopy` 默认 `/COPY:DAT`、`/DCOPY:DA` 不保留 owner/audit，且 `/MOVE` 会在复制后删除 source；旧树已实测存在文件 owner=`BUILTIN\Administrators`、父目录 owner=`BAKER\WINDOWS` 的差异。因此 v6 禁止用 robocopy merge 搬运任何旧根条目，计数也不得替代 ACL/owner/stream 与对象 identity 证明。
- cc-switch/.claude/.grok 的 skill 均为指向 `D:\Codex\.codex\skills\` 实体的 symlink；skill 编辑只改 D: 实体。
- 本机 hostname=BAKER=zi-xi-shi（自习室/study）；`ban-gong-shi.md` 是办公室机器文档，不可由本机证据更新。
- 计划任务：`Cursor Daily Codex Ecosystem Update` 每日 02:00 跑 `Invoke-CursorDailyCodexEcosystemUpdate.ps1 -Mode Run`（不显式传 -EvidenceRoot）；`Codex Remote Plugin Catalog Guard` 常驻 Watch 本身不写 run-evidence，但 manager 维护模式（`统一环境\scripts\Invoke-CodexRemotePluginCatalogGuard.ps1:899`）会 New-SafeDirectory 旧根；`Reconcile CC Switch Skill Links` 不写 run-evidence，但会与 skill 编辑共享状态。三者在准备/切换窗口都必须记录原状态、禁用并确认非 Running，完成后逐一恢复原状态。
- 当前 Codex 会话本身属于 `codex*` 进程，不能一边要求 `Get-Process codex*` 为空一边由同一会话继续执行，也不能按进程名推断 ownership 后强杀。最终冻结、搬运和早期回滚必须由 D 盘报告目录中的外部 PowerShell Core 7 runner 接管；用户手工关闭 Codex，runner 只等待零进程，不执行 `Stop-Process codex*`。
- `purge-explicit-retired-artifacts.cjs`：目标缺失时 :1020-1022 记 state:'absent'，apply 循环 :1491-1498 对非 ready 目标 continue，属 benign skip；`:17 STALE_OPEN_DESIGN_SNAPSHOT` 用于 stale-provenance 检测必须保留旧值（正斜杠形态）；relativeParts（:419,490,549,570）锚定 `D:\Codex` 不动。

## 1. 固定选择与执行前授权点

1. **D-purge 固定跳过**：本次不运行 `purge-explicit-retired-artifacts.cjs`，不把退役树删除混入根迁移。点名退役树随迁到新根；未来删除另立任务，重新取得授权并使用当时的 safe-tree-delete 合同。
2. **git commit 锚点**：统一环境 commit 需用户授权（默认规则：不擅自 commit）。
3. **外部 runner**：最终冻结与 cutover 由用户手工启动的 PowerShell Core 7 runner 执行；若改为一次性计划任务启动，必须另获计划任务注册授权。
4. **30 天哨兵**：注册持续 watcher、每日健康检查和最终自清任务需用户授权；未授权时迁移最多停在“本机切换已验证，双容清退未开始”，不得声称 30 天门槛已覆盖。

登记债务（无需决策，声明即可）：迁移前 hook-reconciliation restore 点作废（阶段 0 记录最后可用 restore 点）；codex-gsd 历史 run 不可 rollback（`Rollback.psm1:445-447` backupManifestPath 绑定）；对端（home/office）推送配置仍指本机旧根的 inbound staging 互操作债；远端 staging schema 与设备文档继续保留旧根语义。codex-gsd 双容清退是后续独立任务，条件=对端均迁移且本机 watcher 连续 30 天无事件、无 overflow、无 heartbeat gap，不能由 T+24h 抽样替代。

## 2. 执行

实际执行顺序：0.1-0.7 → 阶段 2（含 2.15 pre-cutover 测试）→ 0.8-0.10 → 阶段 3→4→5→6→7。

### 阶段 0　准备、基线与可逆锚点

1. 迁移证据唯一汇为 `统一环境\reports\run-evidence-migration-<ts>\`（两根之外）；建立 `state.json`，状态只允许 `preparing -> ready-for-quiesce -> quiesced -> moving -> validating -> reopened -> monitoring`，每次跃迁记录前置证据、UTC 时间和 runner identity。状态不匹配时停止，不能跳阶段。回退跃迁合法：允许回到链上较前状态，须在 state.json 记录 from/to/原因/UTC/runner identity；“不能跳阶段”仅禁止向前跃过中间态。本文所有“登记”动作写入报告目录 `decisions-ledger.jsonl`，最小字段：UTC、身份（agent/runner）、类别（debt/registration/waiver/decision）、主题、证据路径、内容。
2. 记录 `Cursor Daily Codex Ecosystem Update`、`Codex Remote Plugin Catalog Guard`、`Reconcile CC Switch Skill Links` 的定义、State、LastTaskResult、触发器和进程树；临时禁用并确认非 Running。准备阶段不调用这些脚本、4 个待改 skill、safe-tree-delete mutation 或任何仍使用旧默认值的维护入口。
3. git 锚点以**执行时** `git status` 为准；统一环境及三个项目仓只允许修改本文白名单中的路径。经授权 commit 时记录 commit；未授权 commit 时记录 HEAD、task-owned diff 和每个 task-owned 文件的 pre-image SHA-256。回滚只对 task-owned 路径执行 `git restore --source=<anchor> -- <exact paths>`，不使用整仓 checkout/reset，不覆盖用户改动。
4. 所有非 Git、deployed、automations、skill 与计划任务文件逐字节备份到 `backups-live\`，manifest 记录真实路径、length、mtime、raw SHA-256、ACL SDDL、owner 和 stream 清单；恢复必须逐项核验 manifest，不能只复制 4 个 hook 文件。
5. 重跑 writer/default/doc/task 闭包扫描：扫描模式固定为绝对旧根双形态 `(?i)D:[\\/]+Codex[\\/]+\.codex[\\/]+run-evidence`（裸 `rg 'run-evidence'` 会命中新根 leaf 名与 fixture 相对构造，不可用）；扫描根集合=生产源码、managed/deployed 副本、automations、skills、现役设备文档、计划任务 Action/Arguments、环境变量、入口脚本，逐项分类为 `local-new`、`remote-old`、`fixture/history` 或 `must-fix`。任何未分类旧根命中、不可读的现役文件或新增写方都阻塞 cutover；历史报告和 provenance 只进白名单，不改写。
   - 以 live 旧默认值跑 reconciler 基线：`& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\agents\projects\统一环境\scripts\Invoke-CodexHostHookReconciliation.ps1' -Mode Check`，存 `reconciler-check-baseline.json`（逐 check name 的 ok 集合与漂移文件集合），供阶段 4.5 比较。
   - 记录最后可用 hook-reconciliation restore 点（host-hook-remediation 最新 evidence run-id/路径）入 ledger。
6. 建立有限批次 scope manifest：旧根全部顶层条目、新根既有条目、source/destination 规范路径、D: volume identity、每个顶层对象 file ID、类型、length/count 投影和错误账本。旧根与新根不在同一 volume、任一祖先是 reparse point、或任一顶层目标同名时，第一次 move 前停止。
7. 对 `safe-tree-delete`、`codex-hook-health` 生成递归完整性 manifest：相对路径、类型、length、mtime、regular-file raw SHA-256、owner、ACL SDDL 和 stream name/size/hash；对全树 reparse point 记录 relativePath、tag、target、原始 reparse bytes hash 与可读状态。ACL fixture 的 access denied 作为具名错误单位，父目录 rename 不遍历它，但不得把“未读取”报告成“无 reparse”。
8. 先完成阶段 2 的代码/文档修改与阶段 2.15 的 pre-cutover 测试。managed source 可在三个任务已禁用时修改；deployed hook 与计划任务定义保持旧版本，直到外部 runner 接管。所有 pre-cutover 运行使用 fixture 或唯一 `migration-preflight-<ts>` evidence 子树，不得预建与旧根同名的 production 目标域。
9. 在报告目录生成外部 runner 与 `runner-manifest.json`，绑定脚本 raw SHA-256、PowerShell Core 7 路径（统一 `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`，runner-manifest 绑定时以实测为准）、cwd、允许路径、状态机和回滚动作。runner 不结束未知进程、不创建 branch/worktree、不 commit/push；运行方式由决策点 3 确定。
10. 当前 Agent 写入 `ready-for-quiesce` 后停止实现动作。用户手工关闭 Codex/Cursor/Claude/Grok 交互会话；外部 runner 只等待 `Get-Process codex*` 为空，并复核三任务 Disabled/非 Running。零 delta 口径：范围=旧根、新根、`D:\Codex\.codex\hooks`、`D:\Codex\.codex\automations`、三个计划任务定义导出；字段=相对路径+类型+length+LastWriteTimeUtc 的名称级清单（109 GiB 不做全量 hash：全量读取成本高且对“无写入”判定无增量价值，名称级清单已能检出新增/删除/改名/mtime 变化）；工具=`robocopy <src> %TEMP%\nonexistent /L /S /XJ /NFL /NDL /NJH` 或等价 Get-ChildItem 导出排序后 Compare-Object；判据=两份相隔 ≥10 分钟、同工具同旗标的导出零差异，不满足则回到 writer 定位，不能强杀或宽松放行。零进程、三任务 Disabled/非 Running、零 delta 全部通过后 runner 写 `state=quiesced`。

### 阶段 1　reparse 与目标根合同

1. 保留新根既有 `display-debug`、`dwm-debug` 及唯一 preflight 证据条目；不预建 `safe-tree-delete`、`codex-hook-health` 或任何与旧根顶层同名的目录。目标同名冲突一律停止并请求精确 merge 决策，本方案没有 merge 分支。
2. 已知和新发现的树内 reparse point 全部作为 opaque evidence 随其顶层父目录同卷 rename；不调用 `Remove-Item`、`rmdir`、`fsutil reparsepoint delete` 或 safe-tree-delete 改变它们。迁后断链写入 terminal manifest，主动消费者继续使用 `/XJ`/不跟随 reparse 的扫描方式。
3. move manifest 预先冻结 372 个基线顶层单位（执行时以 scope manifest 实数为准），每个单位只允许 `pending/moved/reversed/failed`。move manifest 落报告目录 `move-manifest.jsonl`，字段=relativeName、type、sourceFileId、destFileId、length/count、state（pending/moved/reversed/failed）、error；file ID 获取：pwsh 打开句柄后 P/Invoke `GetFileInformationByHandle`（无需管理员），volume identity：`Get-Volume -DriveLetter D | Select-Object -ExpandProperty UniqueId`。完成判定要求 `scope_total = moved + reversed + failed + pending` 且每个相对名唯一；任何 `failed/pending` 都使迁移非完成。

### 阶段 2　准备改动（语义化改写；保持 LF；2.1→2.2→2.12 单 writer 串行）

本阶段允许修改 Git-managed source、tests 和 docs；三个相关任务保持 Disabled，禁止手工调用受影响入口。所有 deployed hook、计划任务定义和需要在 Codex 关闭后才安全切换的 live 文件先生成 candidate bytes 与 SHA-256，阶段 3 由外部 runner 按 manifest 一次发布。pre-cutover 测试只能写 fixture 或唯一 `migration-preflight-<ts>` 证据域，不能预建旧根中已有的 production 顶层域。

**2.1 hooks 五件套（先改 managed；deployed 只生成 candidate，禁止独立重改）**

- `统一环境\managed\codex-hooks\hooks\lib\CodexHookRuntime.ps1` :276 `:313`（字面量换新根）
- `hooks\codex-state-preflight.py` :17 → 显式改写为 `PRODUCTION_HEALTH_ROOT = Path(r"D:\agents\run-evidence\codex-hook-health")`；**:16 `PRODUCTION_CODEX_HOME` 不动**（状态文件路径依赖它）
- `hooks\codex-state-policy-guard.py` :37（字面量）
- `hooks\serena-behavior-guard.ps1` :420、:626（仅 production 段；:439/:642 fixture Join-Path 逻辑不动）
- 为 managed→deployed 共 4 文件（preflight.py 为 4 之一）生成精确 destination 与 raw SHA-256 manifest；阶段 3 才 Copy-Item 到 `D:\Codex\.codex\hooks\` 对应位置，复制后逐字节核验

**2.2 哈希原子单元（与 2.1 同 writer 串行）**

- 重算 policy-guard 新 raw sha256 → 更新 managed + deployed-candidate 两份 preflight.py 的 `EXPECTED_STATE_CORE_SHA256`
- 4 个改动 hook 文件 canonical（CRLF→LF）哈希 → `host-preflight-manifest.json` files[].sha256；raw 哈希 → `manifest.json` files[].sha256（LF 下两值同数）
- 两份 manifest 的 codex-hook-health writeResources 路径换根
- `legacy-fixture-manifest.json` 保留 commandPath、writeResources 和 legacy fixture 路径语义，但对每个被改 managed source 同步更新 files[].sha256 为新 raw SHA-256；`Test-CodexHookInventory.ps1:80-89` 必须继续检查当前 source，禁止 skip、改成 canonical 或放宽断言
- 负向验证：对内存/临时 fixture 中一个 legacy hash 注入已知旧值，`Test-CodexHookInventory.ps1` 必须变红；恢复正确 hash 后再跑绿，临时 fixture 不落到 managed/live 路径

**2.3 reconciler / CodexHostHookEvidence（production/fixture 分裂）**

- 新建单一 scope resolver（名称可服从模块现有命名），一次返回 `{runEvidenceRoot, remediationRoot, capabilityRoot, isFixture}`：live `ResolvedCodexHome=D:\Codex\.codex` 时三根锚定 `D:\agents\run-evidence`；受控 fixture 时继续锚定 `Join-Path $ResolvedCodexHome 'run-evidence'`。调用方不得自行二次推导 capability root。
- `统一环境\scripts\Invoke-CodexHostHookReconciliation.ps1`：:756 TOML pycache 使用 resolver 的 production runEvidenceRoot；:3642 `Resolve-RestoreEvidencePath` 使用 remediationRoot；:3008-3011 的 `.claims` 使用同一 capabilityRoot；New/Read restore contract 及其调用点共享该 scope。`:370` fixture seam 的预期路径由 fixture scope 派生，fixture 行为不变。
- `统一环境\modules\codex-host\CodexHostHookEvidence.ps1`：`New-CodexHostHookEvidenceSnapshot` 接受/解析同一 scope；:14-27 的 run root、evidence root、run path、ACL 与 New-CodexHookCapabilityDirectory 全部使用 scope 中配对的 root/capabilityRoot，不能只改 :14 字面量。
- 静态闭包门：枚举 production 可达的全部 `-CapabilityRoot $ResolvedCodexHome`；凡被保护 Path 可落到 `D:\agents\run-evidence` 的调用必须归零。fixture-only 调用保留并由 marker/fixture root 证明不可达 live。
- 行为门：新增 production-scope fixture，证明 Repair snapshot、restore-contract、`.claims` 与 Restore 都落新根并通过 containment；现有 25+ fixture 断言继续证明非默认 CodexHome 仍使用 fixture-local run-evidence。

**2.4 统一环境 scripts/ + lib/ 14 文件 + modules/ 2 文件（旧根→新根）**

- `scripts\Deploy-SkillInstallGuarded.ps1:5`、`Deploy-GitHubDefaultBranchSkillOverlay.ps1:47`（含 :48-50 controlledRoot 拒绝逻辑）、`Apply-GitHubDefaultBranchSkillOverlay.cjs:16`、`Get-CodexStatePathInventory.ps1:37`、`Invoke-CodexSafeTreeDelete.ps1:36`、`Invoke-CodexRemotePluginCatalogGuard.ps1:22`、`New-BackupRetentionDryRun.ps1:29,32,50`、`New-BackupRetentionApplyManifest.ps1:20`、`New-CodexAccountSwitchDependencyUpdateDryRun.ps1:80,89`、`New-ProjectLocalEnvRebuildDryRunPlan.ps1:69,78,86,95`、`New-ProjectLocalEnvReviewPack.ps1:93,102`、`New-StalePathEntryCleanupDryRun.ps1:71,80`、`scripts\lib\CodexHookProductionFull.ps1:14`、`scripts\lib\CodexHookProductionRegistrationRepair.ps1:73`
- `modules\skill-supply-chain\implementation\install_skill_guarded.py:72`、`reconcile_skill_source_records.py:41`

**2.5 deployed scripts（`D:\Codex\.codex\scripts\`，显式 6 文件）**

本节文件按阶段 2 头部规则只生成 candidate bytes 与 SHA-256，阶段 3 由 runner 按 manifest 一次发布。

- `install_skill_guarded.py:60`、`Apply-GitHubDefaultBranchSkillOverlay.cjs:16`、`Install-StudyToHomeSshAuthorization.ps1:10`、`Invoke-CursorDailyCodexEcosystemUpdate.ps1:23`、`purge-explicit-retired-artifacts.cjs:13`（仅 DEFAULT_EVIDENCE_ROOT；**:17 与 relativeParts 不动**）、`test_install_skill_guarded.py:18`（属"改"不属白名单）

**2.6 automations（四方同步）**

本节文件按阶段 2 头部规则只生成 candidate bytes 与 SHA-256，阶段 3 由 runner 按 manifest 一次发布。

- `D:\Codex\.codex\automations\cursor\prompt.txt:16`、`cursor\automation.toml:14`（latest_report）、`codex\automation.toml`（PAUSED 也改，防重新启用写旧根）、`codex\memory.md` **仅 :5 行**（dated 历史行不动）

**2.7 Invoke-RetiredProjectSnapshotSanitizer.ps1（统一环境 scripts\）**

- evidence 类目标引入第二 scope root = **`D:\agents`**（不是 `D:\agents\run-evidence`——:487-511 相对枚举 `run-evidence\...`，防双嵌套静默零覆盖）
- 第二根仅在 fixture=$false 时加入（fixture 测试 hermetic 零改动）
- :360 live 拒绝守卫扩展 `D:\agents`/`D:\agents\run-evidence` + 平行拒绝测试
- :370 fixture regex（锚 `\.codex$`）扩展以支持新 scope 形状的 fixture home 校验（与"fixture 零改动"的张力说明：仅扩正则形状，不改 fixture 语义）
- `tests\Test-RetiredProjectSnapshotSanitizer.ps1` 同步入 2.12
- 阶段 4 增跑一次生产模式 Audit（只读）验证允许清单目录在新根可达且无 reparse point（`Add-RecursiveSnapshotTargets:439-441` 遇 reparse 硬 throw）

**2.8 skills 写方（D: 实体，cc-switch 侧为 symlink 不用改）**

- `D:\Codex\.codex\skills\artifact-migration\SKILL.md` :50-53 Destination Map + :66 蒸馏规则换根
- `skills\a-stock-data\SKILL.md` :12,854,1221（reports/cache 默认）
- `skills\nodesek-image-generation\SKILL.md` :66 与 :78（正斜杠形态）+ `scripts\generate_nodesek_image.py:34`
- `skills\neat-freak\references\repo-clean-closeout.md:34`
- 4 个 skill 的 SOURCE.md local changes、source ledger local_changes、skill catalog 与 closure candidate 同步在本阶段生成；阶段 2.15 跑 `D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py --strict` 和 writing-for-agents 门，阶段 3 同批发布，阶段 6 只复核 live 结果

**2.9 时钟倒计时项目**

- 项目根为 `D:\agents\projects\时钟倒计时\`。
- `Build-CountdownApplication.ps1:75`、`Deploy-OfficeCountdown.ps1:773`、`tools\Invoke-CountdownVerificationRun.ps1:8,80,122`（:8、:122 为注释行，与代码同批同字面换根）、`tools\Invoke-DesktopLauncherLatencyProbe.ps1:12,41`
- `Countdown.Core.Tests.ps1`、`Countdown.CSharp.Tests.ps1`（8 处）、`Countdown.Ui.Tests.ps1:144` 字面量**同批同字面**换根（`Countdown.Core.Tests.ps1:5463` 为 Contains 断言，与 Build:75 必须一致）
- `docs\办公室部署.md:52` 同步（:14-54 其余为根无关相对表述，不动）

**2.10 codex-gsd-codex-c-skill（四桶分类；`D:\Codex\projects\codex-gsd-codex-c-skill\`）**

桶一　双容（仅本机读取、回滚兼容或同字段确实跨本机/历史；接受两根）：
- `src\PathPolicy.psm1:4,11`（AllowedRoots）、`src\EvidenceStore.psm1:79`、`src\Rollback.psm1:451-455`（函数内 `$allowedRoots`，Test-ReplicatorRollbackInputEvidence 内局部变量；:459/:467/:477 ThrowOnDeny 同源放宽，兼容性已实证）+ `:483-484`（StartsWith 双前缀 + throw 消息双根表述）、`src\Backup.psm1:518,525,532`（fallback 读路径）+ `:599`、`src\Transport.psm1:1431`
- `src\ReplicatorRun.psm1` 的 `Get-ReplicatorRunAllowedRoots`（返回 stagingRoot + `D:\agents\run-evidence`；stagingRoot 伞耦合——该函数只服务本地 PathPolicy 门禁，不放宽远端校验，已实证）；补一条新根 RunRoot 被接受的 operator 测试
- 仅 3 份本机/历史兼容 schema 共 8 个 pattern 位点改双根交替（保留各站点原有 `^D:`/`[Dd]` 约定；Test-Json ECMA-262 兼容非捕获组交替）：`schemas\apply-evidence.schema.json:166,170,174`、`backup-manifest.schema.json:67,71`、`rollback-evidence.schema.json:172,176,180`
- scripts/ 骨架门禁：`Invoke-ReplicatorApply.ps1:37-47`、`Invoke-ReplicatorRollback.ps1:31-34,43-44,54-55,65-66`（含 throw 消息双根表述）、`Get-ReplicatorInventory.ps1:37-46`、`New-ReplicatorSourceManifest.ps1:34-36`、`Compare-ReplicatorDrift.ps1:37-39`、`New-ReplicatorPackage.ps1:39-41`、`Test-ReplicatorPackage.ps1:34-36`、`Send-ReplicatorPackage.ps1:31-33`、`Invoke-ReplicatorCoreSync.ps1:32-34`、`New-ReplicatorRunReport.ps1:414-416`、`Invoke-ReplicatorArtifactDiagnostics.ps1:33-35`（随 :29 同改）、`New-ReplicatorRunPlan.ps1:46-48`、`Test-ReplicatorSafety.ps1:28-30,52-58`、`Copy-ReplicatorUuFile.ps1:29-32`、`Invoke-ReplicatorUuCommand.ps1:27-30`（UU 两门襟约束本地 JsonOutputPath，非远端语义）

桶二　保持旧根（远端语义，对端未迁移）：
- `tools\` 4 脚本全部（`Invoke-ReplicatorRemoteApply.ps1`、`Invoke-ReplicatorRemoteCoreVerify.ps1`、`Invoke-ReplicatorRemoteRollback.ps1`、`Test-ReplicatorRemoteStaging.ps1`——在远端机器执行、约束远端路径，已实证无本地新根门禁）
- `schemas\remote-staging-validation.schema.json:168,303` 的 `remotePaths.toolPath` 与 `$defs.remoteStagePath` 继续只接受远端旧根；增加负向测试：`D:\agents\run-evidence\...` 放入任一 remote-only 字段必须 schema fail。以后迁远端时另立任务同时改 schema、4 个 remote tools、target manifest 和对端验证，不能本次先放宽 schema。
- `src\Transport.psm1:1504,1616`（远端 backupRoot/EncodedCommand）、`src\CoreSync.psm1:330`（对端 fresh-session TEMP 期望默认值；执行时先 grep 本机 source manifest environmentPolicy 是否含 TEMP/TMP 显式条目再最终定桶）、`src\SshDiagnostics.psm1:358,529`（远端诊断文本+fixture）、`config\targets.example.json:121`、OPERATOR-RUNBOOK/study.md 远端语义行

桶三　净换新根（本机写根）：
- `src\ReplicatorRun.psm1:9,440`、`src\ArtifactTransport.psm1:12`（单字面量三处自跟随：:262-263/:272/:554-558）、`src\SshDiagnostics.psm1:431`、`src\UuTransport.psm1:121`、`src\RemoteLink.psm1:66`、`src\Backup.psm1:609`（按根派生 StopRoot=当前 backupRoot 的 replicator 根：硬编码换根会使守卫遍历边界语义漂移，派生对新旧根均正确；其现值不含 run-evidence 字面量、rg 扫描命不中，靠测试兜底）
- scripts/ 本机写根骨架默认值：`New-ReplicatorBackup.ps1:32`、`New-ReplicatorRunPlan.ps1:59`、`Update-ReplicatorBackupCatalog.ps1:3,25`、`Invoke-ReplicatorArtifactDiagnostics.ps1:29`、`New-ReplicatorConflictResolution.ps1:26`

桶四　派生/参数化：
- `src\Apply.psm1:930` → 一行派生：`$replicatorTempRoot = [IO.Path]::GetFullPath((Join-Path ([string] $BackupManifest['backupRoot']) '..\..'))`（**禁止净换**——OpenSsh apply 时该模块被拷到远端执行，backupRoot 在远端为旧根，派生法两侧兼容，测试无 churn，已实证）
- `src\Apply.psm1:1263`（New-ReplicatorApplyEvidence 默认从调用方证据根派生）、`src\Rollback.psm1:960`（失败证据 JSON 合成标记串，外观性残留，登记即可）

测试与 fixture（30 脚本 + 30 fixture = 60 文件含 run-evidence）六条分类规则：
1. 活写（New-Item 真建目录/文件）→ 换根（如 `phase1\PathPolicy.Tests.ps1:227-240`、`operator\ReplicatorRun.Tests.ps1:17,26-27`）
2. 本机语义正向断言 → 换根
3. 远端语义正向断言 → **保留旧字面量**（与代码远端桶对齐；如 `phase4\RemoteApply.Tests.ps1:408,490,644,693,706`、`phase3\Transport.Tests.ps1:1686`）
4. 双容位点的正向接受用例 → **参数化为双根各一遍**（如 `phase1\PathPolicy.Tests.ps1:110-127`）
5. 负向探针/惰性历史 sample → 保留并登记
6. remote-only schema/工具一致性 → 旧根正向通过、新根负向拒绝；schema 通过但 tool fallback 到另一根属于失败，不接受“最终还能运行”

文档：`AGENTS.md`、`README.md`、`docs\OPERATOR-RUNBOOK.md`、`docs\SAFETY-RUNBOOK.md` 本机现役条款换根 + 登记"pre-migration run 不可 rollback"（Rollback.psm1:445-447 绑定语义）；`docs\adr\0001`、`docs\specs\2026-06-26-*` 归类（历史白名单或换根逐项定）；`docs\environments\` 仅改本机（study.md）本机条款，他机不动；study.md:37 inbound staging 行登记互操作债。

阶段 2.15 pre-cutover 与阶段 4 post-cutover 都从 `README.md:100-118` 实时发现入口；pre-cutover 跑全量 fixture/operator/artifact，post-cutover 只重跑生产路径与受 live root 影响的代表性组合。

登记执行时确认项（潜伏 5 项，门禁路径来自必填参数、不在自动 run 链）：`Invoke-ReplicatorJunctionMaintenance.ps1:96-98`、`Measure-ReplicatorUuTransport.ps1:76-78,88-94`、`New-ReplicatorCoreSourceManifest.ps1:34-36`、`New-ReplicatorNormalizedManifest.ps1:30-32`、`Invoke-ReplicatorSshDiagnostics.ps1:34-36`（RepairPlanPath 默认值派生自 stagingRoot，需桶决策）。

**2.11 safe-tree-delete managed policy.json**

- `统一环境\managed\safe-tree-delete\policy.json`：`codex-run-evidence` 条目 capabilityRoot → `D:\agents\run-evidence`；deniedExactPaths → `D:\agents\run-evidence\safe-tree-delete`（两项同改，漏改 deniedExactPaths 则新根下自身证据子树失去拒绝删除保护）

**2.12 统一环境 tests\ 同步（与 2.1/2.2 同 writer 串行收尾）**

- 改：`Test-CodexHookConfig.ps1:96-97`、`Test-CodexHookInventory.ps1`（继续校验 legacy raw hash并增加负向 fixture）、`Test-CodexHookPolicy.ps1:565-566`、`Test-CodexHookProductionRegistrationRepair.ps1:43,47,48`、`Test-CodexLocalHealthGuards.ps1:94-95`（修失效断言）、`Test-CodexSafeTreeDeleteProductionSmoke.ps1:37`、`Test-CodexSafeTreeDeleteParallelismBenchmark.ps1:39`、`Test-CodexSafeTreeDeletePhase3Integration.ps1:43`、`Test-CodexRemotePluginCatalogGuardVendorAbortStress.ps1:5`、`Test-GitHubDefaultBranchSkillOverlay.cjs:51,58,64,741`、`Test-CodexHostHookReconciliation.ps1`（同时覆盖 production scope 与 fixture scope）、`Test-RetiredProjectSnapshotSanitizer.ps1`（2.7 配套）
- `Test-BackupRetentionDryRun.ps1:213,227`：保留旧根条目（防旧根复活）+ 补新根断言
- 不动：`Test-CodexHookProductionFullCli.ps1:43,52`、`Test-CodexHostHookAuthority.ps1:43`、`Test-CodexHookRuntime.ps1:419`（must-not-be-read 负向探针/伪造外国路径）、`Test-ExplicitRetiredArtifactPurge.cjs:105`（fixture 内嵌历史 README）、`Test-DDrivePolicyDocs.ps1:43`（裸 token，换根后仍过）

**2.13 双侧 rg 验证**

- 对全部改动文件双侧（统一环境源 + deployed）跑闭包扫描，模式固定为绝对旧根双形态 `(?i)D:[\\/]+Codex[\\/]+\.codex[\\/]+run-evidence`（裸 `rg 'run-evidence'` 会命中新根 leaf 名与 fixture 相对构造，不可用）；残留必须落在显式白名单：
  - codex-gsd 双容桶 + 远端语义桶（2.10 桶一/桶二）
  - fixture/负向探针（2.12 不动清单）
  - `legacy-fixture-manifest.json` 的 legacy 路径/fixture 语义（hash 已按 2.2 更新，不把整文件当历史白名单）
  - 历史 provenance（见"明确不动"）
  - `purge-explicit-retired-artifacts.cjs` :17（正斜杠）、relativeParts :419,490,549,570、:1479（fixture join）
  - `generate_skill_catalog.py:53`（deployed + managed 两副本，`_EXCLUDED_DIRS` 裸名排除，新根同名仍有效）
  - `cursor\prompt.txt:20`（通用名词）
  - 类级豁免：fixture 相对构造（如 `Join-Path <fixtureHome> 'run-evidence\...'`）、裸名词/通用名词、项目相对 `.scratch\run-evidence`、负向探针变体（如 `run-evidence-outside-policy`）
  - `Test-BackupRetentionDryRun.ps1:213,227`（保留旧根防复活哨兵，属 2.12 改清单）
  - `Test-CodexSafeTreeDeleteProductionSmoke.ps1:5`（注释）
  - `scripts\lib\BackupRetentionPolicy.ps1:648`（死配置，见不动清单）
  - `Test-GitHubDefaultBranchSkillOverlay.cjs:523,781,787`（负向探针）
  - `Test-CodexHookRuntime.ps1:408,410,417,418`
  - `Test-ExplicitRetiredArtifactPurge.cjs:61,77`
  - `artifact-migration\SKILL.md:50`（项目相对 .scratch 命中）

**2.14 codex-account-switch**

- `D:\Codex\projects\codex-account-switch\scripts\deploy-remote-windows-desktop.ps1:482` 本机 EvidenceRoot fallback → 新根字面量（保留显式 override）；`scripts\check-windows-release-hygiene.mjs:142`（.scratch 负向守卫）不动；`LOCAL_PATCHES.md:122` 同步更新
- `docs\environments\windows-dual-host.md:37-38` 显式拆方向：`:37` 远端 `RemoteStageRoot` 保留 `D:\Codex\.codex\run-evidence\...`，`:38` 本机 `EvidenceRoot` 改为 `D:\agents\run-evidence\codex-account-switch`；可复制命令必须同时显式传两参数，不能让读者把本机新根套到未迁移的远端

**2.15 pre-cutover 红绿门（数据仍在旧根）**

1. 所有 hash/manifest/ledger、production/fixture capability scope、remote-only schema 负向用例、双侧旧根白名单先通过；新/改检查至少有一个可信负向控制，恢复后再绿。
2. 统一环境四模块 fixture profile（codex-host / host-safety / dev-environment / skill-supply-chain；入口 `node scripts\Run-PowerShellTests.cjs --module <id>`，cwd=统一环境根，profile 以 `modules\manifest.json` 为真源）与 `Test-ModuleBoundaries.cjs` 全绿；`Test-CodexHookInventory.ps1`、production-scope Repair/Restore fixture、safe-tree-delete policy tests 为 required。
3. 时钟倒计时运行 `Countdown.Core.Tests.ps1`、`Countdown.CSharp.Tests.ps1`、`Countdown.Ui.Tests.ps1` 及 build/ValidateOnly 的 fixture-safe 组合；根 `settings.json` 按项目规则做前后 length/mtime/SHA-256 门，所有写证据参数指向 `migration-preflight-<ts>` 或独立 D 盘 settings file。
4. codex-gsd 按 README 实时入口跑 phase1-9 + operator + artifact 全量；remote-only 新根负向与本机双根正向均为 required。
5. 任一 required 测试失败、被 skip/todo、断言放宽、mock 被测路径、`|| true` 或写入 production 新根同名域，都停止在阶段 2；恢复 task-owned source/live pre-image，数据树不动。只有全绿且 `git diff --check` 通过才写 `ready-for-quiesce`。

### 阶段 3　外部 runner cutover（发布 live candidate + 同卷 rename）

1. runner 校验自身 SHA-256、`state=quiesced`、三个任务 Disabled/非 Running、`Get-Process codex*` 为空、10 分钟零 delta、source/target volume identity 相同、顶层 scope/目标冲突与阶段 0 一致。任一不符回到 `ready-for-quiesce`，不执行第一笔写入。全部符合后 runner 写 `state=moving`，再执行发布与首笔 move。
2. 按 `runner-manifest.json` 发布所有 live/deployed candidate bytes；每个目标先核 pre-image identity/hash/ACL，再原子替换（API=`[IO.File]::Replace`）并核 post-image raw SHA-256。计划任务保持 Disabled；此时所有默认值已指新根，但没有写方运行。
3. 按冻结的 scope manifest 逐顶层条目执行 `Move-Item -LiteralPath <旧根\条目> -Destination <新根\同名条目>`，destination 必须写全且事前不存在。只允许同卷 directory-entry rename；禁止 robocopy、Copy-Item fallback、merge、覆盖、`/XO`、递归遍历或先建同名 destination。
4. 每个单位在 move 前记录 source file ID/parent identity，move 后立即核 target file ID 与类型相同，再从 `pending` 原子更新为 `moved`。任何命令非零、target 已存在、file ID 改变或 source 仍存在都停止；runner 在写方仍冻结时按 move manifest 逆序执行阶段 3 回滚，不继续下一项。
5. 所有单位 moved 后，旧根暂时保留为空目录作为反向 rename 的 parent；不得在阶段 4 通过前删除，也不得重开任何写方。新根既有 `display-debug`、`dwm-debug`、preflight 证据与 moved 集合分别对账，不能把两类混进同一个 source 计数。move manifest 全部 moved/reversed 落定、旧根仅剩空壳后 runner 写 `state=validating`。

### 阶段 4　验证

按序执行：

1. **解封闸（最先）**：live `& 'D:\Codex\.codex\hooks\codex-state-preflight.cmd' --check-only --json` 要求 ok=true（同时复核 live policy-guard raw sha == 新常量）；通过前保持 quiesce。
2. 顶层 identity 对账：每个 `moved` 单位 source 不存在、target 存在且 volume/file ID/type 与 move 前相同；`failed=pending=reversed=0`。新根 pre-existing 集合原 identity 不变，旧根除空壳外零子项。
3. `safe-tree-delete`、`codex-hook-health` 递归 manifest 逐项重算，relative path、type、length、raw SHA-256、owner、ACL SDDL、stream name/size/hash 与迁前完全一致；任何 unreadable/error 单位必须与迁前同 identity、同错误类别，不能用总数抵消差异。
4. 全树用同工具同旗标做 count/bytes/error-ledger 对账；这是 identity/metadata 之后的补充门，不单独证明完整性。reparse manifest 的 relativePath/tag/raw-bytes hash 不变；预期历史断链只允许落在阶段 1 冻结集合。
5. reconciler 先跑只读 Check，逐 check name 比较 ok/漂移集合；再跑受控 production-scope Repair/Restore smoke，要求 snapshot、restore-contract、`.claims`、manifest 全落 `D:\agents\run-evidence\host-hook-remediation` 且 capability/ACL 检查通过。现有基线漂移只能持平或减少，不能用总数掩盖新增项。
6. 统一环境 host-live 三项 VendorAbortStress、ProductionSmoke、Phase3Production 全部执行并记录业务结果；sanitizer 生产模式 Audit 只读通过；safe-tree-delete Status exit 与业务字段均正常。host-live 不再是“显式声明执行与否”的 optional 项。
7. 时钟倒计时运行 `Countdown.Core.Tests.ps1` + `Countdown.CSharp.Tests.ps1` + `Countdown.Ui.Tests.ps1`、`Build-CountdownApplication.ps1 -Clean`、`Deploy-OfficeCountdown.ps1 -ValidateOnly`、`tools\Invoke-CountdownVerificationRun.ps1`；根 `settings.json` 前后 length/mtime/SHA-256 不变。已知 flaky 分支若触发，按项目规则给原始证据并保持 required 未完成，不能用“已知 flaky”豁免整个组合。
8. codex-gsd 重跑本机新根 operator smoke、remote-only 旧根 schema/tool 一致性和跨根 rollback 代表用例；完整 phase1-9 + operator + artifact 仍以阶段 2.15 的同 revision 全绿结果为 required，revision 漂移则全量重跑。
9. 所有 required 门通过后，非递归删除已证明为空的旧根；立即复核 `Test-Path` 为 false并写 T+0 sentinel。若空目录删除失败或旧根重现，状态保持 `validating`，定位 writer，不用递归删除清场。

### 阶段 5　文档闭合验收（内容在阶段 2 准备并由阶段 3 同批发布）

以下是必须命中的完整文档白名单；阶段 5 不再临时改文，而是逐文件核 candidate/live raw SHA-256、现役语义和旧根白名单。任一漏项回到阶段 2 并在写方冻结状态下重新走 pre-cutover 门。

- `D:\Codex\.codex\docs\agent-guidance\storage-and-junctions.md`：:23 删"Codex 宿主自身的 run-evidence 仍属 CODEX_HOME"豁免句 + 补分工句（"`D:\agents\run-evidence\<domain>\<run-id>` 存程序与任务运行产生的原始运行证据（含 Codex 宿主 hook health、safe-tree-delete 事务、日更、倒计时验证）；`D:\agents\evidence\<task-slug>` 存一次性任务收口交付的整理证据包"）+ :31-33 换根
- `host-runbook.md`：以执行时 `rg -n 'run-evidence'` 实时枚举为准（2026-08-24 实测 14 处：128,412,414,416,454,507,603,620,632,634,667,754,800,818）逐条换根
- 区分规则：活跃操作文档（host-runbook、zi-xi-shi 操作行、OPERATOR-RUNBOOK 类）中的 dated 证据指针随整树迁移换根（新根路径迁后仍有效）；纯历史日志/记忆/provenance（memory.md dated 行、SOURCE.md、catalog.json、ledger、MEMORY.md）不动
- `cursor-kimi-hooks-mcp-config.md:104,130`、`github-default-branch-skill-policy.md:24-26,33,47`、`context-amplification.md:108`、`karpathy-coding-guidelines.md:10-12`、`ssh-mesh.md:26`
- `skill-operations.md:26`（仅加注新根位置，该行为裸词、与根无关）、`skill-menu-i18n-overlays.md:77`（该行为裸词历史语义，仅加注新根位置，不替换路径）
- `docs\memory-graduation\host-operations.md`（5 处）、`project-pointers.md`（3 处）——仅路径换根，不改历史语义
- 统一环境：`docs\env-governance\d-drive-layout-and-migration-policy.md:23,106`、`docs\agents\knowledge-scope.md:21`、`docs\environments\zi-xi-shi.md:110,125`（仅操作行，dated 快照行不动）、`README.md:26`、`docs\env-governance\remote-plugin-catalog-guard.md:50`、5 份现役权威 spec 的证据根条款（`docs\specs\2026-07-24-safe-tree-delete-capability.md:23`、`2026-07-11-host-hook-reconciliation-design.md:43`、`2026-07-14-skill-install-guarded-wrapper.md:36`、`2026-07-13-github-default-branch-skill-policy-design.md:149`、`2026-07-11-codex-hook-governance-design.md:101`——均为 modules/manifest.json 登记的现役合同，改动合规）
- `D:\Codex\projects\README.md:15`
- codex-gsd 文档（见 2.10）
- `时钟倒计时\docs\办公室部署.md:52`
- `codex-account-switch\LOCAL_PATCHES.md:122`
- `codex-account-switch\docs\environments\windows-dual-host.md:37-38`（远端 staging 保留旧根，本机 evidence 改新根，并在命令中显式区分两参数）

### 阶段 6　skill 治理复核、writer 闭包与 reopen

1. 复核阶段 3 已发布的 4 个 skill（artifact-migration、a-stock-data、nodesek-image-generation、neat-freak）：SKILL/SOURCE/ledger/catalog raw SHA-256 与 candidate manifest 一致，`D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py --strict` 和 writing-for-agents 门再次通过；阶段 6 不生成新的 catalog/ledger revision。
2. `D:\Codex\.codex\scripts\Reconcile-CcSwitchSkillLinks.ps1` dry-run（省略 `-Apply`）确认 cc-switch/.claude/.grok 三条 symlink 链路 intact（防写穿 symlink 物化成第二实体）。
3. 重新运行 writer/default/doc/task 闭包扫描（模式同阶段 0.5：绝对旧根双形态 `(?i)D:[\\/]+Codex[\\/]+\.codex[\\/]+run-evidence`），所有 production 本机命中均为新根，remote-only/fixture/history 命中均在具名白名单；任何新增未分类命中阻塞 reopen。
4. 按阶段 0 保存的原状态逐一恢复 `Codex Remote Plugin Catalog Guard`、`Reconcile CC Switch Skill Links`、02:00 日更任务；验证定义未漂移、应 Running 的确实 Running、应 Ready 的确实 Ready。不得用统一 Enable 替代原状态恢复。
5. 日更任务显式运行一次并等待其真实终态；新根本次 run 与 `LATEST.md` 绑定同一 run-id，旧根不重现。通过后 runner 写 `state=reopened`，Codex 才可重新打开。

### 阶段 7　连续哨兵（30 天；注册需用户授权）

- `sentinel.ps1` 与任务定义放迁移报告目录（两根之外）。persistent watcher 用 `FileSystemWatcher`：Path=`D:\Codex\.codex`、Filter=`run-evidence`（顶层 exact 名），监视 Created/Renamed/Changed/Delete 事件；捕获事件后对出现子树动态挂载 `IncludeSubdirectories` 观察并写 JSONL。`InternalBufferSize`=64KB，`Error` 事件记 overflow 并裁决失败；watcher generation 持久化在报告目录 `sentinel-state.json` 递增。每条 JSONL 含 watcher generation、sequence、event、path/oldPath、UTC、buffer status；JSONL 按天滚动、保留 35 天（覆盖 30 天门槛）；不移动或删除任何对象。
- watcher 必须写 heartbeat（每 60s 一条，gap 预算 ≤5 分钟，超预算裁决失败），任务配置要求开机/登录启动与失败重启；每日健康检查=`sentinel.ps1 -Mode DailyHealth` 参数模式，输出同目录 JSONL，检查 generation 连续、heartbeat 最大间隔未超预算、无 buffer overflow、无日志截断/sequence 回退。任一 gap/overflow/identity 漂移使该观察窗 `manual-review` 并把 30 天时钟归零，不能把“没记录到事件”当作无写入。
- 任务定义在报告目录给出三个任务的 schtasks/`Register-ScheduledTask` 骨架：持续 watcher、每日健康、最终自清。注册三个任务后 runner 写 `state=monitoring`。
- T+0 由阶段 4 完成；T+24h 是本机切换里程碑：旧根不存在，watcher coverage 连续，02:00 日更 run-id 与新根 `LATEST.md` 一致。历史运行超过 30 分钟时等待该 run 终态，不按固定 02:30 假阴性。
- 连续 30 个完整 24h 窗口都满足：旧根事件=0、overflow=0、heartbeat gap=0、每日 writer scan 无新增旧根生产引用，才能形成 `monitoring-complete.json`。任一旧根事件：冻结相关 writer，按精确 source/destination Move-Item 前移 straggler，修复并复验写方，重新从 T+0 计时；不自动删除证据。**最终自清任务契约**：连续 30 天无事件、无 overflow、无 heartbeat gap → 由自清任务写 terminal 裁决并 `schtasks /delete` 三个任务自清。
- home/office 都完成各自迁移且本机 30 天完成后，另立 codex-gsd 双容清退任务；本机 watcher/每日健康/自清三个任务由最终自清任务在 30 天门槛满足时退役（见上），双容清退验证处理 remote schema/tools 与旧根兼容分支删除。T+24h 不自清，迁移本身也不把双容清退冒充已完成。

## 3. 回滚与中止态

- 阶段 0-2 中止（尚未 move）：三个任务保持冻结；按 task-owned exact paths 恢复 Git pre-image/anchor和 `backups-live`，核 raw SHA-256/ACL/owner/streams，恢复任务原状态。旧数据根未动；preflight 唯一证据域保留并登记，不混入 production 迁移。
- 阶段 3-4 中止（尚未 reopen）：保持全部写方冻结，先按 move manifest 逆序把每个 `moved` 顶层对象 rename 回旧根并核原 file ID，再恢复全部 live/deployed pre-image和 Git task-owned paths；旧根递归 integrity manifest、preflight、原任务状态全部复验后才允许 reopen。任一 reverse 失败则状态 `manual-review`，不得保留“脚本新根+历史双根”后继续运行。
- 阶段 6 reopen 后失败：新根可能已有新写入，不自动反向迁移。立即冻结具名 writer，保存新写入 identity/hash，前移旧根 straggler、修复漏写方并重跑阶段 4/6；只有能证明新写入完整反向合并且另获授权时才考虑整树回滚。
- 同一 required 验收连续失败 3 次停止该分支，保存最后有效 checkpoint，报告原始错误、退出码、业务字段和未完成单位。不得用 disable/stub/ignore/skip、放宽 schema/assertion 或删除测试伪装恢复。

## 4. 明确不动清单（闭合）

- 历史记录：带日期报告/plans/specs（除 5 份现役权威合同）/.scratch/issues；60+ 份 skill SOURCE.md（计数以执行时 rg 实测为准）、`skill-catalog\catalog.json`、`.downloaded-skills-source-state.json`、`memories\MEMORY.md` 中的历史 provenance 指针（已核实 wrapper 复核不验证 evidence 路径存在性；改写=伪造历史）；倒计时 `assets\floating-plush\SOURCES.md` 与 `docs\悬浮窗视觉复刻 GitHub 方案调研.md` provenance；`automations\codex\memory.md` dated 行；`complete-config-report-20260816.md` 等 dated 报告。
- codex-gsd 远端语义桶（2.10 桶二）、`remote-staging-validation.schema.json:168,303` 与他机设备文档；`ban-gong-shi.md`。`windows-dual-host.md` 只保留远端 staging 行，本机 evidence 行按 2.14 修改。
- `legacy-fixture-manifest.json` 的 legacy 路径/fixture 语义不动，但受改 source 的 files[].sha256 必须更新；`generate_skill_catalog.py:53` 排除集、`purge :17` 与 relativeParts 不动。
- 旧树内全部 reparse point 的 tag/target/raw bytes 不动；迁后历史断链只登记，不修写历史证据。
- 测试内负向字面量（must-not-be-read/伪造外国路径/fixture 历史副本，见 2.12）。
- 杨杨子退役 `data\codex_home_yangyangzi\` 休眠副本（登记：跨设备复活前须先扫 skill 副本）。
- `D:\Codex\tmp\workflow-asset-harvester\script-tests-v4\Run-ProjectControls.ps1`（tmp 残留）；`deep-swe\tasks\README.md`（os error 1920 不可读，残余风险极低）；`ambient-suggestions\`、`process_manager\chat_processes.json` 缓存（Codex 自再生，非写方）。
- `BackupRetentionPolicy.ps1:648`（相对 CodexRoot 的死配置登记；`Invoke-BackupRetentionEvaluation` 扫描范围列为阶段 6.3 验证项——阶段 6.3 复核闭包扫描时确认，若超出 `.codex` 则为新根补护栏条目）。
- `D:\Codex\.codex\AGENTS.md`（实测无 run-evidence 引用，无需改）。

## 5. 审查溯源

- 第 1 轮（4 reviewer，完整性/回归/执行/治理）：~30 发现。推翻初版四处：sha256 完整性链（preflight 钉 policy-guard、两份 manifest 钉哈希）；统一环境 managed/scripts/modules 源不改会被再部署回退；三个隐藏写方面（cursor 日更 automation、时钟倒计时、codex-gsd 留守项目）；cc-switch skill 实为 symlink（非两份实体）。
- 第 2 轮（3 reviewer，完整性/顺序原子性/范围判据）：~15 发现。派生路径三处与字面替换错配（preflight:17、CodexHostHookEvidence capability 锚定、reconciler :3642/:370）；Move-Item 改名陷阱；步骤 2→3 窗口控制面硬宕；回滚/断点续跑整体缺失；codex-gsd 测试范围低估（60 文件）。
- 第 3 轮（2 reviewer，gsd 专项/端到端）：~11 发现。schema 双根交替（初记 4 份；remote-staging-validation.schema.json 保持旧根系远端语义（校验远端 staging 路径），有意不纳入双根交替，实际落地为 3 份双根交替）；tools/src 远端语义桶；sanitizer 三门控陷阱（第二根=D:\agents）；哈希三钉措辞（manifest=raw / host-preflight=canonical / preflight 常量=raw）；codex-account-switch 漏改；哨兵假阴性窗口与 schtasks 落地。
- 第 4 轮（2 reviewer，gsd 核验/全案一致性）：~10 发现。stagingRoot 门禁伞（Get-ReplicatorRunAllowedRoots）；scripts/ 骨架门禁分类；CoreSync:330 误分类；测试分类两可补两条子规则；git 脏集以执行时为准。
- 独立 verifier ×2（agent-36）：scripts/ 门禁穷尽排查（25 个 .ps1 全扫，最终 15 个必修位点）；Apply.psm1:930 定稿派生改法（净换会破坏远端）；Rollback.psm1:451-455 双容兼容性证实；tools/ 4 免改证实。
- v5 追加对抗审查（3 个正交 reviewer + fresh cross-review + 独立 verifier）：总判决 `no-go`。P1：robocopy `/MOVE /XO` 不能证明 ACL/owner/stream 与回滚；legacy manifest 不动会让 raw-hash inventory 必红；production `.claims`/snapshot capability root 清单不闭合。P2：account-switch 设备文档漏项、remote-only schema 误放宽、按名退出 Codex 不可自执行、T+24h 哨兵不能证明 30 天、reparse 删除无可逆受管路径。
- v6 修订映射：阶段 0/1/3/4 采用外部 runner + 同卷顶层 rename + metadata/identity manifest + reopen 前逆向回滚；2.2 更新 legacy raw hashes并保留负向门；2.3 统一 evidence/capability scope；2.10 remote schema 保持旧根；2.14 补设备文档方向；阶段 7 改连续 watcher。该映射只证明任务书已覆盖发现，不证明实现或迁移已经通过。

## 6. 完成条件

1. **计划级完成（本次文档修订）**：v6 中每个 v5 审查发现都有唯一修复步骤、失败分支和可复跑验收；不存在 `legacy-fixture-manifest.json` 整份不动、robocopy merge、迁移前删除 junction、remote schema 双根、T+24h 自清或按名强杀 Codex 的旧路线残留。
2. **本机迁移完成（后续执行）**：阶段 2.15 与阶段 4 全部 required 门在同一 source revision 上通过；旧根不存在；新根包含全部 moved 单位；顶层 file ID、两个敏感域的 hash/owner/ACL/streams、count/error/reparse manifest 全部对账；三个计划任务恢复原状态并有一次真实日更成功；`state=reopened`。
3. **长期兼容清退完成（后续独立任务）**：home/office 均迁移，连续 30 天 watcher coverage 无事件/overflow/gap（本机哨兵三任务由最终自清任务在该门槛退役），remote schema/tools 与双容清退同批验证通过，才允许删除旧根兼容分支。
4. 任一 required 单位 `failed/pending/manual-review`、任一 pre-existing 用户改动被覆盖、或任何未授权 commit/push/计划任务/删除动作发生，都不能使用 `complete`；交付必须指出精确 checkpoint、证据路径、原始错误和下一授权边界。
