---
type: reference
title: 本机 Codex Hook 治理与安全重构设计
tags: [设计, Codex, hooks]
intent: 说明已被取代的 Codex Hook 治理设计及其历史约束
---

# 本机 Codex Hook 治理与安全重构设计

> **历史设计（已取代）：** 本文描述的五个 SessionStart 与 ProductionFull 部署架构不再是当前生产方案。`scripts/Invoke-CodexHostHookReconciliation.ps1` 是唯一当前生产权威；旧 production façade 固定返回 `superseded-by-host-hook-reconciler`，本文其余内容只用于解释历史约束和 fixture/core 测试来源，不构成 live 执行授权。

## 背景

本机 Codex 的真实 hook 注册位于 `D:\Codex\.codex\hooks.json`，实现位于
`D:\Codex\.codex\hooks\`。当前注册包含 5 个 `SessionStart`、1 个 `Stop` 和
2 个 `PreToolUse`，但这些 live 文件没有仓库内受管源、manifest、部署器、回滚器或专项测试，
现有环境 inventory 也不采集 hook 事实。

只读审计确认了以下当前故障与风险：

- GitHub CLI guard 被插入 `SessionStart` 索引 1，旧的 0–3 hook trust identity 未同步迁移，
  导致原索引 1–3 的信任身份错位，新增索引 4 没有 trust state。
- 两个 projectless 映射各仍有 86 个 C 盘前缀、0 个 D 盘前缀，说明对应 hook 没有可靠执行。
- mobile permission Python 与 projectless JavaScript 会独立、非原子地重写同一个
  `.codex-global-state.json`，没有共享锁、写前 hash 复核或原子替换。
- provider 与 Serena dashboard 各自维护一套 TOML 文本变换；Serena YAML 仍直接覆盖，
  缺少锁、备份、解析校验和原子替换。
- provider 的 TOML 尾空行处理在合法边界输入下可能无限循环，最终撞上 10 秒 hook timeout。
- `codex-mobile-permission-guard.cmd` 未注册，仍优先引用已不存在的 Python 3.13，
  并回退到 Hermes 项目 runtime。
- User/Process `SERENA_HOME` 仍指向 `D:\hermes-data\.serena`，与当前
  `D:\Codex\.serena` 的受管位置不一致。

本设计采用分阶段治理。第一阶段先建立最小可信的 manifest、事实盘点、dry-run 和回滚能力，并用它
恢复现有 hook 的有效性和信任索引稳定性；第二阶段补齐完整受管源、部署和测试闭包；第三阶段在保持
故障隔离的前提下修复不安全实现。不会先手工修改 live 状态，也不会把所有职责立即合并成一个大型
SessionStart 脚本。

## 目标

1. 恢复已存在的 provider、projectless、Serena activate 和 Serena dashboard hook 的旧索引身份，
   让新增 GitHub hook 只占用追加索引。
2. 让 `统一环境` 仓库成为本机自定义 Codex hook 的唯一受管源，live `.codex` 只作为部署目标。
3. 为 hook 注册、实现文件、runtime、timeout、作用域、副作用、关键性和健康检查建立声明式 manifest。
4. 所有 live 写入具备路径边界、互斥、输入校验、写前漂移检测、备份、临时文件、原子替换和失败回滚。
5. 消除 `.codex-global-state.json` 的不协调双写，修复 TOML/YAML 边界和 timeout 预算。
6. 保留 GitHub CLI、provider/state、Serena config 和 Serena activate 的独立故障域；可选集成失败不得
   阻断普通 Codex 会话。
7. 用真实 `.cmd` 入口、fresh SessionStart、Serena MCP smoke 和脱敏状态计数证明行为生效。

## 非目标

- 不扫描或治理所有第三方软件、所有 Git 仓库的 Git hooks。
- 不修改 Codex 官方 Store/AppX 产物或 Serena vendor runtime 源码。
- 不伪造、复制或直接计算 `[hooks.state]` 下的 `trusted_hash`。
- 不把未知 hook、未知字段或未知 live 文件作为同步副作用删除。
- 不在本次工作中修复与 hook 无关的 IFEO router、Store 更新计划任务或其他 host-runbook 漂移。
- 不把完整线程 ID、凭据、代理认证信息或原始全局状态写入项目报告。

## 方案比较与决策

### 方案 A：分阶段治理（采用）

先恢复原 0–3 顺序，把 GitHub guard 追加为索引 4；随后建立受管源与 patch-preserving 部署链，
再原位替换不安全实现。该方案优先恢复当前功能，避免一次性扩大信任和回滚范围，同时从根本上解决
live-only 漂移。

### 方案 B：直接收敛为三个 SessionStart 域

把全部 host policy 合并为单一协调器，只保留 GitHub 和 Serena activate 两个独立入口。最终入口更少，
但一次性改变命令身份、stdout hook 协议和 failure semantics，必须重新信任更多 hook，单点失败面也更大。
本轮不采用；在分阶段治理稳定后可单独评估。

### 方案 C：仅最小修补

只调回索引、修 runtime 和非原子写。它不能阻止下一次注册插入再次破坏 trust，也无法回答 live 文件
是否来自已审查源，因此不采用。

## 受管布局

仓库新增以下结构：

```text
managed/codex-hooks/
  manifest.json
  hooks/
