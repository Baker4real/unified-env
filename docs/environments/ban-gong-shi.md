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
- 统一环境仓库：登记为 `D:\agents\projects\统一环境`，但 2026-08-26 经 SSH 现场审计该机
  `D:\agents\projects` 不存在（仓库未部署到该机；SSH 会话中 git 不在 PATH）。同步该机仓库
  属另立任务；审计同期确认 `D:\Codex\.codex\docs\agent-guidance\` 已同步在机。
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

## 办公网、v2rayN 与 Tailscale

2026-08-21 办公室订阅故障处置，以及 2026-08-22 01:23 从家里经正式 SSH 的只读复核。连接方向、identity 与 known-hosts 以 `D:\Codex\.codex\docs\agent-guidance\ssh-mesh.md` 为准；本文只记办公室本机事实。

### 办公网

- 当前出口是移动 `cmcc.wifi`，没有全局 IPv6 路由。
- 对部分境外目标按 IP 在 TLS 阶段重置：TCP 能握手，随后连接被杀。2026-08-22 01:23 直连 `controlplane.tailscale.com` 仍是此模式。
- 同一出口对机场订阅 IP 的封锁会变。2026-08-21 晚 `blogzone.me` 直连 TLS 被杀，2026-08-22 01:23 直连 HTTP 200。把直连偶然通畅写成已经解封，或因此改回直连节点，都会误判。
- 网卡 DNS 已固定 `223.5.5.5` 与 `119.29.29.29`。原路由器 DNS 对外部域名普遍超时。
- 在这台机器上用 Windows curl 测境外站须加 `--ssl-no-revoke`，否则 `CRYPT_E_REVOCATION_OFFLINE` 会看起来像连不上。

### v2rayN

- 安装根是 `D:\v2rayN-windows-64\`：`v2rayN.exe` 在该根下，配置在 `guiConfigs\`，核心是 `bin\xray\xray.exe`。不要按嵌套路径 `v2rayN-windows-64\v2rayN-windows-64` 查找。
- `127.0.0.1:10808` 由 xray 监听。2026-08-22 01:23：v2rayN 与 xray 均在交互会话 1。
- 激活节点必须是机场香港/台湾中转（`*.nwncd.com`）。这台 Wi-Fi 没有 IPv6，IPv6-only 节点（例如曾出现的 `hkac02-ipv6`）会让“通过代理更新”秒死。
- `import_sub` 已开 30 分钟自动更新；更新会重绑激活条目。2026-08-22 01:23 快照：备注 `A Series - HK 25`，`newazhk25.nwncd.com:443`，VLESS/REALITY。节点名会随自动更新改变，约束是中转域名，不是这一条备注。
- 计划任务 `Codex Office v2rayN Autostart`：Highest + Interactive，启动 `D:\v2rayN-windows-64\v2rayN.exe`。进程不退出时 `LastTaskResult=267009`（`SCHED_S_TASK_RUNNING`）表示任务仍在跑，不是失败。
- 2026-08-22 01:23 经 socks `10808`：gstatic 与 google 均为 HTTP 204。

### Tailscale 对本机代理的依赖

- Tailscale 服务 `HKLM\SYSTEM\CurrentControlSet\Services\Tailscale` 的 `Environment` 含 `HTTPS_PROXY=socks5://127.0.0.1:10808` 与 `HTTP_PROXY=socks5://127.0.0.1:10808`。控制面走本地 socks；数据面在代理恢复后可再协商 UDP 直连。
- v2rayN 或 10808 停止后，办公室 Tailscale 控制面会掉线，正式 SSH mesh 随之不可用。这种掉线先查本机代理，不要先当成密钥或 sshd 损坏。

### 提权看门狗

- 计划任务 `Codex Office Proxy FailSafe`：HighestAvailable，脚本 `D:\Codex\.codex\tools\office-v2rayn\Ensure-ProxyFailSafe.ps1`。UU 远程会话是中完整性，杀不掉提权的 v2rayN，也写不了 HKLM；一次性提权修复要借用该任务写入自解除块，跑完还原原件。
- 2026-08-22 01:19 该任务 `LastTaskResult=0`、状态 `Ready`。本次只读探测没有打开脚本正文，不能声称它会在 10808 挂掉时自动拉起 v2rayN。

### 回滚材料（办公室本机）

- 2026-08-22 01:23 仍在：`D:\v2rayN-windows-64\guiConfigs\guiNConfig.json.bak-uu`、`guiNDB.db.bak-uu`。
- 2026-08-21 记录、本次未再列目录：`D:\Codex\.codex\tools\office-v2rayn\Ensure-ProxyFailSafe.ps1.bak-uu`。

### 办公室 mesh 不通时

| 触发 | 先做 | 仍失败 |
|---|---|---|
| 10808 未监听，或 v2rayN/xray 不在 | 看 Autostart 与 FailSafe 任务状态；需要提权则走 FailSafe 脚本通道 | 按 ssh-mesh 用 UU 做 bootstrap/救援，不改正式 SSH 密钥 |
| Tailscale 在线但 SSH 失败 | 复核 sshd 与 TCP 22 | 同上 |
| 激活节点变成 IPv6-only 或被出口拉黑的直连 IP | 切回 `*.nwncd.com` 香港/台湾中转 | 中转入口也会轮换；全面超时先等几分钟再改配置 |

## 远端操作边界

- 正式远端操作使用严格 OpenSSH/SCP over Tailscale；UU 只用于 bootstrap、诊断和受限救援。办公室 Tailscale 控制面依赖本机 v2rayN 的 10808，见上一节。
- 不从本文推断当前 IP、密钥、host-key 或账号；这些均从调用端受控配置现场读取。
- 设备级运行证据位于 `D:\Codex\.codex\run-evidence\office-win11-upgrade-20260728\`。关键终态包括 `updates\scan-final-01.json`、`cleanup\final-current-audit.json`、`cleanup\startup-memory-final-current.json`、`cleanup\backup-removal-verification.json` 与 `cleanup\volume-labels-unified.json`。

## 事实审计

- Windows 版本、更新扫描、许可证、磁盘、Codex 记忆、CC Switch、v2rayN `AutoHideStartup`、UU 的 HKCU Run：2026-07-28 现场，本次未复核。
- sshd / Tailscale / GameViewerService、v2rayN / xray / 10808、DNS、Tailscale 服务代理环境变量、计划任务、当前中转节点与 socks 验收：2026-08-22 01:23 从家里经正式 SSH 只读复核。
- 设备页是快照。服务、进程、监听和激活节点操作前仍须实时复核。
