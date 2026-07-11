# 本机 Codex Hook 治理实施计划

> **供 agent worker 使用：** 按任务逐项实施。优先使用 `subagent-driven-development`；每个任务必须走红灯、绿灯、任务级 spec/质量评审，高风险任务再追加独立对抗性审查。所有步骤使用复选框跟踪。

**目标：** 把本机 Codex hooks 从未纳管的 live 脚本升级为可盘点、可审查、可回滚、并发安全且通过真实 SessionStart 验收的 D 盘受管系统。

**架构：** `统一环境` 仓库保存严格 manifest、受管 hook 源码、纯策略库和 plan/apply/restore 工具；`D:\Codex\.codex` 只作为 patch-preserving 部署目标。先在 fixture 中证明 manifest、注册合并和回滚，再恢复旧 0–3 trust 顺序；配置文件和全局状态分别使用共享安全写入器，provider、state、GitHub、Serena config/activate 保持独立故障域。

**技术栈：** PowerShell 7.6.3、Python 3.14.6 标准库、Serena 1.5.3 自带 PyYAML、JSON/TOML/YAML、Windows 命名互斥锁、Git。

## 全局约束

- 设计基线固定为 `docs/specs/2026-07-11-codex-hook-governance-design.md`；任何偏离必须先更新设计并重新批准。
- 所有仓库文件与生成内容位于 `D:\`；不得在 `C:\` 创建新的脚本、fixture、日志、备份或交付物。
- live 根固定为 `D:\Codex\.codex`；受管源固定为 `D:\Codex\projects\统一环境\managed\codex-hooks`。
- PowerShell 固定使用 `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`；Python 固定使用 `D:\Codex\tools\python314-official\python.exe`。
- Serena YAML 校验器固定使用 `D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe` 与其已安装的 PyYAML 6.0.2；不得给官方 Python 额外安装依赖。
- 不修改 Codex Store/AppX、Serena vendor 源码、官方 GitHub CLI 二进制或其他 upstream/vendor tree。
- 不直接增加、删除、复制、计算或伪造 `D:\Codex\.codex\config.toml` 的 `[hooks.state]` / `trusted_hash`。
- `hooks.json` 合并必须保留未知 group、未知字段和相对顺序；新增受管 SessionStart 只能追加，禁止插入现有受信 group 之前。
- 不 mirror/prune 整个 live hooks 目录；只发布 manifest 明确拥有的 allowlist 文件。retired 文件默认取消注册、备份并保留，不自动删除。
- 所有 live apply 前必须有 source/live SHA-256 final gate、D 盘/reparse 父链检查、完整备份、反序回滚和独立对抗性审查。
- `.codex-global-state.json`、`config.toml`、`serena_config.yml` 和 `hooks.json` 的写入必须使用同目录临时文件、验证和原子替换；写入失败时旧字节保持不变。
- 输出不得包含完整线程 ID、auth token、代理 user-info、GitHub 凭据、原始全局状态或完整用户 PATH。
- 外层 hook timeout 初始保持 10 秒；内部单锁等待上限 1500ms，子进程必须有显式 timeout。
- provider/state/config 为 critical，GitHub 为 optional，Serena activate 为 degraded；optional 失败不得阻断普通会话。
- `Bash` matcher 暂时保留，只有合成 payload 与 fresh live 证据都否定时才能改 matcher。
- User `SERENA_HOME` 的唯一目标值是 `D:\Codex\.serena`；变更必须记录 before/after 和 restartRequired，不输出其他用户环境值。
- 每个任务先写稳定红灯，再写最小实现；每个任务独立提交。Tasks 2、3、4、5、7、8 需要风险/对抗审查。

---

## 文件结构

```text
managed/codex-hooks/
  manifest.json                         # 受管事件、顺序、runtime、文件闭包和环境政策
  hooks/
    codex-github-cli-guard.cmd
    codex-github-cli-guard.ps1
    codex-provider-stability-guard.cmd
    codex-provider-stability-guard.ps1
    codex-projectless-root-d.cmd        # compatibility wrapper，内部转到 state policy
    codex-state-policy-guard.py
    serena-activate-guarded.cmd
    serena-activate-guarded.ps1
    serena-dashboard-guard.cmd
    serena-dashboard-guard.ps1
    lib/
      CodexHookRuntime.ps1              # hash、路径、备份、atomic replace、timeout、脱敏、health
      CodexConfigFile.ps1               # TOML/YAML 纯变换与验证
  retired/
    codex-mobile-permission-guard.cmd
    codex-mobile-permission-guard.py
    codex-projectless-root-d.js
scripts/
  Get-CodexHookInventory.ps1            # 只读事实生产者
  New-CodexHookDeploymentPlan.ps1       # 纯 dry-run 计划生产者
  Invoke-CodexHookDeployment.ps1        # final gate、备份、发布、postcheck
  Restore-CodexHookDeployment.ps1       # 依据 evidence manifest 反序恢复
  lib/CodexHookPolicy.ps1               # strict manifest、registry merge、计划/验证纯函数
tests/
  Test-CodexHookPolicy.ps1
  Test-CodexHookInventory.ps1
  Test-CodexHookDeployment.ps1
  Test-CodexHookRuntime.ps1
  Test-CodexHookConfig.ps1
  Test-CodexStatePolicy.py
reports/codex-hook-inventory/
  inventory.json
  REPORT.md
```

---

### Task 1：严格 Manifest 与只读 Hook Inventory

**风险：** 中。该任务只读 live 状态，不允许执行任何 hook 或写 `D:\Codex\.codex`。

**文件：**

- Create: `managed/codex-hooks/manifest.json`
- Create: `scripts/lib/CodexHookPolicy.ps1`
- Create: `scripts/Get-CodexHookInventory.ps1`
- Create: `tests/Test-CodexHookPolicy.ps1`
- Create: `tests/Test-CodexHookInventory.ps1`
- Modify: `.gitignore`

**接口：**

- Produces: `Assert-CodexHookStrictJsonText -JsonText <string>`。
- Produces: `Assert-CodexHookManifest -Manifest <object>`。
- Produces: `Read-CodexHookManifest -Path <D path>`，返回严格验证的 schema 1 对象。
- Produces: `Get-CodexHookRegistryFacts -RegistryPath <path> -Manifest <object>`，按 manifest 的完整路径、事件、matcher 与精确参数识别受管 identity；不返回 raw command、raw arguments 或未知 matcher/target。
- Produces: `Get-CodexHookFileFacts -Manifest <object> -ManagedRoot <path> -LiveHooksRoot <path>`。
- Produces: `Get-CodexHookDependencyFacts -Manifest <object>`，只读验证 wrapper、implementation 与 runtime 的存在性、hash 和引用关系。
- Produces: `New-CodexHookInventoryDocument -Manifest <object> -Registry <object> -FileFacts <array> -DependencyFacts <array> -TrustObservation <array>`。

- [ ] **Step 1：写 strict JSON 与 schema 红灯测试**

在 `Test-CodexHookPolicy.ps1` 断言重复键、未知顶层属性、错误 artifactType、非整数 schema、重复 id、重复 active command、非 D 盘路径、缺 runtime、非法 criticality、timeout≥30 或 ≤0 均被拒绝：

```powershell
$duplicateJson = '{"artifactType":"env-governance.codex-hook-manifest","artifactType":"x","schemaVersion":1}'
Assert-Throws { Assert-CodexHookStrictJsonText -JsonText $duplicateJson } '重复 JSON 属性'

