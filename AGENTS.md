# 项目代理说明

## Agent skills

### Issue tracker

本项目使用本地 markdown issue：任务、PRD 和讨论记录放在 `.scratch/<feature-slug>/`。见 `docs/agents/issue-tracker.md`。

### Triage labels

本项目使用默认五状态标签：`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`。见 `docs/agents/triage-labels.md`。

### Domain docs

本项目使用 single-context 布局：根目录 `CONTEXT.md` 描述项目背景，`docs/adr/` 记录架构决策。见 `docs/agents/domain.md`。

### Environment governance

真实迁移前必须先读取 `docs/env-governance/d-drive-layout-and-migration-policy.md`，确认 D 盘布局、环境分类、显式授权、验证和回滚边界。

## 知识适用域策略

使用 `neat-freak`、整理文档或准备提交前，先把新增知识分类：

- `project`：换设备仍成立，写入 `README.md`、`docs/` 或 `CONTEXT.md`。
- `device`：只对某台设备成立但另一台设备需要知道，写入 `docs/environments/<device-id>.md`。
- `local`：只对当前机器有用，不提交，写入 `.local/`、`*.local.md` 或 `.env.local`。
- `agent`：下次 AI 写代码必须遵守，写入 `AGENTS.md`。
- `evidence`：一次性验证、日志、截图或 run output，写入 `D:\Codex\.codex\run-evidence\` 或项目 `reports/`。

凡是涉及本机路径、桌面快捷方式、端口占用、代理、登录态、cookie、安装目录、工具链路径、系统服务状态或硬件差异的事实，默认不是 `project`。
