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
| `Read-BoundedProjection.ps1` | 文本、Markdown 章节、字段白名单 JSONL 与 `-HttpLog` 共用整批默认 6000 UTF-8 字节预算。已知敏感字段在裁剪前处理；HTTP 模式只输出固定事件与安全字段。活动日志允许写入/轮转；含 UTF-8 替换字符的行整行跳过，计 `replacementCharacterRows`，返回 `read-with-encoding-omissions` 和退出 1。未知行不回显，计数不是零错误证明。 |
| `Invoke-CheckedPowerShell.ps1` | PowerShell Core 7.4+；Parser 预检后才执行，`-CheckOnly` 只解析。`-RequiredJsonFields` 验证单份 JSON 对象的指定路径存在且非 null，保留 false/0；目标非零退出时不校验，照常转出它的 stdout/stderr 并透传退出码。语法/输入拒绝 2、JSON 拒绝 3、超时 124，原生非零透传；执行异常退出 1，stderr 报 `runtime-error type=… category=… script=… line=… column=…`，不回显异常消息或源码（`throw` 的文本还会进 error id，故也不输出 id）。目标已退出而后代占用输出管道时，stderr 另报 `targetExited=true targetExitCode=<code> outputClosed=false descendantsMayRemain=true retrySafe=false`；先核对既有实例，再决定处置。 |
| `BrowserPrivacyProbe.py` | Windows、Python 3.12+ 标准库；仅启动本机环回验证服务，浏览器由用户打开。独立 run/attempt、服务器接收时间、完整报告校验和持久手动路线防止旧结果误判与重复自动启动。验收固定为英语语言/Intl、三组 ICE 无候选且完成无错误、本地字体 API denied；Canvas 字体仅观察。 |
| `Get-NvidiaDownloadStatus.ps1` | 原生下载计数、任务关联、进程/用户/机器代理摘要；进程代理凭据和完整环境不输出。`-Offline` 只读状态文件；单点零速不证明卡住，`bytes-complete` 不证明包完整性或已安装。Windows x64 PEB 无法读取时明确 unavailable。NO_PROXY 不绕过 TUN。 |
| `Get-TaskbarSnapshot.ps1` | 当前 shell 身份、窗口响应、固定项聚合哈希；不返回窗口标题或快捷方式目标。窗口就绪不能证明图标视觉正常。 |
| `Restart-ExplorerShell.ps1` | Core 7.5+；默认 Plan，Apply 必须消费 120 秒内计划，核对 PID/启动时间/路径/会话、固定项和窗口。会话互斥覆盖停止至验收；停止前保存路径，先观察自动恢复，再有限创建。计划预算为 5–60 秒。工具层成功要求 ready、桌面/任务栏就绪和固定项一致，视觉验收单独完成。 |
| `Invoke-ManagedRecycle.ps1` | Core 7.4+；把单个文件或目录树移入所在卷的回收站。Check 只读运行同一套预检，不需要用途和授权，也不写 evidence；Plan 把逐项相对路径清单、回收站状态、用途和用户授权原话写入 D 盘 evidence 的 `plan.json`；Apply 须在 30 分钟内凭 plan SHA-256 与 `-ConfirmRecycle` 执行，重跑预检并比对清单后调用 `SHFileOperationW`，再按原路径读回 `$I`/`$R` 记录、比对回收站副本；被别的进程占用的 `$I` 记录重试到读回开始后 3 秒，仍读不了就跳过并列入 `unreadableBinRecords`，目标记录不在可读记录里时报 `bin-record-unreadable`。结果只写一次 `result.json`，同一 plan 不能重放；只有 `checked`/`planned`/`recycled` 退出 0。卷根、受保护根及其祖先、系统子树、链接、超长路径（拒绝时分列原位与回收站内长度并点名超长条目）、NoRecycleFiles/NukeOnDelete 和回收站余量不足一律拒绝；不做永久删除，也不清空回收站。Agent 使用边界见宿主 `host-runbook/safe-tree-delete.md` 的受管回收节。 |
| `Get-ConsoleLaunchAudit.ps1` | 只读。枚举在用户会话里运行的计划任务（登录类型 Interactive、InteractiveOrPassword、Group）、HKCU 与 HKLM 的 Run/RunOnce（含 WOW6432Node）和两个启动文件夹；已禁用的任务和被任务管理器禁用的登录项（StartupApproved 首字节为奇数）只计数。按启动的程序分类：hidden 是 pythonw 跑的脚本以 `CREATE_NO_WINDOW` 启动紧跟在它后面的程序（按脚本文本判断，受管的 `hidden-console-launcher.py` 就是这种形式），或 `conhost.exe --headless`，且被启动的程序存在；gui 是 GUI 子系统程序、Windows Script Host 脚本或 pythonw 跑的其他脚本（这类脚本之后再打开的控制台静态审计看不到，要靠复验）；visible-console 是控制台子系统、`.cmd`/`.bat`、不带 `--headless` 的 conhost 或 Windows Terminal，`-WindowStyle Hidden` 不改变结论（Windows Terminal 承接控制台时窗口照样弹出）；missing 是程序、pythonw 要跑的脚本或被包装的程序不存在；unknown 是读不出 PE。名字某一段以 Codex 开头，或程序、参数指向 `D:\Codex\`、`D:\agents\` 的算 Codex 自有，全部列出且发现项在前；其他入口只在会开控制台时列出，仅供参考。不输出参数；Codex 自有入口有 visible-console、missing 或 unknown 时退出 1。经 SSH 运行时，HKCU 和个人启动文件夹是 SSH 账户的。 |
| `Watch-ConsoleWindows.ps1` | 在真实会话复验改动。为当前账户注册两个没有触发器的临时 Interactive 任务：经 `conhost --headless` 启动的监视器，和不加包装直接跑 pwsh 的对照任务。对照会在用户桌面闪一个约 2.5 秒的窗口，证明监视器看得见这个桌面。随后每隔 5 秒启动一个 `-StartTasks` 任务，最后由监视器经 shell 打开 `-LaunchPath`（如启动文件夹快捷方式）。新窗口归到它之前最近的触发：`quiet` 退出 0；`windows-seen`、`control-missed`、`trigger-failed`、`monitor-not-started`（该账户没有交互登录）退出 1。临时任务在写报告前删除，被中断的运行会留下 `zz-CodexConsoleWatch-*`。不记录窗口标题和命令行；`-EvidenceDirectory` 必须是新的 D 盘目录。 |

参数与返回结构以各脚本帮助/源码为准。活动日志不是原子快照；命名模式脱敏不保证发现任意秘密，仍要缩小敏感来源与字段范围。需要复核某条失败时保留来源、行窗口和退出码，不输出完整日志。

## 按章节读取

已知标题时直接选 ATX 章节，保留原文件行号、子标题内容、脱敏与总预算：

```powershell
& 'D:/Codex/.codex/scripts/Read-BoundedProjection.ps1' -LiteralPath 'D:/agents/projects/统一环境/docs/env-governance/host-diagnostics.md' -MarkdownSection '工具合同' -MaxRows 80 -MaxValueChars 1000
```

spec 对应 `{"path":"D:/path/reference.md","format":"markdown","section":"标题"}`。标题精确区分大小写，忽略代码围栏中的伪标题；只支持 ATX，不解释 Setext。缺失或重复标题分别返回 `section-not-found`、`section-ambiguous` 和退出 1，来源内容不输出。命中总预算或单行裁剪时按返回的行号续读，不把省略部分当作已读。

## 浏览器语言与隐私复测

维护 Edge 语言、Intl、字体权限或 WebRTC 前，先用下表确定设置层；真实网页是验收来源。浏览器 locale 与系统显示语言分开设置；除非任务明确要求，保留当前系统显示语言和系统字体。

| 目标 | 设置入口与验收 |
|---|---|
| 网站语言与请求头 | `edge://settings/languages` 的 Preferred languages。按任务目标选择首选语言，再读取 `navigator.languages`、Worker 和服务端 `Accept-Language`。离线 Preferences 写入可能被重开后的状态覆盖；出现覆盖时改走正式设置入口。 |
| Intl 日期与数字 locale | Edge 显示语言/应用 locale 可独立于 Windows 显示语言；选择目标语言、按 Edge 提示重开后实测主线程和 Worker。配置值或界面语言本身不能代替 Intl 结果。 |
| 字体 | Local Font Access 权限控制枚举 API；普通 Profile 和禁止该权限都不能隔离 Canvas/CSS 字体宽度探测。用户接受日常 Edge 的这一限制时，字体检测保留为观察项。 |
| WebRTC | 先确认当前版本支持的设置入口；没有适用 setter 时，完整退出后只改目标 Profile 的 `webrtc.ip_handling_policy=disable_non_proxied_udp`。先备份、最小 diff、重开回读，再实测三组 ICE。零候选只证明所测场景，不代表 RTCPeerConnection API 被禁用。 |