$invalid = [pscustomobject]@{
    artifactType = 'env-governance.codex-hook-manifest'
    schemaVersion = 1
    codexHome = 'C:\Users\fixture\.codex'
    hooks = @()
    files = @()
    environment = @()
}
Assert-Throws { Assert-CodexHookManifest -Manifest $invalid } 'codexHome 必须位于 D:\'
```

- [ ] **Step 2：运行红灯**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookPolicy.ps1'
```

Expected: FAIL，首个错误是 `Assert-CodexHookStrictJsonText` 未定义。

- [ ] **Step 3：实现严格解析与精确 schema**

`CodexHookPolicy.ps1` 复用本仓库的 `System.Text.Json` 唯一属性检查模式，但使用 hook 专属函数名：

```powershell
function Assert-CodexHookStrictJsonText {
    param([Parameter(Mandatory)][string]$JsonText)
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 128
    $document = [System.Text.Json.JsonDocument]::Parse($JsonText, $options)
    try { Assert-CodexHookJsonElementUniqueProperties -Element $document.RootElement } finally { $document.Dispose() }
}
```

manifest 顶层精确属性固定为：

```json
{
  "artifactType": "env-governance.codex-hook-manifest",
  "schemaVersion": 1,
  "codexHome": "D:\\Codex\\.codex",
  "managedRoot": "D:\\Codex\\projects\\统一环境\\managed\\codex-hooks",
  "runtimes": {},
  "hooks": [],
  "files": [],
  "environment": []
}
```

每个 hook 精确字段为 `id,event,order,matcher,timeoutSeconds,commandPath,arguments,wrapperPath,implementationPath,runtimeId,readResources,writeResources,criticality,lifecycle,lifecycleReason,quickHealthCheck,fullAcceptanceCommand`。`wrapperPath=null` 仅表示 direct vendor entry；其余 hook 必须显式声明 wrapper。read/write resource 每项精确为 `{kind,value}`：`kind=path` 时只能是 D 盘绝对路径，`kind=abstract` 时只能使用受控的 stdin/stdout/env/network/state 枚举。quick/full command 每项精确为 `{commandPath,arguments}`，仅声明、不在 inventory 中执行。manifest 是 desired contract；inventory 单独报告 observed wrapper/runtime/implementation gap，desired 文件尚未导入不使 schema 失败。retired hook 必须填写 `lifecycleReason`，其他 lifecycle 必须为 null。每个文件精确字段为 `relativePath,liveRelativePath,sha256,lifecycle,ownerHookIds`；`environment` 项现在即精确验证 `{name,scope,desired,restartRequired}`。

- [ ] **Step 4：加入当前受管注册与 runtime manifest**

SessionStart 顺序固定为 provider 0、projectless/state 1、Serena activate 2、Serena dashboard 3、GitHub 4；Stop cleanup 与 PreToolUse Bash reminder 保留；Serena auto-approve 现在即声明为 `lifecycle="retired"`。registration-repair 模式只修 SessionStart，不执行 retirement，并把仍注册项报告为 `retired-but-registered`；只有 full 模式（Task 7）才精确取消该 identity。runtime 固定：

```json
{
  "pwsh": "D:\\Codex\\tools\\PowerShell\\7.6.3\\pwsh.exe",
  "python": "D:\\Codex\\tools\\python314-official\\python.exe",
  "serenaPython": "D:\\Codex\\tools\\uv\\tools\\serena-agent\\Scripts\\python.exe",
  "serenaHooks": "D:\\Codex\\tools\\uv\\bin\\serena-hooks.exe"
}
```

`files` 同时声明 Task 3 将导入的 12 个审计快照文件和其当前 live SHA-256；在 managed 源尚未建立时，
manifest 仍是合法声明，inventory 必须把 `managedExists=false` 作为事实缺口输出，不能把缺文件误报为
manifest schema 错误。Task 3 导入后该缺口必须归零。

- [ ] **Step 5：写 inventory 红灯测试**

fixture registry 覆盖：正确注册、GitHub 插入索引 1、allowlist 内缺 target、未知 event/group、重复受管 identity、同文件名错误父目录、精确 vendor 参数、verb 前后缀、额外敏感参数、非 command type、歧义候选、UNC/C/device target 和缺 trust observation。未知 target 不做 exists/hash 探测；inventory 是纯事实，不输出 raw command/arguments/matcher、秘密、线程 ID 或完整 trust hash：

```powershell
$facts = Get-CodexHookRegistryFacts -RegistryPath $fixtureRegistry -Manifest $manifest
Assert-True ($facts.events.SessionStart.Count -eq 5) '必须看到全部 SessionStart'
Assert-True ($facts.events.SessionStart[1].idMatch -eq 'github-cli') '必须观察索引错位'
Assert-True (-not ($facts | ConvertTo-Json -Depth 20).Contains('trusted_hash')) '不得泄露完整 trust hash'
```

- [ ] **Step 6：实现只读 inventory 入口**

`Get-CodexHookInventory.ps1` 参数固定：

```powershell
param(
    [string]$ManifestPath = 'D:\Codex\projects\统一环境\managed\codex-hooks\manifest.json',
    [string]$CodexHome = 'D:\Codex\.codex',
    [string]$OutputDir = 'D:\Codex\projects\统一环境\reports\codex-hook-inventory'
)
```

