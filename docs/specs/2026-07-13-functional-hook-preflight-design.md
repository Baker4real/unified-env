---
type: reference
title: 本机 Codex 功能钩子分层恢复设计
tags: [设计, Codex, hooks]
intent: 说明 Codex 功能钩子分层恢复的历史设计和现役边界
---

# 本机 Codex 功能钩子分层恢复设计

> **历史设计（已取代）：** 本文保留分层恢复的设计来源和 fixture 测试背景，不构成 live registration、`Repair`、`Restore` 或 lifecycle canary 的执行授权。当前唯一生产入口与安全边界见 `docs/specs/2026-07-11-host-hook-reconciliation-design.md`；本机 live 状态见 `docs/environments/zi-xi-shi.md`。

## 状态

本文已被当前 host hook reconciler 取代。Task 1–8、live registration、canonical path repair 与 lifecycle 验收的描述均为历史快照，不能据此推断当前配置健康或执行 live 写入。fixture 回归可独立验证；live `Repair`、`Restore` 与 lifecycle canary 仍须先由配置所有者明确 Serena 配置及权限策略来源。

## 已归档的实现落点

- `managed/codex-hooks/hooks/codex-state-policy-guard.py` 已提供 path inventory、permission policy 和分域 state policy；local-only preflight、Serena reminder/cleanup/activation、provider/GitHub 显式维护层及 production/legacy manifest 分离均已落地。
- 专项测试覆盖当前已合入的 path/state、preflight、Serena 行为、local health guard 与 manifest 路由边界。
- canonical path repair 与四个受管 hook 的 registration 是历史实现记录；它们不替代当前 reconciler 的 `Check` 结果，也不授权恢复旧 lifecycle 状态。

## 目标

在不恢复旧钩子叠加、隐式联网和非原子双写的前提下，恢复确实有价值的防错和效率能力：

1. 自动保持 Codex heartbeat 权限状态可用，并持续观察 projectless canonical path 与目标线程 SQLite 权限漂移。
2. 保留 Serena 的符号工具效率提醒和会话清理能力。
3. 保持 Serena 启动中性，任务内显式绑定当前仓库。
4. 保留 provider/GitHub 的健康检查能力，但不在生命周期热路径写用户环境或访问网络。
5. 继续由冷路径 reconciler 维护 hooks、Serena 静态配置、context、ACL 和退役文件。
6. 任何未知字段、未知文件、竞争写入或不确定路径都必须保留并报告，不能静默覆盖。

## 历史事实与问题

以下内容是设计阶段的基线和调查记录。需要 live 状态时必须运行当前生产入口的只读 `Check` 并查看设备事实，不得以这些数值或路径作为写入依据。

- 当前 `D:\Codex\.codex\hooks.json` 的用户级 `hooks` 精确注册 4 个受管本地 hooks：`codex-state-preflight`、`serena-activate`、`serena-cleanup`、`serena-reminder`。GitHub CLI guard 文件仍可作为显式工具保留，但未注册为生命周期 hook。
- 初始审计时，旧 state policy 的只读检查曾报告 `178` 项 drift：两张 projectless map 共 `176` 项，heartbeat 权限 `2` 项；`state_5.sqlite` drift 为 `0`。这是修复前基线，不是当前状态。
- 旧代码的目标 `D:\Users\WINDOWS\Documents\Codex` 不存在。当前存在 `D:\Documents\Codex` 和 `D:\Codex-Archive`，C 盘路径中包含 junction/reparse point。
- 初始逐条比较显示约 `171/176` 条路径可候选映射到 `D:\Documents\Codex`，另有 `5` 条 output 路径缺失；Task 7 已按批准映射完成修复并保留歧义项。2026-07-15 fresh preflight 显示 heartbeat 与 SQLite 均为 `0` drift，路径域为 `2` 条新安全候选和 `2` 条歧义保留；任何 reparse、缺失或多目标条目仍不能做无条件字符串替换。
- 当前 User `SERENA_HOME` 已由 reconciler 设置为 `D:\Codex\.serena`；Serena MCP wrapper 和行为 hook wrapper 仍显式固定该路径，不能依赖外部 cwd 或旧 Hermes 目录。
- 旧 provider check-only 实现存在当前 PowerShell 下的标量 `.Count` 异常；旧 dashboard policy 仍要求 `--project-from-cwd`，与当前中性 Serena 设计冲突。因此旧 wrapper 不能原样重新注册。
- 多实例 Serena/dashboard listener 和旧版本 Codex/Python 防火墙规则是独立的主机健康问题，不能通过恢复 SessionStart hook 解决，也不纳入本设计的隐式网络动作。

