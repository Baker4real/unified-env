# Codex 主机钩子 reconciler 设计

本项目用 `scripts/Invoke-CodexHostHookReconciliation.ps1` 检查并收敛 Codex 主机钩子状态。它是唯一当前生产权威，也是显式调用的冷路径维护工具；不注册 watcher、计划任务或新的启动 hook，也不占用每个任务的生命周期热路径。

旧 `New-CodexHookDeploymentPlan.ps1`、`Invoke-CodexHookDeployment.ps1`、`Restore-CodexHookDeployment.ps1` 的 ProductionFull / registration-repair 参数集只为兼容调用者而保留，参数绑定后立即返回 `superseded-by-host-hook-reconciler`，不会加载旧 production runtime、读取 live 状态、生成报告或写入文件。对应 fixture/core 只作为历史算法测试材料，不是生产入口。

## 目标状态

- `hooks.json` 中的用户级自定义 lifecycle hook 注册为空；`features.hooks` 仍保持开启，供真正需要的项目级或 skill 级 hook 使用。
- Serena 不固定项目，也不根据 MCP 进程 cwd 推断项目。任务需要语义工具时，按当前 `environment_context` 的绝对 workspace root 显式激活。
- 正式权限默认值保持 `approval_policy = "never"`、`sandbox_mode = "danger-full-access"`，并保持 `features.unified_exec` 开启。
- Projectless 路径、线程数据库、heartbeat、Store、IFEO、代理和其他 Windows guard 不由本 reconciler 接管。

## 公共接口

只读检查：

从仓库根目录使用 PowerShell 7.6+ 运行：

```powershell
& .\scripts\Invoke-CodexHostHookReconciliation.ps1 -Mode Check -Json
```

显式修复：

```powershell
& .\scripts\Invoke-CodexHostHookReconciliation.ps1 -Mode Repair -Json
```

结构化结果包含 `schemaVersion`、`mode`、`ok`、`changed`、`driftCount`、`checks` 和 `evidencePath`。`Check` 发现 drift 时仍可能正常退出，因此自动化必须同时判断 `ok` 和 `driftCount`，不能只看进程退出码。

`-CodexHome` 可为只读检查指定 D 盘绝对路径。真实 `Repair` 只允许受管 live home；其他目录必须是带固定 marker 的测试 fixture，不能借此放宽写入范围。

## 状态所有权

reconciler 只维护以下状态：

- `config.toml` 中的 Serena 项目选择参数、正式权限默认值、`hooks` 与 `unified_exec` feature，以及失效的用户级 hook trust state；
- `hooks.json` 中的用户级 lifecycle hook 注册；
- 明确 allowlist 内的旧 hook implementation；
- 稳定 hook surface 与目标 `codex-file-tools.yml` 文件的写权限。

`config.toml` 是 Codex Desktop 可原子替换的 vendor-owned 文件。工具维护其列明字段的语义，但不把该文件或整个 Codex home 的 ACL 当作持久安全边界，也不改写无关 vendor state、Serena sibling context 或其他主机 guard。

## 修复保证

- 所有路径必须位于 D 盘，且受管路径不得穿过 reparse point；受管文件不得是 NTFS hard link。
- TOML 固定由 `D:\Codex\tools\python314-official\python.exe`（ProductVersion 3.14、PSF 签名）及其标准库 `tomllib` 做完整语法验证，再由定向 parser 识别受管 section/key，生成结果也必须在写前复验；输入、输出与进程退出共用 5 秒截止时间。runtime 根、必要 DLL 与 `Lib\tomllib` 源文件不得经过 reparse point 或 hard link；`-B` 配合唯一且确认不存在的 D 盘 `pycache_prefix`，强制从已检查源码加载且不生成 bytecode cache。启动器签名不是标准库内容证明，验证器继承现有 `D:\Codex\tools` runtime 的主机信任边界。JSON 在写入前严格解析。Serena context 定向验证唯一根级 prompt 及完整激活契约。验证器缺失、重复或语义等价的关键 section/key、歧义 prompt、越界 context 都会 fail closed。
- 写入前保存受保护 evidence，随后使用同卷临时文件、原子替换、内容与 ACL 的 CAS 校验完成提交。
- 并发替换或文件提交、ACL 加固、legacy 退役中的不安全部分提交不会用旧 snapshot 覆盖较新 active state；可定位 backup 和 manifest 会被保留，状态按 `unsafe-partial` 报告。
- 只有固定 allowlist 内的旧实现可以退役；未知路径与文件内容必须保持不变，其 ACL 可随稳定 hook surface 收紧。
- `Repair` 按 Codex home 获取互斥锁；健康状态再次执行必须返回 `changed = false`。

## 验证

回归测试：

```powershell
& .\tests\Test-CodexHostHookReconciliation.ps1
```

live 终态以 `Check` 返回 `ok = true`、`driftCount = 0` 为准。执行过 `Repair` 后必须立即再次 `Check`，并复跑 `Repair` 验证幂等。Serena 的端到端验收还必须使用 fresh 任务证明激活前为中性状态、显式激活后可以解析当前项目符号；旧任务或仅观察进程日志不能替代这项 canary。
