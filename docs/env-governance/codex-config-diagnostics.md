---
type: reference
title: Codex 配置警告只读检查
tags: [Codex, 配置, 诊断]
intent: 区分用户配置、profile、运行时和桌面会话的配置警告，并提供可失败的只读验收入口
---

# Codex 配置警告只读检查

遇到 `unrecognized configuration`、`deprecated and ignored` 或配置加载错误时使用本入口。检查器只读取配置、启动短生命周期验证进程，不修改配置、不启动模型任务，也不恢复已退役的 config reconciliation。

## 检查入口

```powershell
python -B D:/agents/projects/统一环境/modules/codex-host/Check-CodexConfig.py --home D:/Codex/.codex --cwd D:/agents/projects/misc
```

默认从正在运行的 `codex.exe app-server` 发现二进制；没有活动 app-server 时才使用 PATH 中的 Codex，并在 `runtimeIdentity.source` 标明 `path-cli`。存在多个不同活动二进制或发现失败时，使用 `--codex-exe <绝对路径>` 选择目标，不能从安装目录名猜当前版本。`--timeout` 是每次运行时探测的截止时间，默认 20 秒。

一次输出一份 JSON，退出码 0 仅表示文件检查和本次运行时加载均通过；失败退出 1，参数非法退出 2。不输出配置值、模型提示词、MCP 环境变量或原始 stderr。

| 字段 | 验证范围 |
|---|---|
| `acceptance.files` | 基础 `config.toml` 与当前全部 `*.config.toml` 的 TOML 语法、目标废弃键及验证期间的内容稳定性 |
| `acceptance.runtime` | 基础配置以 `app-server --strict-config --stdio` 完成 `initialize → initialized → config/read`；命名 profile 以 `-p <name> mcp list --json` 完成实际本地加载 |
| `acceptance.desktopSession` | 始终为 `unverified`；新进程成功不证明已打开桌面的会话参数或警告状态 |

当前运行时的 `app-server` 不接受 `--profile`，也不能将 `--strict-config` 套给 `features list`。profile 的检查方法会单独记录为 `profile-mcp-list`，不冒称严格 app-server 检查；该命令列出本地配置，不连接 MCP 服务。未知参数、提前 EOF、缺少响应、错误响应、超时、非零退出、已识别的配置警告均不能通过。

## 按来源排查

1. 先读警告的来源标签。`user (<path>)` 只定位该真实路径；`session-flags` 指向会话注入层，不能靠在用户配置中添加同名键抵消。
2. 运行检查器，确认基础配置、profile 和当前运行时。目标废弃项是 `disable_response_storage`、`features.code_mode_tool_description_first` 和 `features.guardianv2.thread_context`，包括其 profile 覆盖；注释或字符串提及不算配置键。
3. 文件和运行时通过但桌面仍告警时，核对当前客户端会话来源。安装包中找到旧键只证明它包含相关代码；结合实际警告才能归因，仍不能据此断言只有官方更新可修复。
4. 桌面警告消失需要新会话或重新加载后的直接观察。未做该观察时保持 `desktopSession: unverified`；记录剩余警告，不以清理历史聊天或修改官方安装包消除提示。

## 有界检索

先用 `rg -n` 定位确切文件或标题，再复用受管投影工具读取片段。对于多个来源，使用一份 `-LiteralPath` 数组或 spec，让整批共享输出预算；不要将整个主机手册、知识索引和配置状态文件一起回显。

```powershell
& D:/Codex/.codex/scripts/Read-BoundedProjection.ps1 -LiteralPath D:/agents/projects/统一环境/docs/env-governance/codex-config-diagnostics.md -MarkdownSection '按来源排查' -MaxValueChars 500 -MaxTotalBytes 4000
```

结果包含真实路径、行号和省略数量；存在省略时继续缩小章节或行区间。JSON/日志使用字段白名单，不把聊天历史中的键名提及当成实际配置。多种 PowerShell 对象分别投影为固定字段后输出 JSON，避免管道格式化产生空列。完整投影合同见 `D:/Codex/.codex/docs/agent-guidance/context-amplification.md` 的「工具输出总预算」。

## 回归与维护

`python -B tests/Test-CodexConfig.py` 覆盖真实子进程协议的成功、提前 EOF、错误/缺失响应、超时与关闭超时、非零退出、配置警告、输出超限，以及 profile 失败和敏感值不外泄。测试通过现有 CI 执行，fixture 使用合成配置。

Serena 文档/数据查询豁免的实现和边界仍由 `managed/codex-hooks/hooks/serena-behavior-guard.ps1` 与 `tests/Test-CodexSerenaBehaviorHooks.ps1` 维护。静态文件元数据查询可与文档检索组合；混合代码正文检索或动态路径继续原提醒，不清空已有代码计数。正式部署只走 `Invoke-CodexHostHookReconciliation.ps1`，验证 Check、Repair 幂等及实际注册 wrapper 的正反行为。
