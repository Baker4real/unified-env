---
type: reference
title: 自习室设备环境说明
tags: [设备, 自习室, Windows]
intent: 记录自习室设备的受控环境事实与差异
---

# 自习室设备环境说明

## 设备身份

- 设备标识：`zi-xi-shi`（自习室）
- Windows 主机名：`Baker`——与 `jia-li`（家里）主机名**完全相同**（2026-08-26 审计）。
  hostname 不能作为两机区分依据；设备身份以 Tailscale 登记名为准，跨机操作前按
  `D:\Codex\.codex\docs\agent-guidance\ssh-mesh.md` 的连接方向与登记名双锚定。
- UU 远程设备名：`自习室`；设备 ID：`aeawutfrjia4s5i6`（2026-08-31 经正式 SSH 与 UU 客户端设备列表交叉核验）。
- 2026-08-26 身份核验：按 Tailscale 登记，`zi-xi-shi` 是独立 Windows 设备。本文件
  此前误装了 `jia-li` 的环境事实，已迁至 `docs/environments/jia-li.md`；本页只保留
  已现场核验的事实。
- 网络地址、SSH 用户、密钥路径不写入本仓库；连接前从调用端 `ssh-mesh.md` 与本地 identity 重新确认。

## 已核验环境事实（2026-08-26 只读 SSH 审计）