scripts/
  Get-CodexHookInventory.ps1
  New-CodexHookDeploymentPlan.ps1
  Invoke-CodexHookDeployment.ps1
  Restore-CodexHookDeployment.ps1
  lib/CodexHookPolicy.ps1
tests/
  Test-CodexHookPolicy.ps1
  Test-CodexHookInventory.ps1
  Test-CodexHookDeployment.ps1
```

`managed/codex-hooks/hooks/` 保存本机自定义 wrapper、实现和共享库。live 目标继续是
`D:\Codex\.codex\hooks\`。真实备份、前后 hash、apply 日志与 rollback 状态写入
`D:\agents\run-evidence\env-governance\codex-hooks-<UTC timestamp>\`；
项目报告只保存脱敏摘要和证据路径。

## Manifest 模型

`manifest.json` 使用严格 JSON，拒绝重复键和未知顶层字段。每个受管 hook 至少声明：

- 稳定 `id`、事件、matcher、timeout 和顺序约束；
- wrapper、implementation、runtime 和参数；
- 所有受管文件的相对路径与 SHA-256；
- 所有预期读写资源；
- `critical`、`degraded` 或 `optional` 关键性；
- 快速健康检查和完整验收命令；
- `active`、`compatibility` 或 `retired` 生命周期状态。

hook 在 `hooks.json` 中没有稳定 ID，因此部署器通过受管 command path 识别所有权。部署器保留未知
group、未知字段及其相对顺序；新增受管 group 默认追加，不允许在已有受信 group 前插入。

## 注册与 Trust 策略

第一批 live 修复把 `SessionStart` 恢复为：

1. provider stability guard；
2. projectless/state guard；
3. Serena activate（`startup|resume`）；
4. Serena dashboard/config guard；
5. GitHub CLI guard（新增、追加）。

这会恢复旧索引 0–3 的命令身份，只让 GitHub guard 成为新增待审 hook。部署器不修改 `[hooks.state]`，
不删除旧 trust cache，也不生成 hash。部署完成后完整重启 Codex，由 Codex 自己显示 hook 审核界面；
用户审核并信任新增 GitHub hook 后，再进行 fresh SessionStart 验收。

`PreToolUse` 的 `Bash` matcher 暂时保留。本机 Serena 的 Codex 分支会从 payload 的 `command/cmd`
识别 shell 命令；最终是否触发以合成输入测试和 fresh live hook 证据为准。当前对 Codex 实质无效的
Serena `auto-approve` group 会在 manifest 中标记 retirement，部署时只取消注册，不修改 vendor 文件。

## 实现边界

### Provider guard

Provider guard 只负责 provider feature/network 配置与代理环境政策，不再直接重写 heartbeat 全局状态。
它使用共享 TOML 写入库，删除现有尾空行无限循环实现，所有代理诊断统一剥离 URI user-info 后输出。
`-Watch` 不再静默每秒吞错；若保留，只允许有界退避并写入脱敏健康状态。

### State guard

projectless 与 mobile permission 状态收敛到一个状态策略实现：

- `.codex-global-state.json` 只读一次，在内存中同时应用 projectless D-root 与 heartbeat permission 变换；
- 使用命名锁、JSON schema/形状校验、同目录临时文件、写前 SHA-256 比对和原子替换；
- 若 Electron 在写入前改变原文件，重新读取并有限次数重放纯变换，不覆盖未知新状态；
- 每次变更创建可轮换备份，而不是永久复用一个旧 `.bak`；
- `state_5.sqlite` 使用显式事务、busy timeout、目标行复核和提交后计数验证；
- 报告只输出数量，不输出线程 ID。

为了避免第一阶段扩大 trust 变更，live 注册入口可以继续使用旧的
`codex-projectless-root-d.cmd` 作为 compatibility wrapper，但其受管 manifest ID 与实现职责命名为
`codex-state-policy`。稳定后若要重命名入口，另开一次需要用户信任的迁移。

### Serena config 与 hooks

Serena TOML 使用共享 TOML 安全写入库；YAML 写入增加严格顶层键匹配、重复键拒绝、D 盘路径检查、
命名锁、备份、临时文件、解析/形状校验和原子替换。guard 同时维护
`project_serena_folder_location`。Serena activate 继续独立转发 stdin，确保只输出 vendor hook 协议 JSON。

User `SERENA_HOME` 修正为 `D:\Codex\.serena`，Process 状态仅在当前子进程内修正；完整重启 Codex 后
验证 Stop/PreToolUse 继承值。现有 MCP wrapper 继续显式设置 `SERENA_HOME`，形成双重保证。

### GitHub CLI guard

保留现有签名校验、hardlink 身份验证、互斥锁、临时链接和失败回滚。SessionStart 继续使用快速、
fail-open 模式；完整签名/认证检查保留为显式 strict 验收。内部锁等待预算必须小于外层 timeout，
并记录脱敏 duration/result。任何凭据内容都不得进入输出或证据。

## 部署与回滚

部署分为 plan 与 apply：

1. inventory 读取 live registry、受管/未知文件、runtime、trust observation、wrapper 依赖和 hash，
   不执行有副作用的 hook。
2. plan 记录 source/live SHA-256、所有新增/覆盖/取消注册项、顺序变化、风险、验收和回滚动作；production full 报告同时绑定 `generationId` 与 JSON SHA-256，Markdown front matter 必须引用同一 JSON。
3. apply 前重新计算全部 hash；真实 production full apply 还必须接收人工批准的 `generationId` 与 plan SHA-256，并验证 `plan.json`/`PLAN.md` 成对一致。任一 source、live、unknown projection 或报告对输入漂移立即停止，且不得产生或保留不一致的 registry 激活。
4. 对 live `hooks.json`、所有将覆盖或 retirement 的文件、相关配置创建证据备份。
5. 按共享库/implementation → wrapper → `hooks.json` 的顺序发布；registry 最后激活。
6. 每个文件在替换前完成语法/结构校验，并使用同目录临时文件和原子替换。
7. 任一步 postcheck 失败，按反序恢复备份并再次验证 hash、JSON/TOML/YAML 语法和 wrapper 可用性。
8. retirement 文件先取消注册；本轮默认备份后保留，不把删除作为迁移副作用。

## 完整性并发边界

Windows 普通用户态文件 API 存在一个必须显式记录的约束：如果目标 handle 不共享 `DELETE`，另一个
handle 就不能在该 handle 存活期间原子替换目标；即使使用
`FileRenameInformationEx(65) + FILE_RENAME_REPLACE_IF_EXISTS + FILE_RENAME_POSIX_SEMANTICS` 也会因
sharing violation 失败。因此部署器不声称提供对所有不合作外部进程的绝对 compare-and-swap。

existing-target 发布采用可实现的完整性合同：在 production mutex 内 fresh rederive；由同一 verified
target handle 完成最终路径、普通文件、bytes 和 SHA-256 采样；该 lease 使用
`FileShare.Read | FileShare.Delete`，明确不共享 `WRITE`，并持有到同目录 class 65 原子 rename 完成。
随后继续做 handle/path postcheck；rollback 只有在所有已恢复 target（包括 registry）与 active/status 终态发布均按明确 expected hash 完成最终重验后才报告成功，其他状态
进入 `rollback-blocked` / recovery 语义。missing-target 发布使用 flags=0，若最终 missing snapshot 后出现竞争创建则 collision
并失败关闭，不覆盖新文件。

这套合同保证不合作的内容 writer 不能在最终采样后写入 third bytes，同时保留 crash-atomic replacement；
它不保证阻止不合作外部进程恰好在最终系统调用前删除或替换目标名称。此残余边界由 fresh rederive、两次
snapshot、write-excluding lease、原子 rename、handle/path postcheck 与 blocked rollback 共同缩小并显式
暴露，不以“绝对 CAS”描述。

## Timeout 与 Failure Semantics

- provider SessionStart 预算为 `1500ms + 4 x (1000ms + 250ms) + 2000ms = 8500ms`，保持 10 秒；dashboard 最坏预算为 `1500ms + 7 x (1000ms + 250ms) + 2000ms = 12250ms`，外层为 15 秒。250ms 是 stdout/stderr drain 的有界上限；Task 8 的 provider `-CheckNetwork` 不属于常规 SessionStart 预算。
- provider/state/config 属于 `critical`：变更失败时不覆盖 live 文件，并返回明确非零退出或结构化失败。
- GitHub CLI 属于 `optional`：失败记录 warning/health，但不阻断普通会话。
- Serena activate 属于 `degraded`：协议转发失败会丢失提示，但不应破坏其他 host policy 写入。
- hook stdout 只保留协议要求或极短摘要；详细脱敏结果写入 D 盘 latest-health/evidence。

## 测试与验收

### 仓库测试

- manifest：严格 JSON、唯一 ID、合法 event/matcher/timeout、稳定顺序、无秘密。
- 文件闭包：wrapper、实现、runtime 全存在；所有受管目标位于 D 盘且祖先无 reparse point。
- patch-preserving reconcile：未知 group/字段/文件原样保留；新增项只能追加；重复受管 entry 被拒绝。
- fixture：畸形 JSON/TOML/YAML、重复键、缺 runtime、hash 漂移、C 盘路径、reparse point 全部失败关闭。
- TOML 回归：section header + 空行 + managed key 不得循环，并保持合法注释和多行数组。
- state：两个策略一次事务完成；并发/CAS 漂移会重试或安全失败；异常后原字节保持不变。
- YAML：只修改真正顶层键，不提升缩进键；变更前后均可解析。
- wrapper：真实 `.cmd` 入口、stdin passthrough、stdout/stderr、退出码和耗时符合契约。
- deploy/rollback：final hash gate、发布顺序、中途故障注入和完整反序恢复。

### Live 验收

- `hooks.json` 与 manifest 的受管投影一致，旧 0–3 顺序恢复，GitHub 位于索引 4。
- provider 使用真实 `.cmd` 入口和 `-Json -CheckNetwork` 返回健康结果。
- GitHub guard 使用真实 `.cmd` 入口执行 `-CheckOnly -Json`，完整验收执行 `-Json -CheckAuth -Strict`。
- 全局 JSON 与 SQLite 通过解析/quick check，projectless C-prefix 为 0，目标 D-prefix 与总数一致，
  heartbeat/mobile drift count 为 0。
- Serena YAML/TOML 目标键一致；MCP 完成 `initialize`、`tools/list` 和文件工具 smoke。
- 完整重启 Codex 后，新增 hook 经过用户信任；fresh SessionStart 产生每个受管入口的脱敏成功证据。
- `Bash` reminder 用合成 hook payload 与真实 shell 调用验证；若当前 Codex 不触发，则记录 vendor/host
  兼容性限制，不通过猜测修改 matcher。
- 全部专项测试、相关现有测试、PowerShell/Python/JSON/TOML/YAML 语法检查和 `git diff --check` 通过。

## 分阶段执行顺序

1. **最小治理基线**：引入 manifest、只读 inventory、dry-run plan、备份/restore 骨架及其 fixture 测试。
2. **紧急注册恢复**：通过已验证的 apply/restore 链恢复 0–3 顺序并把 GitHub 追加为索引 4。
3. **受管源闭包**：纳入全部受管实现、wrapper、hash、完整部署测试和 runbook/inventory 投影。
4. **安全写入重构**：修 TOML 循环、state 单写者、YAML 原子写、timeout/redaction/runtime 漂移。
5. **Live 发布**：通过 final hash gate 部署，保留 retirement 文件备份并取消无效注册。
6. **重启与信任**：完整重启 Codex，用户审核新增 GitHub hook，不直接修改 trust state。
7. **全链路验收**：fresh SessionStart、provider/GitHub/Serena/state 功能检查和对抗性复核。

只有当前阶段通过验证后才进入下一阶段。任一阶段出现 live hash 漂移、解析失败、无法回滚或未预期的
未知 entry 变化，立即停止并保持/恢复上一个已验证状态。
