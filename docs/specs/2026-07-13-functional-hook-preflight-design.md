# 本机 Codex 功能钩子分层恢复设计

## 状态

分阶段实施中：Task 1（path inventory）与 Task 2（policy source、path inventory、state repair 核心）已合入当前 `main` 并由专项测试覆盖；Task 3–8 仍是未排期的设计/未实施项。只有用户明确授权并完成 fixture、对抗性审查、重启和 fresh lifecycle 验收后，才可讨论推进。本文不授权注册新的 live hooks、执行 live repair 或恢复旧的多钩子热路径。

## 当前实现落点

- `managed/codex-hooks/hooks/codex-state-policy-guard.py` 已提供 `build_path_inventory`、`resolve_permission_policy` 和分域 `run_policy`，并保留 unresolved path 的原始字节。
- `tests/Test-CodexStatePathInventory.py`、`tests/Test-CodexStatePolicy.py` 与 `tests/Test-CodexHookPolicy.ps1` 覆盖当前已落地的 path/policy 安全边界。
- `codex-state-preflight` wrapper、Serena reminder/cleanup/activation hook、provider/GitHub 显式维护层、manifest 分离和 live registration 尚未落地；不要把本设计中的目标接口当作当前可调用入口。

## 目标

在不恢复旧钩子叠加、隐式联网和非原子双写的前提下，恢复确实有价值的防错和效率能力：

1. 自动保持 Codex projectless、heartbeat 和目标线程权限状态可用。
2. 保留 Serena 的符号工具效率提醒和会话清理能力。
3. 保持 Serena 启动中性，任务内显式绑定当前仓库。
4. 保留 provider/GitHub 的健康检查能力，但不在生命周期热路径写用户环境或访问网络。
5. 继续由冷路径 reconciler 维护 hooks、Serena 静态配置、context、ACL 和退役文件。
6. 任何未知字段、未知文件、竞争写入或不确定路径都必须保留并报告，不能静默覆盖。

## 当前事实与问题

- 当前 `D:\Codex\.codex\hooks.json` 的用户级 `hooks` 为空，活动目录只保留未注册的 GitHub CLI guard 文件。
- 旧 state policy 的只读检查当前报告 `178` 项 drift：两张 projectless map 共 `176` 项，heartbeat 权限 `2` 项；`state_5.sqlite` 当前 drift 为 `0`。
- 旧代码的目标 `D:\Users\WINDOWS\Documents\Codex` 不存在。当前存在 `D:\Documents\Codex` 和 `D:\Codex-Archive`，C 盘路径中包含 junction/reparse point。
- 逐条比较显示约 `171/176` 条路径可候选映射到 `D:\Documents\Codex`，另有 `5` 条 output 路径缺失；任何 reparse、缺失或多目标条目都不能做无条件字符串替换。
- 当前 User/Process `SERENA_HOME` 仍为 `D:\hermes-data\.serena`，MCP wrapper 子进程显式覆盖为 `D:\Codex\.serena`。恢复 vendor hook 前必须在 wrapper 内固定正确的 process 环境，不能依赖当前 User 环境。
- 旧 provider check-only 实现存在当前 PowerShell 下的标量 `.Count` 异常；旧 dashboard policy 仍要求 `--project-from-cwd`，与当前中性 Serena 设计冲突。因此旧 wrapper 不能原样重新注册。
- 多实例 Serena/dashboard listener 和旧版本 Codex/Python 防火墙规则是独立的主机健康问题，不能通过恢复 SessionStart hook 解决，也不纳入本设计的隐式网络动作。

## 功能分类

### 必须保留的功能

`codex-state-policy` 的职责必须恢复，但实现只能是一个合并的 state preflight：

- projectless path 的逐条 canonical inventory 和安全映射；
- heartbeat/thread permission policy；
- `state_5.sqlite` 中明确目标 Codex 用户线程的 approval/sandbox 漂移修复。

旧的 mobile Python 和 projectless JavaScript 不恢复，因为它们会竞争写同一个 JSON、没有共享锁和可靠 CAS。

### 保留但改为显式或只读的功能

- provider：启动时只做本地 TOML/环境漂移检查；配置和 User/Process 环境修复必须显式调用；网络探测只能显式调用。
- GitHub CLI：启动时只读检查 native `gh.exe`、签名、hardlink、PATH 和 `GH_CONFIG_DIR`；修复及认证检查必须显式调用。
- Serena TOML/YAML/context/hooks：继续由冷路径 reconciler 维护。

### 恢复的 Serena 行为能力

- `serena-reminder` 恢复为受控 `PreToolUse` Bash reminder。它确实能减少低效的连续 grep/read，但达到阈值后 vendor 会返回 deny/reminder，因此必须验证真实 Codex payload、计数文件位置和失败语义。
- `serena-cleanup` 可恢复为受控 `Stop` cleanup；它只清理 vendor hook state，不负责结束 MCP 或 dashboard 进程。wrapper 必须固定 `SERENA_HOME=D:\Codex\.serena`。
- `serena-activate` 不恢复 cwd 推断。若保留启动提示，只输出静态“使用当前绝对 workspace 调用 `activate_project` 并用 `get_current_config` 复验”的上下文，不自动绑定项目。

### 明确退役的功能

