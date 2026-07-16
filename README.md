# 统一环境治理

本项目用于治理本机开发环境：先只读盘点事实，再生成 dry-run 计划，最后只在明确授权下逐项迁移、更新或重建。

核心原则：该共享的共享，该隔离的隔离。共享缓存和可复用工具入口优先放到 D 盘；项目本地 `.venv`、`node_modules`、服务状态和凭据目录默认保持隔离。

## 当前能力

- 可信环境治理报告链分别记录 Process、User、Machine PATH，并用 `generationId` 和源 JSON SHA-256 配对校验当前 JSON/Markdown 产物。
- 环境迁移、项目本地环境重建、备份保留和依赖更新均先生成 dry-run；真实迁移、更新或删除仍需对具体项显式授权。
- 备份保留 apply 受 schema、覆盖完整性、候选一致性和 manifest 安全门约束，不从过期报告推断可执行动作。
- Codex 主机钩子治理由 `scripts/Invoke-CodexHostHookReconciliation.ps1` 作为唯一当前生产入口统一维护；当前受管 lifecycle hooks 为 `codex-state-preflight`、Serena activation、cleanup 与 reminder。它提供只读 `Check`、显式 `Repair` 与受 evidence 约束的 `Restore`；后者只能使用同一 Codex home 固定 evidence root 的直接子目录。旧 ProductionFull 与 registration-repair façade 已稳定拒绝，历史 fixture/core 仅保留测试价值；协调器不写入 `approval_policy`、`sandbox_mode`、`features.hooks` 或 `unified_exec`，省略 `features.hooks` 时遵循官方默认启用，合法的 inline `[hooks]` 保留，退役 hook 不会由 Restore 重建。
- Codex CLI、Node、npm、Git、gh、uv、sqlite3、CodeGraph 和 Serena 主链路已验证；Serena 运行在官方 Python 3.14.6 上，并通过 uv override 使用 `anthropic==0.116.0`。
- 共享环境入口已验证：`planning-with-files`、CMake `4.3.3`、Rust toolchain `1.96.1` 等均保持可用；skill ledger coverage 为 `missing=0` / `duplicates=0`。
- 已按用户授权修复默认入口：`.NET` 默认命中 D 盘 SDK `10.0.301`，Python 默认切到官方 `3.14.6`；WSL 当前判断为“不确实需要”，未安装、未启用、未初始化；CodeGraph 活动版本已切换为 `1.4.1`，Codex Desktop 已完整重启并通过 fresh MCP smoke。
- 已固化上游稳定 skill 约束并同步 Matt stable catalog：稳定目录与上游对齐，严格资源闭包和 ledger 一致性检查通过；活动数量、哈希和上游版本属于易变状态，操作前必须实时复核。`skills/in-progress/**` 不安装；用户明确退役的 skill 不保留本机备份。
- 本机 Skill Catalog 生成器已落地：默认只读扫描 active、system 和 plugin-cache，来源以本机 ledger / `SOURCE.md` 为准；它不安装或更新 skill、不访问网络、不读取凭据、不注册 hook。实现入口是 `scripts/generate_skill_catalog.py`，本机派生输出和运行证据位于 `D:\Codex\.codex\skill-catalog\` 与 `D:\Codex\.codex\run-evidence\skill-catalog\`。
- 功能钩子分层恢复的 path inventory/state policy、local-only preflight、Serena 行为 hooks、provider/GitHub 显式维护和 production/legacy manifest 分离均已有专项实现，并通过定向 fixture 回归。fixture 全量 reconciler 回归不依赖 live 配置所有者；仅 live Repair 与 live 验收仍待配置所有者明确 Serena 配置及权限策略来源，不得从历史 evidence 推断或自动写入这些值。
- GitHub 与收尾 skill 已统一为“解析远端默认分支后发布”；临时分支只在说明必要性并获确认后使用，patch-stack 仅报告、不自动创建或删除。实现状态与证据见对应设计和计划文档。

## 关键入口

- 项目上下文：`CONTEXT.md`
- 设备差异与跨设备验证：`docs/environments/`
- 迁移政策：`docs/env-governance/d-drive-layout-and-migration-policy.md`
- 本机 Skill Catalog：`scripts/generate_skill_catalog.py`、`docs/plans/2026-07-13-local-skill-catalog-implementation.md`
- Skill 安装事务已统一到 `D:\Codex\.codex\scripts\install-skill-guarded.cmd`：它在安装/更新后同步 `SOURCE.md`、统一 ledger、资源闭包和 catalog，失败时回滚；设计见 `docs/specs/2026-07-14-skill-install-guarded-wrapper.md`。
- Codex 主机钩子治理：`docs/specs/2026-07-11-host-hook-reconciliation-design.md`
- Codex Hook 治理设计：`docs/specs/2026-07-11-codex-hook-governance-design.md`
- 功能钩子分层恢复设计/计划：`docs/specs/2026-07-13-functional-hook-preflight-design.md`、`docs/plans/2026-07-13-functional-hook-preflight.md`
- Git 默认分支与收尾 skill 策略：`docs/specs/2026-07-13-github-default-branch-skill-policy-design.md`、`docs/plans/2026-07-13-github-default-branch-skill-policy-implementation.md`
- 本地 tracker/spec/tickets：`.scratch/unified-env/`
- 可信盘点设计：`docs/specs/2026-07-10-environment-inventory-trust-design.md`
- 可信盘点实施计划：`docs/plans/2026-07-10-environment-inventory-trust-implementation.md`
- 环境更新执行报告：`reports/env-update-execution-20260706/REPORT.md`

## 主要报告

- 只读盘点：`reports/env-inventory/REPORT.md`
- 迁移 dry-run：`reports/env-migration-plan/PLAN.md`
- pip cache 迁移证据：`reports/env-migration-execution/pip-cache/`
- 更新准备：`reports/env-update-readiness/REPORT.md`
- 失效 PATH 入口清理 dry-run：`reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`
- 当前备份膨胀治理 dry-run：`reports/backup-retention-dry-run-current/BACKUP-RETENTION-DRY-RUN.md`
- 备份清理 apply manifest：当前没有可发布的 schema 2 manifest；生产 dry-run 覆盖不完整，安全门已拒绝生成。
- `codex-account-switch` 依赖更新 dry-run：`reports/codex-account-switch-dependency-update-dry-run/PLAN.md`
- 项目本地环境分类刷新：`.scratch/unified-env/issues/12-project-local-env-classification-refresh.md`
- `codex_switch` 安装回滚备份保留 dry-run：`.scratch/unified-env/issues/14-codex-switch-installed-backup-retention.md`
- 备份保留 apply 执行：`.scratch/unified-env/issues/15-backup-retention-apply-execution.md`
- `codex_switch` 旧式平铺备份文件删除：`.scratch/unified-env/issues/16-codex-switch-flat-backup-delete.md`
- 三类人工审查项删除：`.scratch/unified-env/issues/17-manual-review-cache-staging-backup-delete.md`

## 验证命令

从仓库根目录使用 PowerShell 7.6+ 运行 PowerShell 测试。普通测试可直接按文件运行；参数化的 hook hardening 套件必须按 `-Case` 逐项运行：

```powershell
$tests = Get-ChildItem -LiteralPath '.\tests' -Filter 'Test-*.ps1' -File |
    Where-Object Name -ne 'Test-CodexHookProductionRegistrationRepairHardening.ps1' |
    Sort-Object Name
