# 统一环境项目交接：项目本地环境阶段

生成时间：2026-06-30 23:14:03 +08:00

> Superseded：本文件是项目本地环境阶段的历史交接。后续已经完成 PATH 清理、备份保留 apply、`codex_switch` 备份保留 dry-run 扩展和多批人工授权删除。当前状态见 `docs/handoffs/2026-07-01-env-governance-cleanout-closeout-handoff.md`、`README.md` 和 `CONTEXT.md`。

## 当前目标

用户要继续推进“本机环境尽量统一、保持最新、能复用则复用、不能复用则隔离”的治理工作。当前已经进入“项目本地环境”阶段，但仍必须遵守项目政策：项目本地 `.venv`、`node_modules`、`.conda` 默认不自动迁移、不自动合并、不自动删除、不自动重建。

下一会话重点建议：先围绕 `D:\Codex\projects\codex-account-switch\node_modules` 做项目级依赖更新 dry-run 计划，而不是直接执行 `npm ci` 或更新依赖。

## 必读文件

- 项目说明：`D:\Codex\projects\统一环境\AGENTS.md`
- D 盘迁移政策：`D:\Codex\projects\统一环境\docs\env-governance\d-drive-layout-and-migration-policy.md`
- 项目本地环境审查包：
  - `D:\Codex\projects\统一环境\reports\project-local-env-review\REPORT.md`
  - `D:\Codex\projects\统一环境\reports\project-local-env-review\review.json`
- 项目本地环境重建 dry-run 计划：
  - `D:\Codex\projects\统一环境\reports\project-local-env-rebuild-plan\PLAN.md`
  - `D:\Codex\projects\统一环境\reports\project-local-env-rebuild-plan\plan.json`
- 统一更新准备报告：
  - `D:\Codex\projects\统一环境\reports\env-update-readiness\REPORT.md`
  - `D:\Codex\projects\统一环境\reports\env-update-readiness\readiness.json`

## 已完成状态

本项目本轮 issue 全部完成：

- `01-readonly-env-inventory.md`：done
- `02-harden-readonly-inventory.md`：done
- `03-generate-dry-run-migration-plan.md`：done
- `04-migrate-low-risk-pip-cache.md`：done
- `05-project-local-env-review-pack.md`：done
- `06-unified-update-readiness-report.md`：done
- `07-d-drive-layout-and-migration-policy.md`：done
- `08-project-local-env-rebuild-dry-run.md`：done

本阶段提交：

- `b27378c feat: 生成项目本地环境重建 dry-run 计划`
- `c11401a docs: 收口只读盘点 issue 状态`
- `ffc46e4 feat: 生成项目本地环境审查包`
- `159c9e2 feat: 迁移 pip cache 到 D 盘`
- `e8b9039 docs: 沉淀 D 盘环境迁移政策`
- `114e701 feat: 生成统一更新准备报告`
- `e04480a feat: 生成环境迁移 dry-run 计划`
- `c6d8435 chore: 初始化统一环境治理基线`

## 当前事实

- `pip cache` 已迁到 `D:\Codex\.cache\pip`。
- 当前 User 和 Process 的 `PIP_CACHE_DIR` 都是 `D:\Codex\.cache\pip`。
- 当前迁移计划里 `migrationPlans = 0`，没有新的明确安全迁移候选。
- 项目本地环境重建计划摘要：
  - 总计划项：5
  - 可计划重建：1
  - 需 owner 决策：5
  - 缺少重建来源阻塞：1
  - 高风险或状态敏感：3
- 当前唯一 `planned-rebuild` 项是 `D:\Codex\projects\codex-account-switch\node_modules`，但 `executionAllowed=false`，仍需 owner 授权。

## 重要风险边界

