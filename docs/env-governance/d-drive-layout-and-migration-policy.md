---
type: reference
title: D 盘目标布局与迁移政策
tags: [环境治理, D盘, 迁移]
intent: 约束 D 盘布局、迁移授权、验证与回滚边界
---

# D 盘目标布局与迁移政策

本项目的目标不是把全机强行压成一份环境，而是从实用性出发做到：该共享的共享，该隔离的隔离；能安全迁移的先 dry-run，不能确定的先停在人工审查。

本政策供后续 agent 在执行迁移、更新入口整理或环境复用方案前读取。除非用户明确授权，本文只允许作为决策边界，不代表可以直接移动、删除、更新或重装任何内容。

## D 盘目标布局

| 根目录 | 用途 | 默认策略 |
| --- | --- | --- |
| `D:\Codex\tools` | 共享工具和运行时根，例如 Python、PowerShell、uv、CodeGraph 等。 | 优先用于可重装、可版本化、可验证的工具入口。 |
| `D:\Codex\envs` | 可复用共享环境根，例如跨项目使用的通用 Python/Node/Rust 工作环境。 | 只放明确跨项目复用、没有项目锁文件强绑定的环境。 |
| `D:\Codex\.cache` | 共享缓存根，例如 pip、npm、NuGet、Maven、Gradle 等缓存的统一候选位置。 | 优先迁移低风险缓存；真实迁移必须先有 dry-run。 |
| `D:\Codex\.cargo` 和 `D:\Codex\.rustup` | Rust 工具链、cargo 工具和缓存状态。 | 保持官方工具链机制管理，不直接搬目录。 |
| `D:\agents\projects\统一环境\reports\` | 本项目的盘点、迁移计划、更新准备等报告。 | 作为项目内事实基线，不放真实迁移副本。 |
| `D:\agents\run-evidence\env-governance\` | 跨项目或本机级迁移证据、前后对比和回滚记录。 | 真实迁移时保存证据；项目内只放摘要或链接。 |

已有历史路径可以暂时保留，例如 `D:\Codex\.pip-cache`、`D:\Codex\tools\npm-cache`、`D:\uv\cache`。后续如要统一到 `D:\Codex\.cache`，必须单独开 issue，不能靠批量搬目录完成。

## 环境分类

### 共享运行时

共享运行时是能被多个项目安全调用的解释器、编译器或运行时，例如 D 盘 Python、PowerShell、Rust 工具链、.NET 运行时，以及未来可能纳入的 Node 运行时。

迁移或更新原则：

- 优先通过官方安装器、运行时管理器或重新安装切到 D 盘。
- 不直接搬动 `C:\Program Files`、`C:\Windows`、WindowsApps、WinGet 包目录或 MSI 管理目录。
- 变更前必须确认 PATH 入口顺序、shim、版本探测和回滚方式。

### 共享缓存

共享缓存包括 pip、npm、pnpm、Cargo、NuGet、Maven、Gradle 等下载缓存或包缓存。

迁移或更新原则：

- 共享缓存是最优先考虑的低风险迁移对象。
- 默认目标根是 `D:\Codex\.cache`，具体生态可使用子目录，例如 `D:\Codex\.cache\pip`。
- 即使来源位于 `C:\Users`，也只能针对明确缓存子目录生成 dry-run；不得批量迁移用户目录或 AppData。
- 真实迁移时先复制、验证配置生效；旧源目录默认保留。
- 任何 C 盘源目录删除、清理或配置写入都必须作为单独步骤列明，并取得用户对该步骤的显式授权；“迁移授权”不自动包含删除或清理授权。

### 全局 CLI

全局 CLI 包括 `uv`、`git`、`cmake`、`ninja`、GitHub CLI、jq、Everything CLI 等命令入口。

迁移或更新原则：

- D 盘已有 CLI 优先保持现有策略。
- C 盘或用户目录 CLI 先判断来源：官方安装器、WinGet、pipx、npm global、Cargo install 或手工放置。
- WinGet、Scoop、npm、Cargo、Rustup、uv 等命令不得由本项目自动执行；默认只能在报告中给出建议。只有用户明确授权具体项，且已准备验证证据和回滚路径时，才可执行对应管理器命令。
- 同一 CLI 的多个 PATH 入口要单独清理，不能作为迁移副作用处理。

### 项目本地环境

项目本地 `.venv`、`node_modules`、`.conda`、`.direnv`、构建输出、项目数据库和服务状态默认保留隔离。

默认规则：

- `.venv` 和 `node_modules` 不进入共享环境合并计划。
- 不跨项目复用项目本地依赖目录。
- 不自动迁移长期服务项目、本地机器人、历史归档项目或带运行状态的环境。
- 如某个项目需要重建环境，应由该项目自己的锁文件、安装命令和测试流程完成。

### 人工审查项

以下对象必须进入人工审查，不能自动迁移或自动更新：

- 项目本地环境和依赖目录。
- reparse point、junction、symlink 以及目标不明的路径。
- 正在运行的服务、数据库、虚拟磁盘、容器状态和浏览器 profile。
- 包含凭据、token、证书、license、SSH/GPG key、DPAPI 保护数据的目录。
- 官方安装器、MSI、Store、WinGet 或 Windows 功能管理的工具根。

### 绝不自动迁移项

以下根目录或对象不允许本项目自动迁移：

- `C:\Windows`
- `C:\Program Files`
- `C:\Program Files (x86)`
- `C:\ProgramData`
- `C:\Users` 整体以及未被明确识别为缓存子目录的 AppData 内容
- `C:\Program Files\WindowsApps`
- 服务状态、凭据目录、系统组件、浏览器 profile、证书、SSH/GPG key、token、license、数据库和虚拟磁盘

## 真实迁移门槛

任何真实迁移、更新入口切换或 PATH 修改前，必须同时满足以下条件：

1. 重新运行只读 inventory，确认事实基线是最新的。
2. 生成或更新 dry-run 计划，并明确来源、目标、风险、root policy 和排除项。
3. 用户对具体迁移项给出显式授权；笼统的“继续”不等于授权真实迁移。
4. 迁移计划包含验证步骤：工具命令、版本探测、inventory 对比、报告对比和必要的项目级 smoke test。
5. 迁移计划包含回滚步骤：恢复配置、恢复旧路径、保留旧副本、重新验证。
6. 来源、目标、输出路径及其所有已存在父级都不能穿过 junction、symlink 或 reparse point；命中时必须停在人工审查。
7. 输出路径必须位于 D 盘。
8. 迁移证据写入 `D:\agents\run-evidence\env-governance\` 或本项目 `reports\`，不得写到 C 盘。

同样的门槛适用于全局管理器更新、Machine/User PATH 改写、默认解释器切换和工具 shim 调整；这些操作即使不移动目录，也会改变后续进程的默认行为。

## 后续执行顺序

推荐顺序：

1. 继续保持只读盘点和报告为事实基线。
2. 优先处理低风险共享缓存，例如当前 dry-run 中的 pip cache 候选。
3. 再处理全局 CLI 的更新入口和 D 盘重装策略。
4. 最后逐项目审查 `.venv`、`node_modules` 等本地环境；默认不合并。

若报告、inventory 和本政策冲突，以更保守的规则为准：先停止、记录冲突，再让用户确认下一步。