入口只读 `hooks.json`、受管/live 文件元数据、runtime 存在性、`config.toml` 中 trust key 的脱敏类别/摘要、User/Process `SERENA_HOME` 和 reparse 祖先；使用 `ReportArtifactPublisher.ps1` 生成 JSON/Markdown，顶层固定 `artifactType="env-governance.codex-hook-inventory"`、`schemaVersion=1`、`readOnly=true`、`executionAllowed=false`。OutputDir 只允许仓库内两个显式报告根，拒绝 ADS 与任一 reparse ancestor。

- [ ] **Step 7：运行绿灯与空白检查**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookPolicy.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookInventory.ps1'
git -C 'D:\Codex\projects\统一环境' diff --check
```

Expected: 两个测试都输出 `ok=True`，`git diff --check` 无输出，fixture 外没有文件改动。
`.gitignore` 精确加入 `reports/codex-hook-policy-test/`、`reports/codex-hook-inventory-test/`、
`reports/codex-hook-deployment-test/`、`reports/codex-hook-runtime-test/`、
`reports/codex-hook-config-test/` 和 `reports/codex-state-policy-test/`。

- [ ] **Step 8：提交**

```powershell
git add -- .gitignore managed/codex-hooks/manifest.json scripts/lib/CodexHookPolicy.ps1 scripts/Get-CodexHookInventory.ps1 tests/Test-CodexHookPolicy.ps1 tests/Test-CodexHookInventory.ps1
git commit -m "feat: add codex hook manifest and inventory"
```

---

### Task 2：Patch-Preserving Plan / Apply / Restore 引擎

**风险：** 最高。该任务先只在 fixture Codex home 上执行；任务完成前不得把 `CodexHome` 指向 live。

**文件：**

- Create: `scripts/New-CodexHookDeploymentPlan.ps1`
- Create: `scripts/Invoke-CodexHookDeployment.ps1`
- Create: `scripts/Restore-CodexHookDeployment.ps1`
- Create: `tests/Test-CodexHookDeployment.ps1`
- Modify: `scripts/lib/CodexHookPolicy.ps1`

**接口：**

- Produces: `Merge-CodexHookRegistry -Manifest <object> -LiveRegistry <object>`，只替换受管 command entries。
- Produces: `New-CodexHookDeploymentPlanDocument -Manifest -Inventory -DesiredRegistry -Mode <registration-repair|full>`。
- Produces plan schema 1：`artifactType,schemaVersion,generationId,generatedAtUtc,manifestSha256,mode,applyEligible,sourceFacts,liveFacts,registryBeforeSha256,registryAfterSha256,actions,environmentActions,postChecks,rollbackRequired`。
- `Invoke-CodexHookDeployment.ps1 -PlanPath <path> -Apply -ApprovedScope codex-hook-governance-2026-07-11 -EvidenceRoot <D path>`。
- `Restore-CodexHookDeployment.ps1 -EvidenceDirectory <path> -Apply`。

- [ ] **Step 1：写 registry merge 红灯**

fixture 在 SessionStart 前后放置未知 group，并给未知 group 增加自定义字段。断言受管 0–4 恢复固定顺序、未知项原样保留、新项只追加：

```powershell
$merged = Merge-CodexHookRegistry -Manifest $manifest -LiveRegistry $live
Assert-Sequence ($merged.hooks.SessionStart | Get-ManagedCommandName) @(
    'codex-provider-stability-guard.cmd',
    'codex-projectless-root-d.cmd',
    'serena-activate-guarded.cmd',
    'serena-dashboard-guard.cmd',
    'codex-github-cli-guard.cmd'
)
Assert-True ($merged.hooks.SessionStart[-1].customOwner -eq 'fixture') '未知 group 必须保留'
```

- [ ] **Step 2：运行红灯并实现纯合并器**

Expected: FAIL，`Merge-CodexHookRegistry` 未定义。实现时用 command path allowlist 识别所有权，不按索引盲删；未知字段通过原对象深拷贝保留。`registration-repair` 模式禁止产生文件覆盖和环境动作。

- [ ] **Step 3：写 apply/rollback 故障注入红灯**

在 `reports/codex-hook-deployment-test/fixture-home` 建立 hooks.json、hooks 文件和未知文件，覆盖：

- source hash 变化；
- live hash 变化；
- target/reparse 父链；
- implementation 发布成功后 wrapper 故障；
- wrapper 成功后 registry postcheck 故障；
- restore 重复执行。

断言任何 final gate 失败时 evidence 只有只读诊断、live 字节不变；中途失败时全部字节恢复。

- [ ] **Step 4：实现部署 evidence 与原子单文件替换**

apply 的固定顺序：

```powershell
Assert-CodexHookDeploymentPlanFresh -Plan $plan
$evidence = New-CodexHookEvidenceDirectory -EvidenceRoot $EvidenceRoot
Backup-CodexHookLiveState -Plan $plan -EvidenceDirectory $evidence
Publish-CodexHookImplementations -Plan $plan
Publish-CodexHookWrappers -Plan $plan
Publish-CodexHookRegistry -Plan $plan
Invoke-CodexHookPostChecks -Plan $plan
Complete-CodexHookEvidence -EvidenceDirectory $evidence -Status 'applied'
```

每个发布函数只能写 plan actions 声明的绝对目标；临时文件必须位于目标同目录，使用 `[IO.File]::Move($temp,$target,$true)`。异常 catch 中调用共享 restore 核心；restore manifest 记录 `path,beforeExists,beforeSha256,backupRelativePath,restoreOrder`。

plan 使用 `ReportArtifactPublisher.ps1` 发布到 `reports/codex-hook-deployment-plan/plan.json` 与 `PLAN.md`。
apply 严格要求 `artifactType="env-governance.codex-hook-deployment-plan"`、`schemaVersion=1`、
`applyEligible=true`、生成时间不超过 1 小时、manifest hash 与当前文件一致，并要求显式参数
`-ApprovedScope 'codex-hook-governance-2026-07-11'`；缺少 `-Apply` 或 scope 不精确时只返回拒绝原因，
不创建 evidence 或 live 临时文件。

- [ ] **Step 5：实现环境动作的窄接口**

只允许 manifest 声明的 User `SERENA_HOME`：

```powershell
if ($action.name -cne 'SERENA_HOME' -or $action.scope -cne 'User' -or $action.after -cne 'D:\Codex\.serena') {
    throw '拒绝未授权的环境动作。'
}
```

环境动作只在 `full` 模式执行；rollback 恢复 before 值。报告只记录 before 是否匹配目标，不记录其他环境变量。
纯函数 `Invoke-CodexHookEnvironmentAction` 接受注入的 `ReadValue` / `WriteValue` scriptblock；fixture 测试
必须使用内存字典 adapter，禁止写真实 User/Machine 环境。production 入口才注入
`[Environment]::GetEnvironmentVariable` / `SetEnvironmentVariable`。

- [ ] **Step 6：运行 fixture 全绿与对抗审查**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookDeployment.ps1'
```

