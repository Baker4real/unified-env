# Claude Code 适配层

本文只覆盖 Claude Code 与 `SKILL.md` 默认假设不同的调度事实：接口名、容量、递归深度、只读强制、上下文继承和验收机制。`SKILL.md` 的建图、分支选择和外发边界不变，任务契约与隐私规则仍以 `D:\Codex\.codex\docs\agent-guidance\reasoning-and-adversarial-review.md` 为准。

版本锚：本机 Claude Code 2.1.226（`claude --version`）。默认值随版本变动过，行为与本文不符时先核对当前版本和 `CLAUDE_CODE_*` 环境变量，再按实测事实执行。

## 调度接口

`spawn_agent` 和 `list_agents` 是 Codex 的接口名，在 Claude Code 上不存在。对应关系：

- 派发用 `Agent` 工具，`subagent_type` 选定义，`run_in_background` 选前台或后台。调度证据是接口返回的 agentId 与 name。
- 续跑、纠偏和追问用 `SendMessage`，`to` 填 name 或 agentId。
- 取消用 `TaskStop`。

## 容量：自己记账，撞上不重试

Claude Code 没有公布容量的查询接口，`SKILL.md` 完整分发第 1 步的"调用真实容量状态接口"在这里按本节执行。

默认上限是单会话 20 个并发 subagent（`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`）。wave 大小由派发者自己按已派发且未终结的数量记账，并为根 Agent 和仍在运行的协调路径留余量。会话累计派发总数没有上限，只有同时在跑的数量受限。

超限时 `Agent` 返回 `Concurrent subagent limit reached`，该错误明确要求不要重试。等在跑的子树终结后再按依赖派发。

## 递归深度：默认 3 层，到顶表现为工具消失

默认允许主对话下方 3 层 subagent（`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`，设 `1` 关闭嵌套）。

到达上限的 subagent 直接拿不到 `Agent` 工具，而不是收到一个报错。观察到自己的工具里没有 `Agent`，就在本任务内串行完成该节点，并向父级如实报告这条深度边界。fork 是例外：`Agent` 仍在工具列表里，但调用返回错误。

## 只读：用工具边界强制

`SKILL.md` 要求只读 worker 及其后代保持只读。在 Claude Code 上这条可以强制，不必只靠指令：

- 只读 worker 的定义里不列写入工具，或用 `disallowedTools` 拒掉。
- reviewer 不给 `Agent`，它就无法继续派发。

工具边界优先于 prompt 里的只读要求；两者同时给出时以工具边界为实际保证。

## 上下文继承与隐私

- 自定义 subagent 和 `general-purpose` 继承整条 CLAUDE.md 层级，全局外发与破坏性动作边界已经到达 worker。内置 `Explore` 和 `Plan` 不继承 CLAUDE.md，派发它们做只读调查时把外发边界和禁止范围写进 prompt。
- 每个非 fork subagent 的上下文全新，看不到会话历史和主 Agent 已读的文件。任务契约必须自带最小充分事实。
- fork 继承父对话的全部上下文，与最小充分脱敏上下文相冲突。承载敏感数据的节点保持非 fork 派发。

## 验收

- 后台是默认形态，结果以完成通知在后续轮到达。通知到达前只报告"仍在运行"，不假设也不预测 worker 结论。
- worker 报告可能被输出扫描加上 `[harness:` marker 行或插入反斜杠。那是 harness 注释，不是 worker 的发现，也不改变必须回读真实文件、diff 和命令输出的要求。
- `isolation: worktree` 可用，但共享外发边界要求保持共享工作区加单一 owner。需要隔离副本时先单独取得用户授权。

## 回退

只列与 `SKILL.md` 回退表不同的触发条件。

| 触发条件 | 第一修复 | 仍失败时 |
| --- | --- | --- |
| `Agent` 返回 `Concurrent subagent limit reached` | 不重试，等在跑子树终结后按依赖串行派发。 | 当前协调者收回未派发节点串行完成，并向父级如实报告。 |
| 自己的工具里没有 `Agent`，即已到深度上限 | 在本任务内完成该节点，不尝试绕过运行时限制。 | 向父级返回受限证据和未完成边界，由上层重新安排。 |
| `Agent` 因 `subagent_type` 无效或零工具启动失败 | 按接口错误点名的条目改用真实存在的类型和工具集。 | 当前协调者收回该节点串行执行。 |
| 后台 worker 的完成通知未到达 | 用 `SendMessage` 向该 agent 查询状态，或继续做不依赖它的工作等待。 | 用 `TaskStop` 显式终结并把该节点标为 unresolved，不让未验证结论进入补丁。 |
| worker 因 API 错误中断 | 保留接口返回的部分输出和错误原文，按未完成处理。 | 底层错误清除后重派或 `SendMessage` 续跑；仍失败则标为 unresolved。 |

完成标准：每个已调度节点都有 agentId 或 name 证据，容量与深度按本文记账，只读节点由工具边界强制，且根 Agent 在完成通知到达后复核过真实改动与测试。
