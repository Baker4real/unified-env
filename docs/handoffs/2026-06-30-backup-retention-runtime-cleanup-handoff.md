# 备份膨胀与 runtime 清理修复交接

生成时间：2026-06-30 23:24:05 +08:00

> Superseded：本文件是备份保留工具实现前后的历史交接。2026-07-01 已在用户授权下执行备份保留 apply、`codex_switch` 平铺备份删除和三类人工审查项删除。当前状态见 `docs/handoffs/2026-07-01-env-governance-cleanout-closeout-handoff.md`、`README.md` 和 `CONTEXT.md`。

## 当前结论

本轮目标来自用户反馈：本机似乎有五千多个 skill 备份，同一个项目同一种备份反复生成，期望从第一性原理出发梳理并最终做到“同一种备份按时间倒序最多保留 5 个”。

当前状态：

- 已完成只读 dry-run 盘点，没有删除或移动真实备份。
- 已完成对 `codex-account-switch` 的 runtime/autosave 修复，避免错误清理破坏原始核心功能。
- 真正执行历史备份清理仍需要用户对路径和类别做显式确认。

## 必读文件和证据

- 当前项目说明：`D:\Codex\projects\统一环境\AGENTS.md`
- D 盘迁移政策：`D:\Codex\projects\统一环境\docs\env-governance\d-drive-layout-and-migration-policy.md`
- 旧阶段 handoff：`D:\Codex\projects\统一环境\docs\handoffs\2026-06-30-project-local-env-handoff.md`
- 备份清理 dry-run 证据：
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260630-221159\skill-backup-cleanup-dry-run-20260630-221159.md`
  - `D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260630-221159\skill-backup-cleanup-dry-run-20260630-221159.json`
- 已修复代码仓库：`D:\Codex\projects\codex-account-switch`
- 已修复提交：`a31d9a4 fix: harden runtime cleanup without pruning auth backups`

## 关键事实

dry-run 报告摘要：

- 保护项：7 个
- 候选项：262 个
- 候选体积：1946.25 MB
- 候选项内 `SKILL.md` 数：2737 个
- 最大低风险候选曾包括 runtime 插件缓存，例如 `D:\Codex\.codex\account_backup\windows\refresh_runtime\plugins`

重要修正：

- dry-run 报告中的“先修改 codex-account-switch 的运行态复制策略，避免继续把插件 skill 缓存复制进账号 runtime”这条建议已经被后续对抗性审查和上游源码对照推翻。
- 上游 `origin/main` 的核心行为是 runtime 继续共享 `plugins/cache/sqlite`，只隔离清理 `rules/skills/vendor_imports/memories`。
- 因此后续 agent 不应再把 `plugins` 或 `.tmp` 整体加入自动删除范围，也不应把 `_autosave` 做无确认自动清理。

## 已完成修复

在 `D:\Codex\projects\codex-account-switch`：

- `src-tauri/shared/runtime/runtime_isolation.rs`
  - 保持 `RUNTIME_SHARED_DIRS = ["plugins", "cache", "sqlite"]`，与上游核心行为一致。
  - 保持 `RUNTIME_REMOVED_DIRS = ["rules", "skills", "vendor_imports", "memories"]`。
  - runtime 删除路径增加 relative/path traversal、symlink、Windows reparse point、ancestor guard 防护。
- `src-tauri/shared/runtime/fs_ops.rs`
  - `autosave_auth` 不清理旧快照。
  - 增加唯一目录创建逻辑，避免同秒 timestamp 冲突覆盖或写入已有快照。
- `src-tauri/win/runtime/refresh_runtime.rs`
- `src-tauri/mac/runtime/refresh_runtime.rs`
  - 测试覆盖 refresh runtime 仍保留 `.tmp/plugins`，且仍执行上游预期的共享资源复制。

验证记录：

- `cargo test --manifest-path D:\Codex\projects\codex-account-switch\src-tauri\Cargo.toml`：146 passed
- `git diff --check`：无空白错误
- `D:\Codex\projects\codex-account-switch`：当前工作区干净，分支 `codex/clean-codex-switch-local-patches`

## 不要做的事

- 不要直接删除 `auth.json`、profile、quota cache、install state 或 `_autosave` 历史快照。
- 不要把 `plugins`、`cache`、`sqlite` 从 runtime 共享列表移除。
- 不要把 `plugins` 或 `.tmp` 整体加入自动 prune 范围。
- 不要根据 dry-run 报告直接执行删除；它只是只读证据。
- 不要清理 `run-evidence`、`.codex-c-backups`、历史账号备份等高/中风险项，除非用户单独确认。

## 建议下一步

1. 先让用户确认是否执行低风险清理，不要默认执行。
2. 若用户确认，优先只处理 dry-run 报告里低风险且可重建的 runtime/cache 类候选，并先再次生成最新 dry-run。
3. 对“同项目同备份类型按时间倒序最多保留 5 个”的规则，建议实现为显式清理工具或 dry-run/apply 两阶段脚本，不要藏进登录、refresh、autosave 等核心生命周期函数。
4. 若继续做项目本地依赖治理，再回到旧 handoff 中的 Issue 09 建议；但先以当前 `codex-account-switch` 已干净、已有 `a31d9a4` 提交为准。

## 建议 skills

- `storage-analyzer`：继续做只读存储盘点和风险分级。
- `review`：执行清理前做对抗性审查，重点攻击误删、reparse/junction、路径归属和回滚边界。
- `implement`：如果要实现 dry-run/apply 两阶段清理脚本，用它约束小步实现、测试和提交。
- `artifact-migration`：仅当要迁移错放证据或 report 时使用。
- `karpathy-guidelines`：继续保持第一性原理、最小改动和可验证成功标准。

## 交接给下一位 agent 的一句话

当前不要再改 runtime 原始共享行为；真正待办是重新生成 dry-run 并取得用户显式授权，做一个不会碰认证文件、不会穿越 junction/reparse、能按“同项目同备份类型按时间倒序最多保留 5 个”执行的备份清理流程。
