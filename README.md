---
type: readme
title: 统一环境治理
tags: [环境治理, 项目说明]
intent: 说明统一环境项目的能力、入口和当前治理边界
---

# 统一环境治理

本项目用于治理本机开发环境：先只读盘点事实，再生成 dry-run 计划，最后只在明确授权下逐项迁移、更新或重建。

核心原则：该共享的共享，该隔离的隔离。共享缓存和可复用工具入口优先放到 D 盘；项目本地 `.venv`、`node_modules`、服务状态和凭据目录默认保持隔离。

仓库当前按五个模块维护：`dev-environment`、`codex-host`、`skill-supply-chain`、`host-safety` 和 `workstation-operations`。导航、依赖与迁移规则见 `modules/README.md`；机器可校验的 ownership/interface/test 真源是 `modules/manifest.json`。当前处于保留现役路径的 `expand` 阶段，尚未拆 Git 仓库。

## 当前能力

- 可信环境治理报告链分别记录 Process、User、Machine PATH，并用 `generationId` 和源 JSON SHA-256 配对校验当前 JSON/Markdown 产物。
- 环境迁移、项目本地环境重建、备份保留和依赖更新均先生成 dry-run；真实迁移、更新或删除仍需对具体项显式授权。
- 备份保留 apply 受 schema、覆盖完整性、候选一致性和 manifest 安全门约束，不从过期报告推断可执行动作。
- Codex 主机钩子治理由 `scripts/Invoke-CodexHostHookReconciliation.ps1` 作为唯一当前生产入口统一维护；当前受管 lifecycle hooks 为 `codex-state-preflight`、Serena activation、cleanup 与 reminder。它提供只读 `Check`、显式 `Repair` 与受 evidence 约束的 `Restore`；后者只能使用同一 Codex home 固定 evidence root 的直接子目录。生产 wrapper 通过受管 hidden-console launcher 启动最终 PowerShell/Python 进程，显式禁止外部控制台窗口，同时保留协议流与退出码。旧 ProductionFull 与 registration-repair façade 已稳定拒绝，历史 fixture/core 仅保留测试价值；协调器不写入 `approval_policy`、`sandbox_mode`、`features.hooks` 或 `unified_exec`，省略 `features.hooks` 时遵循官方默认启用，合法的 inline `[hooks]` 保留，退役 hook 不会由 Restore 重建。manifest 的 `trustedProjects` 仅补齐精确项目根，`retiredProjectTrusts` 是精确根 denylist：evidence 与 Restore 均不得保留或回流退役 trust，其余用户 trust 保留。
- Codex CLI、Node、npm、Git、gh、uv、sqlite3、CodeGraph 和 Serena 主链路已验证；Serena 运行在官方 Python 3.14.6 上。其运行时版本与解析依赖属于易变状态，操作前必须实时复核。
- 共享环境入口已验证：`planning-with-files`、CMake `4.3.3`、Rust toolchain `1.96.1` 等均保持可用；skill ledger coverage 为 `missing=0` / `duplicates=0`。
- Python 默认入口已切到官方 `3.14.6`；`.NET` 默认入口当前未收敛，具体 live 状态与待授权修复边界记录在 `docs/environments/zi-xi-shi.md`。WSL、Windows Terminal、PowerShell 与 CodeGraph 的设备级版本和进程采用边界同样由该设备文档和主机 runbook 维护，不在项目概览写死易变版本。
- 已固化上游稳定 skill 约束并同步 Matt stable catalog：稳定目录与上游对齐，严格资源闭包和 ledger 一致性检查通过；活动数量、哈希和上游版本属于易变状态，操作前必须实时复核。`skills/in-progress/**` 不安装；用户明确退役的 skill 不保留本机备份。
- Skill Catalog 的仓库源实现已落地：默认只读扫描 active、system 和 plugin-cache，来源以本机 ledger / `SOURCE.md` 为准；它不安装或更新 skill、不访问网络、不读取凭据、不注册 hook。实现入口是 `scripts/generate_skill_catalog.py`，部署后的本机派生输出位于 `D:\Codex\.codex\skill-catalog\`；一次性运行证据按 run id 写入 `D:\Codex\.codex\run-evidence\`。
- 功能钩子分层恢复的 path inventory/state policy、local-only preflight、Serena 行为 hooks、provider/GitHub 显式维护和 production/legacy manifest 分离均已有专项实现，并通过定向 fixture 回归。fixture 全量 reconciler 回归不依赖 live 配置所有者；获授权的 live Repair 与验收只通过当前 reconciler 和当前主机状态执行，不得从历史 evidence 推断或手工写入 Serena 配置或权限策略值。
- Git 的唯一现役发布政策要求全部普通 closeout/push skill（包括 GitHub `github:yeet` 与 `neat-freak`）只发布到用户拥有远端的 `main`。2026-07-13 的 default-branch overlay 模板和现役插件 cache 仍保留旧实现，当前属于 `pending drift`；受控修复完成前，它们不构成向非 `main` 分支发布的授权。临时分支只在事前确认后使用，历史 patch-stack 只报告、不自动创建或删除。

## 关键入口

- 项目上下文：`CONTEXT.md`
- 模块导航与归属真源：`modules/README.md`、`modules/manifest.json`
- 设备差异与跨设备验证：`docs/environments/zi-xi-shi.md`、`docs/environments/ban-gong-shi.md`
- 迁移政策：`docs/env-governance/d-drive-layout-and-migration-policy.md`
- Codex 远端插件 catalog guard：`docs/env-governance/remote-plugin-catalog-guard.md`
- Skill Catalog 仓库源：`scripts/generate_skill_catalog.py`、`docs/plans/2026-07-13-local-skill-catalog-implementation.md`
- Skill 安装事务的仓库源已形成 installer、command wrapper 与 catalog generator 的三文件部署闭包；现役 `D:\Codex\.codex\scripts\` 是受管部署产物，installer 从同目录解析 generator，不依赖项目源仓库路径。后续源文件变更、移动或拆分仓库前必须通过 `scripts/Deploy-SkillInstallGuarded.ps1` 重新部署并核验 hash；现役入口仍是 `D:\Codex\.codex\scripts\install-skill-guarded.cmd`；设计见 `docs/specs/2026-07-14-skill-install-guarded-wrapper.md`。
- Codex 主机钩子治理：`docs/specs/2026-07-11-host-hook-reconciliation-design.md`
- Codex Hook 治理设计：`docs/specs/2026-07-11-codex-hook-governance-design.md`
- 功能钩子分层恢复设计/计划：`docs/specs/2026-07-13-functional-hook-preflight-design.md`、`docs/plans/2026-07-13-functional-hook-preflight.md`
- Git `main`-only 现役政策与历史 default-branch overlay：`docs/specs/2026-07-13-github-default-branch-skill-policy-design.md`、`docs/plans/2026-07-13-github-default-branch-skill-policy-implementation.md`
- 本地 tracker/spec/tickets：`.scratch/unified-env/`
- 可信盘点设计：`docs/specs/2026-07-10-environment-inventory-trust-design.md`
- 可信盘点实施计划：`docs/plans/2026-07-10-environment-inventory-trust-implementation.md`
- 环境更新执行报告：`reports/env-update-execution-20260706/REPORT.md`

## 主要报告

以下报告都是带时间戳的事实快照。JSON/Markdown 配对校验只证明同一次生成的来源一致；真实迁移、更新或删除前必须重新生成相关报告并现场核验。

- 只读盘点：`reports/env-inventory/REPORT.md`
- 迁移 dry-run：`reports/env-migration-plan/PLAN.md`
- pip cache 迁移证据：`reports/env-migration-execution/pip-cache/`
- 更新准备：`reports/env-update-readiness/REPORT.md`
- 失效 PATH 入口清理 dry-run：`reports/stale-path-entry-cleanup-dry-run/PLAN.md`
- 项目本地环境审查：`reports/project-local-env-review/REPORT.md`
- 项目本地环境重建 dry-run：`reports/project-local-env-rebuild-plan/PLAN.md`
- 当前备份膨胀治理 dry-run：`reports/backup-retention-dry-run-current/BACKUP-RETENTION-DRY-RUN.md`
- 备份清理 apply manifest：仅在最新 schema 3 production dry-run 现场验证通过、覆盖完整且存在 directory candidates 时生成；当前状态以上述报告为准。
- `codex-account-switch` 依赖更新 dry-run：`reports/codex-account-switch-dependency-update-dry-run/PLAN.md`

## 验证命令

从仓库根目录使用 Node 编排 PowerShell 7.6+ 测试。PowerShell 只逐项启动测试文件；文件枚举、排序和参数化用例编排均由 Node 完成。默认使用 PATH 中的 `pwsh`；非标准路径可通过 `PWSH_PATH` 指定完整 `pwsh.exe` 路径，脚本会确认它是 PowerShell 并拒绝低于 7.6 的版本：

```powershell
node .\scripts\Run-PowerShellTests.cjs
```

仅查看将执行的测试清单：

```powershell
node .\scripts\Run-PowerShellTests.cjs --list
```

查看某个模块的默认 `fixture` 测试清单：

```powershell
node .\scripts\Run-PowerShellTests.cjs --module dev-environment --list
```

`host-live` 会读取真实宿主状态或写入受管 evidence，只能显式选择，例如 `--module codex-host --profile host-live --list`。无 `--module` 的旧入口保持原有全量 PowerShell 行为。

模块 ownership/interface/test 边界校验：

```powershell
node .\scripts\Validate-ModuleBoundaries.cjs --json
node .\tests\Test-ModuleBoundaries.cjs
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
