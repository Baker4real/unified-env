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

- `docs/automation/daily-update-prompt.md` 是 ZCode「每日更新」自动化提示词的可审阅源文本；运行时生效的是 ZCode 任务库 `automations.prompt`，改动后须写库并读回比对 sha256。
- `scripts/daily-update/` 是该自动化的受管辅助脚本（ledger TSV、上游 ls-remote 差分 sweep、MCP smoke），调用方式见同目录 `README.md`；自动化不得在证据目录重写这些脚本。
