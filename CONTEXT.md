# 统一环境治理上下文

本项目用于治理本机开发环境：先盘点事实，再生成 dry-run 计划和更新准备报告，最后在明确授权下逐项迁移或调整配置。

核心原则是：该共享的共享，该隔离的隔离。工具运行时、共享缓存和全局 CLI 可以在 D 盘形成稳定入口；项目本地 `.venv`、`node_modules`、服务状态和凭据相关目录默认保持项目隔离或人工审查。

## 必读政策

- D 盘布局、环境分类、迁移授权、验证和回滚边界见 `docs/env-governance/d-drive-layout-and-migration-policy.md`。

## 当前事实基线

- 只读盘点报告：`reports/env-inventory/REPORT.md`
- dry-run 迁移计划：`reports/env-migration-plan/PLAN.md`
- 统一更新准备报告：`reports/env-update-readiness/REPORT.md`

这些报告是事实快照，不是执行授权。真实迁移前必须重新生成最新基线。
