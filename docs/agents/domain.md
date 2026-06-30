# Domain Docs

本文件说明工程技能在探索本项目时应该如何读取领域文档。

## 探索前优先读取

- 根目录 `CONTEXT.md`
- 根目录 `CONTEXT-MAP.md`，如果它存在；它会指向每个上下文对应的 `CONTEXT.md`
- `docs/adr/` 中和当前工作相关的 ADR

如果这些文件不存在，静默继续即可；不要因为缺失而主动报错。后续可以由 `domain-modeling`、`grill-with-docs` 或 `improve-codebase-architecture` 在真正需要时补齐。

## 文件布局

本项目采用 single-context 布局：

```text
/
├── CONTEXT.md
├── docs/adr/
└── docs/agents/
```

## 使用项目词汇

当输出 issue 标题、重构建议、调试假设或测试名称时，优先使用 `CONTEXT.md` 中定义的领域词汇。

如果需要的概念还没有进入 `CONTEXT.md`，说明可能存在词汇缺口；可以在后续领域建模时补充。

## 标出 ADR 冲突

如果输出内容和已有 ADR 冲突，需要明确说明冲突点，而不是静默覆盖已有决策。
