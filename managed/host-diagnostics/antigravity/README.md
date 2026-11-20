# Antigravity 桌面启动维护

桌面入口通过 `LaunchAntigravity.exe` 读取当前用户启用的 Windows 手动 HTTP(S) 代理，并把它交给新进程。切换代理后需要冷启动。代理切换和快捷方式目标回归由主机诊断的 `diagnostics` profile 执行。启动器源码见 [LaunchAntigravity.cs](LaunchAntigravity.cs)。

在本仓库根目录用 Windows 自带的 .NET Framework C# 编译器构建启动器候选。重新部署前先跑 `node ./scripts/Run-PowerShellTests.cjs --module host-safety --profile diagnostics --only AntigravityDesktopContracts`，保留上一份启动器，并通过原快捷方式复测。

```powershell
& "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /r:System.Windows.Forms.dll /out:D:\agents\tmp\LaunchAntigravity.candidate.exe .\managed\host-diagnostics\antigravity\LaunchAntigravity.cs
```

## 复测更新后的应用

1. 从官方渠道更新。核对新版本的可执行文件与安装包来源，然后记录这次从官方包取得的 `resources/app.asar` SHA-256。保留能恢复本次更新的原包和对应程序版本。
2. 运行以下检查。已有窗口时添加 `-Restart`，它会正常关闭 Antigravity，再通过原桌面快捷方式开一个新实例。检查记录应用版本和归档哈希、两个进程的代理设置、匿名 Google OAuth 响应及 WSL 启动观察。匿名请求以 `HTTP 400` 和 `invalid_request` 验证连通性。Google 账户授权在应用中完成。

```powershell
& './managed/host-diagnostics/antigravity/Test-AntigravityDesktop.ps1' -ExpectedArchiveSha256 '<已核实的官方包或本地已批准补丁哈希>' -Restart
```

3. 无 WSL 运行时或发行版的机器用于复测安装提示。检查同时使用有界进程采样和新启动的应用日志，采样可能漏过极短命进程。发现安装提示、`wsl.exe` 启动记录或 WSL 探测错误时，检查新包的 WSL 探测逻辑，再决定是否适配补丁。结果目录中的 `result.json` 记录验证通过的组合。

## 复建 2.33.0 补丁

`status` 按归档完整 SHA-256 识别 `official-baseline`、`local-patch` 或 `unrecognized`。`stage` 仅接收已登记的官方基线，输出到 D 盘的暂存或证据目录。已安装的补丁与同版本异哈希都会被拒绝。新版归档保持 `unrecognized`，待完成上节复测再评估。

```powershell
python -B -I managed/host-diagnostics/antigravity/patch_wsl.py status 'D:/Apps/Google.Antigravity/resources/app.asar'
python -B -I managed/host-diagnostics/antigravity/patch_wsl.py stage 'D:/Apps/Google.Antigravity.Local/app.asar.2.33.0.original' 'D:/agents/tmp/Antigravity-2.33.0.candidate.asar'
```

生成器验证只有 `dist/wsl.js` 的内容发生变化。测试覆盖无发行版时跳过 `wsl.exe`，以及已登记 WSL 2 时仍可列出。应用候选和回退前，先退出应用，再核对当前版本、哈希和同版本备份。候选生成器只产出待审文件。

叠加扩展后的归档也会显示 `unrecognized`。从扩展部署记录核对组合归档哈希及 `dist/wsl.js` 后，用这个哈希执行桌面复测。保留与本次变更对应的回退包，避免恢复某一层补丁时丢失其他扩展。
