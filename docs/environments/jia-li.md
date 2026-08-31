---
type: reference
title: 家里设备环境说明
tags: [设备, 家里, Windows]
intent: 记录家里设备的受控环境事实与差异
---

# 家里设备环境说明

## 设备身份

- 设备标识：`jia-li`
- Windows 主机名：`Baker`
- 统一环境仓库：`D:\agents\projects\统一环境`
- Codex 受管根：`D:\Codex\.codex`
- 2026-08-26 核验：按 Tailscale 登记复核，本机登记名为 `jia-li`（家里）；本文此前误标为
  `zi-xi-shi`（自习室），真正的 `zi-xi-shi` 是另一台独立 Windows 设备，其环境不由本文档覆盖。
- 主机名碰撞注意：`zi-xi-shi`（自习室）的 Windows 主机名也是 `Baker`（2026-08-26 审计）；
  hostname 不能作为设备区分依据，跨机操作以 Tailscale 登记名与 ssh-mesh 方向双锚定。

网络地址、SSH 用户、密钥路径、登录态和凭据属于调用端本地事实，不写入仓库；连接前必须从当前设备的本地配置重新确认。

## UU 远程（2026-08-31 现场）

- 安装根：`D:\Program Files\Netease\GameViewer`。2026-08-31 现场核验：`bin\GameViewer.exe` 与 `bin\Upgrade.exe` 均为 `4.38.3.9325`，`GameViewerService` 为 Running，主进程已拉起。
- UU 远程设备名：`家里`；设备 ID：`aeawutisfya4t4ev`。
- 正式命令与文件传输走 OpenSSH/SCP over Tailscale；UU 只用于 bootstrap、诊断和受限救援。
- 本机 `bak\` 下没有 `Upgrade.exe` / `aria2c.exe`（2026-08-31）。应用内更新从 `bin` 启动下载器。自习室的 `bak` 回退约束见 `docs/environments/zi-xi-shi.md`，不要套到本机。

## Windows Terminal、PowerShell 与 WSL

- 2026-07-20 实测 Windows Terminal `1.24.11911.0` 已设为系统默认终端；其
  `defaultProfile` 为 `{5fb123f1-af88-5b5c-8953-d14a8def1978}`，对应
  `PowerShell 7` / `Windows.Terminal.PowershellCore`。系统委派值为
  `DelegationTerminal={E12CFF52-A866-4C77-9A90-F570A7AA2C6B}`、
  `DelegationConsole={2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}`。
- PowerShell Store 包版本为 `7.6.5.0`，User PATH 已把
  `D:\Codex\tools\PowerShell\7.6.5` 放在首位。2026-08-18 新进程复核：
  `Get-Command pwsh.exe` 解析到该目录的 `pwsh.exe`，版本为 `7.6.5`；当前 Codex
  任务仍由既有 7.6.4 进程承载，需重启 Codex 后才会采用新 runtime。
- `D:\Codex\.codex\config.toml` 已设
  `integratedTerminalShell = "powershell"`。这表示 Codex 的集成终端使用 PowerShell；
  Codex 内部 PTY 和后台命令仍在应用内或隐藏运行，不应为每条命令新开外部 Windows
  Terminal 窗口。
- 2026-07-23 已在本机复现并修复 lifecycle hook/test 的 PowerShell 闪窗；当前 4 个
  live wrapper 已采用受管 hidden-console launcher。实现、标准流与最终子进程无窗口验收
  合同见 `docs/specs/2026-07-11-host-hook-reconciliation-design.md`，本文不复制项目机制。
  实际 Codex Desktop 重启后的独立 180 秒观察窗内，新增可见 cmd、PowerShell、pwsh、
  conhost 或 Windows Terminal 窗口为 `0`。
- 2026-08-16 本机 Cursor 用户级 hooks 现役文件为
  `%USERPROFILE%\.cursor\hooks.json`，源在
  `D:\agents\projects\统一环境\managed\cursor-hooks\`。事件映射以
  `D:\Codex\.codex\docs\agent-guidance\host-runbook.md` 的 Cursor Host Hooks
  为准；不要把 Cursor 注册写进 Codex `hooks.json` 或 Cursor `settings.json`。
- 本机 Grok 用户级 hooks 现役文件为
  `%USERPROFILE%\.grok\hooks\host-lifecycle.json`，源在
  `D:\agents\projects\统一环境\managed\grok-hooks\`。事件映射以 host-runbook
  的 Grok Host Hooks 为准；不要把 Grok 注册写进 Codex `hooks.json`。
- 2026-08-26 本机 live 已从 Grok `SessionStart` 和 Cursor `workspaceOpen`
  拿掉 `serena-dashboard`；Grok live 也没有 `codex-state-preflight`。
  `managed/grok-hooks/host-lifecycle.json` 与 live 一致，命令路径为
  `D:\agents\projects\统一环境`。权威是 live 文件与 host-runbook。
- 同日 `wsl.exe --list --verbose` 返回 `Ubuntu` 与 `docker-desktop`，两者均为
  WSL2；这已经推翻旧 README 中“WSL 未安装、未启用、未初始化”的历史判断。运行时
  `Running` / `Stopped` 状态属于易变事实，使用前现场复核；D-Radar 的 WSL/Docker
  配置与验收步骤以 `D:\Codex\.codex\docs\agent-guidance\host-runbook.md` 为准。

## .NET 默认入口

- 2026-07-23 现场复核：裸 `dotnet` 只解析到
  `C:\Program Files\dotnet\dotnet.exe`，SDK 为 `6.0.428`。`DOTNET_ROOT` 虽指向
  `D:\Codex\tools\dotnet`，该根目前只有 .NET host/runtime `10.0.9`，残留的
  `sdk\10.0.301` 仅含 `Roslyn` 子树，`dotnet --info` 明确返回 `No SDKs were found`。
  这是入口与载荷分裂的待修复状态，不得再表述为 D 盘 SDK 已采用。
- 本机没有可复用的官方 `10.0.301` 安装包或缓存。恢复必须按 D 盘迁移政策另行取得
  对 `.NET 10.0.301` 的具体授权：从微软官方源安装到全新 staging，校验版本与哈希后
  可回滚切换，并单独处理 PATH；不得在残缺 live 根上原地覆盖，也不得删除 C 盘后备入口。

## 显示输出与窗口恢复

- 同一台 Odyssey G7 同时连接 NVIDIA 的 DisplayPort 与 HDMI。期望拓扑是任一时刻只启用一条物理桌面路径：DP 为主路径（已验证模式 `3840 × 2160 @ 165 Hz`），HDMI 保持已连接但不作为第二个扩展屏；需要切换时把 HDMI 当作人工备选路径，不把它视为已验证的自动故障接管。
- `DISPLAY1`、`DISPLAY2` 等编号会随拓扑重排，不能作为端口的持久身份。诊断时应使用 Windows CCD 的 target device path 与 `outputTechnology` 区分 DP/HDMI。微信或 CC Switch 点击后无主界面时，先检查顶层窗口的 monitor、`WINDOWPLACEMENT`、DWM cloaked 状态和恢复矩形，把窗口恢复到当前活动工作区后再调整显示拓扑。
- 更改拓扑前必须保存完整 CCD path/mode 基线和精确回滚数据；先临时应用并确认画面稳定，再持久化。若屏幕枚举只出现 `WinDisc` / GameViewer 虚拟显示，或 `GetDisplayConfigBufferSizes` 返回零路径，说明虚拟显示层正在干扰物理拓扑查询，此时不得写入持久显示配置。
- 2026-07-18 已完成一次 DP 单路径验收：活动路径为 DP、模式为 `3840 × 2160 @ 165 Hz`，HDMI target 保留但不活动，微信和 CC Switch 均已移回活动屏幕。当天稍后的只读复核受到 `WinDisc` 虚拟显示层影响，因此后续操作仍须重新查询 live CCD，不能把本条历史验收当作当前状态。

## Aura 风扇灯自动关闭

- 登录后通过 `C:\Users\WINDOWS\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\aura-lights-off.lnk` 运行；该快捷方式只承载 Startup 兼容配置，目标为 `C:\Windows\System32\wscript.exe`。
- 实际载荷位于 D 盘：`D:\Codex\.codex\scripts\Start-AuraLightsOffHidden.vbs`；它以隐藏窗口运行 `D:\hermes-data\hermes-agent\venv-new\Scripts\python.exe D:\hermes-data\scripts\turn_off_aura_hid_startup.py`。这个解释器含有必需的 `hidapi`。
- 此自动化只关闭 ASUS Aura / 风扇 RGB，不改变风扇转速或散热策略；不要在常规 Startup/Hermes 清理中删除或改写快捷方式与 D 盘载荷。
- 2026-07-15 验证：启动器退出码为 `0`、未新建 Windows Terminal 进程，且用户已目视确认灯光保持熄灭。若修复或迁移，仍须同时核对启动器退出码与实际灯光状态。

## Codex provider 代理（后台）

- 此代理是 Codex 主机服务，不属于 Hermes 项目。脚本固定为 `D:\Codex\.codex\scripts\codex-provider-proxy.py`，日志固定为 `D:\Codex\.codex\logs\codex-provider-proxy.log`，运行时使用官方 `D:\Codex\tools\python314-official\pythonw.exe`。
- 入口源码位于 `D:\Codex\tools\codex-launcher\`，现役入口为 `D:\Codex\tools\bin\codex.exe`。修改脚本或 launcher 后必须重新发布并核验现役入口，不能改动官方 Store/AppX Codex 二进制。
- launcher 只在 stdin、stdout、stderr 都连接真实终端，且 `TERM` 缺失或为 `dumb` 时，为官方 Codex 子进程设置 `TERM=xterm-256color`；重定向、GUI 和后台入口必须保留原值。修改该契约后运行 `tests\Test-CodexLauncherTerminalEnvironment.ps1`，并在不显式覆盖 `TERM` 的真实 PTY 中复验 `codex doctor --json`。
- 服务子进程必须以 `pythonw.exe` 和 `CREATE_NO_WINDOW` 后台启动；验收时检查 `/health`、`/v1/models`、窗口句柄为零且没有 `conhost.exe` 后代，不能通过关闭用户终端来掩盖问题。
- 不得把 proxy 或其日志放回 `D:\hermes-data`。`D:\hermes-data\.npm-global` 仅用于排除旧 npm shim，与该代理无关，不能作为迁移副作用修改。

## 共享工具判定根

- 环境盘点的 canonical shared roots 为 `D:\Codex\tools`、`D:\Codex\envs` 和 `D:\uv`。
- `D:\hermes-data\.local` 与 `D:\hermes-data\.npm-global` 已从共享工具根分类中退役；仍存在的 Hermes 专属内容按 Hermes authority 保留，旧报告或历史测试中的引用不能作为恢复共享入口的依据。

## CodeGraph 与 Serena

- CodeGraph `1.5.0` 已安装在 `D:\Codex\tools\codegraph\releases\1.5.0`，受管
  `current\bin\codegraph.cmd` 已指向该版本；旧 `1.4.1` release 保留为回滚点。独立
  MCP 的 `initialize`、`tools/list` 与真实查询均已通过。
- 2026-07-23 重启后复核：所有现役受管 CodeGraph MCP 进程均运行 `1.5.0`，
  不再有 `1.4.1` 旧会话等待自然退出；受管 wrapper 的真实 MCP
  `initialize`、`tools/list` 与查询再次通过。
- Serena 现役 CLI 为 `1.7.0`（`D:\Codex\tools\uv\bin\serena.exe`，2026-08-26 核验
  `--version`）。2026-07-23 的 MCP 验收针对当时的 `1.6.1`，是历史快照，不能当作当前版本。
  上游自 `1.6.1` 起已直接要求 `anthropic==0.117.0`，不再需要本机针对 `1.6.0` 的依赖
  metadata override。

## Codex 设备连接

- 已于 2026-07-16 在本机 Codex Desktop 的“连接”页确认：当前只显示“控制此电脑”和“SSH”。“控制此电脑”中的“添加”仅配对可远程控制本机的设备，不赋予本机控制其他电脑的能力。
- 若需要在另一台开发机上运行 Codex 任务，使用 SSH 连接。当前界面未提供“控制其他设备”的出站配对入口；该界面属于客户端和账号功能发布状态，升级、重新登录或改用其他设备前必须重新确认，不能当作跨设备能力保证。

## Skill 安装入口

- 活动 skill 根：`D:\Codex\.codex\skills`
- 受守卫安装入口：`D:\Codex\.codex\scripts\install-skill-guarded.cmd`
- 项目部署入口：`scripts\Deploy-SkillInstallGuarded.ps1`
- 本机 catalog：`D:\Codex\.codex\skill-catalog\catalog.json`
- 运行证据：`D:\agents\run-evidence\skill-install-guarded\`（2026-08-26 起从旧根 `D:\Codex\.codex\run-evidence\` 迁移至此）

不得把安装后的回写职责放入被安装的 skill，也不得直接修改 bundled `.system` 安装器。新安装或更新必须经过 decision manifest、`writing-for-agents` 证据、SOURCE/ledger、严格资源闭包和 catalog 后置校验；任一门槛失败都应回滚。

## Codex 主机 Hook 当前边界（2026-07-24）

- 2026-07-23 早些时候的 live Repair、SessionStart wrapper 与重启后监视器曾全部通过；同日稍后的只读 Check 曾返回 `ok=false`、`driftCount=1`，漂移类别为 `config`。这些都是历史验证快照，不代表当前配置持续保持一致。
- 2026-07-24 22:07 的当前验收先发现 `config` 单项 drift，随后通过 reconciler Repair 恢复；首轮 Repair 为 `ok=true`、`changed=true`、`driftCount=0`，证据位于 `D:\Codex\.codex\run-evidence\host-hook-remediation\20260724T140626.793Z-c015fdca`。第二轮 Repair 为 `changed=false`，最终只读 Check 为 `ok=true`、`changed=false`、`driftCount=0`，8 项检查全部通过。后续操作前仍须重新运行 Check，不能把本条快照当作永久状态。
- 只有 reconciler 可以修复受管 Serena section 与 hook registration；不得依据历史 evidence 或本文手工重建它们，也不得手工写入 `approval_policy` 或 `sandbox_mode`。若 Repair 结果的 `registrationProjection` 出现 `restartRequired=true`，完整退出并重启 Codex 应用后再做运行时验收。

## 每日 Codex 生态组件更新（2026-08-26）

- 本机日更已改由 ZCode Desktop 自动化 `每日更新` 执行，不再由 Cursor 计划任务或 Codex Desktop 自动化触发。
- Codex 侧 `D:\Codex\.codex\automations\codex\automation.toml` 必须保持 `PAUSED`。Windows 任务 `Cursor Daily Codex Ecosystem Update` 必须保持 Disabled。
- 调度、证据入口和授权边界以 `D:\Codex\.codex\docs\agent-guidance\host-runbook.md` 的「Daily Codex Ecosystem Update」为准。
- 结果固定入口：`D:\agents\run-evidence\daily-codex-ecosystem-update\LATEST.md`。
- PATH 上的 `agent` 是 Grok CLI，禁止当执行器调用。

## GitHub CLI

- 官方二进制：`D:\Codex\tools\gh\bin\gh.exe`
- Codex 原生入口：`D:\Codex\tools\bin\gh.exe`
- 配置目录：`D:\Codex\.config\gh`
- 检查与修复入口：`D:\Codex\.codex\hooks\codex-github-cli-guard.ps1`

守卫默认只读；只有显式 `-Repair` 才允许修改入口、环境或 health 状态。完整验收使用 `-Json -CheckAuth -Strict`，预期 `ok:true`、`authProbe.success:true`、`restartRequired:false`。GitHub 登录和认证验收必须在设备的交互终端执行；SSH 网络登录会话可能无法读取 Windows Credential Manager 中的 DPAPI 凭据，不能复制 token 或配置文件绕过该边界。

## Android 调试工具（当前无可用入口）

- 当前没有可解析的 `adb` 命令，且已知 D 盘 Platform-Tools 与 `adb.cmd` 历史入口均不存在；不得使用这些失效路径。本页不据此推断其他位置是否存在 SDK 组件。
- 若未来需要手机调试，先取得单独授权安装并记录真实 D 盘入口与版本；安装前不执行任何 `adb` 操作。
- 手机型号、序列号、当前授权状态、已安装应用版本和密钥位置属于本地易变或敏感事实，不写入仓库，也不能从本页推断当前可访问范围。

## 跨设备同步与验收

1. 先同步本仓库的已提交默认分支，不复制调用端的 dirty worktree。
2. 从仓库源部署 wrapper，并确认部署文件与项目源文件哈希一致。
3. 运行严格资源闭包和 catalog dry-run；只有两者都通过，才把设备视为已同步。
4. 设备上的日志、临时 staging 和验证快照留在该设备的 D 盘 evidence 路径，不提交到仓库。

除另有注明外，本页审计日期为 2026-07-18；数量、哈希和工具版本属于易变状态，后续操作必须实时复核，不能把本页当作当前运行结果。