Expected: `ok=True`，所有故障注入均证明回滚。独立 reviewer 攻击 unknown-entry 丢失、TOCTOU、reparse、路径穿越、部分发布和重复 restore。

- [ ] **Step 7：提交**

```powershell
git add -- scripts/lib/CodexHookPolicy.ps1 scripts/New-CodexHookDeploymentPlan.ps1 scripts/Invoke-CodexHookDeployment.ps1 scripts/Restore-CodexHookDeployment.ps1 tests/Test-CodexHookDeployment.ps1
git commit -m "feat: add reversible codex hook deployment"
```

---

### Task 3：纳入 Live 基线并恢复 Trust 索引顺序

**风险：** 最高。该任务首次修改 live `hooks.json`；必须先完成 Task 2 对抗审查，并核对本次已批准设计明确覆盖 registration repair。

**文件：**

- Create: `managed/codex-hooks/hooks/codex-github-cli-guard.cmd`
- Create: `managed/codex-hooks/hooks/codex-github-cli-guard.ps1`
- Create: `managed/codex-hooks/hooks/codex-provider-stability-guard.cmd`
- Create: `managed/codex-hooks/hooks/codex-provider-stability-guard.ps1`
- Create: `managed/codex-hooks/hooks/codex-projectless-root-d.cmd`
- Create: `managed/codex-hooks/hooks/codex-projectless-root-d.js`
- Create: `managed/codex-hooks/hooks/codex-mobile-permission-guard.cmd`
- Create: `managed/codex-hooks/hooks/codex-mobile-permission-guard.py`
- Create: `managed/codex-hooks/hooks/serena-activate-guarded.cmd`
- Create: `managed/codex-hooks/hooks/serena-activate-guarded.ps1`
- Create: `managed/codex-hooks/hooks/serena-dashboard-guard.cmd`
- Create: `managed/codex-hooks/hooks/serena-dashboard-guard.ps1`
- Create: `.gitattributes`
- Modify: `managed/codex-hooks/manifest.json`
- Generate: `reports/codex-hook-inventory/inventory.json`
- Generate: `reports/codex-hook-inventory/REPORT.md`

**接口：**

- Consumes Task 1 inventory and Task 2 registration-repair mode。
- Produces a Git-tracked byte-for-byte live baseline and evidence-backed repaired registry。

- [ ] **Step 1：导入并校验内容等价的 live 基线**

使用 `apply_patch` 创建受管源，语义内容必须与审计快照一致；managed 源统一 LF，`.cmd` 在 Windows
仍使用 CRLF checkout。创建 `.gitattributes`：

```gitattributes
managed/codex-hooks/hooks/*.cmd text eol=crlf
managed/codex-hooks/hooks/*.ps1 text eol=lf
managed/codex-hooks/hooks/*.py text eol=lf
managed/codex-hooks/hooks/*.js text eol=lf
managed/codex-hooks/*.json text eol=lf
```

导入前验证当前 live 输入 SHA-256 仍为：

```text
codex-github-cli-guard.cmd  f15bd903e9198d6865d50df1ad156c3a895e90f6b03a8a36fe24adecf54349c8
codex-github-cli-guard.ps1 e953359767c3eed033aa9ad1ceb52793287d7b27bc531399c642167f14eb0f3d
codex-mobile-permission-guard.cmd 86ffe069008611c2d2854132efd34e1b61b398da43719ddf3e4c3635a23cd621
codex-mobile-permission-guard.py efb7c3838f9085e5ebe1a452352149fb8843db64d6560e552e009b8de71aac64
codex-projectless-root-d.cmd 19fafb8c1c59b4f967a0e60597fb76d7db443c9e7ba04ef31ab53e04cd723b23
codex-projectless-root-d.js f32046560a34c035e28a58bf3c7dee9e770e424de87a313f6fd336c01eacca21
codex-provider-stability-guard.cmd 9bec3b9681c2b255acfc801bd05898f735029a7e9e414bae9b7517627afeedaa
codex-provider-stability-guard.ps1 24e2aa35bb07bf962b7b081a3de7b8f9b48b8b6817ebfadcf052686bc054ccf6
serena-activate-guarded.cmd e6beb44294b1c32bec6741ac417f38030e8fb099b20d47c22b85a5e160c7d4d3
serena-activate-guarded.ps1 87855f0e8d239737461b79207fa9486650d756f3a8af69f98a4279f6c690eb97
serena-dashboard-guard.cmd 784e4f55b174b8a32172f1eae351418328d47ea5a15929d04e6fd1d302a4d096
serena-dashboard-guard.ps1 ab6f29732ef350adc4c038451a3fdad3b1fe0a57f0b02fa774c9c280d1f26bb1
```

任一 live hash 不同就停止，重新做 inventory，不把上述快照当作当前事实。
managed 文件创建后重新计算其工作树 SHA-256 并写入 manifest；不要求 managed hash 与混合换行的
live hash 相同。`registration-repair` 模式必须保持文件 actions=0，因此本任务不会因换行规范化覆盖 live 文件。

- [ ] **Step 2：让 manifest 文件闭包与受管源 hash 一致**

运行 policy/inventory 测试，断言所有 active/compatibility 文件在 managed 与 live 两端存在，managed hash 与 manifest 一致；未注册 mobile `.cmd` 先标记 `compatibility`，不能误删 `.py`。

- [ ] **Step 3：生成 production inventory 与 registration-repair plan**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\scripts\Get-CodexHookInventory.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\scripts\New-CodexHookDeploymentPlan.ps1' -Mode registration-repair
```

Expected plan：唯一 registry 变化是 SessionStart 从 `provider,github,projectless,activate,dashboard` 变为 `provider,projectless,activate,dashboard,github`；文件 actions 和 environmentActions 均为 0；`[hooks.state]` 无 action。

- [ ] **Step 4：对抗审查 production plan**

独立 reviewers 逐项检查 source/live hash、unknown group 保留、Stop/PreToolUse 不变、GitHub 只追加、证据/回滚路径位于 D 盘、没有文件删除或 trust state 修改。

- [ ] **Step 5：执行 registry repair 并验证**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\scripts\Invoke-CodexHookDeployment.ps1' `
  -PlanPath 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan\plan.json' `
  -Apply -ApprovedScope 'codex-hook-governance-2026-07-11' `
  -EvidenceRoot 'D:\Codex\.codex\run-evidence\env-governance'
```

