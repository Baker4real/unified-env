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
  一切自动化必须走该显式路径，禁止任何 `powershell.exe` 隐式调用。
- 统一环境仓库位于旧布局 `D:\Codex\projects\统一环境`（审计时工作区干净，HEAD
  落后 jia-li main）；`D:\agents` 树在该机不存在。仓库布局迁移属另立任务。
- `D:\Codex\.codex\docs\agent-guidance\` 已同步在机（14 条目）。
- run-evidence 迁移（旧根 101 个顶层条目）的执行契约见
  `docs/plans/2026-08-26-run-evidence-migration-plan-zi-xi-shi-ban-gong-shi.md` §4。

## UU 远程（2026-08-31 现场）

- 安装根：`D:\Program Files\Netease\GameViewer`。2026-08-31 09:27 经正式 SSH 核验：`bin\GameViewer.exe` 与 `bin\Upgrade.exe` 均为 `4.38.3.9325`，`GameViewerService` 为 Running，主进程已拉起。
- 正式命令与文件传输走 OpenSSH/SCP over Tailscale；UU 只用于 bootstrap、诊断和受限救援。
- 应用内「检查更新」由未提权 GUI 启动。它会把 `Upgrade.exe` 拷进 `bak\`，在 Program Files 上会得到拒绝访问（Win32 `ec=5`），随后运行已有的 `bak\upgrade.exe`。
- 该升级器在**自身所在目录**启动 `aria2c.exe`。`aria2c.exe` 只在 `bin\`、不在 `bak\` 时，界面报下载失败，即使更新接口和 `a56.gdl.netease.com` 都通。
- 2026-08-31 已把当时的 `bin\aria2c.exe` 补进 `bak\` 后，下载与安装完成。安装成功后 `bin` 已是 `4.38.3.9325`，`bak\Upgrade.exe` 仍可能落后（当日仍为 `4.37.0.9232`）。下次应用内更新仍会走 `bak` 回退：先确认 `bak\aria2c.exe` 存在，再点检查更新。
- 旧版 `4.35` 的 `bak\Upgrade.exe` 备份在该机 `D:\Codex\.codex\tmp\uu-upgrade-bak-backup-20260831\`，不是现役入口。

本页身份与 PowerShell 路径审计日期为 2026-08-26；UU 版本与更新约束审计日期为 2026-08-31。数量、进程和任务状态属易变事实，操作前必须实时复核。
