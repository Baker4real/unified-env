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
| `Read-BoundedProjection.ps1` | 文本、Markdown 章节、字段白名单 JSONL、字段白名单单份 JSON（spec `format:"json"`，文件超过 4 MiB 时不解析，报 `json-too-large` 和退出 1）与 `-HttpLog` 共用整批默认 6000 UTF-8 字节预算。已知敏感字段在裁剪前处理；HTTP 模式只输出固定事件与安全字段。活动日志允许写入/轮转；含 UTF-8 替换字符的行整行跳过，计 `replacementCharacterRows`，返回 `read-with-encoding-omissions` 和退出 1。未知行不回显，计数不是零错误证明。 |
| `Read-SessionDocument.ps1` | 静态文档的会话内读取入口，复用有界投影器；以内容 SHA-256 和读取选择识别重复，只把已实际返回的内容登记到显式 `StatePath`；有行因 `MaxValueChars` 带 `[value clipped]` 时报 `incomplete`，不登记。未变化时返回指针，`-Refresh` 强制重读。 |
| `Get-GitHubPublicationTarget.ps1` | 只读回查显式仓库的所有者、可见性、默认分支和写权限；与预期比较，输出 `observed` / `ready` / `mismatch` / `error`。不执行发布，也不产生用户授权。 |
| `screenshot-geometry.mjs` | 纯数据函数 `selectScreenshotForClick`，从同一坐标系的截图元数据中选择唯一完整覆盖窗口的截图，并校验、换算点击坐标。无 GUI 操作；缺失或歧义直接报错。 |
| `Invoke-CheckedPowerShell.ps1` | PowerShell Core 7.4+；Parser、单引号常量正则、原生 argv 和内置 cmdlet 参数绑定预检后才执行，`-CheckOnly` 只预检。`rg -e` / `--regexp` 的双引号参数中含 `\"` 时以 `native-argument-error command=rg reason=escaped-quote-native-argv` 拒绝，避免 XAML 属性片段被原生参数解析成搜索路径；模式改用单引号字符串。`gh --json` 的逗号字段列表须为单个字符串，`gh issue view` 的 `--comments` 与 `--json` 互斥。参数预检用 StaticParameterBinder 绑定 Core/Management/Utility/Security 模块的 cmdlet，`AmbiguousParameterSet` 与 `NamedParameterNotFound` 拒绝（stderr `parameter-error id=… command=… line=… column=…`），splat、输入自定义的同名函数和其他模块命令不查，内置 provider 的动态参数放行。stdout、stderr 各超过 `-MaxOutputChars`（默认 12000，0 关闭）时回显开头 2/3 与结尾 1/3，全文写进 `-SpillDirectory`（默认 `D:/Codex/temp/checked-powershell`），stderr 末尾报 `output-truncated stream=… shown=… total=… path=…`；带 `-RequiredJsonFields` 时 stdout 不截断。`-RequiredJsonFields` 验证单份 JSON 对象的指定路径存在且非 null，保留 false/0；目标非零退出时不校验，照常转出它的 stdout/stderr 并透传退出码。语法/正则/参数/输入拒绝 2、JSON 拒绝 3、超时 124，原生非零透传；执行异常退出 1，stderr 报 `runtime-error type=… category=… script=… line=… column=…`，不回显异常消息或源码（`throw` 的文本还会进 error id，故也不输出 id）。目标已退出而后代占用输出管道时，stderr 另报 `targetExited=true targetExitCode=<code> outputClosed=false descendantsMayRemain=true retrySafe=false`；先核对既有实例，再决定处置。 |
| `BrowserPrivacyProbe.py` | Windows、Python 3.12+ 标准库；仅启动本机环回验证服务，浏览器由用户打开。独立 run/attempt、服务器接收时间、完整报告校验和持久手动路线防止旧结果误判与重复自动启动。验收固定为英语语言/Intl、三组 ICE 无候选且完成无错误、本地字体 API denied；Canvas 字体仅观察。 |
| `Test-LoopbackProxy.ps1` | 真实 HTTP 204 业务预检；必须发出真实请求并验收 204，`listeners` 为空时仍以业务结果判定，不把空列表误判为代理故障。 |
| `Get-NvidiaDownloadStatus.ps1` | 原生下载计数、任务关联、进程/用户/机器代理摘要；进程代理凭据和完整环境不输出。`-Offline` 只读状态文件；单点零速不证明卡住，`bytes-complete` 不证明包完整性或已安装。Windows x64 PEB 无法读取时明确 unavailable。NO_PROXY 不绕过 TUN。 |
| `Get-TaskbarSnapshot.ps1` | 当前 shell 身份、窗口响应、固定项聚合哈希；不返回窗口标题或快捷方式目标。窗口就绪不能证明图标视觉正常。 |
| `Restart-ExplorerShell.ps1` | Core 7.5+；默认 Plan，Apply 必须消费 120 秒内计划，核对 PID/启动时间/路径/会话、固定项和窗口。会话互斥覆盖停止至验收；停止前保存路径，先观察自动恢复，再有限创建。计划预算为 5–60 秒。工具层成功要求 ready、桌面/任务栏就绪和固定项一致，视觉验收单独完成。 |
| `Invoke-ManagedRecycle.ps1` | Core 7.4+；把单个文件或目录树移入所在卷的回收站。Check 只读运行同一套预检，不需要用途和授权，也不写 evidence；Plan 把逐项相对路径清单、回收站状态、用途和用户授权原话写入 D 盘 evidence 的 `plan.json`；Apply 须在 30 分钟内凭 plan SHA-256 与 `-ConfirmRecycle` 执行，重跑预检并比对清单后调用 `SHFileOperationW`，再按原路径读回 `$I`/`$R` 记录、比对回收站副本；被别的进程占用的 `$I` 记录重试到读回开始后 3 秒，仍读不了就跳过并列入 `unreadableBinRecords`，目标记录不在可读记录里时报 `bin-record-unreadable`。结果只写一次 `result.json`，同一 plan 不能重放；只有 `checked`/`planned`/`recycled` 退出 0。卷根、受保护根及其祖先、系统子树、链接（加 `-AllowInternalHardLinks` 时放行每个名字都在目标内的 hardlink，计数报在 `internalHardLinkFiles`；Plan 记下开关，Apply 按 plan 的设置重检）、当前进程拿不到 DELETE 的条目（`delete-access-denied`，点名前 20 个并报是否提权；安装器收紧过的目录以前到 Apply 才报 `0x78`）、超长路径（拒绝时分列原位与回收站内长度并点名超长条目）、NoRecycleFiles/NukeOnDelete 和回收站余量不足一律拒绝；知识库页面 frontmatter `sources` 指向的目标或其内部路径报 `kb-cited`，点名前 20 处引用（2026-11-07 起，知识库根可用 `-KnowledgeBaseRoot` 改，不存在时不检查）；回收会丢掉的 git 内容报 `git-unsaved-work`（2026-11-08 起），逐条列在 `gitUnsavedWork`：目标里、目标所在和 `core.worktree` 指到目标里的工作树的未提交、未跟踪文件（含没检出的子模块目录里的文件，路径不分大小写匹配）、标了 assume-unchanged/skip-worktree 的文件，链接工作树只有其 HEAD 持有的提交，以及随目标一起回收的 git 目录（`.git`、裸仓库、`.git\modules` 下的仓库、目标所在的 git 目录）里目标外远端的远端跟踪分支到不了的提交（含 tag 与游离 HEAD）和 stash；git 以显式 `--git-dir` 只读运行，不联网、不执行仓库配置里的命令，读不了也拒绝。用户同意丢掉时 Check 与 Plan 加 `-GitLossAuthorization <用户原话>`，Plan 连同 `gitUnsavedWork` 记下，Apply 按 plan 重检，内容与 plan 不一致报 `git-unsaved-work-changed`。不做永久删除，也不清空回收站。Agent 使用边界见宿主 `host-runbook/safe-tree-delete.md` 的受管回收节。 |
| `Get-ConsoleLaunchAudit.ps1` | 只读。枚举在用户会话里运行的计划任务（登录类型 Interactive、InteractiveOrPassword、Group）、HKCU 与 HKLM 的 Run/RunOnce（含 WOW6432Node）和两个启动文件夹；已禁用的任务和被任务管理器禁用的登录项（StartupApproved 首字节为奇数）只计数。按启动的程序分类：hidden 是 pythonw 跑的脚本以 `CREATE_NO_WINDOW` 启动紧跟在它后面的程序（按脚本文本判断，受管的 `hidden-console-launcher.py` 就是这种形式），或 `conhost.exe --headless`，且被启动的程序存在；gui 是 GUI 子系统程序、Windows Script Host 脚本或 pythonw 跑的其他脚本（这类脚本之后再打开的控制台静态审计看不到，要靠复验）；visible-console 是控制台子系统、`.cmd`/`.bat`、不带 `--headless` 的 conhost 或 Windows Terminal，`-WindowStyle Hidden` 不改变结论（Windows Terminal 承接控制台时窗口照样弹出）；missing 是程序、pythonw 要跑的脚本或被包装的程序不存在；unknown 是读不出 PE。名字某一段以 Codex 开头，或程序、参数指向 `D:\Codex\`、`D:\agents\` 的算 Codex 自有，全部列出且发现项在前；其他入口只在会开控制台时列出，仅供参考。不输出参数；Codex 自有入口有 visible-console、missing 或 unknown 时退出 1。经 SSH 运行时，HKCU 和个人启动文件夹是 SSH 账户的。 |
| `Watch-ConsoleWindows.ps1` | 在真实会话复验改动。为当前账户注册两个没有触发器的临时 Interactive 任务：经 `conhost --headless` 启动的监视器，和不加包装直接跑 pwsh 的对照任务。对照会在用户桌面闪一个约 2.5 秒的窗口，证明监视器看得见这个桌面。随后每隔 5 秒启动一个 `-StartTasks` 任务，最后由监视器经 shell 打开 `-LaunchPath`（如启动文件夹快捷方式）。新窗口归到它之前最近的触发：`quiet` 退出 0；`windows-seen`、`control-missed`、`trigger-failed`、`monitor-not-started`（该账户没有交互登录）退出 1。临时任务在写报告前删除，被中断的运行会留下 `zz-CodexConsoleWatch-*`。不记录窗口标题和命令行；`-EvidenceDirectory` 必须是新的 D 盘目录。 |
| `Get-WslState.ps1` | 只读输出单份 JSON，不执行 `wsl.exe`；Lxss 只保留具有非空 `DistributionName` 的条目，`InstallStatus` 不计发行版；包名匹配同时覆盖 `WindowsSubsystemForLinux`。功能状态优先 `Get-WindowsOptionalFeature`，未提权时回退 `Win32_OptionalFeature`；ForTest 夹具只替换对应采集器。 |
| `Watch-WslLaunch.ps1` | 按需、有限时长（5–3600 秒，默认 600）监视新 `wsl.exe`；写入新 D 盘 `EvidenceDirectory` 的 `events.jsonl` 与 `result.json`。记录目标命令行、创建时间、路径和父/祖父进程身份，不记录父/祖父命令行；`StopAfterFirst` 首次捕获后结束。任务监视可经 `DSH_WSL_WATCH_OWNER_TOKEN` 传入随机 token，证据只记录其 SHA-256。轮询可能漏掉两次采样间退出的短命进程；不启动、停止或修改被监视进程，不替代持久审计。 |
| `Protect-SensitiveLog.ps1` | 有界日志投影。剔除启动命令、已知凭据形态和疑似未知高熵秘密（24 位以上的长串）；提到 sha256/diff/height 的行只免于长串这一条，已知凭据形态照样剔除。丢弃行时返回 `read-with-omissions` 和退出 1，原始敏感行不回显。支持 Tail、行数和 UTF-8 字节预算。 |
| `Request-KryptexBenchmarkReset.py` | `plan` 默认只读校验 schema、设备、算法和矿工；`request` 需 `--approve`，单算法，每次另存一份带时间戳的备份并 integrity_check，再写入回读；`wait` 只接受 `--since-ms` 之后非零 hashrate 的真实读数，同时回报 accepted 计数，不用请求或估算值冒充完成。 |
| `Invoke-RemoteStep.ps1` | 经同目录的 `Invoke-OfficeRemote.ps1` 执行，以 helper 打印的那行运行摘要（与 `.run.json` 同内容，连接前拒绝时也打印）为业务门禁，不按文件名推算 `.run.json`；`result` 不是 `ok`、目标错配、helper/远端非零退出均失败，拒绝时摘要带 `reason`。业务失败即使进程退出 0 也不能通过，关键序列不得只依赖 shell 的 `&&`。`-WriteOperation` 要求 payload 首条语句断言目标标记，防止在本机误执行远端写操作；`-IncludeOutput` 把远端 stdout 至多 `-MaxOutputChars`（默认 65536）个字符放进摘要，超出时 `outputTruncated=true`。 |
| `Invoke-RemotePython.ps1` | 统一远端 Python stdin 执行，固定 `-X utf8` 并透传真实 Python 退出码；`-IncludeOutput` 按 `-MaxOutputChars`（默认 6000）回显 stdout。默认解释器为 `D:/Codex/tools/python314-official/python.exe`，现场不同可传 `-PythonExecutable`。生成的脚本首条语句断言目标并经 RemoteStep 的写门禁；源路径、解释器和参数以 Base64 编码，参数不拼进 shell。异常、非零退出与中文 stdout/stderr 的完整链路由 `Test-RemoteEncoding.ps1` 验证。 |
| `codex_diagnostics.py` | Python 3.11+ 标准库；`snapshot` 只读配置、已注册桌面父子进程、真实后端版本和哈希；`desktop-check` 验收配置加载与当前任务记录；`tool-roundtrip` 发出一次 ephemeral 模型轮次，必须完成附件→工具→随机回执。输出只含白名单字段，失败理由为固定代码，非零退出。 |
| `Invoke-UuTerminalCommand.ps1`、`Read-StudyUuMarker.ps1` | UU 新建唯一会话；每条命令以退出码 0 结束才写唯一 marker，核对通过才允许下一条。缺少 reader、marker 超时（含命令失败）、传输失败或清理不完整均闭锁；marker 只证明命令成功退出，不证明业务效果。reader 经同目录 RemoteStep 走 SSH 回读，路径、哈希和 runId 以 Base64 嵌入；SSH 不可用时回读失败、序列闭锁。 |
| `RemoteOperations.psm1` | 提供 UU marker 序列、路径规范化进程停止和链路预检的公共函数；停止前先核对全部同名进程的路径，任何一个不符都不停止。进程已消失可忽略停止竞态，仍存活则失败。 |
| `Get-SafeTreeDeleteCapability.ps1` | 只读解析同目录 safe-delete 的 Mode AST（shim 委托时读被委托的实现及现役共享 dispatcher）、CapabilityRoot 需求、结果格式与回收工具可用性。返回支持 mode 的 requiredParameters/confirms、batchGroupingKey=policyEntryId、listArgumentSeparator=:: 与 lowercase-hex-sha256 调用合同；不据此生成授权。支持 `Check` 时放行与否、CapabilityRoot 和拒绝原因原样取自 `Check`；没有 `Check` 的旧版只列出 root 包含目标的 policy 条目作为 `capabilityRootCandidates`，报 `check-unavailable`。不执行 Plan/Apply/Purge。 |
| `Test-StudyLink.ps1` | 一次 `--c 1 --timeout 3s` Tailscale ping 失败即停止，不进入 SSH；成功后才经同目录 RemoteStep 做严格身份预检，并区分 relay/direct。默认 ping 自习室在 Tailscale 登记的设备名 `zi-xi-shi`，`-TargetHost` 可改。 |
| `Get-GitHubReleaseAsset.ps1` | 用 `gh api --jq` 只投影指定 release 资产的名称、大小、digest 和 URL，避免整份 release JSON 进入上下文。 |

参数与返回结构以各脚本帮助/源码为准。活动日志不是原子快照；命名模式脱敏不保证发现任意秘密，仍要缩小敏感来源与字段范围。需要复核某条失败时保留来源、行窗口和退出码，不输出完整日志。

## Git 状态有界投影

共享工作树不要直接把完整 `git status` 回显进上下文。用同一投影器的 `GitStatus` 参数集，把完整 porcelain 写入 `D:/agents/run-evidence/`，只读回分支、计数和本次目标路径：

```powershell
& 'D:/Codex/.codex/scripts/Read-BoundedProjection.ps1' -GitRepository 'D:/agents/skills-manager/skills' -GitStatusEvidencePath 'D:/agents/run-evidence/<本次运行>/skills-status.txt' -GitStatusPath @('handoff', 'neat-freak') -MaxTotalBytes 6000
```

`matchedRows = emittedRows + omittedRows`；超出整份 UTF-8 字节预算的行只计入 `omittedRows`，需要时缩小 `GitStatusPath` 后重查。证据文件路径和 SHA-256 随结果返回。该快照不证明工作树干净，也不替代目标 diff 与测试。

## Codex 配置、工具往返与重启验收

```powershell
python -B D:/Codex/.codex/scripts/codex_diagnostics.py snapshot
python -B D:/Codex/.codex/scripts/codex_diagnostics.py tool-roundtrip --expected-config-sha256 <本次快照哈希>
python -B D:/Codex/.codex/scripts/codex_diagnostics.py desktop-check --previous-pid <重启前后端PID> --expected-config-sha256 <本次快照哈希>
```

`--codex-home` 默认取 `CODEX_HOME` 或当前用户的 `.codex`，`--profile` 可指定 profile。快照绑定当前 provider、模型、配置哈希和后端身份；端点移除认证、query、fragment，不读取认证文件、header 或附加页面正文。自定义供应商的 `login_mode` 默认 `unknown`；Magpie 可显式加 `--magpie-executable D:/Apps/Magpie/magpie.exe`，只读查询 `codex login` 并仅返回 `api` / `companion` / `chatgpt` 枚举，不从 `requires_openai_auth` 猜登录方式。桌面后端只接受当前注册的 `OpenAI.Codex` 应用在交互会话中的子进程，包含内置路径与官方本地缓存路径；没有唯一可核验后端时失败，不猜旧路径。

`tool-roundtrip` 使用快照中的真实程序、provider 和模型启动独立 app-server；不重写 live 配置，也不把旧供应商的临时覆盖带到新路由。只有轮次 completed、恰好一次有效工具调用（含 call ID）、附件参数正确、返回工具生成的随机回执、没有协议错误且前后配置哈希一致时退出 0。未调用工具、错参数、RPC 错误、提前 EOF、超时或配置漂移都退出 1。只创建 ephemeral 线程，诊断工具仅回传内存中的回执。进程启动和 thread/start 都使用临时覆盖关闭 shell、代码执行、多代理、apps、plugins、图像、artifact、hooks、网页搜索及当前配置中各 MCP 入口，不改变供应商或持久配置；其他执行 item 一经出现即失败。该命令会产生模型用量，不进入默认离线回归。

`desktop-check` 不重启、不停止任何桌面进程。它核对旧 PID 已更换、后端启动晚于配置写入、期望配置哈希一致，并只读查询当前后端启动后的 `inProgress` 记录；旧记录另计，不因数周前的陈旧行否定重启。无当前记录不证明恢复中的旧任务空闲，不能据此自动终止进程。未知活动状态和不可信路径保持失败；有明确重启授权时，仍先核对当前实际工作。

`accept --result <结果JSON>` 只判定已记录的业务观察，不等于新做了 live 验收。CLI 退出码与 `ok` 一致；错误对象或结果字段未满足条件不能因“打印成功”而通过。

离线检查为相邻的 `Test-CodexDiagnostics.py`，仓库 adapter `tests/Test-CodexDiagnostics.py` 登记在 host-safety 的 `diagnostics`，也由完整主机诊断入口运行；它使用本地协议 peer，不连接供应商，不操作真实桌面。远端执行优先用 `Invoke-RemotePython.ps1 -PythonScriptPath <本机 codex_diagnostics.py> -PythonArgument @('snapshot') -IncludeOutput`，无需把 Python 嵌进临时 PowerShell here-string。旧 run-evidence 中的一次性探针保留为历史证据，复测统一使用此受管入口。

## vcpkg 健康检查

`Get-VcpkgHealth.ps1` 默认从 PATH 解析 `uniget`，找不到时使用 `D:/UniGetUI/uniget.exe`；也可用 `-UniGetCliPath` 指定 CLI。它只读取 manager 和日志状态，不执行 reload、install、repair 或 bootstrap。stdout 只有一份 UTF-8 JSON，固定包含 `status/mode/manager/ready/executablePath/executableExists/bootstrap/packageSearch`。

- `-Mode Fast`（默认）读取 `manager list` 和 `log manager --manager vcpkg --verbose`。健康要求恰好一个 vcpkg manager、JSON Boolean `ready=true`、非空 `executablePath` 独立通过 `Test-Path -PathType Leaf`，以及最近一条命令行明确调用 `bootstrap-vcpkg.bat` 的 RefreshIndexes 记录含 `Return code: SUCCESS (0)`。没有该记录时是 `bootstrap_not_recorded`，不是健康。
- `-Mode Live` 只在上述 Fast 条件全部通过后执行 `package search --manager vcpkg --query zlib --max-results 3`，要求 `status=success` 且至少一项结果，并再次检查 exe。Fast 失败时 `packageSearch.status=not_run`，不得执行查询；任一后续成功都不能覆盖前面的失败。
- 退出 0：`healthy`。退出 1：明确不健康，包括 `manager_missing`、`ready_false`、`executable_path_missing`、`executable_missing`、`bootstrap_failed`、`package_search_failed`、`package_search_empty`、`executable_missing_after_search`。退出 3：CLI 缺失、IPC/JSON 不可判定或必要证据缺失，包括 `cli_missing`、`manager_duplicate`、`manager_ready_invalid`、`manager_list_invalid`、`manager_log_invalid`、`bootstrap_not_recorded`、`package_search_invalid`。
- 三个 `*JsonPathForTest` 参数只用于合成夹具；Fast 不读取 package 夹具。负面 Live 用例只删除测试目录内的假 exe，不得删除或改名真实 vcpkg exe。

仓库套件和部署后验收：

```powershell
& ./managed/host-diagnostics/Test-VcpkgHealth.ps1
& ./scripts/Deploy-HostDiagnostics.ps1 -Mode Check
& 'D:/Codex/.codex/scripts/Get-VcpkgHealth.ps1' -Mode Fast
& 'D:/Codex/.codex/scripts/Get-VcpkgHealth.ps1' -Mode Live
```

## 按章节读取

已知标题时直接选 ATX 章节，保留原文件行号、子标题内容、脱敏与总预算：

```powershell
& 'D:/Codex/.codex/scripts/Read-BoundedProjection.ps1' -LiteralPath 'D:/agents/projects/统一环境/docs/env-governance/host-diagnostics.md' -MarkdownSection '工具合同' -MaxRows 80 -MaxValueChars 1000
```

spec 对应 `{"path":"D:/path/reference.md","format":"markdown","section":"标题"}`。标题精确区分大小写，忽略代码围栏中的伪标题；只支持 ATX，不解释 Setext。缺失或重复标题分别返回 `section-not-found`、`section-ambiguous` 和退出 1，来源内容不输出。命中总预算或单行裁剪时按返回的行号续读，不把省略部分当作已读。

## 会话文档读取

同一会话重复读取静态 `.md` / `.txt` 时使用 `Read-SessionDocument.ps1`，`StatePath` 指向该会话独占的 D 盘 evidence 文件。活动日志继续使用 `Read-BoundedProjection.ps1`。

```powershell
& 'D:/Codex/.codex/scripts/Read-SessionDocument.ps1' -LiteralPath 'D:/Codex/.codex/docs/agent-guidance/git-publishing-policy.md' -StatePath '<本会话 evidence>/document-reads.json' -MarkdownSection '目标预检' -MaxRows 40 -MaxValueChars 1000
```

状态只保存路径、内容指纹、读取选择和时间，不保存正文，不属于用户长期记忆。只对同一文档版本、同一读取选择去重；内容变动或范围变化重新投影。`unchanged` 只表示本会话已返回过这一范围，不代表全文已读；压缩后缺少该段内容时显式用 `-Refresh`。读取失败、缺失章节和预算不足不登记为完成。默认 6000 字节预算包含外层元数据。

## GitHub 目标预检

首次 GitHub 外部写入前回查目标，显式传预期所有者和默认分支；公开/私有口径来自 API 的 `visibility` 字段。

```powershell
& 'D:/Codex/.codex/scripts/Get-GitHubPublicationTarget.ps1' -Repository 'Baker4real/kimi-switch-private' -ExpectedOwner 'Baker4real' -ExpectedBranch 'main' -ExpectedVisibility public
```

没有已确认的可见性预期时省略 `ExpectedVisibility`，返回 `observed`、`ready=false`，退出 0 仅证明成功读取。预期齐全且全部一致才为 `ready`；错配退出 2，API 或响应无效退出 1。`github_api_failed` 时 `reasons` 是固定词表里的失败类别加 gh 退出码（如 `["network_eof","gh_exit_1"]`、`["http_404","gh_exit_1"]`），不复述 gh 原文；`network_*` 多为偶发，重跑一次再判断。预检不替代提交、推送或外部通信授权，错配交回现有发布流程处理。测试通过 CLI 的 `GhCommand` seam 注入合成响应，另用真实 API 做只读回读。

## 截图选择与坐标校验

在已有电脑操作授权和工具文档允许的前提下，从最新窗口状态提取截图元数据，再在 Node 中导入部署后的 `screenshot-geometry.mjs`：

```javascript
const { selectScreenshotForClick } = await import('file:///D:/Codex/.codex/scripts/screenshot-geometry.mjs');
const click = selectScreenshotForClick({ screenshots, windowBounds, point });
// click 为 { screenshotId, x, y }，交给当前电脑工具支持的点击入口。
```

`windowBounds={x,y,width,height}`、`point={x,y}`、截图 `originX/originY/width/height` 必须来自同一坐标系、同一像素单位；函数不猜测 DPI 或屏幕原点。只有一张截图完整覆盖窗口时才返回相对它左上角的坐标；14×14 辅助图不会被当成完整窗口。截图身份、尺寸或窗口范围不明确时刷新工具状态；观察焦点和最小化行为时仍保持只读，不为了截图而激活窗口。回归入口 `Test-ScreenshotGeometry.ps1` 只处理合成元数据，不操作真实桌面。

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

执行异常诊断在原有位置字段后追加 `innerType`、`hresult`、`nativeErrorCode`：沿异常链最多读取 16 层，报告最内层异常类型与有符号数值码；无内层异常或非 Win32 错误的对应字段为 `-`。异常消息、Data、文件路径和源码仍不输出。回归入口为 `Test-CheckedPowerShell.ps1`，覆盖文件系统异常及带敏感占位消息的嵌套 Win32 异常。

## 部署

```powershell
& ./scripts/Deploy-HostDiagnostics.ps1
& ./scripts/Deploy-HostDiagnostics.ps1 -Mode Apply
& ./scripts/Deploy-HostDiagnostics.ps1 -Mode Check
```

Check 只读比较明确 allowlist 内的源码与部署文件：一致退出 0，差异退出 1，不创建证据或缓存。`SourceRoot`、`TargetRoot` 可指定独立的 D 盘测试目录；路径重叠、reparse point 或缺少源码时拒绝部署。`-Only <文件名,…>` 把 Check/Apply 限定到 allowlist 里的这几个文件，名单外的名字直接拒绝；`-Summary` 只输出 `status`、`changedFiles`、`writtenFiles`、`evidenceDirectory` 和失败时的 `error`，不列逐文件明细。

Apply 只更新这份闭包，先完成全部备份和源文件暂存，再逐文件原子替换并回读哈希；这是逐文件替换，不保证整包事务回滚。失败返回非零，保留 `EvidenceRoot` 下的备份和 manifest，按其中的已写入文件及哈希核对恢复范围。运行中的 NVIDIA/Explorer、代理配置、hook 和计划任务不由部署器修改。仓库发布与宿主部署分别回读，Git 提交或工具存在都不等于已经部署。

## 验收

仓库内的定向命令接入模块 manifest 和现有 Windows CI fixture：

```powershell
node ./scripts/Run-PowerShellTests.cjs --module host-safety --profile diagnostics
node ./scripts/Run-ManifestTests.cjs --module host-safety --profile diagnostics --kind python
node ./tests/Test-ModuleBoundaries.cjs
git diff --check
```

`--profile diagnostics` 除完整入口 `tests/Test-HostDiagnostics.ps1` 外，还跑 `tests/` 下远端与探测入口的夹具测试（`Test-RemoteStep`、`Test-RemoteEncoding`、`Test-UuTerminalCommand`、`Test-UuMarkerReader`、`Test-StudyLink`、`Test-RemoteProcesses`、`Test-SafeTreeDeleteCapability`、`Test-GitHubReleaseAsset`）：入口复制进夹具目录，同目录放下一层的替身，不连接远端。线上 `Invoke-OfficeRemote.ps1` 的首条断言校验与单行摘要合同由 host-live 的 `tests/Test-OfficeRemoteContract.ps1` 只用 `-DryRun` 和连接前拒绝核对。

仓库 fixture 运行合成日志、语法/JSON 合同、NVIDIA 状态、浏览器 CLI/HTTP 合成报告、带所有权握手的隔离恢复用例、D 盘 fixture 上的回收入口拒绝/计划用例，以及控制台入口审计的合成 PE 与快捷方式夹具，显式跳过真实桌面快照和真实回收站移入（`-SkipLiveRecycle`）。审计 suite 还会注册一个没有触发器、跑完即删的临时 Interactive 任务，确认真实收集路径能读到它。`Watch-ConsoleWindows.ps1` 每次运行都会闪出对照窗口，不进自动回归，只做语法检查；它的每次结果由对照组自证。WSL 状态测试使用合成包、Lxss 与可选功能 CIM 夹具，避免把宿主功能清单差异当成脚本缺陷；启动监视测试用仅访问环回地址的短时 `ping.exe` 和空窗口验证捕获与未捕获路径，不调用真实 `wsl.exe`。宿主完整入口会把两个 D 盘 fixture 树移入 D 盘回收站：回收第二个时，第一个的 `$I` 记录被测试独占打开，回收站里另有测试写入的一条日期更晚、指向别的路径的诱饵 `$I` 记录。随后像资源管理器还原那样移回两个树，`$I` 记录（含诱饵）归入本轮 evidence，不永久删除任何内容。浏览器 suite 不启动或附着真实浏览器，不能代替真实页面验收。CI 为 host-safety 配置 Python；本机测试从 PATH 解析 `python.exe`。部署后使用完整入口检查实际宿主只读面：

```powershell
& 'D:/Codex/.codex/scripts/Test-HostDiagnostics.ps1'
& 'D:/Codex/.codex/scripts/Get-ConsoleLaunchAudit.ps1'
& 'D:/Codex/.codex/scripts/Get-NvidiaDownloadStatus.ps1'
& 'D:/Codex/.codex/scripts/Get-TaskbarSnapshot.ps1'
& 'D:/Codex/.codex/scripts/Restart-ExplorerShell.ps1' -Mode Plan
```

完整回归也不停止真实 Explorer。故障修复的 Apply 属于单独的用户授权动作；不得为重复验收重启健康桌面。若计划过期、身份漂移或其他恢复正在执行，重新采集 Plan；启动失败/readiness 超时按结果中的 Reason、LaunchAttempts 与 ProcessState 处理，不对漂移目标继续操作。

设备事件、活动进程、下载版本、校验值、账户与一次性测试输出属于运行证据，写入 D 盘 evidence，不提交到本目录。全局 Agent 规则由既有共享源同步器维护，不将生成的 AGENTS.md 当成此工具源码。
