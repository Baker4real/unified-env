---
type: report
title: 环境盘点可信度实施计划
tags: [历史计划, 环境盘点, project-docs]
intent: 记录环境盘点可信度改造的实施任务和完成过程
---

# 环境盘点可信度实施计划

> 状态：已于 2026-07-11 完成。下列复选框保留为实施过程记录，不再表示当前待办；当前结果以 `README.md`、`CONTEXT.md` 和 `reports/` 下的最新报告为准。

> **供 agent worker 使用：** 按任务逐项实施；每个任务必须走红灯、绿灯、任务级 spec/质量评审，高风险任务再追加独立对抗性审查。所有步骤使用复选框跟踪。

**目标：** 把环境 inventory、readiness、备份 dry-run 和 apply manifest 升级为可审计、失败关闭且不会改动真实环境的可信报告链路。

**架构：** 入口脚本只负责采集和编排；PATH/工具归属、迁移策略、备份保留策略和严格验证分别下沉到纯 PowerShell 库。所有 JSON/Markdown 通过共享发布器生成，使用 `generationId` 和源 JSON SHA-256 检测配对不一致。

**技术栈：** PowerShell 7.6.3、JSON、Markdown、Git、Serena；CodeGraph 已初始化但官方不支持 PowerShell，因此本仓库使用 Serena 作为语义导航。

## 全局约束

- 不修改 Process、User 或 Machine PATH，不写注册表。
- 不创建、恢复、删除或替换任何 Python、.NET、CMake、Ninja、Rust 运行时。
- 不移动、删除、压缩或改写任何备份、缓存、项目本地环境、凭据或运行证据。
- 所有新输出和测试 fixture 必须位于 `D:\`；路径操作使用绝对路径、`-LiteralPath` 和 reparse point 父链检查。
- inventory schema 固定为 3，`artifactType="env-governance.inventory"`。
- readiness schema 固定为 3，`artifactType="env-governance.update-readiness"`，只接受 inventory 3。
- backup dry-run 现役 schema 固定为 3，`artifactType="env-governance.backup-retention-dry-run"`；下方 Task 5 的 schema 2 表述只保留为历史实施记录。
- 历史实施 baseline 中 apply manifest schema 固定为 2，`artifactType="env-governance.backup-retention-apply-manifest"`；当前实现已转为只接受 production dry-run 3。
- backup production context 固定：`CodexRoot=D:\Codex\.codex`、`DDriveRoot=D:\Codex`、`retainCount=5`、`policyId=env-governance.backup-retention`、`policyVersion=3`。
- 严格 JSON 校验不得使用 `[bool]"false"` 或其他 PowerShell 宽松强转。
- 报告是脚本可再生产物；不得手工修改 JSON/Markdown 快照。
- 每个生产改动前必须先运行能稳定失败的专项测试；失败原因必须是目标行为尚未实现。

---

### Task 1：共享 JSON/Markdown 发布器

**风险：** 中。该库只操作报告目标文件，不得操作报告引用的源路径。

**文件：**

- Create: `scripts/lib/ReportArtifactPublisher.ps1`
- Create: `tests/Test-ReportArtifactPublisher.ps1`
- Modify: `.gitignore`

**接口：**

- Produces: `Publish-JsonMarkdownArtifactPair -Document <psobject> -OutputDir <D path> -JsonFileName <name> -MarkdownFileName <name> -RenderMarkdown <scriptblock>`
- Produces: `Test-JsonMarkdownArtifactPair -JsonPath <path> -MarkdownPath <path>`
- Output model includes `generationId` in JSON; Markdown front matter contains the same id and `sourceJsonSha256`.

- [ ] **Step 1：写发布成功与配对验证红灯测试**

在 `tests/Test-ReportArtifactPublisher.ps1` 构造 `reports/report-artifact-publisher-test` fixture，调用尚不存在的函数并断言：

```powershell
$published = Publish-JsonMarkdownArtifactPair `
    -Document ([pscustomobject]@{ schemaVersion = 1; artifactType = "fixture" }) `
    -OutputDir $outputDir `
    -JsonFileName "fixture.json" `
    -MarkdownFileName "FIXTURE.md" `
    -RenderMarkdown { param($Document, $JsonSha256) "generationId=$($Document.generationId)`nsourceJsonSha256=$JsonSha256" }

