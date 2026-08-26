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
- 2026-08-26 身份核验：按 Tailscale 登记，`zi-xi-shi` 是独立 Windows 设备。本文件
  此前误装了 `jia-li` 的环境事实，已迁至 `docs/environments/jia-li.md`；本页只保留
  已现场核验的事实。

## 已核验环境事实（2026-08-26 只读 SSH 审计）

- Windows 11 家庭中文版 10.0.26200；PowerShell 7.6.3 位于
  `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`；**该机 PowerShell 5.x 被策略封锁**，
  一切自动化必须走该显式路径，禁止任何 `powershell.exe` 隐式调用。
- 统一环境仓库位于旧布局 `D:\Codex\projects\统一环境`（审计时工作区干净，HEAD
  落后 jia-li main）；`D:\agents` 树在该机不存在。仓库布局迁移属另立任务。
- `D:\Codex\.codex\docs\agent-guidance\` 已同步在机（14 条目）。
- run-evidence 迁移（旧根 101 个顶层条目）的执行契约见
  `docs/plans/2026-08-26-run-evidence-migration-plan-zi-xi-shi-ban-gong-shi.md` §4。

本页审计日期为 2026-08-26；数量、进程和任务状态属易变事实，操作前必须实时复核。
