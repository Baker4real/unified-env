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

## 显示环境

2026-10-10 经受管 office helper 的只读 SSH 探针实测（证据 `D:\agents\run-evidence\office-display-probe\20261010-130705\result.json`，探针发起于家里）：

- 物理显示：NVIDIA GeForce GT 1030，当前模式 1920×1080 @ 60 Hz；另有 ToDesk、GameViewer 两个虚拟显示适配器，均无活动模式。
- 缩放：交互用户 `AppliedDPI` 为 96（100%），`Win8DpiScaling` 为 0，无按显示器的缩放覆盖。
- 推算可用工作区高度约 1032–1040 DIP（扣除任务栏）。界面尺寸类决策以此为办公室基准；显示器或缩放变更后须重新探测。

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

2026-08-21 办公室订阅故障处置、2026-08-22 01:23 从家里经正式 SSH 的只读复核，以及 2026-10-19 的 v2rayN 升级、新界订阅与 OpenAI 分组改造（23:17 经正式 SSH 回读）。连接方向、identity 与 known-hosts 以 `D:\Codex\.codex\docs\agent-guidance\ssh-mesh.md` 为准；本文只记办公室本机事实。

### 办公网

- 当前出口是移动 `cmcc.wifi`，没有全局 IPv6 路由。
- 对部分境外目标按 IP 在 TLS 阶段重置：TCP 能握手，随后连接被杀。2026-08-22 01:23 直连 `controlplane.tailscale.com` 仍是此模式。
- 同一出口对机场订阅 IP 的封锁会变。2026-08-21 晚 `blogzone.me` 直连 TLS 被杀，2026-08-22 01:23 直连 HTTP 200。把直连偶然通畅写成已经解封，或因此改回直连节点，都会误判。
- 网卡 DNS 已固定 `223.5.5.5` 与 `119.29.29.29`。原路由器 DNS 对外部域名普遍超时。
- 在这台机器上用 Windows curl 测境外站须加 `--ssl-no-revoke`，否则 `CRYPT_E_REVOCATION_OFFLINE` 会看起来像连不上。

### v2rayN

