---
type: reference
title: 知识适用域
tags: [agents, knowledge-scope, project-docs]
intent: 区分统一环境项目中长期知识、设备事实和临时证据的落点
---

# 知识适用域

使用 `neat-freak`、整理文档或准备提交前，先为新增知识选择适用域，避免把设备事实、临时证据或 agent 规则混入项目长期文档。

## 分类与落点

| 适用域 | 判定 | 落点 |
| --- | --- | --- |
| `project` | 换设备后仍成立 | `README.md`、`docs/` 或 `CONTEXT.md` |
| `module` | 换设备后仍成立，但只属于一个模块 | `modules/<module-id>/CONTEXT.md` 引用的权威文档；归属同步到 `modules/manifest.json` |
| `device` | 只对某台设备成立，但其他设备需要知道 | `docs/environments/<device-id>.md` |
| `local` | 只对当前机器有用，且不应提交 | `.local/`、`*.local.md` 或 `.env.local` |
| `agent` | 下次 AI 写代码必须遵守 | `AGENTS.md` |
| `evidence` | 一次性验证、日志、截图或 run output | `D:\Codex\.codex\run-evidence\` 或项目 `reports/` |

## 默认判断

涉及本机路径、桌面快捷方式、端口占用、代理、登录态、cookie、安装目录、工具链路径、系统服务状态或硬件差异的事实，默认不属于 `project`。