- `serena-auto-approve` 不恢复。vendor 实现只识别 Claude Code 的 `acceptEdits`/`auto` permission mode；当前 Codex payload 没有该模式。Codex 工具确认属于 Codex 自身权限机制，不能用这个无效 hook 代替。
- 旧 mobile/projectless wrapper、旧 provider/dashboard 自动写入 wrapper、GSD 历史 wrapper 不重新注册。

## 推荐架构

### 1. 热路径：单一 local-only state preflight

新增唯一热路径入口 `codex-state-preflight.cmd`，调用受管 Python 实现。它必须：

- 只读取和写入明确 allowlist 内的 D 盘 state 文件；禁止 URL、curl、DNS、认证、PATH、proxy、Serena config、hooks registry 和 vendor binary。
- 使用一个顶层互斥锁；JSON 与 SQLite 作为两个独立状态域分别 CAS/提交，不能假装跨文件原子事务。
- JSON 使用严格 UTF-8/duplicate-key/NaN 检查、同目录临时文件、fsync、原子替换和写前 SHA-256。
- SQLite 使用稳定快照、`quick_check`、`BEGIN IMMEDIATE`、目标行过滤、提交后计数和并发重验。
- heartbeat/SQLite 只有在 desired policy 来源明确时自动修复；desired approval/sandbox 从当前受控配置或明确 policy 文件读取，禁止硬编码扩大权限。
- projectless 路径先逐条计算 canonical candidate：目标存在、最终身份明确、无未审查 reparse 且一对一时才修复；缺失、歧义、junction 或多目标条目保留原值并写 unresolved evidence。
- 正常收敛保持 hook stdout 安静；诊断命令提供 JSON。失败写脱敏 health/evidence，并按“结构损坏/策略歧义阻断、瞬时 busy 可见 pending”区分。

### 2. Serena 行为层

- `SessionStart` 只保留静态 activation reminder，不读取当前 cwd 推断项目。
- `PreToolUse` 只注册 Bash matcher 的 reminder，使用固定 wrapper 和固定 `SERENA_HOME`。
- `Stop` 可注册 cleanup，验证其只删除当前 session 的 `hook_data`，不误杀其他 MCP 实例。
- 所有 Serena 行为 hook 都不得承担 TOML/YAML/config/context 修复；这些留在冷路径 reconciler。

### 3. 冷路径与显式维护层

- `Invoke-CodexHostHookReconciliation.ps1` 继续拥有 `hooks.json`、Serena context、静态 config、ACL 和 legacy retirement。
- provider/GitHub 的 `Check` 只读；`Repair`、`-CheckNetwork`、`-CheckAuth` 分离为显式命令，输出独立 evidence。
- firewall/runtime 版本漂移、dashboard listener 数量和 User `SERENA_HOME` 持久环境作为独立 host health 项，不塞入 state preflight。

### 4. Manifest 与状态分离

当前 `managed/codex-hooks/manifest.json` 仍把历史 wrapper 标成 active，容易被未来部署器误认为可恢复。实施时必须拆分：

- `legacy-fixture-manifest.json`：只供历史 fixture/core 测试；
- `host-preflight-manifest.json`：只声明真正允许的 state preflight、reminder、cleanup 和静态冷路径 ownership。

任何生产入口只接受后者，旧 manifest 不能提供 production apply identity。

## 失败、回滚与安全边界

- 目标文件缺失、JSON/SQLite 损坏、锁忙超过预算、CAS 竞争、policy 来源不明确时不覆盖旧字节。
- JSON 已成功发布而 SQLite 提交失败时，只在仍匹配预期新 hash 时反向恢复；若出现第三方版本，报告 `unsafe-partial`，保留竞争版本和 evidence，不强行回写旧 snapshot。
- 未知字段、未知 state row、未知 hook group、未知文件一律 preserve。
- preflight 不执行任何网络系统调用；网络安全请求归因必须通过独立 firewall/runtime/dashboard 证据确认。

## 验收标准

1. path inventory 能逐条解释 `176` 项旧值：可安全映射项、junction/ambiguous 项和 `5` 个缺失项分开计数。
2. state preflight 在 fixture 中把确定的 heartbeat/SQLite drift 修到零；路径 unresolved 不得被误改。
3. 竞争写入、锁忙、损坏 JSON、SQLite WAL/journal 和权限策略歧义均 fail closed，原字节保持不变。
4. 新鲜 Codex 任务验证 reminder 的静默阈值、deny/reminder payload、Serena tool reset 和 Stop cleanup 的 session 隔离。
5. auto-approve synthetic payload 和真实 Codex payload 均证明当前 Codex 不支持该 Claude-only mode，生产注册保持为零。
6. provider/GitHub read-only check 不写 User/Process 环境、不访问网络；显式 repair 和 network/auth acceptance 单独验证。
7. 完整重启后，Serena 初始无项目，显式 `activate_project`、`get_current_config` 和符号查询成功。
8. hooks/config/context/reconciler 的现有全套测试、新增 preflight/reminder/cleanup/path tests、`git diff --check` 全部通过。

## 实施顺序

先完成 path inventory 和 state preflight，再恢复 reminder/cleanup/activation reminder；之后拆分 provider/GitHub 的只读与显式 repair；最后做 live registration、重启、网络边界和回滚验收。任何一个子项目未通过其独立门槛，都不进入下一个子项目。