- Windows 11 家庭中文版 10.0.26200；PowerShell 7.6.3 位于
  `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`；**该机 PowerShell 5.x 被策略封锁**，
  一切自动化必须走该显式路径，禁止任何 `powershell.exe` 隐式调用。2026-09-08 再核：
  `D:\Codex\tools\PowerShell\` 下 `7.6.3`、`7.6.4`、`7.6.5` 均已存在（2026-09-01 记录的
  「7.6.5 不存在」已过期），且 HKCU Run 的 `Codex Provider Stability Guard` 正指向 7.6.5；
  自动化仍以 7.6.3 为既定显式路径，改用 7.6.5 前先现场复核。
- 统一环境仓库位于旧布局 `D:\Codex\projects\统一环境`（审计时工作区干净，HEAD
  落后 jia-li main）；`D:\agents` 树在该机不存在。仓库布局迁移属另立任务。
- `D:\Codex\.codex\docs\agent-guidance\` 已同步在机（14 条目）。
- run-evidence 迁移（旧根 101 个顶层条目）的执行契约见
  `docs/plans/2026-08-26-run-evidence-migration-plan-zi-xi-shi-ban-gong-shi.md` §4。

## Microsoft Teams 与工作账户（2026-09-01 现场 SSH，2026-09-08 彻底移除）

- 新版 Teams（MSTeams MSIX）已从当前用户卸载，并移除预配包；HKCU Run 的 Teams 项已删除，AppX 启动任务随后不存在。复查：无 Teams 进程、无 Appx 包、无开始菜单项。
- 2026-09-08 再处置：首次只读扫描已无 MSIX 与预配包，但发现真正的复发载体 **Teams Machine-Wide Installer**（MSI `{731F6BAA-A986-45A4-8936-7C3AAAAA760B}`，1.6.0.22378，安装目录 `C:\Program Files (x86)\Teams Installer`，135.71 MB，含 `Teams.exe`）。该 MSI 是经典 Teams 的机器级引导器，会在每个用户登录时为其安装 Teams。已 `msiexec /x /qn /norestart` 卸载（退出码 0），目录随 MSI 一并移除。
- 2026-09-08 复验全空：卸载条目、Appx 包（AllUsers）、预配包、进程、安装目录、磁盘 exe、计划任务、服务、HKCU Run `Teams`、开始菜单命中均为空。
- 仍保留 `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\Teams`（`maglevInstallationSource=1`、`maglevInstallationResult=0`、`maglevSilentUninstall="-m -x"`），仅为 Office 安装结果记录，不含 Teams 二进制，未改动。
- 当时不是 Azure AD 设备加入、不是域加入。曾有一条 Entra 已注册（Workplace join），租户显示名 Cloud、账户域 `a.v365.lol`。用户确认不再使用后已断开：`WorkplaceJoined : NO`，对应组织访问证书已删除。个人 Microsoft / OneDrive 账户未改。
- `dsregcmd /leave` 退出码 0，但立即复查仍为 WorkplaceJoined YES；删除该账户的 JoinInfo、TenantInfo 与组织访问证书后才变为 NO。以后在这台机断开同类账户，以 `dsregcmd /status` 为准，不要只看 leave 退出码。
- 仍未封锁 Windows 收件箱 Chat（当前无 `Windows Chat` 策略键）。若 Teams 再次出现，优先复查是否有新的 Machine-Wide Installer 或收件箱 Chat 重新落盘，属另立任务。
- 2026-09-08 防复发评估（只读，未变更）：官方「移除后不被 Windows 更新装回」机制 `AppxAllUserStore\Deprovisioned\MSTeams_8wekyb3d8bbwe` 已存在；但该机是家庭版（`CoreCountrySpecific`），`CloudContent` 与 `Windows Chat` 策略均不在支持版本内，且本机 `PolicyDefinitions` 仅 33 个 ADMX、`Taskbar.admx`/`CloudContent.admx` 不存在，写入也不会有组件读取。结论是保持现状，不追加未文档化注册表键。中国区 Teams 消费版桌面/网页自 2026-08-17 起已不可用。评估报告：`D:\agents\run-evidence\replicator\study-teams-recurrence-20260908\ASSESSMENT.md`。
- 运行证据：`D:\agents\run-evidence\replicator\study-teams-20260901\`、`D:\agents\run-evidence\replicator\study-workplace-leave-20260901\`、`D:\agents\run-evidence\replicator\study-teams-20260908\`、`D:\agents\run-evidence\replicator\study-teams-recurrence-20260908\`。

## UU 远程

- 安装根：`D:\Program Files\Netease\GameViewer`。正式命令与文件传输走 OpenSSH/SCP over Tailscale；UU 只用于 bootstrap、诊断和受限救援。
- 应用内「检查更新」由未提权（Medium IL）GUI 启动：先把 `bin\Upgrade.exe` 拷到 `bak\Upgrade.exe`，拷失败（Win32 `ec=5`）就运行已有的 `bak\upgrade.exe`。升级器在**自身所在目录**启动 `aria2c.exe`；bak 缺该文件时界面报下载失败。
- 2026-08-31 只对齐过一次文件，未改 bak 文件 ACL。之后 GUI 仍拷不进去，bak 停在旧升级器，更新再次失败。2026-09-07 现场：`bin` 为 `4.39.1.1375`，`bak\Upgrade.exe` 仍为 `4.38.3.9325`，Users 对 bak 文件只有 `RX`。
- 2026-09-07 已做防复发：把 `bak\Upgrade.exe` 与 `bak\aria2c.exe` 对齐到当时的 `bin`（`4.39.1.1375`），并授予 Users/Authenticated Users `Modify`（含继承）。未提权 GUI 必须能打开 `bak\Upgrade.exe` 写入，否则会复发。同日稍后复核：`bin` 已到 `4.39.2.1561`，`bak` 停在 `4.39.1.1375`，aria2c 哈希仍对齐、计划任务 Ready——这是成功升级后 bak 落后一代的预期态，不是 Users `RX` / `4.38.3` 复发。
- 受管入口：`D:\Codex\.codex\scripts\uu-bak-align\Invoke-UuBakUpgradeAlign.ps1`（该机 pwsh `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`）。计划任务 `Codex UU Bak Upgrade Align`（SYSTEM、Highest、开机 + 每小时）在哈希不一致或 ACL 漂移时重对齐。状态：`D:\Codex\.codex\logs\uu-bak-align\last.json`。不要在 bak 不存在的机器上创建 bak。
- 版本、进程、任务状态属易变事实；操作前复核 `bin`/`bak` 文件版本、SHA-256 与 Users 是否仍有 `Modify`。

## UniGetUI（2026-09-07）

- 安装树：`D:\UniGetUI\UniGetUI.exe`（2026.2.7.0，从家里同路径拷入）。桌面快捷方式：`D:\桌面\UniGetUI.lnk`，目标即上述 exe。该机当时没有 tailcat 二进制，传输走 tar+scp 回退。

本页身份审计日期为 2026-08-26；PowerShell 受管版本目录于 2026-09-08 再核（7.6.3/7.6.4/7.6.5 均在，此前「7.6.5 不存在」的结论已作废）；Teams 与工作账户处置日期为 2026-09-01，Teams 彻底移除（含 Machine-Wide Installer）于 2026-09-08；UU 更新约束与防复发于 2026-09-07 再核。数量、进程和任务状态属易变事实，操作前必须实时复核。
