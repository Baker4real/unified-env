---
type: reference
title: 工作站运维模块上下文
tags: [工作站, 模块, 设备]
intent: 定义设备事实、跨设备验收和宿主集成政策的文档边界
---

# 工作站运维模块

## 范围

本模块只拥有设备身份、易变事实、跨设备验收差异和 Sub2API 等工作站集成政策。它是文档/集成域，不是新的代码项目。

## 不属于本模块

- 环境盘点、PATH 和迁移实现属于 `dev-environment`。
- CodeGraph/Serena、hooks 与 catalog guard 机制属于 `codex-host`；设备文档只记录当前采用状态和指针。
- Skill 合同属于 `skill-supply-chain`，不在设备页复制。

## 权威合同

- `docs/environments/jia-li.md`
- `docs/environments/zi-xi-shi.md`
- `docs/environments/ban-gong-shi.md`
- `docs/env-governance/sub2api-update-policy.md`

设备页是时间点快照；变更其他设备的记录必须有该设备的直接证据。证据指针写 `D:\agents\run-evidence\` 下的路径；`tests/Test-DeviceDocRetiredPaths.cjs` 拒绝指向已退役存储根（`D:\Codex\.codex\run-evidence\`、`D:\Codex\.gsd\`）下具体路径的写法。

## 每日更新自动化

- `docs/automation/daily-update-prompt.md` 是 DeepSeek Harness 计划任务「每周更新」（`schedule-2a8292b0-5876-4d7c-a20a-080f98e18eab`）提示词的可审阅源文本；运行时以 DSH `schedule_view` 为准。更新使用 DSH `schedule_edit` 的 `promptFile` 读取这一受管源文件，保留现有名称、频率、目标和状态；compact `schedule_view` 读回 SHA-256 并核验 `promptMatchesCanonical=true`，不粘贴第二份完整提示词。Codex Desktop 自动化 `codex` 已于 2026-11-09 由用户手动暂停；旧 ZCode 日更及 Cursor 计划任务保持退役。
- `scripts/daily-update/` 是该自动化的受管集成入口；ledger/上游差分、MCP/三 shell 验收、单步收据、恢复索引、Kimi 独立回滚事务与 SM 文本锁的路由统一见同目录 `README.md`；初始导航、代理摘要和 npm/npx 命令配方先走 `preflight-summary.py`，不全文读取 manifest 或枚举所有连接。恢复先用已登记索引进入有界 reader，自动化不得在证据目录重写这些脚本。底层运行时/PATH 事务仍由 `dev-environment` 负责，本模块仅编排验收。
- 新入口的 Python 回归登记在 `modules/manifest.json`，由现有 `python-node-fixtures` CI 执行；本机验收使用同一 manifest runner。