Assert-True ($published.generationId -match '^[0-9a-f-]{36}$') "缺少 generationId"
Assert-True ((Test-JsonMarkdownArtifactPair -JsonPath $published.jsonPath -MarkdownPath $published.markdownPath).ok) "报告对必须通过校验"
```

- [ ] **Step 2：运行红灯**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-ReportArtifactPublisher.ps1'
```

Expected: FAIL，错误指向 `Publish-JsonMarkdownArtifactPair` 未定义。

- [ ] **Step 3：实现最小发布器**

`ReportArtifactPublisher.ps1` 必须：

```powershell
function Get-ReportSha256 {
    param([Parameter(Mandatory)][string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}
```

发布流程固定为：校验 OutputDir 在 D 盘且父链无 reparse → 在目标父目录创建 `.staging-<guid>` → 给文档加入 `generationId` → 先序列化最终 JSON 并算 SHA-256 → 渲染 Markdown → 回读 staging 文件并校验 id/hash → 使用同卷临时文件和 `[System.IO.File]::Move(..., $true)` 对单文件替换 → 清理 staging。只允许删除 staging 自身；不得接受源数据路径参数。

- [ ] **Step 4：补失败保持旧成品和错配检测测试**

断言渲染器抛错时旧 JSON/Markdown 内容不变；篡改 Markdown 的 `generationId` 或 hash 后 `Test-JsonMarkdownArtifactPair.ok=false`；C 盘和 reparse 输出父链被拒绝。

- [ ] **Step 5：运行绿灯与空白检查**

Run focused test；Expected: `ok=True`。随后运行 `git diff --check`。

- [ ] **Step 6：提交**

```powershell
git add -- .gitignore scripts/lib/ReportArtifactPublisher.ps1 tests/Test-ReportArtifactPublisher.ps1
git commit -m "feat: add trusted report artifact publisher"
```

---

### Task 2：Inventory 纯事实核心与 schema 3

**风险：** 高。错误分类会误导后续 PATH/运行时决策；任务后追加对抗性审查。

**文件：**

- Create: `scripts/lib/EnvInventoryTrust.ps1`
- Create: `tests/Test-EnvInventoryTrust.ps1`
- Modify: `scripts/Invoke-EnvInventory.ps1`
- Modify: `tests/Test-EnvInventory.ps1`

**接口：**

- Consumes: `Publish-JsonMarkdownArtifactPair` from Task 1.
- Produces: `New-PathScopeRecord`, `Get-ToolOriginDecision`, `ConvertFrom-PythonRuntimeProbe`, `New-InventoryV3Document`.
- Produces inventory 3 fields: `pathScopes.process/user/machine`, compatibility `pathEntries`, `tools[*].launcher/runtime/originClass/originEvidence/resolutionScope/requiresManualReview`.

- [ ] **Step 1：写 PATH scope 红灯测试**

fixture 必须覆盖 `%SystemRoot%` 成功展开、scope 内重复、注册表/.NET 值不一致、展开失败、读取失败：

```powershell
$scope = New-PathScopeRecord -Source user -RawValue '%SystemRoot%\System32;D:\Tools;d:\tools\' -DotNetValue '%SystemRoot%\System32;D:\Tools;d:\tools\' -ReadErrors @() -MetadataResolver $resolver
Assert-True $scope.complete "合法 scope 应完整"
Assert-True ($scope.entries[0].expandedPath -eq 'C:\Windows\System32') "变量必须展开"
Assert-True ($scope.duplicates.Count -eq 1) "比较必须忽略大小写和尾分隔符"
```

另断言读取/展开失败时 `complete=false` 且 missing cleanup 建议集合为空。

- [ ] **Step 2：运行 PATH 红灯**

Expected: FAIL，`New-PathScopeRecord` 未定义。

- [ ] **Step 3：实现 PATH 纯函数**

每个 entry 固定：`index, rawPath, expandedPath, expansionStatus, exists, drive, isReparsePoint, reparseTarget`。`rawValueSha256` 只保存哈希；`pathEntries` 只投影旧字段 `index,path,exists,drive`，其中 `path=expandedPath`。

- [ ] **Step 4：写工具归属与 Python 红灯测试**

使用严格 JSON probe fixture：

