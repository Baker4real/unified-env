# 项目代理说明

## Agent skills

### Issue tracker

本项目使用本地 Markdown tracker：任务、spec、tickets 和讨论记录放在 `.scratch/<feature-slug>/`。见 `docs/agents/issue-tracker.md`。

### Triage labels

本项目使用默认五状态标签：`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`。见 `docs/agents/triage-labels.md`。

### Domain docs

本项目使用 single-context 布局：根目录 `CONTEXT.md` 描述项目背景，`docs/adr/` 记录架构决策。见 `docs/agents/domain.md`。

### Environment governance

真实迁移前必须先读取 `docs/env-governance/d-drive-layout-and-migration-policy.md`，确认 D 盘布局、环境分类、显式授权、验证和回滚边界。
