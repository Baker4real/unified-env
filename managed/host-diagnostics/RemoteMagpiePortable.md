# Magpie 远端便携安装

Owner 为 `host-safety`。公开入口是 [Invoke-RemoteMagpiePortable.ps1](Invoke-RemoteMagpiePortable.ps1)，同目录依赖 [MagpiePortablePayload.ps1](MagpiePortablePayload.ps1)、[Invoke-RemoteStep.ps1](Invoke-RemoteStep.ps1) 及已受管的 `Invoke-OfficeRemote.ps1`。入口将 payload 经 stdin 送入已有 helper，远端仅接收短 bootstrap，适用于 office/study 的命令长度限制。

## 调用

从已部署的本机入口调用。先只读核对目标电脑名、交互用户和架构，再替换示例中的设备名、账号和架构。

```powershell
$entry = 'D:/Codex/.codex/scripts/Invoke-RemoteMagpiePortable.ps1'
$target = @{
    Target = 'office'
    ExpectedComputerName = 'EXAMPLE-PC'
    InteractiveUser = 'EXAMPLE-PC\ExampleUser'
    Architecture = 'amd64'
    InstallDirectory = 'D:/Apps/Magpie'
}
& $entry @target -Mode Plan
# 将上一条输出 evidenceDirectory 下的 release-metadata.json 作为审阅过的固定版本输入。
$release = 'D:/agents/run-evidence/remote-magpie-portable/<Plan的runId>/release-metadata.json'
& $entry @target -Mode Install -ReleaseMetadataPath $release
& $entry @target -Mode Verify -ReleaseMetadataPath $release -RequireRunning
```

未传 `ReleaseMetadataPath` 时读取 [官方 api/latest](https://usemagpie.ai/api/latest)，按显式 `amd64` / `arm64` 选择唯一的 `magpie-windows-<架构>.exe`。asset 必须含整数 size、64 位 SHA256 和匹配版本/架构的官方 URL。网络不通时可显式加 `-DownloadProxy 'socks5h://127.0.0.1:10808'`，仅作用于远端本次 curl 下载，不修改代理配置；metadata 由发起端读取。固定 metadata 是操作者已审阅的官方快照，不是独立数字签名；保留原始来源证据，不能用本地 exe 自算 hash 冒充官方值。

`Plan` / `Verify` 对远端只读，本机仍产生独立 D 盘 evidence（release metadata、stdin bundle、运行摘要及结果）。`Install` 经 `RemoteStep -WriteOperation`，bootstrap 首条语句断言远端标记，payload 在任何写入前再核对电脑名、OS 架构、交互用户和 Explorer 会话。桌面来自该 Explorer 用户 SID 的 HKU User Shell Folders，只展开其用户 profile，不使用 SSH 账户的 Desktop；桌面重定向含其他未解析变量时闭锁。

## 结果与拒绝

成功状态是 `planned`、`installed`、`unchanged` 或 `verified`，失败退出非零。结果以 JSON 写到进程 stdout，并保存到 evidence 的 `result.json`；需要在另一个 PowerShell 脚本内捕获时，用独立的 `pwsh -File` 进程并检查退出码。结果提供 official asset、目标路径、before/after、changes 与进程观察。

同 hash/size exe、现有 data 目录和同 target 且无参数的快捷方式重复安装为 `unchanged`，不下载、不重写 exe 或 lnk。新 exe 先落到安装目录内唯一 `.download`，size/SHA256 均通过后 no-replace 移动落位；新 lnk 在准确桌面目录暂存并 no-replace 发布。同 target 既有 lnk 保持原属性。

既有 Magpie 进程必须匹配官方 exe hash/size、路径、交互 SessionId 和 Explorer 用户 SID，且 Responding 并持有 3425 网关监听。存活父进程接受已核实的交互 Explorer，或同 exe 路径、同 SID、同会话且启动不晚于子进程的健康 Magpie；其它存活父进程直接拒绝，不用日志替代冲突事实。成功报告 `running-verified`，不会重启或杀进程；此健康检查不证明模型/provider API 请求成功。无进程时安装或普通 Verify 可成功并报告 `not-running`；`-RequireRunning` 会只读拒绝。入口不负责首次启动。

自更新后父进程已退出时，只接受 `data/logs/app.log` 内完整 startup 记录：当前 PID、官方 metadata 版本、Windows 架构及日志自身路径均一致，并且只找到一条时间匹配记录。日志按远端本地时区转换为 UTC；秒精度 timestamp 相对进程 StartTime 只允许 -1 至 +10 秒，拒绝夏令时歧义，exe 修改时间不得晚于进程启动。成功如实报告 `parent=exited`、`launchEvidence=portable-startup-log`，并投影校验过的时间；不声称由 Explorer 启动，不回传其它日志内容。缺日志、残缺/重复/不匹配记录及 owner 错配均只读闭锁。仍要求每个枚举到的应用进程独立满足健康门禁，不增加多进程启动或交接角色管理。

不同 hash、未知目录内容、路径类型冲突、reparse、同名快捷方式指向其他程序或含参数均失败闭锁。已有版本与 latest 不同不会升级；用安装时官方 metadata 验收旧版，升级另行审阅。下载/校验失败保留本次 `.download` 并在结果给出路径，后续调用会拒绝该未知残留。检查失败的 evidence 后，仅在重新核实所有权和 hash 的前提下由操作者处理本次新建文件；入口不自动清理、不回退既有文件或 portable data，也不宣称全事务回滚。已发布文件与用户 data 保留，成功安装后撤销仍需按宿主受管回收政策处理。

## 验证与接线

```powershell
& 'D:/Codex/.codex/scripts/Invoke-CheckedPowerShell.ps1' -ScriptPath 'D:/agents/projects/统一环境/managed/host-diagnostics/Test-RemoteMagpiePortable.ps1' -TimeoutSeconds 120
```

[Test-RemoteMagpiePortable.ps1](Test-RemoteMagpiePortable.ps1) 从公开入口走真实 RemoteStep；只替换 SSH、HTTP 下载、CIM/进程/注册表观察边界，实际在 D 盘创建 fixture exe 和 Windows lnk。覆盖默认 metadata 路线、固定 metadata、首装、只读 Plan/Verify、重复零应用写入、完整性失败、路径/快捷方式冲突、准确设备标记、reparse 和已运行分支。fixture 不证明实际 SSH、官方二进制下载或远端桌面/监听状态。

入口、payload 与 fixture 由 [Deploy-HostDiagnostics.ps1](../../scripts/Deploy-HostDiagnostics.ps1) 管理；部署用 Check/Apply/Check 保存备份并回读，同目录 RemoteStep/OfficeRemote 必须就绪。[模块清单](../../modules/manifest.json) 登记公开入口和 `host-safety` 的 `diagnostics` 测试。部署本机脚本不会安装或升级远端应用，远端写入只发生在显式 `Install` 调用。