foreach ($test in $tests) {
    & ([Environment]::ProcessPath) -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "$($test.Name) 失败，退出码：$LASTEXITCODE"
    }
}

$hardeningCases = @(
    'semantic-noop', 'crash-applying-deployed', 'crash-applied-before',
    'crash-applying-before', 'terminal-incompatible', 'third-hash-rejected',
    'postpublish-source-drift', 'postpublish-live-drift',
    'postpublish-static-and-registry-third', 'rollback-cas-race',
    'rollback-write-excluding-lease', 'forged-evidence', 'projection-summary'
)
foreach ($case in $hardeningCases) {
    & ([Environment]::ProcessPath) -NoProfile -File '.\tests\Test-CodexHookProductionRegistrationRepairHardening.ps1' -Case $case
    if ($LASTEXITCODE -ne 0) {
        throw "Test-CodexHookProductionRegistrationRepairHardening.ps1 -Case $case 失败，退出码：$LASTEXITCODE"
    }
}
```

仓库还包含 Python 与 Node 专项测试；使用已验证的 Python/Node 入口分别运行：

```powershell
python -B .\tests\Test-CodexStatePathInventory.py
python -B .\tests\Test-CodexStatePolicy.py
python -B .\scripts\generate_skill_catalog.py --dry-run
node .\tests\Test-GitDefaultBranchSkillPolicy.cjs
node .\tests\Test-GitHubDefaultBranchSkillOverlay.cjs
```

## 安全边界

- 不自动迁移 `C:\Users`、`Program Files`、WindowsApps、凭据、浏览器 profile、数据库或服务状态。
- 不自动删除 C 盘旧源目录；删除需要单独显式授权。
- 不跨项目复用项目本地依赖目录。
- 不在 dirty repo 中更新依赖、锁文件或环境目录。
- 输出和证据必须留在 D 盘允许路径。

## Git 分支策略

- 本项目是独立私有治理仓库，不是第三方上游的本地补丁栈仓库。
- 不维护 `patch-stack/*` 远端分支；回滚和审计以 `main` 的普通 Git 历史、报告和证据目录为准。
- 只有名称或职责明确为 `*-local-patches` 的私有补丁栈仓库才使用 `patch-stack/*`。
