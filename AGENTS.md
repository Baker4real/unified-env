# 项目代理说明

## Agent skills

### Issue tracker

本项目使用本地 Markdown tracker：任务、spec、tickets 和讨论记录放在 `.scratch/<feature-slug>/`。见 `docs/agents/issue-tracker.md`。

### Triage labels

本项目使用五种 triage 状态：`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`；已完成 issue 使用终态 `done`。见 `docs/agents/triage-labels.md`。

### Domain docs

本项目使用 single-context 布局：根目录 `CONTEXT.md` 描述项目背景；当前没有独立 ADR 目录，如未来存在架构决策记录则位于 `docs/adr/`。见 `docs/agents/domain.md`。

### Environment governance

真实迁移前必须先读取 `docs/env-governance/d-drive-layout-and-migration-policy.md`，确认 D 盘布局、环境分类、显式授权、验证和回滚边界。

宿主递归目录删除只能通过 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd` 执行，不得使用直接递归删除入口；能力边界和三阶段确认流程见 `docs/specs/2026-07-24-safe-tree-delete-capability.md`。

Sub2API 后续升级不再以零中断为硬门槛；满足安全静默窗口和可验证联合回滚条件时，持续更新授权包含 application-only 重建所需的短暂中断。范围、禁止项和验收门槛见 `docs/env-governance/sub2api-update-policy.md`。

## 知识适用域策略

使用 `neat-freak`、整理文档或准备提交前，先按 `docs/agents/knowledge-scope.md` 分类新增知识。