离线编辑只用于已核实的当前 Profile/Local State 字段，且浏览器及其后台进程已完整退出。记录文件哈希、原值和回退范围；重开后字段被覆盖时改走正式设置入口，不循环重写整个 Profile。浏览器自动启动/调试出现网页超时或反复许可时，记录失败并转手动路线；单次故障与恢复不足以唯一确定根因，归因和恢复记录留在对应运行证据。

先查询持久路线。出现故障时记录在宿主 evidence，后续任务沿用，正常手动复测不会自动解锁：

```powershell
python -B 'D:/Codex/.codex/scripts/BrowserPrivacyProbe.py' route --browser edge
python -B 'D:/Codex/.codex/scripts/BrowserPrivacyProbe.py' record-failure --browser edge --reason navigation-timeout
```

默认路线文件为 `D:/agents/run-evidence/browser-privacy-routing/state.json`。`automationAllowed=false` 时停止该浏览器的自动启动/附着重试，保留设置，由用户从开始菜单/桌面启动；工具对 `start --transport automation` 返回退出 5，不创建服务目录。这是受管工作流入口的约束，不是对任意 CDP 客户端的系统拦截。只有独立隔离试验证明故障路径已修复后，才另行维护该路线状态。

每轮使用新的 D 盘 run 目录；以下 `<new-run>` 必须替换为该轮目录：

