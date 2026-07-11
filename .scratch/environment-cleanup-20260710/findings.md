# 本机环境整理发现

## 用户目标

- 按“统一环境”项目开始整理本机环境。
- 从第一性原理先盘点事实、识别归属和失败模式，再决定动作。

## 已确认事实

- 项目政策将共享运行时、共享缓存、全局 CLI、项目本地环境、人工审查项和绝不自动迁移项分开治理。
- 真实迁移、PATH 修改、管理器更新或删除均需要最新 inventory、具体 dry-run、验证/回滚方案和对具体项的显式授权。
- 现有 README 记录：低风险 pip cache 已迁移，当前旧基线没有新的明确安全迁移候选。
- 2026-07-09 旧 inventory 只列出 5 个 `minmin-calendar` 云函数 `node_modules`，均为项目本地环境，默认保留并需项目级 owner 决策。
- 报告是可再生事实快照，应由项目脚本刷新，不手工修改。
- Git 当前位于 `main`，开始时工作树干净，基线提交为 `5f7ae70`。

## 环境异常

- 工具层传入的 `workdir` 首次未生效；`git status` 报非仓库，`rg` 从 `D:\` 根扫描并遇到 WindowsApps/NVIDIA 目录访问拒绝。
- 显式执行 `Set-Location -LiteralPath 'D:\Codex\projects\统一环境'` 后，Git 和窄范围文件扫描恢复正常。
- 当前进程、HKCU 和 HKLM 的 PATH 基本一致地缺少 2026-07-06 报告宣称已设置的 `D:\Codex\_tools`、`D:\Codex\tools\python314-official` 和 `D:\Codex\tools\dotnet`；这不是单纯的 Codex 旧进程 PATH 快照。
- `D:\Codex\_tools`、`D:\Codex\tools\dotnet\dotnet.exe` 及 PowerShell 目录内的 python/dotnet shim 当前均不存在；`D:\Codex\tools\python314-official\python.exe` 仍存在。
- 当前 `python` 命中 `D:\hermes-data\.npm-global\python.exe`，`uv` 命中 `D:\hermes-data\.local\bin\uv.exe`，`dotnet` 命中 `C:\Program Files\dotnet\dotnet.exe`，`cmake`/`ninja` 不可解析。
- 当前 HKCU PATH 有 2 个缺失入口：`C:\Users\WINDOWS\.dotnet\tools` 和 `D:\Codex\.codex\tmp\dotnet-home\.dotnet\tools`；当前进程另有 PowerShell 7 重复入口。
- 本机身份是 `baker\windows`、profile 为 `C:\Users\WINDOWS`；旧 host-runbook 中出现的 `D:\Users\14224` 事实不能无条件套用到当前账户边界。

## 报告链路缺陷

- `New-EnvUpdateReadinessReport.ps1` 的 `Get-UpdatePolicy` 虽计算 `locationClass`，但多个工具的 `recommendedAction` 和风险由工具名写死。
- 可稳定复现的矛盾包括：Git 实际在 `C:\Program Files` 却写“当前已在 D 盘”；Cargo/Rust 在 D 盘却写“当前入口在系统安装目录”。
- 根因是策略文案没有消费已计算的位置分类；现有测试只断言字段存在且非空，没有断言文案与路径事实一致，因此测试全绿仍无法阻止该缺陷。
- 修复需要先经用户批准最小设计，然后按 TDD 先补失败 fixture，再让动作和风险由 `locationClass` 驱动。
- 当前默认 `D:\hermes-data\.npm-global\python.exe` 无数字签名，运行后 `sys.executable` 为 `D:\hermes-data\hermes-agent\venv-new\Scripts\python.exe`，说明它是项目本地 venv launcher，不能仅因位于 D 盘就标为低风险共享工具。
- `Invoke-EnvInventory.ps1` 盘点的是当前 Process PATH；Codex 启动注入目录会进入快照，因此它不能替代 HKCU/HKLM 持久 PATH 基线。
- `New-BackupRetentionDryRun.ps1` 对 `backups_state` 未识别子目录返回 `__skip__` 后静默 `continue`；当前至少有 `chrome-native-hosts-fix-*`、`codex-path-clean`、`machine-path`、`remote-plugin-debug-*` 等目录不进入保护项、人工审查项或候选项。
- 因此当前 backup 报告“3 个人工审查根、621.87 MB”只代表显式 allowlist 覆盖，不是全机或全部 Codex 备份覆盖。

## 对抗性审查结论

- 2026-07-06 状态回退不能归因于单纯旧进程；持久 PATH 和工具物理目录均已变化，且旧回滚证据缺失。
- 不能把当前 Process PATH 整体写回注册表，否则会把 Codex 临时 arg0、bundled runtime 和 AppX 路径持久化。
- 修复顺序应先恢复盘点可信度，再基于新报告逐项请求 HKCU、HKLM、运行时重装、Python/UV、Rust 和删除授权。
- 每个真实动作都需要独立备份、验证和回滚，不得用“开始整理”概括授权。

## 实施前只读基线（2026-07-10）

- inventory：15 个工具可解析、18 个未解析、0 个探测失败、0 个迁移候选、5 个项目本地环境人工审查项。
- migration plan：0 个可计划迁移项。
- stale PATH dry-run：0 个“失效项目本地环境”清理候选；普通缺失 PATH 入口仍有 2 个，不能混同。
- backup retention dry-run：0 个保留规则清理候选；3 个根级人工审查项，共 621.87 MB。
- 10 个项目验证脚本全部通过，但 readiness 语义缺陷不在现有断言覆盖范围内。

## 最终可信基线（2026-07-11）

- inventory 为 schema 3，分别记录 Process、User、Machine PATH；Python launcher/runtime 归属证据可审计。
- readiness 为 schema 3，已消除 Git/Cargo/uv 等位置事实与建议文案矛盾。
- backup retention dry-run 为 production schema 2，`coverageComplete=false`、gap 5、candidate 0；apply manifest 安全门拒绝生成。
- 7 组正式 JSON/Markdown 报告对全部通过 generationId 与源 JSON SHA-256 校验。
- 17 个项目测试、35 个 PowerShell 文件 parser、全分支常规和对抗性评审均通过。
- 本轮未修改 PATH、注册表、runtime 或任何备份源；后续真实环境动作仍需逐项授权。

## 边界

- 本轮可以更新项目内报告和 D 盘证据。
- 不自动移动 `C:\Windows`、Program Files、ProgramData、整个用户目录、服务状态、凭据或项目本地依赖目录。
- 不把笼统的“开始整理”解释为删除 C 盘旧源、修改 PATH 或执行具体迁移项的授权。