- 安装根是 `D:\v2rayN-windows-64\`：`v2rayN.exe` 在该根下，配置在 `guiConfigs\`，核心在 `bin\xray\` 与 `bin\sing_box\`。不要按嵌套路径 `v2rayN-windows-64\v2rayN-windows-64` 查找。
- 2026-10-19 23:17：v2rayN `7.25.6`（同晚由 `7.24.9` 升级），Xray `26.10.10`，sing-box `1.14.3`。`7.25.6` 生成的 sing-box DNS 规则要求 sing-box ≥ 1.14；反过来 `7.24.9` 配 1.14 不保证可用。
- 激活条目是策略组 `OpenAI`（IndexId `office-openai`，sing-box urltest，`MultipleLoad=0` 最低延迟）。`127.0.0.1:10808` 与 Clash API `127.0.0.1:10813` 由 sing-box 监听，v2rayN 与 sing-box 在交互会话 1。
- OpenAI 组按备注正则从新界订阅选成员，正则在 `D:\Codex\.codex\tools\office-v2rayn\openai-filter.txt`：排除香港（保留“香港中转”到其他地区的线路）、澳门、中国大陆、俄罗斯、白俄、伊朗、朝鲜、叙利亚、古巴、委内瑞拉，以及 IPv6、剩余/到期/订阅更新、故障、“将在…恢复”条目。2026-10-19 结果：120 条中 72 条入组（AnyTLS 19、Trojan 11、VLESS 42），选中 `China Taiwan B02`，`chatgpt.com/cdn-cgi/trace` 为 `loc=TW`。
- 探测间隔由 v2rayN 写死：sing-box urltest 用默认 3 分钟、50 ms 容差、`www.gstatic.com/generate_204`（Xray leastPing 同为 3 分钟）。改成 5 分钟只能改 v2rayN 本身。
- 2026-10-19 23:17 的一轮探测：72 个成员中 64 个有成功延迟，最快约 148 ms，8 个没有成功记录。其中包括非 `*.nwncd.com` 的直连节点，所以“激活节点必须是香港/台湾中转”已不是当前事实。出口封锁会变，改由分组自动择优，不再手工固定节点。
- 这台 Wi-Fi 没有 IPv6，IPv6-only 节点会让“通过代理更新”秒死；OpenAI 组已按正则排除这些节点。
- 订阅 `新界`（SubItem Id `5419959239927671091`，原名 `import_sub`）指向 `6691fe61.neworld.digital`，完整链接只存 v2rayN 数据库。原 `blogzone.me` 链接约自 10-10 起返回 404，此后节点列表一直没刷新。`AutoUpdateInterval=1440`，另由 03:00 任务强制刷新；订阅更新不会删除 `IsSub=0` 的策略组。
- 策略组 `办公室 - 自动最低延迟`（`office-auto-lowest-latency`，Xray，2026-10-12 建）仍在，未激活，本次未改。
- 计划任务 `Codex Office v2rayN Autostart`：Highest + Interactive，启动 `D:\v2rayN-windows-64\v2rayN.exe`。进程不退出时 `LastTaskResult=267009`（`SCHED_S_TASK_RUNNING`）表示任务仍在跑，不是失败。维护脚本都经它重启 v2rayN。
- 2026-10-19 23:17 经 socks `10808`：google HTTP 204；`api.openai.com/v1/models` 未带 key 时返回 401，说明可达，且没有出现地区拒绝。
- v2rayN 日志里成组出现的 `open connection to <本机以太网 IP>:443 using outbound/direct ... actively refused` 是无害噪声。2026-10-20 抓到的来源是腾讯视频的 `hardwarecheck.exe`：它经 10808 的 SOCKS 去连本机自己的以太网 IP（DHCP 分配，会变）的 443 端口，本机没有监听，所以被拒。它自己走 SOCKS，不受系统代理的局域网例外约束。不用为此改路由；嫌吵就关掉腾讯视频的后台服务。证据在家里 `D:\agents\run-evidence\office-v2rayn-openai\20261020-local-ip-443-refused\`。

### v2rayN 定时维护（2026-10-19 起）

- 脚本在 `D:\Codex\.codex\tools\office-v2rayn\`：`V2rayNOps.ps1`（公共函数）、`v2rayn_db.py`（SQLite 与配置读写，不输出订阅链接）、`Update-V2rayN.ps1`、`Update-V2rayNSubscription.ps1`、`Enable-OpenAIGroup.ps1`（一次性启用 OpenAI 组，可重跑）和 `openai-filter.txt`。三个任务都是 Administrator、Interactive、Highest：只在管理员已登录时运行，与 v2rayN 同会话。
- `Codex Office v2rayN Daily Update` 每天 02:00 运行。它查询 GitHub 最新稳定版，按发布摘要校验 `v2rayN-windows-64.zip` 的 SHA-256。和 AmazTool 一样，已存在的 `bin` 文件保持不动；例外是安装包自带的 xray 或 sing-box 比现有版本新时，整个对应核心目录会被替换。安装后检查 10808 代理，失败则回滚程序文件和配置。首次运行在 2026-10-19 23:09–23:10，从 7.24.9 升到 7.25.6，停机约 11 秒。2026-10-20 02:00 第一次无人值守运行：已是最新版，没有安装，约 2 秒结束，`LastTaskResult=0`。
- `Codex Office v2rayN Subscription Refresh` 每天 03:00 运行。它把新界订阅的 `UpdateTime` 置 0，由 v2rayN 自己的每分钟调度执行更新；成功后 v2rayN 会重载核心。代理检查不通过时，恢复更新前的数据库与配置。2026-10-19 23:15 试跑成功：仍为 120 条、72 个成员，`LastTaskResult=0`。2026-10-20 03:00 第一次无人值守运行成功：仍为 120 条，核心配置重写并重载，前后代理检查都通过。OpenAI 组随订阅变为 71 个成员，少掉的 `Japan D01` 被订阅标成“将在 10-25 恢复”，按正则排除。
- 维护期间会暂停 `Codex Office Proxy FailSafe`，避免它在 10808 短暂断开时清掉系统代理；结束后再恢复。三个脚本共用 `D:\Codex\.codex\cache\office-v2rayn-update\maint.lock` 互斥。加锁靠持有文件句柄，文件会一直留着，文件存在不代表锁被占用。
- 日志与每类任务的最新摘要（`*-last.json`）在 `D:\agents\run-evidence\office-v2rayn-maint\`，超过 90 天的日志会被删除。下载包和回滚备份在 `D:\Codex\.codex\cache\office-v2rayn-update\`，程序备份保留 2 份，订阅更新前的数据库备份保留 7 份。

### 2026-10-19 断线根因

- 14:38:50 v2rayN 日志记录“运行 Core 失败”：核心进程启动后 100 ms 内就退出了。v2rayN 不会自动重试，核心一直停到 22:24 用户手动切换节点。期间 15:28 本机连 10808 被拒，Tailscale 约从 14:41 起离线。
- 推断（未证实）：当时选中的条目走 sing-box，而 sing-box 1.14.0 不接受 v2rayN 7.24.9 生成的配置。失败配置已被覆盖，无法回看。升级到 7.25.6 + sing-box 1.14.3 后不再是这种组合。

### Tailscale 对本机代理的依赖

- Tailscale 服务 `HKLM\SYSTEM\CurrentControlSet\Services\Tailscale` 的 `Environment` 含 `HTTPS_PROXY=socks5://127.0.0.1:10808` 与 `HTTP_PROXY=socks5://127.0.0.1:10808`。控制面走本地 socks；数据面在代理恢复后可再协商 UDP 直连。
- v2rayN 或 10808 停止后，办公室 Tailscale 控制面会掉线，正式 SSH mesh 随之不可用。这种掉线先查本机代理，不要先当成密钥或 sshd 损坏。

### 提权看门狗

