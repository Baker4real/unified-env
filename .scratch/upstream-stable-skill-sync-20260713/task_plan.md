# 上游稳定 Skill 同步计划

## 目标

以上游最新稳定版本为内容基线，同步本机所有可识别的稳定 skill；保留上游新增、修复和资源，同时以三方合并方式重放本机 overlay。`skills/in-progress/**` 不下载、不安装、不刷新到 active root。已从 in-progress 晋升到稳定目录的 skill（例如 `wayfinder`）属于 eligible 范围。

## 阶段

- [x] 盘点 active skill、来源台账、上游 stable/deprecated/in-progress 边界。
- [x] 为每个来源建立 D 盘上游 staging、版本记录和回滚快照。
- [x] 三方合并上游内容与本机 overlay，并安装所有 eligible stable skill。
- [x] 同步 SOURCE.md、统一台账和稳定/排除决策。
- [x] 运行资源闭包、依赖、frontmatter、中文菜单和重复/冲突审计。
- [x] 启用多子代理进行对抗性审查，收口残余风险。

## 当前边界

- `mattpocock/skills` 的 `skills/in-progress/**` 仍是永久排除；已晋升稳定目录的 `wayfinder` 已安装。
- 中文菜单 overlay 已版本化并重放；上游正文和资源仍是内容基线。
- my-coffee MCP 当前 token 返回 HTTP 401，需有效 token 才能完成连接器可用性验收。
- Codex Desktop 已完整重启并完成运行时 smoke：CodeGraph、Serena MCP 可调用，GitHub/Gmail 插件工具重新暴露；GitHub/yeet overlay dry-run 无改动。
- 重启后远端 HyperFrames catalog/cache 曾回流，已用退役面脚本备份清理并重放菜单 overlay；最终菜单、退役面、overlay 和资源闭包审计均通过。
- 当前 Store 稳定包为 `OpenAI.Codex 26.707.8479.0`；D 盘 `.system` skill 快照和 SOURCE/ledger 仍记录 `26.707.3748.0`，需按官方 runtime 刷新边界单独收口。

## 合并规则

- 上游最新稳定内容优先：新增文件、修复、资源、元数据和行为不能被旧本地副本覆盖。
- 本机 overlay 只作为显式补丁重放：D 盘路径、主机安全边界、中文菜单、禁止 GSD 和本地输出约束可以保留。
- 同一处发生语义冲突时保留上游更新，并在 SOURCE.md/台账记录冲突及调整后的 overlay。
- deprecated、未知来源和真正 source-unresolved 的本地 skill 不猜测升级；记录原因。

## 错误记录

| 错误 | 尝试 | 处理 |
|---|---:|---|
