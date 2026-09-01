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
  一切自动化必须走该显式路径，禁止任何 `powershell.exe` 隐式调用。2026-09-01 再核：
  `D:\Codex\tools\PowerShell\7.6.5\pwsh.exe` 在该机不存在，不要把 `jia-li` 的 7.6.5 收敛套过来。
- 统一环境仓库位于旧布局 `D:\Codex\projects\统一环境`（审计时工作区干净，HEAD
  落后 jia-li main）；`D:\agents` 树在该机不存在。仓库布局迁移属另立任务。
- `D:\Codex\.codex\docs\agent-guidance\` 已同步在机（14 条目）。
- run-evidence 迁移（旧根 101 个顶层条目）的执行契约见
  `docs/plans/2026-08-26-run-evidence-migration-plan-zi-xi-shi-ban-gong-shi.md` §4。

## Microsoft Teams 与工作账户（2026-09-01 现场 SSH）

- 新版 Teams（MSTeams MSIX）已从当前用户卸载，并移除预配包；HKCU Run 的 Teams 项已删除，AppX 启动任务随后不存在。复查：无 Teams 进程、无 Appx 包、无开始菜单项。
- 当时不是 Azure AD 设备加入、不是域加入。曾有一条 Entra 已注册（Workplace join），租户显示名 Cloud、账户域 `a.v365.lol`。用户确认不再使用后已断开：`WorkplaceJoined : NO`，对应组织访问证书已删除。个人 Microsoft / OneDrive 账户未改。
- `dsregcmd /leave` 退出码 0，但立即复查仍为 WorkplaceJoined YES；删除该账户的 JoinInfo、TenantInfo 与组织访问证书后才变为 NO。以后在这台机断开同类账户，以 `dsregcmd /status` 为准，不要只看 leave 退出码。
- 未封锁 Windows 收件箱 Chat 再次预装 Teams。若 Teams 又出现，属另立任务。
- 运行证据：`D:\agents\run-evidence\replicator\study-teams-20260901\`、`D:\agents\run-evidence\replicator\study-workplace-leave-20260901\`。

## UU 远程（2026-08-31 现场）

- 安装根：`D:\Program Files\Netease\GameViewer`。2026-08-31 09:27 经正式 SSH 核验：`bin\GameViewer.exe` 与 `bin\Upgrade.exe` 均为 `4.38.3.9325`，`GameViewerService` 为 Running，主进程已拉起。
- 正式命令与文件传输走 OpenSSH/SCP over Tailscale；UU 只用于 bootstrap、诊断和受限救援。
- 应用内「检查更新」由未提权 GUI 启动。它会把 `Upgrade.exe` 拷进 `bak\`，在 Program Files 上会得到拒绝访问（Win32 `ec=5`），随后运行已有的 `bak\upgrade.exe`。
- 该升级器在**自身所在目录**启动 `aria2c.exe`。`aria2c.exe` 只在 `bin\`、不在 `bak\` 时，界面报下载失败，即使更新接口和 `a56.gdl.netease.com` 都通。
- 2026-08-31 已把 `bin\aria2c.exe` 补进 `bak\` 后完成下载安装。同日稍后已将 `bak\Upgrade.exe` 与 `bak\aria2c.exe` 对齐为 `4.38.3.9325`（与 `bin` SHA-256 一致）。未提权 GUI 仍会回退到 `bak`；回退目录必须继续与 `bin` 的升级器及 `aria2c.exe` 对齐。

本页身份审计日期为 2026-08-26；PowerShell 7.6.3 路径于 2026-09-01 再核；UU 版本与更新约束审计日期为 2026-08-31；Teams 与工作账户处置日期为 2026-09-01。数量、进程和任务状态属易变事实，操作前必须实时复核。
