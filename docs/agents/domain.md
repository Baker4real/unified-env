---
type: reference
title: Domain Docs
tags: [agents, domain, project-docs]
intent: 说明 Agent 探索统一环境项目时的领域文档读取顺序
---

# Domain Docs

本文件说明工程技能在探索本项目时应该如何读取领域文档。

## 探索前优先读取

- 根目录 `CONTEXT.md`
- `modules/README.md`
- 与当前任务相关的 `modules/<module-id>/CONTEXT.md`
- `docs/agents/` 中与当前工作相关的项目规则

如果这些文件不存在，静默继续即可；不要因为缺失而主动报错。后续可以由 `domain-modeling`、`grill-with-docs` 或 `improve-codebase-architecture` 在真正需要时补齐。

## 文件布局

本项目采用单仓模块化布局：

```text
/
├── CONTEXT.md
├── modules/
│   ├── README.md
│   ├── manifest.json
│   └── <module-id>/CONTEXT.md
└── docs/agents/
```

根 `CONTEXT.md` 只负责项目组合与跨模块规则；模块的 scope、interface、依赖和已知 drift 记录在对应模块 CONTEXT。现役合同仍以模块 CONTEXT 引用的 `docs/` 文档为真源，不在 CONTEXT 中复制正文。

## 使用项目词汇

当输出 issue 标题、重构建议、调试假设或测试名称时，优先使用 `CONTEXT.md` 中定义的领域词汇。

如果需要的概念还没有进入 `CONTEXT.md`，说明可能存在词汇缺口；可以在后续领域建模时补充。

## 标出文档冲突

本项目当前没有独立 ADR 目录。如果输出内容与 `CONTEXT.md` 或现有项目规则冲突，需要明确说明冲突点，而不是静默覆盖已有决策。