Expected：evidence status=`applied`；hooks.json 严格 JSON 通过；旧 0–3 命令顺序恢复；GitHub 为 4；live 其他文件 hash 不变。当前 Codex 进程可能仍使用旧加载状态，记录 `restartRequired=true`，本任务不重启 app。

- [ ] **Step 6：提交受管基线与当前 inventory**

```powershell
git add -- managed/codex-hooks reports/codex-hook-inventory
git commit -m "feat: manage codex hook baseline"
```

---

### Task 4：共享安全配置写入与 Provider/Serena 重构

**风险：** 最高。错误实现会破坏 `config.toml` 或 Serena YAML；任务只改 managed 源，在 Task 7 前不得发布 live。

**文件：**

- Create: `managed/codex-hooks/hooks/lib/CodexHookRuntime.ps1`
- Create: `managed/codex-hooks/hooks/lib/CodexConfigFile.ps1`
- Create: `tests/Test-CodexHookRuntime.ps1`
- Create: `tests/Test-CodexHookConfig.ps1`
- Modify: `managed/codex-hooks/hooks/codex-provider-stability-guard.ps1`
- Modify: `managed/codex-hooks/hooks/serena-dashboard-guard.ps1`
- Modify: `managed/codex-hooks/manifest.json`

**接口：**

- Produces: `Get-CodexHookSha256`, `Assert-CodexHookDPath`, `Invoke-CodexHookMutex`, `Write-CodexHookAtomicText`, `Invoke-CodexHookProcess`, `ConvertTo-CodexHookRedactedUri`, `Write-CodexHookLatestHealth`。
- Produces: `Set-CodexTomlSectionValue`, `Update-CodexTomlPolicyText`, `Update-SerenaYamlPolicyText`。
- `Write-CodexHookAtomicText -Path -Text -Validator -BackupRoot -ExpectedBeforeSha256`。

- [ ] **Step 1：写 atomic writer 红灯**

fixture 覆盖 validator 抛错、before hash 漂移、目标父链 reparse、backup 失败、replace 故障和重复运行。断言失败时旧字节完全不变，成功时 backup hash 等于旧字节：

```powershell
$before = [IO.File]::ReadAllBytes($target)
Assert-Throws { Write-CodexHookAtomicText -Path $target -Text 'bad' -Validator { throw 'invalid' } -BackupRoot $backupRoot } 'invalid'
Assert-BytesEqual ([IO.File]::ReadAllBytes($target)) $before 'validator 失败不得修改目标'
```

- [ ] **Step 2：实现 runtime 安全原语**

`Invoke-CodexHookMutex` 固定 1500ms，处理 abandoned mutex；`Write-CodexHookAtomicText` 固定流程为 D-path/reparse gate → current hash → 同目录 temp → validator → backup → final hash gate → atomic move → post-read validator。`ConvertTo-CodexHookRedactedUri` 只输出 scheme/host/port，不输出 user-info/query/fragment。

`Write-CodexHookLatestHealth` 只允许写入
`D:\Codex\.codex\run-evidence\codex-hook-health\<manifest hook id>.json`，使用 per-hook 同目录临时文件和原子替换；payload 精确包含 `hookId,runId,startedAtUtc,completedAtUtc,durationMs,ok,changed,restartRequired,errors`，其中 `errors` 先经过脱敏且不得包含 thread/session id。fixture 断言 provider/config 两个并发 writer 只写各自文件、stdout 不受 health 写入影响。

- [ ] **Step 3：写 TOML 无限循环与格式保持红灯**

用以下合法 fixture 证明旧算法会挂、共享新算法必须在 1 秒内返回且幂等：

```toml
[features]

unified_exec = false

[network]
enabled = true
```

另覆盖注释表头、多行 `args` 数组、重复 section/key、multiline string 拒绝、CRLF/LF 保持和未知键保留。

- [ ] **Step 4：实现共享 TOML 纯变换**

禁止复用 provider 的 `$body[0..($body.Count - 2)]`。使用 `ArrayList.RemoveAt()` 删除尾空行，section/key 定位与 Serena 现有数组边界扫描合并为单一实现。最终 temp 文件用官方 Python 3.14 `tomllib` 验证。

- [ ] **Step 5：写 Serena YAML 红灯并实现纯变换**

fixture 包含顶层键、缩进同名键、重复顶层键、注释、quoted scalar 和 malformed YAML。只允许列 0 的 managed key：

```yaml
web_dashboard: false
nested:
  web_dashboard: false
```

Expected：顶层变为 `true`，嵌套值保持 `false`。变换前后都用 Serena Python `yaml.safe_load` 验证 object shape；重复 managed 顶层键失败关闭。

- [ ] **Step 6：重构 provider 与 Serena managed 源**

provider 只维护 features/network/proxy policy，不再包含 TOML 文本编辑副本；Serena guard 只声明 MCP/YAML desired values。两者 dot-source 共享库，锁名保持 `Local\CodexConfigTomlGuard`，内部等待 1500ms。provider 代理输出统一调用 URI 脱敏函数；当前没有持久 watcher 消费者，因此删除 `-Watch` 参数及无限循环分支。

provider desired values 固定：

```powershell
$featureKeys = [ordered]@{
    unified_exec = 'true'; image_generation = 'false'
    responses_websockets_v2 = 'false'; responses_websockets = 'false'
    network_proxy = 'false'; respect_system_proxy = 'false'
}
$networkKeys = [ordered]@{
    enabled = 'true'; allow_local_binding = 'true'; allow_upstream_proxy = 'true'
    proxy_url = '"http://127.0.0.1:10808"'
}
```

Serena TOML desired values固定为当前 D 盘 wrapper、`--context=D:\Codex\.serena\contexts\codex-file-tools.yml`、
`--project-from-cwd`、dashboard enabled/open=false，以及 Python 3.14 的 `UV_PYTHON/PYTHON314_*` 环境。
YAML managed keys 精确为：

```yaml
gui_log_window: false
web_dashboard: true
web_dashboard_open_on_launch: false
web_dashboard_interface: tray_manager
project_serena_folder_location: "D:/Codex/.serena/projects/$projectFolderName/.serena"
```