## 功能分类

### 必须保留的功能

`codex-state-policy` 的职责必须恢复，但按写入风险拆成三个明确状态域：

- heartbeat/thread permission policy：生命周期热路径可按受控 policy 自动修复全局 JSON；
- projectless path：生命周期热路径只做逐条 canonical inventory 和报告，安全映射仅由显式、已批准的维护入口执行；
- `state_5.sqlite`：生命周期热路径只报告明确目标 Codex 用户线程的 approval/sandbox 漂移，修复必须走带当前源代、备份和返回租约证明的显式冷维护入口。

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

- 旧 `serena-auto-approve` 实现退役，不进入生产注册。vendor 行为对照证明它会在 Claude 风格 `permission_mode=acceptEdits|auto` 时直接返回 allow；这与用户要求“Serena 工具仍需合理批准”的目标相反，也不能替代 Codex 自身的审批机制。测试中的无 `permission_mode` payload 仅用于验证不会误放行，不作为 Codex 当前真实 payload schema 的证据。未来若要减少确认，应基于 fresh Codex lifecycle payload 和原生审批能力另行设计按工具限定的策略，而不是恢复旧 vendor auto-approve。
- 旧 mobile/projectless wrapper、旧 provider/dashboard 自动写入 wrapper、GSD 历史 wrapper 不重新注册。

## 推荐架构

### 1. 热路径：单一 local-only state preflight

新增唯一热路径入口 `codex-state-preflight.cmd`，调用受管 Python 实现。它必须：

- 只读取和写入明确 allowlist 内的 D 盘 state 文件；禁止 URL、curl、DNS、认证、PATH、proxy、Serena config、hooks registry 和 vendor binary。
- 使用一个顶层互斥锁；JSON 与 SQLite 作为两个独立状态域分别 CAS/提交，不能假装跨文件原子事务。
- JSON 使用严格 UTF-8/duplicate-key/NaN 检查、同目录临时文件、fsync、原子替换和写前 SHA-256。
- heartbeat 只有在 desired policy 来源明确时自动修复；desired approval/sandbox 从当前受控配置或明确 policy 文件读取，禁止硬编码扩大权限。
- projectless 路径在热路径只逐条计算 canonical candidate 并报告；缺失、歧义、junction 或多目标条目保留原值。实际映射由显式、已批准的 canonical repair 执行。
- SQLite 在热路径使用稳定只读观察、`quick_check` 和目标行过滤，只报告 drift；显式冷维护修复复用安全 state 核心，并要求源代绑定备份、独占性证明、事务提交和返回租约穿过最终输出门。
- 正常收敛保持 hook stdout 安静；诊断命令提供 JSON。失败写脱敏 health/evidence，并按“结构损坏/策略歧义阻断、瞬时 busy 可见 pending”区分。

### 2. Serena 行为层

- `SessionStart` 只保留静态 activation reminder，不读取当前 cwd 推断项目。
- `PreToolUse` 只注册 Bash matcher 的 reminder，使用固定 wrapper 和固定 `SERENA_HOME`。
- `Stop` 可注册 cleanup，验证其只删除当前 session 的 `hook_data`，不误杀其他 MCP 实例。
- 所有 Serena 行为 hook 都不得承担 TOML/YAML/config/context 修复；这些留在冷路径 reconciler。