- 不要直接删除旧 C 盘 pip cache 源目录。旧源保留是回滚边界；删除需要单独显式授权。
- 不要直接删除、移动、重建任何 `.venv`、`node_modules` 或 `.conda`。
- 不要在 dirty repo 里更新依赖、锁文件或 `node_modules`。
- `requirements.txt` 不视为锁文件；不要为 `yangyangzi-direct-qqbot` 输出或执行 `pip install -r requirements.txt` 之类候选命令。
- 高风险或长期服务项目必须先确认 owner、停机窗口、启动命令、健康检查、状态恢复和回滚步骤。
- 输出和证据必须留在 D 盘允许路径，不要写 C 盘。
- `D:\Codex\projects\统一环境\reports\backup-retention\` 已在 neat-freak 收尾时迁到 `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260630-221159\`，因为它是 host-level skill 备份清理 dry-run 证据，不属于项目 reports 的长期内容。

## 刚进入的项目本地环境

已只读检查 `D:\Codex\projects\codex-account-switch\node_modules`：

- 项目根：`D:\Codex\projects\codex-account-switch`
- `package.json` 版本：`1.5.12`
- `package-lock.json`：lockfileVersion 3，package entries 78
- 当前 Node：`v24.15.0`
- 当前 npm：`11.12.1`
- `npm ls --depth=0 --json` 正常，顶层依赖包括：
  - `@tauri-apps/api@2.10.1`
  - `@tauri-apps/cli@2.10.1`
  - `typescript@5.9.2`
  - `vite@7.1.4`
- `node_modules` 和项目根不是 reparse point。

此处原先记录的 `codex-account-switch` dirty 状态已在 2026-06-30 后续修复中收口：

- 修复提交：`a31d9a4 fix: harden runtime cleanup without pruning auth backups`
- 后续备份/runtime 交接：`D:\Codex\projects\统一环境\docs\handoffs\2026-06-30-backup-retention-runtime-cleanup-handoff.md`
- 当前 `codex-account-switch` runtime 事实以后续备份/runtime 交接为准；不要再按本文件旧段落假设目标项目仍有未提交 runtime 改动。

## 依赖更新发现

只读查询已执行：

- `npm outdated --json --depth=0`
- `npm audit --json`

结果摘要：

- `@tauri-apps/api`：`2.10.1 -> latest 2.11.1`
- `@tauri-apps/cli`：`2.10.1 -> latest 2.11.4`
- `typescript`：`5.9.2 -> latest 6.0.3`
- `vite`：`7.1.4 -> latest 8.1.1`
- `npm audit` 报告：
  - `vite` direct high vulnerability，fixAvailable 指向 `vite@7.3.6`
  - `postcss` transitive moderate vulnerability，fixAvailable true

关键判断：直接 `npm ci` 只会重建当前旧依赖，不会让环境保持最新。下一步应该先做项目级依赖更新 dry-run，优先考虑安全补丁 `vite 7.1.4 -> 7.3.6`，不要直接跳 `vite 8` 或 `typescript 6`。

## 建议下一步

1. 在 `D:\Codex\projects\统一环境` 中新增 Issue 09，范围限定为 `codex-account-switch` 依赖更新 dry-run。
2. 只生成计划和报告，不修改 `D:\Codex\projects\codex-account-switch`。
3. 计划内容应包含：
   - 当前 dirty worktree 阻塞说明。
   - 安全补丁优先级：`vite 7.1.4 -> 7.3.6`。
   - 为什么暂不跳 `vite 8`、`typescript 6`。
   - 预期真实执行命令预览，例如 `npm install vite@7.3.6 --save-dev --package-lock-only` 或等价方案，但不要执行。
   - 验证命令预览：`npm ls --depth=0`、`npm audit`、`npm run version:check`、必要时 Windows 项目验证。
   - 回滚边界：恢复 `package.json` / `package-lock.json`，不删除现有 `node_modules`。
4. 等目标项目 dirty 状态由用户确认后，再决定是否真实更新。
5. 不需要再处理 `reports/backup-retention/`；该证据已迁到 `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260630-221159\`。

## 建议 skills

- `implement`：用于新增 Issue 09、脚本、测试和报告。
- `review`：用于完成前对依赖更新 dry-run 计划做审查。
- `ask-matt`：如果下一会话不确定该走哪个 Matt 流程，先用它路由。
- `artifact-migration`：仅当用户要处理 `reports/backup-retention/` 或其他错放产物时使用。

## 验证记录

2026-06-30 全套相关测试已通过：

- `tests\Test-ProjectLocalEnvRebuildDryRunPlan.ps1`
- `tests\Test-ProjectLocalEnvReviewPack.ps1`
- `tests\Test-EnvMigrationPlan.ps1`
- `tests\Test-PipCacheMigration.ps1`
- `tests\Test-EnvUpdateReadiness.ps1`
- `tests\Test-DDrivePolicyDocs.ps1`
- `tests\Test-EnvInventory.ps1`

## 当前 Git 状态

在 `D:\Codex\projects\统一环境`：

- 已提交到 `main`，最新提交 `b27378c feat: 生成项目本地环境重建 dry-run 计划`。
- 本 handoff 文档创建后会在 neat-freak 收尾提交中纳入版本控制。
- `reports/backup-retention/` 已迁出项目目录。
