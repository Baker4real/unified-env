---
type: reference
title: 主机诊断与安全恢复
tags: [宿主安全, PowerShell, 诊断]
intent: 定义诊断工具的源码归属、部署闭包、输出边界和验收入口
---

# 主机诊断与安全恢复

源码真源为 `managed/host-diagnostics/`，由 `host-safety` 模块拥有。目录结构与部署目录一致，脚本通过相邻文件调用，不依赖仓库外的同名实现。默认宿主入口位于 `D:/Codex/.codex/scripts/`；部署副本用于运行，后续修复先改仓库源。

## 工具合同

| 入口 | 行为与完成边界 |
|---|---|
| `Read-BoundedProjection.ps1` | 文本、字段白名单 JSONL 与 `-HttpLog` 共用整批默认 6000 UTF-8 字节预算。已知敏感字段在裁剪前处理；HTTP 模式只输出固定事件与安全字段。活动日志允许写入/轮转；含 UTF-8 替换字符的行整行跳过，计 `replacementCharacterRows`，返回 `read-with-encoding-omissions` 和退出 1。未知行不回显，计数不是零错误证明。 |
| `Invoke-CheckedPowerShell.ps1` | PowerShell Core 7.4+；Parser 预检后才执行，`-CheckOnly` 只解析。`-RequiredJsonFields` 验证单份 JSON 对象的指定路径存在且非 null，保留 false/0。语法/输入拒绝 2、JSON 拒绝 3、超时 124，原生非零透传。它是同步显式入口，不拦截所有宿主 exec；目标先退出但后代持有输出管道时，不能保证后代已退出。 |
| `Get-NvidiaDownloadStatus.ps1` | 原生下载计数、任务关联、进程/用户/机器代理摘要；进程代理凭据和完整环境不输出。`-Offline` 只读状态文件；单点零速不证明卡住，`bytes-complete` 不证明包完整性或已安装。Windows x64 PEB 无法读取时明确 unavailable。NO_PROXY 不绕过 TUN。 |
| `Get-TaskbarSnapshot.ps1` | 当前 shell 身份、窗口响应、固定项聚合哈希；不返回窗口标题或快捷方式目标。窗口就绪不能证明图标视觉正常。 |
| `Restart-ExplorerShell.ps1` | Core 7.5+；默认 Plan，Apply 必须消费 120 秒内计划，核对 PID/启动时间/路径/会话、固定项和窗口。会话互斥覆盖停止至验收；停止前保存路径，先观察自动恢复，再有限创建。计划预算为 5–60 秒。工具层成功要求 ready、桌面/任务栏就绪和固定项一致，视觉验收单独完成。 |

参数与返回结构以各脚本帮助/源码为准。活动日志不是原子快照；命名模式脱敏不保证发现任意秘密，仍要缩小敏感来源与字段范围。需要复核某条失败时保留来源、行窗口和退出码，不输出完整日志。

## 部署

```powershell
& ./scripts/Deploy-HostDiagnostics.ps1
& ./scripts/Deploy-HostDiagnostics.ps1 -Mode Apply
& ./scripts/Deploy-HostDiagnostics.ps1 -Mode Check
```

Check 只读比较明确 allowlist 内的源码与部署文件：一致退出 0，差异退出 1，不创建证据或缓存。`SourceRoot`、`TargetRoot` 可指定独立的 D 盘测试目录；路径重叠、reparse point 或缺少源码时拒绝部署。

Apply 只更新这份闭包，先完成全部备份和源文件暂存，再逐文件原子替换并回读哈希；这是逐文件替换，不保证整包事务回滚。失败返回非零，保留 `EvidenceRoot` 下的备份和 manifest，按其中的已写入文件及哈希核对恢复范围。运行中的 NVIDIA/Explorer、代理配置、hook 和计划任务不由部署器修改。仓库发布与宿主部署分别回读，Git 提交或工具存在都不等于已经部署。

## 验收

仓库内的定向命令接入模块 manifest 和现有 Windows CI fixture：

```powershell
node ./scripts/Run-PowerShellTests.cjs --module host-safety --profile diagnostics
node ./tests/Test-ModuleBoundaries.cjs
git diff --check
```

仓库 fixture 运行合成日志、语法/JSON 合同、NVIDIA 状态与带所有权握手的隔离恢复用例，显式跳过真实桌面快照。部署后使用完整入口检查实际宿主只读面：

```powershell
& 'D:/Codex/.codex/scripts/Test-HostDiagnostics.ps1'
& 'D:/Codex/.codex/scripts/Get-NvidiaDownloadStatus.ps1'
& 'D:/Codex/.codex/scripts/Get-TaskbarSnapshot.ps1'
& 'D:/Codex/.codex/scripts/Restart-ExplorerShell.ps1' -Mode Plan
```

完整回归也不停止真实 Explorer。故障修复的 Apply 属于单独的用户授权动作；不得为重复验收重启健康桌面。若计划过期、身份漂移或其他恢复正在执行，重新采集 Plan；启动失败/readiness 超时按结果中的 Reason、LaunchAttempts 与 ProcessState 处理，不对漂移目标继续操作。

设备事件、活动进程、下载版本、校验值、账户与一次性测试输出属于运行证据，写入 D 盘 evidence，不提交到本目录。全局 Agent 规则由既有共享源同步器维护，不将生成的 AGENTS.md 当成此工具源码。