### 3. 冷路径与显式维护层

- `Invoke-CodexHostHookReconciliation.ps1` 继续拥有 `hooks.json`、Serena context、静态 config、ACL 和 legacy retirement。
- canonical path repair 和 active SQLite 权限修复使用各自已经过测试的显式维护合同；前者只消费批准映射，后者必须提供当前源代绑定的冷维护 evidence。两者都不由 SessionStart 隐式执行。
- provider/GitHub 的 `Check` 只读；`Repair`、`-CheckNetwork`、`-CheckAuth` 分离为显式命令，输出独立 evidence。
- firewall/runtime 版本漂移、dashboard listener 数量和 User `SERENA_HOME` 持久环境作为独立 host health 项，不塞入 state preflight。

### 4. Manifest 与状态分离（已完成）

历史问题是 `managed/codex-hooks/manifest.json` 曾把历史 wrapper 标成 active，容易被未来部署器误认为可恢复。现已完成拆分，生产与历史 fixture 使用不同入口：

- `legacy-fixture-manifest.json`：只供历史 fixture/core 测试；
- `host-preflight-manifest.json`：只声明真正允许的 state preflight、activation reminder、reminder、cleanup 和静态冷路径 ownership。

当前生产入口只读取 `host-preflight-manifest.json`；`legacy-fixture-manifest.json` 与旧 manifest 仅保留历史 fixture/core 测试用途，均不能提供 production apply identity。

## 失败、回滚与安全边界

- 目标文件缺失、JSON/SQLite 损坏、锁忙超过预算、CAS 竞争、policy 来源不明确时不覆盖旧字节。
- JSON 已成功发布而 SQLite 提交失败时，只在仍匹配预期新 hash 时反向恢复；若出现第三方版本，报告 `unsafe-partial`，保留竞争版本和 evidence，不强行回写旧 snapshot。
- 未知字段、未知 state row、未知 hook group、未知文件一律 preserve。
- preflight 不执行任何网络系统调用；网络安全请求归因必须通过独立 firewall/runtime/dashboard 证据确认。

## 验收标准

1. path inventory 能逐条解释 `176` 项旧值：可安全映射项、junction/ambiguous 项和 `5` 个缺失项分开计数。
2. state preflight 在 fixture 中自动把确定的 heartbeat drift 修到零，同时准确报告 canonical path 与 active SQLite drift且不改其字节；专项 state-policy 测试证明显式批准映射和 evidence-bound 冷维护仍能把对应 drift 修到零。
3. 竞争写入、锁忙、损坏 JSON、SQLite WAL/journal 和权限策略歧义均 fail closed，原字节保持不变。
4. 新鲜 Codex 任务验证 reminder 的静默阈值、deny/reminder payload、Serena tool reset 和 Stop cleanup 的 session 隔离。
5. auto-approve 的 Claude 对照 payload 证明旧 vendor 实现会直接返回 allow；脱敏负向 fixture 证明普通 payload 不会被误放行。由于旧实现与“保留 Codex 审批”目标冲突，生产注册保持为零；任何 Codex 原生按工具审批方案必须使用 fresh lifecycle payload 重新设计和验证。
6. provider/GitHub read-only check 不写 User/Process 环境、不访问网络；显式 repair 和 network/auth acceptance 单独验证。
7. 完整重启后，Serena 初始无项目，显式 `activate_project`、`get_current_config` 和符号查询成功。
8. hooks/config/context/reconciler 的现有全套测试、新增 preflight/reminder/cleanup/path tests、`git diff --check` 全部通过。

## 历史实施顺序

此顺序仅解释历史实现过程。后续变更必须从当前 host hook reconciler 的设计、真实 live `Check` 和配置所有者授权重新开始，不得续跑本文步骤。
