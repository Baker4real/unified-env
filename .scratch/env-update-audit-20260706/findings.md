# 本机环境更新与整洁审计发现

## 已确认边界

- `docs/env-governance/d-drive-layout-and-migration-policy.md` 要求真实迁移或更新入口切换前必须重新 inventory、dry-run、显式授权、验证和回滚。
- `skill-install-guard` 只适用于单个候选 skill 的 install/update gate，不适合作为全局清理工具。
- `writing-great-skills` 是本机 skill 创建、更新、重写、审计、路由、本地重构的硬门槛。

## 初步事实

- 2026-07-06 新 inventory 已刷新到 `reports/env-inventory/`。
- 2026-07-06 新 update readiness 已刷新到 `reports/env-update-readiness/`。
- GSD global capsule 当前 disabled；本轮不是 GSD lifecycle 工作。
- 项目 git 起始状态为 `## main`，无已显示的未提交改动；刷新报告后会产生项目内报告变更。

## 待补充

## 子代理审查结论

- 环境治理：不能把 active skills/plugins/account backup/run-evidence 当普通清理项；项目本地环境和系统目录必须阻止自动处理。
- Skill 治理：active skills 共 136 个，全部有 `SOURCE.md`，ledger missing 0、duplicate 0、extra active 0；3 个 source group 远端 HEAD 已变化，需 staged refresh。
- 工具版本：明确候选是 `CMake 4.3.2 -> 4.3.3` 和 `cargo/rustc 1.96.0 -> 1.96.1`；`.NET`、WSL、Python 默认入口需诊断，不直接更新。

## 最终分类

- 可更新候选：CMake、cargo/rustc、3 个 skill source group staged refresh。
- 需诊断：.NET、WSL、Python 默认入口、CodeGraph 发布源。
- 保持不动：Codex CLI、Node/npm、uv、PowerShell、Git、gh、sqlite3、Serena、anthropic、Ninja。
- 整洁候选：重复 PowerShell PATH 入口、缺失 `.dotnet\tools` PATH 入口、plugin catalog overlay dry-run 1 项、run-evidence 保留策略设计。
