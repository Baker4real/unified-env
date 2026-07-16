# 自习室设备环境说明

## 设备身份

- 设备标识：`zi-xi-shi`
- Windows 主机名：`Baker`
- 统一环境仓库：`D:\Codex\projects\统一环境`
- Codex 受管根：`D:\Codex\.codex`

网络地址、SSH 用户、密钥路径、登录态和凭据属于调用端本地事实，不写入仓库；连接前必须从当前设备的本地配置重新确认。

## Aura 风扇灯自动关闭

- 登录后通过 `C:\Users\WINDOWS\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\aura-lights-off.lnk` 运行；该快捷方式只承载 Startup 兼容配置，目标为 `C:\Windows\System32\wscript.exe`。
- 实际载荷位于 D 盘：`D:\Codex\.codex\scripts\Start-AuraLightsOffHidden.vbs`；它以隐藏窗口运行 `D:\hermes-data\hermes-agent\venv-new\Scripts\python.exe D:\hermes-data\scripts\turn_off_aura_hid_startup.py`。这个解释器含有必需的 `hidapi`。
- 此自动化只关闭 ASUS Aura / 风扇 RGB，不改变风扇转速或散热策略；不要在常规 Startup/Hermes 清理中删除或改写快捷方式与 D 盘载荷。
- 2026-07-15 验证：启动器退出码为 `0`、未新建 Windows Terminal 进程，且用户已目视确认灯光保持熄灭。若修复或迁移，仍须同时核对启动器退出码与实际灯光状态。

## Codex provider 代理（后台）

- 此代理是 Codex 主机服务，不属于 Hermes 项目。脚本固定为 `D:\Codex\.codex\scripts\codex-provider-proxy.py`，日志固定为 `D:\Codex\.codex\logs\codex-provider-proxy.log`，运行时使用官方 `D:\Codex\tools\python314-official\pythonw.exe`。
- 入口源码位于 `D:\Codex\tools\codex-launcher\`，现役入口为 `D:\Codex\tools\bin\codex.exe`。修改脚本或 launcher 后必须重新发布并核验现役入口，不能改动官方 Store/AppX Codex 二进制。
- 服务子进程必须以 `pythonw.exe` 和 `CREATE_NO_WINDOW` 后台启动；验收时检查 `/health`、`/v1/models`、窗口句柄为零且没有 `conhost.exe` 后代，不能通过关闭用户终端来掩盖问题。
- 不得把 proxy 或其日志放回 `D:\hermes-data`。`D:\hermes-data\.npm-global` 仅用于排除旧 npm shim，与该代理无关，不能作为迁移副作用修改。

## Codex 设备连接

- 已于 2026-07-16 在本机 Codex Desktop 的“连接”页确认：当前只显示“控制此电脑”和“SSH”。“控制此电脑”中的“添加”仅配对可远程控制本机的设备，不赋予本机控制其他电脑的能力。
- 若需要在另一台开发机上运行 Codex 任务，使用 SSH 连接。当前界面未提供“控制其他设备”的出站配对入口；该界面属于客户端和账号功能发布状态，升级、重新登录或改用其他设备前必须重新确认，不能当作跨设备能力保证。

## Skill 安装入口

- 活动 skill 根：`D:\Codex\.codex\skills`
- 受守卫安装入口：`D:\Codex\.codex\scripts\install-skill-guarded.cmd`
- 项目部署入口：`scripts\Deploy-SkillInstallGuarded.ps1`
- 本机 catalog：`D:\Codex\.codex\skill-catalog\catalog.json`
- 运行证据：`D:\Codex\.codex\run-evidence\skill-install-guarded\`

不得把安装后的回写职责放入被安装的 skill，也不得直接修改 bundled `.system` 安装器。新安装或更新必须经过 decision manifest、`writing-great-skills` 证据、SOURCE/ledger、严格资源闭包和 catalog 后置校验；任一门槛失败都应回滚。

## GitHub CLI

- 官方二进制：`D:\Codex\tools\gh\bin\gh.exe`
- Codex 原生入口：`D:\Codex\tools\bin\gh.exe`
- 配置目录：`D:\Codex\.config\gh`
- 检查与修复入口：`D:\Codex\.codex\hooks\codex-github-cli-guard.ps1`

守卫默认只读；只有显式 `-Repair` 才允许修改入口、环境或 health 状态。完整验收使用 `-Json -CheckAuth -Strict`，预期 `ok:true`、`authProbe.success:true`、`restartRequired:false`。GitHub 登录和认证验收必须在设备的交互终端执行；SSH 网络登录会话可能无法读取 Windows Credential Manager 中的 DPAPI 凭据，不能复制 token 或配置文件绕过该边界。

## Android 调试工具

- 官方 Android SDK Platform-Tools：`D:\Codex\tools\android-platform-tools\platform-tools`，当前稳定版 `37.0.0`。
- 本机命令入口：`D:\Codex\tools\bin\adb.cmd`；包装入口把临时文件和日志限制在 D 盘。
- 每次操作手机前必须实时运行 `adb devices -l`；只有状态为 `device` 才表示当前会话已授权，`unauthorized`、`offline` 或空列表都必须停止。
- 手机型号、序列号、当前授权状态、已安装应用版本和密钥位置属于本地易变或敏感事实，不写入仓库，也不能从本页推断当前可访问范围。

## 跨设备同步与验收

1. 先同步本仓库的已提交默认分支，不复制调用端的 dirty worktree。
2. 从仓库源部署 wrapper，并确认部署文件与项目源文件哈希一致。
3. 运行严格资源闭包和 catalog dry-run；只有两者都通过，才把设备视为已同步。
4. 设备上的日志、临时 staging 和验证快照留在该设备的 D 盘 evidence 路径，不提交到仓库。

本页记录的验证日期为 2026-07-16；数量、哈希和工具版本属于易变状态，后续操作必须实时复核，不能把本页当作当前运行结果。