```json
{"executable":"D:\\hermes-data\\hermes-agent\\venv-new\\Scripts\\python.exe","prefix":"D:\\hermes-data\\hermes-agent\\venv-new","basePrefix":"D:\\hermes-data\\.local\\python\\pythoncore-3.14-64"}
```

launcher 为 `D:\hermes-data\.npm-global\python.exe`，显式项目根为 `D:\hermes-data\hermes-agent`；断言 launcher/runtime owner 分离，最终 `originClass=project-local-env`、`requiresManualReview=true`。再覆盖 reparse、vendor、system installer、显式共享根和 unknown 优先级。

- [ ] **Step 5：运行归属红灯并实现纯函数**

Python 真实探测命令固定使用已解析的绝对 Application：

```powershell
& $pythonPath -I -S -c 'import json,sys; print(json.dumps({"executable":sys.executable,"prefix":sys.prefix,"basePrefix":sys.base_prefix}))'
```

探测超时或非严格 JSON时返回 `unknown + requiresManualReview=true`，不得阻止 inventory 其余部分生成。

- [ ] **Step 6：把入口编排升级到 schema 3**

`Invoke-EnvInventory.ps1`：

- dot-source Task 1/2 库；
- 分别采集 Process、HKCU、HKLM PATH；
- `Get-SelectedEnvironmentVariables` 不再输出完整 `Path` 值；
- `Get-Command` 只有绝对、存在、`CommandType=Application` 才可作为 launcher；
- 顶层加入 `artifactType`, `schemaVersion=3`, `executionAllowed=false`, `pathScopes`；
- 报告明确标注工具 resolution 是 process scope；
- 使用共享发布器。

- [ ] **Step 7：升级端到端测试并运行红灯/绿灯**

