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

设备页是时间点快照；变更其他设备的记录必须有该设备的直接证据。
