# 自习室设备环境说明

## 设备身份

- 设备标识：`zi-xi-shi`
- Windows 主机名：`Baker`
- 统一环境仓库：`D:\Codex\projects\统一环境`
- Codex 受管根：`D:\Codex\.codex`

网络地址、SSH 用户、密钥路径、登录态和凭据属于调用端本地事实，不写入仓库；连接前必须从当前设备的本地配置重新确认。

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

本页记录的验证日期为 2026-07-14；数量、哈希和工具版本属于易变状态，后续操作必须实时复核，不能把本页当作当前运行结果。