`Test-EnvInventory.ps1` 断言 schema 3、artifactType、三个 scope、兼容投影、Python origin 字段、JSON/Markdown pair 校验；保留 C 盘/reparse 输出门和 quick/full probe。

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvInventoryTrust.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-EnvInventory.ps1'
```

Expected: 两者 `ok=True`，无警告。

- [ ] **Step 8：提交**

```powershell
git add -- scripts/lib/EnvInventoryTrust.ps1 tests/Test-EnvInventoryTrust.ps1 scripts/Invoke-EnvInventory.ps1 tests/Test-EnvInventory.ps1
git commit -m "feat: add scoped trusted environment inventory"
```

---

### Task 3：迁移建议与 inventory 事实分离

**风险：** 中。必须保持现有迁移计划行为与项目本地审查结果。

**文件：**

- Create: `scripts/lib/EnvMigrationPolicy.ps1`
- Create: `tests/Test-EnvMigrationPolicy.ps1`
- Modify: `scripts/Invoke-EnvInventory.ps1`
- Modify: `scripts/New-EnvMigrationPlan.ps1`
- Modify: `scripts/New-ProjectLocalEnvReviewPack.ps1`
- Modify: `tests/Test-EnvMigrationPlan.ps1`
- Modify: `tests/Test-ProjectLocalEnvReviewPack.ps1`

**接口：**

- Produces: `Get-EnvMigrationCandidates -Directories <facts>` and `Get-EnvManualReviewItems -Directories <facts> -LocalEnvironmentFindings <facts>`.
- Inventory 3 no longer contains top-level `migrationCandidates` or `manualReviewItems`; migration plan derives them from facts.

- [ ] **Step 1：写纯策略红灯测试**

将现有 canonical pip cache、C 用户缓存、reparse、项目 `node_modules` fixture 搬到 `Test-EnvMigrationPolicy.ps1`，断言候选/人工审查与旧行为一致。

- [ ] **Step 2：运行红灯并搬移最小策略**

把 `Get-MigrationCandidates`、`Get-ManualReviewItems` 从 inventory 入口移动到纯库；不得复制两份逻辑。

- [ ] **Step 3：更新 migration plan 消费 schema 3**

入口严格要求 `artifactType=env-governance.inventory`、整数 `schemaVersion=3`、facts 字段齐全；调用纯策略后再执行现有 root policy 和 dry-run plan 生成。

- [ ] **Step 4：更新 inventory 与项目审查回归**

inventory JSON/Markdown 不再展示迁移动作；`New-ProjectLocalEnvReviewPack.ps1` 继续消费 `localEnvironmentFindings` facts 并通过原测试。若 finding 中仍有 `risk/recommendation`，本任务将它们移动为 review pack 中的派生展示字段，inventory 仅保留 classification、owner、marker、path 和 rebuild evidence。

- [ ] **Step 5：运行专项回归**

Run `Test-EnvMigrationPolicy.ps1`、`Test-EnvMigrationPlan.ps1`、`Test-ProjectLocalEnvReviewPack.ps1`；Expected: 全部 `ok=True`。

- [ ] **Step 6：提交**

```powershell
git add -- scripts/lib/EnvMigrationPolicy.ps1 tests/Test-EnvMigrationPolicy.ps1 scripts/Invoke-EnvInventory.ps1 scripts/New-EnvMigrationPlan.ps1 scripts/New-ProjectLocalEnvReviewPack.ps1 tests/Test-EnvMigrationPlan.ps1 tests/Test-ProjectLocalEnvReviewPack.ps1
git commit -m "refactor: derive migration advice from inventory facts"
```

---

### Task 4：Readiness 条件策略与 stale PATH 严格消费

**风险：** 高。错误文案会指导错误的主机变更；任务后追加对抗性审查。

**文件：**

- Create: `scripts/lib/EnvUpdateReadinessPolicy.ps1`
- Create: `tests/Test-EnvUpdateReadinessPolicy.ps1`
- Modify: `scripts/New-EnvUpdateReadinessReport.ps1`
- Modify: `tests/Test-EnvUpdateReadiness.ps1`
- Modify: `scripts/New-StalePathEntryCleanupDryRun.ps1`
- Modify: `tests/Test-StalePathEntryCleanupDryRun.ps1`

**接口：**

- Consumes inventory 3 from Task 2/3 and publisher from Task 1.
- Produces `Assert-InventoryV3Document`, `Get-ToolDecisionInputs`, `Get-BaseUpdateDecision`, `Get-ToolUpdateEntry`, `Get-UpdatePolicy`.
- Readiness 3 `pathSummary.sourceScope=process`; incomplete process scope produces no missing/stale cleanup advice.

- [ ] **Step 1：写全工具表驱动红灯测试**

表至少包含 Python、uv、Node、npm、Cargo、Rust、.NET、CMake、Ninja、WSL、Git、pwsh、powershell；每行断言 `decisionInputs`、risk、manual review、允许更新入口文案与禁止位置片段。

```powershell
@{ name='git'; locationClass='system-installer'; originClass='system-installer'; probeSucceeded=$true; forbidden=@('当前已在 D 盘') }
@{ name='cargo'; locationClass='d-drive'; originClass='shared-tool'; probeSucceeded=$true; forbidden=@('系统安装目录','迁到 D 盘') }
@{ name='python'; locationClass='d-drive'; originClass='project-local-env'; probeSucceeded=$true; expectedRisk='high' }
```

- [ ] **Step 2：运行红灯并实现两层策略**

`Get-BaseUpdateDecision` 唯一负责位置/归属/探测文案；`Get-ToolUpdateEntry` 只能返回官方更新机制名称，禁止写位置断言。

- [ ] **Step 3：严格输入 schema 与 path scope gate**

readiness 入口拒绝 schema 2、未来 schema、错误 artifactType、缺 pathScopes/origin 字段；错误必须发生在创建 OutputDir 之前。

- [ ] **Step 4：升级 stale PATH 消费**

stale 脚本只接受 readiness 3；要求 `pathSummary.sourceScope=process` 且 `complete=true`。不完整 scope 必须失败或生成 `executionAllowed=false` 且 0 候选，计划采用失败关闭并不创建输出。

- [ ] **Step 5：运行专项测试**

Run policy、readiness、stale PATH 三个测试；Expected: 全部通过，报告不再出现 Git/Cargo/uv 矛盾文案。

- [ ] **Step 6：提交**

```powershell
git add -- scripts/lib/EnvUpdateReadinessPolicy.ps1 tests/Test-EnvUpdateReadinessPolicy.ps1 scripts/New-EnvUpdateReadinessReport.ps1 tests/Test-EnvUpdateReadiness.ps1 scripts/New-StalePathEntryCleanupDryRun.ps1 tests/Test-StalePathEntryCleanupDryRun.ps1
git commit -m "fix: derive readiness advice from trusted facts"
```

---

### Task 5：备份覆盖账本与 dry-run schema 2（历史实施基线；现役为 schema 3）

**风险：** 高。覆盖假阳性可能导致未来误删；任务后必须 spec/质量评审和独立对抗性审查。

**文件：**

- Create: `scripts/lib/BackupRetentionPolicy.ps1`
- Create: `tests/Test-BackupRetentionPolicy.ps1`
- Modify: `scripts/New-BackupRetentionDryRun.ps1`
- Modify: `tests/Test-BackupRetentionDryRun.ps1`

**接口：**

- Produces `New-BackupRetentionPolicyContext`, `Get-BackupRetentionDeclaredScanRoots`, `Invoke-BackupRetentionEvaluation`, `Test-BackupRetentionDelegationGraph`, `Get-BackupRetentionRootSnapshot`.
- Canonical ledger array: `coverageItems`; projections: `candidates`, `retainedItems`, `protected`, `manualReview`, `unclassifiedCoverageGaps`.

- [ ] **Step 1：写未知文件/目录与计数守恒红灯**

fixture root 包含未知目录和未知文件；断言两者均为 `coverageDisposition=gap`、`blocksCoverage=true`、`coverageAccounted=true`、`coverageComplete=false`。

- [ ] **Step 2：写 retained/delegated 图红灯**

断言保留期内 provider-sync 项为 retained；父 `backups_state` 中 provider-sync 是 `delegated-root`。自引用、双向环、非直接子项和多父归属全部失败关闭。

- [ ] **Step 3：实现固定 policy context 与纯 evaluation**

production context 必须精确匹配全局常量；fixture 必须 `artifactMode=test`。枚举使用 `Get-ChildItem -Force` 包含文件/目录，记录 started/completed/errors、canonical snapshot 和 SHA-256。

- [ ] **Step 4：实现 schema 2 dry-run 编排（历史步骤）**

入口只做参数门、context 构造、evaluation、Markdown 渲染、共享发布。未知项进入 gap+manualReview，不能静默 `continue`。

- [ ] **Step 5：运行红灯/绿灯与旧安全门回归**

Run policy + dry-run tests；验证 C 盘、reparse、敏感保护根、只读标志继续生效。

- [ ] **Step 6：提交**

```powershell
git add -- scripts/lib/BackupRetentionPolicy.ps1 tests/Test-BackupRetentionPolicy.ps1 scripts/New-BackupRetentionDryRun.ps1 tests/Test-BackupRetentionDryRun.ps1
git commit -m "feat: prove backup retention coverage"
```

---

### Task 6：Apply manifest 严格验证与 TOCTOU gate

**风险：** 最高。任何漏检都可能让未来删除授权建立在伪造状态上；必须追加对抗性审查。

**文件：**

- Create: `scripts/lib/BackupRetentionValidation.ps1`
- Create: `tests/Test-BackupRetentionValidation.ps1`
- Modify: `scripts/New-BackupRetentionApplyManifest.ps1`
- Modify: `tests/Test-BackupRetentionApplyManifest.ps1`

**接口：**

- Historical task baseline consumed production dry-run 2; the current implementation consumes production dry-run 3 through the same `BackupRetentionPolicy.ps1` and publisher boundary.
- Produces `Test-BackupRetentionDryRunDocument -Document <object> -TrustedPolicyContext <context>`，成功返回 canonical live evaluation，失败抛错。
- Produces `Compare-BackupRetentionEvaluation` and schema 2 manifest model.

- [ ] **Step 1：写严格 JSON 类型红灯**

拒绝字符串 `"false"`、非整数 schema、非数组集合、错误 artifactType、schema 1/未来版本、重复 canonical path/candidate。

- [ ] **Step 2：写可信根/policy 伪造红灯**

拒绝 test artifact 进入正式入口；纯验证 fixture 覆盖篡改 `declaredScanRoots`、CodexRoot、DDriveRoot、retainCount、policyId/version。

- [ ] **Step 3：写现场语义复算与 TOCTOU 红灯**

在 dry-run 后新增 sibling、改变 reparse、调换 candidate/retained、篡改 groupKey/backupType/timestamp/retainRank/blocksCoverage；全部必须在创建输出目录之前失败。

- [ ] **Step 4：实现无写入纯验证器**

严格属性类型使用 `PSObject.Properties` 与 `.GetType()`/`-is` 判断；不得用宽松强转。apply 从固定 production context 重新推导根并调用 Task 5 的纯 evaluation，逐 canonical path 比较 disposition 语义和快照。

- [ ] **Step 5：瘦身正式 apply 入口并升 schema 2**

入口顺序固定：读取原始 JSON并算 SHA → 严格解析 → freshness≤24h → production context → 纯验证/现场复算 → selection allowlist → candidate 当前 stats 二次校验 → manifest model → 共享发布。任何前置失败不创建 OutputDir。

- [ ] **Step 6：运行专项测试**

Run validation + apply tests；保留现有未来时间、过期、重复 AllowPath、C 盘、保护/人工审查祖先和 stats 漂移覆盖。

- [ ] **Step 7：提交**

```powershell
git add -- scripts/lib/BackupRetentionValidation.ps1 tests/Test-BackupRetentionValidation.ps1 scripts/New-BackupRetentionApplyManifest.ps1 tests/Test-BackupRetentionApplyManifest.ps1
git commit -m "feat: harden backup apply manifest gate"
```

---

### Task 7：报告重建、文档同步与全量验证

**风险：** 高。生成报告必须反映新 schema，不能把旧缺陷或临时 fixture 发布为当前事实。

**文件：**

- Modify: `README.md`
- Modify: `CONTEXT.md`
- Regenerate: `reports/env-inventory/*`
- Regenerate: `reports/env-migration-plan/*`
- Regenerate: `reports/env-update-readiness/*`
- Regenerate: `reports/stale-path-entry-cleanup-dry-run/*`
- Regenerate: `reports/project-local-env-review/*`
- Regenerate: `reports/project-local-env-rebuild-plan/*`
- Regenerate: `reports/backup-retention-dry-run-current/*`
- Regenerate: `reports/backup-retention-apply-manifest/*` only if production dry-run coverage is complete and has real candidates；否则删除仓库中已失效的 schema 1 当前快照，并在 README/CONTEXT 明确“没有可发布的 schema 2 manifest”。这里删除的仅是 Git 跟踪的生成报告，不是任何备份源数据。

**接口：**

- Consumes all Tasks 1–6.
- Produces current, paired JSON/Markdown facts and documented test commands.

- [ ] **Step 1：把新增测试加入 README 验证命令**

新增 6 个专项测试：ReportArtifactPublisher、EnvInventoryTrust、EnvMigrationPolicy、EnvUpdateReadinessPolicy、BackupRetentionPolicy、BackupRetentionValidation。

- [ ] **Step 2：按依赖顺序重建报告**

顺序固定：inventory → migration/review/rebuild → readiness → stale PATH → backup dry-run → apply manifest gate。所有脚本使用绝对 PowerShell 入口和 D 盘输出。

- [ ] **Step 3：验证报告事实**

断言：

- inventory 3 有三个 path scope，Python launcher/runtime owner 可见；
- readiness 3 不含已知矛盾文案；
- 历史 baseline 的 backup dry-run 2 对每个 declared root 有 coverage 结果；现役报告为 schema 3；
- `coverageComplete=false` 时 apply manifest 明确被阻止且不生成新产物；
- JSON/Markdown generationId/hash 配对通过。

- [ ] **Step 4：运行完整测试集**

运行 README 原 10 个测试和新增 6 个测试；Expected: 全部退出码 0、无警告。

- [ ] **Step 5：运行最终静态检查**

```powershell
git diff --check
git status --short
```

确认没有测试输出、staging、数据库、日志或 C 盘生成物进入 Git 状态。

- [ ] **Step 6：全分支 review 和对抗性审查**

最终 reviewer 检查 spec 覆盖和代码质量；独立 adversarial reviewers 攻击：PATH scope 混淆、Python origin 逃逸、backup coverage 假阳性、伪造 JSON、TOCTOU、reparse、schema 降级、报告/文档不一致。

- [ ] **Step 7：修复所有 Critical/Important，重新验证并提交**

```powershell
git add -- README.md CONTEXT.md reports
git commit -m "docs: publish trusted environment governance reports"
```

## 完成信号

- 所有 7 个任务各自有红灯、绿灯、提交和任务级评审证据。
- 高风险 Tasks 2、4、5、6、7 额外通过独立对抗性审查。
- 完整测试集全绿，`git diff --check` 无输出。
- 本分支没有修改 PATH、注册表、运行时或任何备份源内容。