```powershell
python -B 'D:/Codex/.codex/scripts/BrowserPrivacyProbe.py' start --run-dir 'D:/agents/run-evidence/browser-privacy/<new-run>'
python -B 'D:/Codex/.codex/scripts/BrowserPrivacyProbe.py' prepare --run-dir 'D:/agents/run-evidence/browser-privacy/<new-run>'
python -B 'D:/Codex/.codex/scripts/BrowserPrivacyProbe.py' status --run-dir 'D:/agents/run-evidence/browser-privacy/<new-run>'
python -B 'D:/Codex/.codex/scripts/BrowserPrivacyProbe.py' stop --run-dir 'D:/agents/run-evidence/browser-privacy/<new-run>'
```

`start` 返回首次 attempt 和 URL；请用户在日常浏览器普通窗口打开 URL，等待“检查完成”，再查 `status`。每次后续设置修改/复测，先 `prepare` 建立新 attempt，再请用户刷新同一 URL。等待用户操作时不要打开自动化通道。每个 attempt 只接收一份完整报告；旧标签的迟到结果、重复提交或空的 ICE/Worker/Intl 字段不能变成成功。`status` 退出码：0 已通过、1 完整但不达标、2 输入/身份/证据错误、3 等待当前结果；`start --transport automation` 被持久路线拒绝时退出 5。其他动作的退出 0 仅表示该动作成功。“检查完成”仅表示保存了报告，最终判断仍用 `status`；内置通过条件固定为英语环境，其他 locale 目标应按原始观察结果单独验收。

服务使用随机 owner 握手、OS 进程身份、独立输出文件和 readiness 核对，默认 900 秒后退出。`start` 遇到已有实例返回同一 PID；退出后的目录不能复用。同步 wrapper 报 124 时先核对原实例，不立即再起一个服务。`stop` 只控制身份匹配实例并回读退出；run 目录保留每次结果及生命周期证据。请求限于同源环回；保存候选地址的类型和 IPv4/IPv6 分类，不保存原始 IP、Cookie 或 Profile 内容。页面会联系 Cloudflare/Google STUN，无媒体权限请求。

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

仓库 fixture 运行合成日志、语法/JSON 合同、NVIDIA 状态、浏览器 CLI/HTTP 合成报告、带所有权握手的隔离恢复用例、D 盘 fixture 上的回收入口拒绝/计划用例，以及控制台入口审计的合成 PE 与快捷方式夹具，显式跳过真实桌面快照和真实回收站移入（`-SkipLiveRecycle`）。审计 suite 还会注册一个没有触发器、跑完即删的临时 Interactive 任务，确认真实收集路径能读到它。`Watch-ConsoleWindows.ps1` 每次运行都会闪出对照窗口，不进自动回归，只做语法检查；它的每次结果由对照组自证。宿主完整入口会把两个 D 盘 fixture 树移入 D 盘回收站：回收第二个时，第一个的 `$I` 记录被测试独占打开，回收站里另有测试写入的一条日期更晚、指向别的路径的诱饵 `$I` 记录。随后像资源管理器还原那样移回两个树，`$I` 记录（含诱饵）归入本轮 evidence，不永久删除任何内容。浏览器 suite 不启动或附着真实浏览器，不能代替真实页面验收。CI 为 host-safety 配置 Python；本机测试从 PATH 解析 `python.exe`。部署后使用完整入口检查实际宿主只读面：

```powershell
& 'D:/Codex/.codex/scripts/Test-HostDiagnostics.ps1'
& 'D:/Codex/.codex/scripts/Get-ConsoleLaunchAudit.ps1'
& 'D:/Codex/.codex/scripts/Get-NvidiaDownloadStatus.ps1'
& 'D:/Codex/.codex/scripts/Get-TaskbarSnapshot.ps1'
& 'D:/Codex/.codex/scripts/Restart-ExplorerShell.ps1' -Mode Plan
```

完整回归也不停止真实 Explorer。故障修复的 Apply 属于单独的用户授权动作；不得为重复验收重启健康桌面。若计划过期、身份漂移或其他恢复正在执行，重新采集 Plan；启动失败/readiness 超时按结果中的 Reason、LaunchAttempts 与 ProcessState 处理，不对漂移目标继续操作。

设备事件、活动进程、下载版本、校验值、账户与一次性测试输出属于运行证据，写入 D 盘 evidence，不提交到本目录。全局 Agent 规则由既有共享源同步器维护，不将生成的 AGENTS.md 当成此工具源码。
