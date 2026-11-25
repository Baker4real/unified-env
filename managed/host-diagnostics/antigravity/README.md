# Antigravity 桌面启动维护

桌面入口通过 `LaunchAntigravity.exe` 读取当前用户启用的 Windows 手动 HTTP(S) 代理，并把它交给新进程。切换代理后需要冷启动。代理切换和快捷方式目标回归由主机诊断的 `diagnostics` profile 执行。启动器源码见 [LaunchAntigravity.cs](LaunchAntigravity.cs)。

在本仓库根目录用受管部署入口 `managed/host-diagnostics/antigravity-addons/Deploy-AntigravityAddons.ps1` 检查或原子发布启动器与扩展对账器（自动在 D 盘证据目录内用 `.NET Framework csc.exe` 编译 `LaunchAntigravity.exe`、留存备份与哈希回读 `manifest.json`）。重新部署前先跑 `node ./scripts/Run-PowerShellTests.cjs --module host-safety --profile diagnostics --only AntigravityDesktopContracts`，并通过原快捷方式复测。

```powershell
& './managed/host-diagnostics/antigravity-addons/Deploy-AntigravityAddons.ps1' -Mode Check
& './managed/host-diagnostics/antigravity-addons/Deploy-AntigravityAddons.ps1' -Mode Apply
```

## 复测更新后的应用

1. 更新前运行 [扩展对账器的 Status](../antigravity-addons/README.md#更新目标与离线验收)，确认 `updateTarget.ready=true`。两个注册表视图的 NSIS 产品键与卸载登记都应指向 D 盘。再从官方渠道更新，核对新版来源和 `resources/app.asar` SHA-256，保留对应版本的官方包用于恢复。
2. 运行以下检查。已有窗口时添加 `-Restart`，它会正常关闭 Antigravity，再通过原桌面快捷方式开一个新实例；叠加了 `context-viewer` 时加 `-CheckContextViewer` 同步验收本地鉴权与额度状态。检查记录应用版本和归档哈希、两个进程的代理设置、匿名 Google OAuth 响应及 WSL 启动观察。匿名请求以 `HTTP 400` 和 `invalid_request` 验证连通性。Google 账户授权在应用中完成。

```powershell
& './managed/host-diagnostics/antigravity/Test-AntigravityDesktop.ps1' -ExpectedArchiveSha256 '<已核实的官方包或本地已批准补丁哈希>' -Restart -CheckContextViewer
```

只读诊断当前运行中的 Antigravity 本地鉴权与额度状态（单命令脱敏输出 `daemon/hub_*.json`、`GET /` `__APP_CONFIG__`、带/不带 CSRF 的 RPC 状态码、以及精简版 `accounts_v1.json` 摘要，不输出 token 或历史 `quotaIntervals`）：

```powershell
node ./managed/host-diagnostics/antigravity/Get-AntigravityQuotaHealth.cjs
```

3. 无 WSL 运行时或发行版的机器用于复测安装提示。检查同时使用有界进程采样和新启动的应用日志，采样可能漏过极短命进程。发现安装提示、`wsl.exe` 启动记录或 WSL 探测错误时，检查新包的 WSL 探测逻辑，再决定是否适配补丁。结果目录中的 `result.json` 记录验证通过的组合。

## 只读检查进程和插件

`Test-AntigravityDesktop.ps1 -ProcessSnapshot` 用于探测进程身份，不启动、停止或重启应用。它只报告 PID、父 PID 和固定的角色判断，不输出命令行、参数值或环境。重开走正常快捷方式；没有唯一、已核实的桌面主窗口时，不向残留进程发退出请求。

1. 在 Antigravity 打开 **插件 → 已安装**（英文界面为 **Customizations → Installed**）。清空搜索，技能与规则的筛选选 **全部**，展开列表直到没有「查看更多」。向下确认 MCP 区域已展开。
2. 从仓库根运行 `pwsh -NoProfile -File managed/host-diagnostics/antigravity/Get-AntigravityCustomizationStatus.ps1`。它只读当前窗口和 Magpie 已选的技能名单，检查个人 `AGENTS.md`、全量技能名称与 `magpie` 启用工具数，不操作界面、不调用认证接口。
3. `status=verified` 表示三项均匹配。未通过时按 `reason` 检查页面、筛选、条目或连接；MCP 区域有多个连接时，只读脚本不归属工具数，请展开 `magpie` 后直接核对该行。技能与规则标题包含内置条目，不能代替按 Magpie 名单核验。

## 复建 2.33.0 补丁

`status` 按归档完整 SHA-256 识别 `official-baseline`、`local-patch` 或 `unrecognized`。`stage` 仅接收已登记的官方基线，输出到 D 盘的暂存或证据目录。已安装的补丁与同版本异哈希都会被拒绝。新版归档保持 `unrecognized`，待完成上节复测再评估。

```powershell
python -B -I managed/host-diagnostics/antigravity/patch_wsl.py status 'D:/Apps/Google.Antigravity/resources/app.asar'
python -B -I managed/host-diagnostics/antigravity/patch_wsl.py stage 'D:/Apps/Google.Antigravity.Local/app.asar.2.33.0.original' 'D:/agents/tmp/Antigravity-2.33.0.candidate.asar'
```

生成器验证只有 `dist/wsl.js` 的内容发生变化。测试覆盖无发行版时跳过 `wsl.exe`，以及已登记 WSL 2 时仍可列出。应用候选和回退前，先退出应用，再核对当前版本、哈希和同版本备份。候选生成器只产出待审文件。

叠加扩展后的归档也会显示 `unrecognized`。从扩展部署记录核对组合归档哈希及 `dist/wsl.js` 后，用这个哈希执行桌面复测。保留与本次变更对应的回退包，避免恢复某一层补丁时丢失其他扩展。