- 计划任务 `Codex Office Proxy FailSafe`：HighestAvailable，脚本 `D:\Codex\.codex\tools\office-v2rayn\Ensure-ProxyFailSafe.ps1`。UU 远程会话是中完整性，杀不掉提权的 v2rayN，也写不了 HKLM；一次性提权修复要借用该任务写入自解除块，跑完还原原件。
- 2026-08-22 01:19 该任务 `LastTaskResult=0`、状态 `Ready`。
- 2026-10-19 读过脚本正文：每 5 分钟检查一次。10808 在听时写 Machine 级 `HTTP_PROXY`/`HTTPS_PROXY`；不在听时清掉指向 10808 的 HKCU 系统代理和环境变量。它不会拉起 v2rayN 或核心。

### 回滚材料（办公室本机）

- 2026-08-22 01:23 仍在：`D:\v2rayN-windows-64\guiConfigs\guiNConfig.json.bak-uu`、`guiNDB.db.bak-uu`。
- 2026-10-19 23:17 列目录确认：`D:\Codex\.codex\tools\office-v2rayn\Ensure-ProxyFailSafe.ps1.bak-uu`。
- 2026-10-19 改造前的配置与数据库：`D:\v2rayN-windows-64\guiConfigs\backup-openai-20261019-225135\`（`integrity_check=ok`，含旧订阅链接，只留本机）。启用 OpenAI 组前的状态：`D:\Codex\.codex\cache\office-v2rayn-update\openai-20261019-231214-guiNDB.db` 与同名 `guiNConfig.json`。7.24.9 程序文件：同目录 `app-backup-7.24.9-20261019-230949.zip`。`openai-*` 文件不会被脚本自动清理；程序备份 zip 再经过两次程序更新后会被轮换掉。
- 回滚 OpenAI 组：先停 v2rayN 及其核心，确认 10808 已释放，有 `guiNDB.db-journal` 先移开；再把 `openai-20261019-231214-guiNDB.db`、`openai-20261019-231214-guiNConfig.json` 分别拷回为 `guiConfigs\guiNDB.db`、`guiConfigs\guiNConfig.json`，最后启动 Autostart 任务。

### 办公室 mesh 不通时

| 触发 | 先做 | 仍失败 |
|---|---|---|
| 10808 未监听，或 v2rayN/核心（sing-box 或 xray）不在 | 看 Autostart 与 FailSafe 任务状态；需要提权则走 FailSafe 脚本通道 | 按 ssh-mesh 用 UU 做 bootstrap/救援，不改正式 SSH 密钥 |
| Tailscale 在线但 SSH 失败 | 复核 sshd 与 TCP 22 | 同上 |
| 10808 在听但代理不通 | 看 Clash API `127.0.0.1:10813` 中 `proxy-auto` 的当前选择与成员延迟，以及 `office-v2rayn-maint\*-last.json` | 中转入口会轮换；全面超时先等几分钟再改配置 |
| 02:00/03:00 任务后不通 | 读 `app-update-last.json` / `sub-update-last.json` 的 `result` 与日志；脚本失败时会自动回滚 | 用上一节的回滚材料手工恢复 |

## 远端操作边界

- 正式远端操作使用严格 OpenSSH/SCP over Tailscale；UU 只用于 bootstrap、诊断和受限救援。办公室 Tailscale 控制面依赖本机 v2rayN 的 10808，见上一节。
- 不从本文推断当前 IP、密钥、host-key 或账号；这些均从调用端受控配置现场读取。
- 设备级运行证据位于 `D:\Codex\.codex\run-evidence\office-win11-upgrade-20260728\`。关键终态包括 `updates\scan-final-01.json`、`cleanup\final-current-audit.json`、`cleanup\startup-memory-final-current.json`、`cleanup\backup-removal-verification.json` 与 `cleanup\volume-labels-unified.json`。

## 事实审计

- Windows 版本、更新扫描、许可证、磁盘、Codex 记忆、CC Switch、v2rayN `AutoHideStartup`、UU 的 HKCU Run：2026-07-28 现场，本次未复核。
- sshd / Tailscale / GameViewerService、v2rayN / xray / 10808、DNS、Tailscale 服务代理环境变量、计划任务、当前中转节点与 socks 验收：2026-08-22 01:23 从家里经正式 SSH 只读复核。
- v2rayN 版本与核心、新界订阅、OpenAI 组成员与探测、02:00/03:00 任务、系统代理（`ProxyEnable=1`，`127.0.0.1:10808`）、Machine 级 `HTTP(S)_PROXY`、Tailscale `Running online=True`：2026-10-19 23:17 从家里经正式 SSH 回读。证据在家里 `D:\agents\run-evidence\office-v2rayn-openai\20261019\`。
- 02:00/03:00 两个任务的第一次无人值守运行、管理员控制台会话（10-14 起在线）、程序版本与 10808：2026-10-20 09:38 从家里经正式 SSH 回读。证据在家里 `D:\agents\run-evidence\office-v2rayn-openai\20261019\followup-20261020\`。
- 设备页是快照。服务、进程、监听和激活节点操作前仍须实时复核。
