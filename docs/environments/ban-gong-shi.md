---
type: reference
title: 办公室设备环境说明
tags: [设备, 办公室, Windows]
intent: 记录办公室设备的受控环境事实与差异
---

# 办公室设备环境说明

## 设备身份

- 设备标识：`ban-gong-shi`
- Windows 主机名：`PC-20250421IVIW`
- 统一环境仓库：`D:\Codex\projects\统一环境`
- Codex 受管根：`D:\Codex\.codex`

网络地址、SSH 用户、密钥路径、登录态和凭据属于调用端本地事实，不写入仓库；连接前必须从当前设备的本地配置重新确认。

## Windows 11 与更新状态

- 2026-07-28 现场升级并复核为 Windows 11 Pro 25H2，版本 `10.0.26200.8875`。
- 2026-07-28 14:58+08:00 的 Windows Update 终扫为 `TotalCount=0`、`SelectedCount=0`；这是时间点快照，后续维护前仍须重新扫描。
- Windows 当前未激活：许可证为 `VOLUME_KMSCLIENT` / `Volume:GVLK`，`LicenseStatus=5`，宽限期为 0。不得把系统表述为已激活；只有现场复核到 `LicenseStatus=1` 才能关闭此待办。
- 升级前系统映像已按用户明确授权永久删除。`wbadmin` 当前找不到任何备份，VHDX 数量为 0；因此这台设备没有可用的升级前系统映像回滚点，后续高风险系统维护前必须重新建立独立恢复保障。

## 磁盘与卷标

- `C:`、`D:`、`E:` 的卷标已分别统一为 `C`、`D`、`E`；三卷均为 NTFS、4096 字节分配单元、GPT Basic 分区且状态为 Healthy。
- `C:` 与 `D:` 位于系统磁盘 0；`E:` 位于磁盘 1，型号 `WDC WD10EZEX-00BBHA0`，序列号 `WD-WCC6Y8HCHV9S`，容量约 1 TB，非启动盘、非系统盘。
- `E:\WindowsImageBackup` 仍有 16,200 字节的 Windows Backup catalog/log 元数据，但没有备份版本或可恢复镜像。不能因为目录存在就把它报告为备份，也不得绕过受管删除入口递归清理。

## Codex 记忆与静默自启动

2026-07-28 16:00+08:00 的当前登录会话复核结果：

- Codex 配置中的 `features.memories`、`memories.generate_memories` 与 `memories.use_memories` 均已启用；现役配置只有一个 `[features]` 和一个 `[memories]` section。
- CC Switch 的 `launchOnStartup=true`、`silentStartup=true`，HKCU Run 项存在；进程运行在交互会话中且没有主窗口。
- v2rayN 的 `AutoHideStartup=true`，`Codex Office v2rayN Autostart` 计划任务存在、启用且运行；`127.0.0.1:10808` 正在监听，进程没有主窗口。
- UU 远程的 HKCU Run 项存在，`GameViewerService` 为 `Auto` 且 `Running`；交互进程没有主窗口。
- `sshd` 与 `Tailscale` 服务均为 `Auto` 且 `Running`，TCP 22 正在监听。

CC Switch、v2rayN 和 UU 的托盘进程依赖管理员交互登录；服务在运行不等于登录后托盘进程已就绪。重启验收必须同时检查配置、注册入口、进程、窗口状态与必要监听端口。

## 远端操作边界

- 正式远端操作使用严格 OpenSSH/SCP over Tailscale；UU 只用于 bootstrap、诊断和受限救援。
- 不从本文推断当前 IP、密钥、host-key 或账号；这些均从调用端受控配置现场读取。
- 设备级运行证据位于 `D:\Codex\.codex\run-evidence\office-win11-upgrade-20260728\`。关键终态包括 `updates\scan-final-01.json`、`cleanup\final-current-audit.json`、`cleanup\startup-memory-final-current.json`、`cleanup\backup-removal-verification.json` 与 `cleanup\volume-labels-unified.json`。

除另有注明外，本页事实审计日期为 2026-07-28；更新数量、服务、进程、监听、许可证与登录态均可能变化，操作前必须实时复核。
