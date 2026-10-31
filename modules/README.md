---
type: index
title: 模块导航
tags: [环境治理, 模块化, 架构]
intent: 说明单仓模块边界、接口、依赖与迁移顺序
---

# 模块导航

本项目保持为一个 Git 仓库，但不再作为单一上下文维护。模块的知识入口位于 `modules/<module-id>/CONTEXT.md`，文件归属、对外接口、测试和依赖的机器可校验真源是 `modules/manifest.json`。

| 模块 | 职责 | 对外 seam |
| --- | --- | --- |
| `dev-environment` | 盘点、dry-run 迁移、PATH、备份与报告 | `Invoke-EnvInventory.ps1` 及 `New-*` 计划/报告入口 |
| `codex-host` | Hooks、state preflight、Serena/CodeGraph 运行时、remote catalog guard | `Invoke-CodexHostHookReconciliation.ps1` 与 `Invoke-CodexRemotePluginCatalogGuard.ps1` |
| `skill-supply-chain` | Skill 来源、安装事务、catalog、ledger 与 Git overlay | `install-skill-guarded.cmd`、catalog 生成器与部署入口 |
| `host-safety` | 句柄绑定 I/O、路径安全、原子发布、安全诊断与恢复、safe delete | manifest 登记的 `scripts/lib/` seam、主机诊断入口与 `invoke-codex-safe-tree-delete.cmd` |
| `workstation-operations` | 设备事实、跨设备验收与工作站集成政策 | 设备文档、Sub2API 更新政策、日更证据读取入口 |

## 依赖方向

```text
dev-environment -----> host-safety <----- codex-host
                           ^
skill-supply-chain --------+
codex-host ----------> workstation-operations -----> host-safety
codex-host ----------> skill-supply-chain
```

`CodexHostSafety.ps1` 是通用 capability I/O、路径校验和原子发布的唯一实现。`codex-host`、safe-delete 与 `skill-supply-chain` 的退休菜单清理都依赖该 seam；safe-delete 不再加载 hook 专用 policy，现役入口路径保持不变。Grok/Cursor/Claude Code 用户级 hook 源落在 `managed/grok-hooks/`、`managed/cursor-hooks/` 与 `managed/claude-hooks/`，不是 reconciler 接口；现役注册以 `D:\Codex\.codex\docs\agent-guidance\host-runbook.md` 的 Grok Host Hooks、Cursor Host Hooks 与 Claude Code Host Hooks 为准。

Claude Code 的 SessionStart 检查 hook（`managed/claude-hooks/claude-session-settings-check.mjs`）在上下文压缩后给 agent 一条指针，指向 active retro skill 的 `transcripts.py`（`find`、`show --grep`）；它的源码是 skill-supply-chain 的 retro overlay，所以 codex-host 依赖这个接口。改这两个子命令或参数时，同步改那条指针。

## 迁移规则

日更证据读取入口调用 host-safety 的有界投影器；codex-host 只识别这个固定入口的只读参数以豁免语义导航提醒，不负责执行日更或更新组件。模块 fixture 由现有 manifest runner 纳入 CI。

- 当前处于 `expand` 阶段：先建立 ownership、接口和测试 seam，不移动部署路径。
- 新增仓库文件必须在 manifest 中有且仅有一个 owner；根治理文件只能进入显式 `shared` 列表。
- 迁移实现时保留旧入口 adapter；只有新模块实现、测试、部署和回滚都独立通过后，才进入 `contract` 阶段。
- 历史 spec/plan 暂不移动；部分 dated 文档仍包含现役合同，模块 CONTEXT 只引用真源，不复制合同正文。

## 校验

```powershell
node .\scripts\Validate-ModuleBoundaries.cjs --json
node .\scripts\Validate-ModuleBoundaries.cjs --owners scripts\Publish-GitHubIssueComment.ps1
node .\tests\Test-ModuleBoundaries.cjs
node .\scripts\Run-PowerShellTests.cjs --module dev-environment --list
```

边界校验经 `git ls-files --others` 纳入未跟踪文件：不得与正在写 `reports/`、`.scratch/` 的测试套件并行跑，否则测试运行产物会被判 no owner 而误报（fail-closed 方向，有意保留）；manifest 门与 fixture 门串行执行。

`--owners` 给出每个路径的归属模块和该模块的测试 profile，不必翻 manifest。提交说明的 scope 用归属模块：`.githooks/commit-msg` 在 scope 是模块 id（含 `shared`）而暂存改动里没有文件归它时拒绝提交，scope 不是模块 id 时不查；它还对要提交的整棵树跑一遍边界校验（同 `--rev`），CI 的 Module boundaries 会拦的违规在提交时就被拒绝。

CI 按模块和 profile 跑上面的 runner。推送后等结果用 `scripts/Wait-CiRun.ps1 -Sha <完整 SHA>`：它等这个提交的 run 跑完，列出每个 job 的结论和耗时，没通过时接着给出下面的失败摘要。某次 run 失败时，先跑 `scripts/Get-CiFailureSummary.ps1 -RunId <id>`：它只列每个失败 job 的失败测试、报错行和失败标记。需要完整日志时再看 `gh run view <id> --log-failed`。

要看耗时（重新平衡分片、估算对照组占比）时跑 `scripts/Get-CiTestTiming.ps1 -RunId <id>`：它给出 run 的墙钟和起跑延迟，列每个 job 的逐测试秒数，测试用 `Write-Stage` 打了 `STAGE` 行时再列分段秒数。main 上的 run 要等同一 concurrency 组里正在跑的 run 结束（见 `ci.yml`），这段排队也算进从 run 开始算的墙钟；脚本把它单列为最早起跑延迟，跨 run 比较墙钟时用括号里从最早起跑算起的那个数。跨 run 比较某一段之前先校准：每个分片各自分到 runner，同一段在不同 run 里能差到约 1.5 倍，所以先看同一测试里没改动的段（`scale-create*`、`scale-plan*`）差了多少，再看改动段。本机单跑对比时，别的会话的负载也能让同一段慢 20%–30%，要在机器空闲时复跑确认。