- [ ] **Step 7：运行绿灯、语法与对抗审查**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookRuntime.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookConfig.ps1'
```

Expected: 两个测试 `ok=True`，其中已包含 PowerShell parser、Python tomllib 和 PyYAML fixture。独立 reviewers 攻击合法 TOML 边界、YAML 键提升、validator 缺失、备份失败、mutex timeout、代理凭据泄漏。

- [ ] **Step 8：提交**

```powershell
git add -- managed/codex-hooks/hooks/lib managed/codex-hooks/hooks/codex-provider-stability-guard.ps1 managed/codex-hooks/hooks/serena-dashboard-guard.ps1 managed/codex-hooks/manifest.json tests/Test-CodexHookRuntime.ps1 tests/Test-CodexHookConfig.ps1
git commit -m "refactor: harden codex hook config writes"
```

---

### Task 5：单一 State Policy Writer

**风险：** 最高。涉及用户线程状态与 Electron 全局状态；只使用脱敏 fixture 做 TDD，production apply 留到 Task 7。

**文件：**

- Create: `managed/codex-hooks/hooks/codex-state-policy-guard.py`
- Create: `tests/Test-CodexStatePolicy.py`
- Modify: `managed/codex-hooks/hooks/codex-projectless-root-d.cmd`
- Modify: `managed/codex-hooks/hooks/codex-provider-stability-guard.ps1`
- Move: `managed/codex-hooks/hooks/codex-mobile-permission-guard.cmd` → `managed/codex-hooks/retired/codex-mobile-permission-guard.cmd`
- Move: `managed/codex-hooks/hooks/codex-mobile-permission-guard.py` → `managed/codex-hooks/retired/codex-mobile-permission-guard.py`
- Move: `managed/codex-hooks/hooks/codex-projectless-root-d.js` → `managed/codex-hooks/retired/codex-projectless-root-d.js`
- Modify: `managed/codex-hooks/manifest.json`

**接口：**

- `codex-state-policy-guard.py --codex-home <D path> [--check-only] [--json]`。
- Produces JSON：`ok,changed,globalState,threadState,restartRequired,errors`；只输出 count/hash/status，不输出 thread IDs。
- Pure functions: `rewrite_projectless_path(value)`, `normalize_global_state(state)`, `select_thread_updates(conn)`。

- [ ] **Step 1：写路径与全局状态纯函数红灯**

Python unittest 覆盖大小写盘符、正/反斜杠、目录边界、`CodexBackup` 误匹配、未知值保持、两个目标 map、heartbeat 非 dict：

```python
self.assertEqual(
    rewrite_projectless_path(r"c:/Users/WINDOWS/Documents/Codex/output"),
    r"D:\Users\WINDOWS\Documents\Codex\output",
)
self.assertEqual(
    rewrite_projectless_path(r"C:\Users\WINDOWS\Documents\CodexBackup"),
    r"C:\Users\WINDOWS\Documents\CodexBackup",
)
```

- [ ] **Step 2：运行红灯并实现纯变换**

Expected: FAIL，module/function 不存在。路径判断使用 `PureWindowsPath` parts 的大小写不敏感比较，不使用裸 `startswith`；只重写精确目录及其子路径。

- [ ] **Step 3：写 atomic/CAS 与 SQLite 红灯**

fixture 用临时 `.codex-global-state.json` 和 SQLite `threads` 表，覆盖：

- JSON 在 temp 写完后被竞争者修改；
- malformed JSON；
- backup 创建失败；
- SQLite busy/rollback；
- check-only；
- 两次运行幂等。

断言竞争时有限重读/重放，无法稳定时退出非零且不覆盖竞争者字节；SQLite 使用 `BEGIN IMMEDIATE`、busy timeout 1500ms 和提交后 drift count=0。
测试根固定为 `D:\Codex\projects\统一环境\reports\codex-state-policy-test`，显式设置
`TMP`、`TEMP` 和 Python `tempfile.tempdir` 到该 D 盘 fixture，禁止使用默认 C 盘临时目录；
`.gitignore` 在 Task 1 同步加入该目录。

- [ ] **Step 4：实现 state writer**

固定流程：Windows 命名 mutex `Local\CodexGlobalStatePolicy` → 读取 bytes/hash → JSON shape 校验 → 两个纯变换 → 同目录 temp+fsync → 写前 hash 比对 → `os.replace` → 回读验证。最多重试 3 次，每次都从最新文件重新应用纯变换。备份目录由 `D:\Codex\.codex\backups_state\codex-state-policy\<timestamp-pid-guid>` 提供。

SQLite 连接固定：

```python
conn = sqlite3.connect(state_db, timeout=1.5)
conn.execute("pragma busy_timeout=1500")
conn.execute("begin immediate")
```

production 运行结束后以 stdlib 原子写入
`D:\Codex\.codex\run-evidence\codex-hook-health\state-policy.json`，字段与 PowerShell health envelope 一致；
`--check-only` 使用 D 盘 fixture health root 或 `--health-root` 显式参数，测试不得写 production health。

- [ ] **Step 5：切换 compatibility wrapper 与 provider 职责**

`codex-projectless-root-d.cmd` 保留注册路径但内容改为：

```bat
@echo off
"D:\Codex\tools\python314-official\python.exe" "D:\Codex\.codex\hooks\codex-state-policy-guard.py" %*
exit /b %ERRORLEVEL%
```

provider 删除 mobile Python 调用和对应 payload 字段；旧 mobile `.cmd/.py` 与 projectless `.js` 在 manifest 标记 `retired`、`deleteLive=false`。

- [ ] **Step 6：运行绿灯与对抗审查**

Run:

```powershell
& 'D:\Codex\tools\python314-official\python.exe' 'D:\Codex\projects\统一环境\tests\Test-CodexStatePolicy.py'
```

Expected: unittest 全部 PASS；测试内部用脱敏 72KB 规模 fixture 做并发压力 100 次，JSON 始终可解析、未知 sentinel 保持。独立 reviewers 攻击路径逃逸、lost update、进程终止、SQLite busy、错误输出泄露和 production 路径误触。

- [ ] **Step 7：提交**

```powershell
git add -- managed/codex-hooks tests/Test-CodexStatePolicy.py
git commit -m "refactor: unify codex state policy writes"
```

---

### Task 6：Wrapper、Serena 环境与可选 Hook 清理

**风险：** 高。会改变 managed registry 和 User `SERENA_HOME` 的期望值，但仍不发布 live。

**文件：**

- Modify: `managed/codex-hooks/manifest.json`
- Modify: `managed/codex-hooks/hooks/*.cmd`
- Modify: `managed/codex-hooks/hooks/codex-github-cli-guard.ps1`
- Modify: `managed/codex-hooks/hooks/serena-activate-guarded.ps1`
- Modify: `tests/Test-CodexHookPolicy.ps1`
- Modify: `tests/Test-CodexHookDeployment.ps1`
- Modify: `tests/Test-CodexHookRuntime.ps1`

**接口：**

- Manifest environment action: `SERENA_HOME`, scope `User`, desired `D:\Codex\.serena`。
- GitHub quick health: `-CheckOnly -Json`；full health: `-Json -CheckAuth -Strict`。
- Serena synthetic hook smoke reads JSON stdin and writes only valid hook protocol JSON or silence。

- [ ] **Step 1：写 wrapper/runtime 红灯**

解析所有 active `.cmd` 并断言只调用 manifest runtime、保留 `%*`、最后透传 `%ERRORLEVEL%`；禁止 `C:\Program Files\nodejs`、`python313-official`、`D:\hermes-data\.npm-global\python.exe` 和裸 `python`。

- [ ] **Step 2：统一 wrapper 与内部 budget**

PowerShell wrapper 使用 7.6.3；state 使用官方 Python 3.14；Serena activate 继续由 PowerShell 读取一次 stdin 并转发。GitHub 两个 mutex 等待各降至 1500ms；quick 模式保留签名/identity/version 但不得做 auth 网络检查。GitHub 和 Serena activate 使用 `Write-CodexHookLatestHealth` 写各自独立 health 文件；Serena activate 必须先捕获 vendor 输出、验证为 SessionStart hook JSON、记录 health，再逐字节输出原 vendor JSON。

- [ ] **Step 3：声明并测试 SERENA_HOME 环境动作**

manifest 增加唯一 environment policy：

```json
{
  "name": "SERENA_HOME",
  "scope": "User",
  "desired": "D:\\Codex\\.serena",
  "restartRequired": true
}
```

fixture apply/restore 证明 before 可恢复；脚本不得接受其他变量名、Machine scope 或 C 盘值。

- [ ] **Step 4：验证 Codex no-op auto-approve retirement**

验证 manifest 已把 `PreToolUse` Serena auto-approve 标记为 retired，并记录原因 `Codex payload does not expose acceptEdits/auto permission modes`。registration-repair 模式仍不得改变 PreToolUse；full 模式把该精确 identity 从 desired active registry 排除。Bash reminder 和 Stop cleanup 保持原 command identity；部署器保留未知 vendor entries。

- [ ] **Step 5：合成 Serena hook 协议测试**

用脱敏 session id 和 `tool_name="Bash"`、`tool_input.command="rg -n hook file.ps1"` 调用 `serena-hooks.exe remind --client=codex`，显式设置 D 盘 fixture `SERENA_HOME`。断言前两次调用不输出 deny但产生计数；第三次调用输出合法 `hookSpecificOutput.hookEventName="PreToolUse"`。activate 输出合法 SessionStart additionalContext，cleanup 删除 fixture session state。

- [ ] **Step 6：运行绿灯与提交**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookPolicy.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookDeployment.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\tests\Test-CodexHookRuntime.ps1'
```

Expected: 全部通过且 live 无变化。

```powershell
git add -- managed/codex-hooks tests
git commit -m "fix: align codex hook runtimes and serena state"
```

---

### Task 7：完整 Live 部署与 Wrapper 级验收

**风险：** 最高。会覆盖 live 受管实现、更新 `hooks.json`、写 User `SERENA_HOME` 并执行 state/config 修复；apply 前必须启用多子代理进行对抗性审查。

**文件：**

- Modify: live allowlist under `D:\Codex\.codex\hooks\` through deployment engine only
- Modify: `D:\Codex\.codex\hooks.json` through deployment engine only
- Modify: User `SERENA_HOME` through deployment engine only
- Generate: `reports/codex-hook-inventory/*`
- Generate: evidence under `D:\Codex\.codex\run-evidence\env-governance\codex-hooks-*\`

**接口：**

- Consumes all Tasks 1–6 and production full deployment plan。
- Produces applied evidence、rollback manifest、latest inventory 和 restartRequired=true。

- [ ] **Step 1：运行完整仓库红绿门**

Run:

```powershell
$pwsh = 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe'
Get-ChildItem -LiteralPath 'D:\Codex\projects\统一环境\tests' -Filter 'Test-*.ps1' | Sort-Object Name | ForEach-Object {
    & $pwsh -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "测试失败：$($_.FullName)" }
}
& 'D:\Codex\tools\python314-official\python.exe' 'D:\Codex\projects\统一环境\tests\Test-CodexStatePolicy.py'
if ($LASTEXITCODE -ne 0) { throw 'Test-CodexStatePolicy.py 失败' }
git -C 'D:\Codex\projects\统一环境' diff --check
```

Expected: 全部 exit 0；专项测试内部覆盖 PowerShell parser、strict JSON、tomllib、PyYAML；仓库在开始生成 production report 前干净。

- [ ] **Step 2：重新生成 live inventory 与 full plan**

plan 必须精确包含：active managed 文件发布、provider/state/Serena/GitHub wrapper 更新、旧 mobile/projectless JS 标记 retired 但不删除、auto-approve 取消注册、User `SERENA_HOME` before/after、registry 最后发布。任何未预期 unknown entry/file 变化阻断 apply。

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\scripts\Get-CodexHookInventory.ps1'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\scripts\New-CodexHookDeploymentPlan.ps1' -Mode full
```

- [ ] **Step 3：多子代理对抗性 pre-apply review**

至少三位 scoped reviewers 分别攻击：

1. source/live hash、unknown preservation、trust/index；
2. config/global-state/SQLite 数据安全与 rollback；
3. timeout、stdout hook protocol、runtime、redaction、docs/manifest 一致性。

所有 Critical/Important 必须先修复并重跑 Step 1–2。

- [ ] **Step 4：执行 full apply**

Run:

```powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\统一环境\scripts\Invoke-CodexHookDeployment.ps1' `
  -PlanPath 'D:\Codex\projects\统一环境\reports\codex-hook-deployment-plan\plan.json' `
  -Apply -ApprovedScope 'codex-hook-governance-2026-07-11' `
  -EvidenceRoot 'D:\Codex\.codex\run-evidence\env-governance'
```

Expected: evidence `status=applied`、所有 source/live hashes 与 plan 一致、registry 顺序为 0–4、auto-approve 已取消、retired live 文件仍存在且未注册、User `SERENA_HOME` 已持久化为 D 盘。

- [ ] **Step 5：运行真实 wrapper 级 postcheck**

按真实入口执行：

```powershell
& 'D:\Codex\.codex\hooks\codex-provider-stability-guard.cmd' -Json -CheckNetwork
& 'D:\Codex\.codex\hooks\codex-github-cli-guard.cmd' -CheckOnly -Json
& 'D:\Codex\.codex\hooks\codex-github-cli-guard.cmd' -Json -CheckAuth -Strict
& 'D:\Codex\.codex\hooks\codex-projectless-root-d.cmd' --json
```

Expected：provider/GitHub/state `ok=true`；TOML/YAML/JSON 均可解析；SQLite `pragma quick_check=ok`；projectless C-prefix=0，D-prefix 与 total 一致；heartbeat/mobile drift=0；输出无 thread IDs/credentials/user-info。

- [ ] **Step 6：失败处理与暂停点**

任一 postcheck 失败立即执行 `Restore-CodexHookDeployment.ps1 -Apply`，再验证旧 hash、registry、User `SERENA_HOME` 和语法。全部通过时保留新状态，但不在当前进程中伪称 SessionStart 已验收；记录必须完整重启 Codex。

- [ ] **Step 7：提交 production inventory 与部署摘要**

```powershell
git add -- reports/codex-hook-inventory managed/codex-hooks
git commit -m "feat: deploy managed codex hooks"
```

---

### Task 8：重启、信任、Fresh SessionStart 与收尾

**风险：** 最高。需要用户在 Codex 自己的审核界面确认新增 GitHub hook；agent 不代写 internal trust state。

**文件：**

- Modify: `D:\Codex\.codex\docs\agent-guidance\host-runbook.md`
- Modify: `README.md`
- Modify: `CONTEXT.md`
- Modify: `docs/specs/2026-07-11-codex-hook-governance-design.md` only if verified behavior differs from approved design
- Modify: `docs/plans/2026-07-11-codex-hook-governance-implementation.md`，完成后记录完成状态
- Regenerate: `reports/codex-hook-inventory/*`

**接口：**

- Consumes Task 7 applied state and user trust decision。
- Produces fresh SessionStart evidence、Serena MCP smoke、mobile permission evidence、最终文档和干净分支。

- [ ] **Step 1：完整重启 Codex 并由用户审核 hook**

在用户确认可中断当前 UI 后退出全部 Codex Desktop/app-server 进程，再重新启动。Codex 显示新增/变化 hook 审核时，用户审核命令路径并信任；不得使用 `--dangerously-bypass-hook-trust` 代替持久审核。

- [ ] **Step 2：验证 fresh SessionStart 实际触发**

在重启前记录 5 个 health 文件的 SHA-256 与 `completedAtUtc`；重启后创建新任务或重新进入会触发 startup/resume 的任务，证明 provider、state、Serena activate/config、GitHub 的 `runId` 全部变化且 `completedAtUtc` 晚于 Codex 新进程启动时间。不得只运行底层 `.ps1`、只看文件存在或沿用 Task 7 手工 postcheck。

- [ ] **Step 3：验证 Serena hooks 与 MCP**

确认 Process `SERENA_HOME=D:\Codex\.serena`；执行真实 shell 调用验证 Bash reminder 在该根产生 hook_data；Stop cleanup 删除对应 session state。Serena MCP 完成 `initialize`、`tools/list`、`read_file`/`list_dir` smoke，dashboard/context 配置保持目标值。

- [ ] **Step 4：验证 mobile-started thread**

由用户从移动端新建一个 fresh thread，检查其第一条 `turn_context` 与 state DB/heartbeat 脱敏计数：`approval_mode=never`、disabled/dangerFullAccess 语义一致、drift count=0。旧线程或静默等待窗口不能替代该证据。

- [ ] **Step 5：更新 runbook、README、CONTEXT 与计划状态**

runbook 记录 managed source、inventory、plan/apply/restore、真实 wrapper 验收、trust/restart 流程和 rollback evidence；README 加入 6 个 hook 专项测试；CONTEXT 指向当前 hook inventory。文档明确 retired 文件仍保留且未注册，不声称已删除。

- [ ] **Step 6：全量验证与最终对抗审查**

重新运行 Task 7 Step 1 的完整测试命令，并运行：

```powershell
& 'D:\Codex\tools\bin\codex.exe' doctor --json
& 'D:\Codex\.codex\hooks\codex-provider-stability-guard.cmd' -Json -CheckNetwork
& 'D:\Codex\.codex\hooks\codex-github-cli-guard.cmd' -Json -CheckAuth -Strict
& 'D:\Codex\.codex\hooks\codex-projectless-root-d.cmd' --check-only --json
git -C 'D:\Codex\projects\统一环境' diff --check
```

Expected: doctor 仅允许与本任务无关且已记录的 optional warning；provider/GitHub/state 为 `ok=true`；Serena MCP smoke、JSON/TOML/YAML 解析均成功。独立 reviewers 检查设计覆盖、代码质量、live/manifest/docs 一致性、回滚可执行性和无隐私泄露。

- [ ] **Step 7：修复所有 Critical/Important，重跑验证并提交**

```powershell
git add -- README.md CONTEXT.md docs reports/codex-hook-inventory
git commit -m "docs: complete codex hook governance"
```

## 完成信号

- 八个任务各自具备红灯、绿灯、任务级评审和独立提交；高风险任务具备对抗审查证据。
- `hooks.json` 的 managed SessionStart 顺序固定为 provider/state/activate/config/GitHub，未知 entries 保留，auto-approve 已取消，retired 文件未删除。
- 不存在 direct write 的 global state/YAML 路径；TOML 合法边界不会循环；所有写入失败保持旧字节并可 restore。
- User/Process `SERENA_HOME` 在完整重启后均为 `D:\Codex\.serena`。
- 真实 wrapper postcheck、fresh SessionStart、GitHub strict、Serena MCP、mobile fresh thread 和 state quick check 全部通过。
- `trusted_hash` 只由 Codex 自身在用户审核后维护；Git diff 中没有 agent 写入的 trust state。
- live/manifest/source hashes 一致，production evidence 可反序回滚，仓库和分支干净。
