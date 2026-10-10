---
type: reference
title: Codex 主机钩子 reconciler 设计
tags: [设计, Codex, hooks]
intent: 说明 Codex 主机钩子 reconciler 的目标状态和安全边界
---

# Codex 主机钩子 reconciler 设计

本项目用 `scripts/Invoke-CodexHostHookReconciliation.ps1` 检查并收敛 Codex 主机钩子状态。它是唯一当前生产权威，也是显式调用的冷路径维护工具；不注册 watcher、计划任务或新的启动 hook，也不占用每个任务的生命周期热路径。

旧 `New-CodexHookDeploymentPlan.ps1`、`Invoke-CodexHookDeployment.ps1`、`Restore-CodexHookDeployment.ps1` 的 ProductionFull / registration-repair 参数集只为兼容调用者而保留，参数绑定后立即返回 `superseded-by-host-hook-reconciler`，不会加载旧 production runtime、读取 live 状态、生成报告或写入文件。对应 fixture/core 只作为历史算法测试材料，不是生产入口。

## 目标状态

- 受管 `hooks.json` 的用户级 lifecycle hook 注册严格收敛为 manifest 声明的四项：`codex-state-preflight`、`serena-activate`、`serena-cleanup` 和 `serena-reminder`。active config layer 中合法的 inline `[hooks]` 也是有效来源；reconciler 只维护 manifest 定义的受管注册和退役项，不删除合法 inline hooks。`features.hooks` 等开关属于 `config.toml` 归属域：自 2026-09-06 config reconciliation 退役后，reconciler 不再读取或改写 `config.toml`，hook feature 开关完全由官方 runtime 语义决定。
- 四个生产 `.cmd` wrapper 统一通过官方 `pythonw.exe` 和受管 `managed/codex-hooks/hooks/lib/hidden-console-launcher.py` 启动最终 `pwsh.exe` / `python.exe`。launcher 对最终 console 程序显式使用 `CREATE_NO_WINDOW`；外层 Node 的 `windowsHide` 或父进程的 `CreateNoWindow` 只约束直接子进程，不能穿过 `.cmd` 自动约束孙进程。
- hidden launcher 复制当前进程有效的 Windows stdin/stdout/stderr 句柄，缺失流才定向到 `DEVNULL`，并原样返回最终子进程退出码。窗口隐藏不得破坏 hook JSON 协议流、错误流或失败状态。
- wrapper 依赖校验将 `%~dp0<relative>` 只相对该 wrapper 的实际目录安全展开；其他 `%` 变量、绝对替代、父目录逃逸或无法证明位于 wrapper 目录内的 token 均不得匹配。三个 Serena wrapper 的最终 `-Mode` 分别固定为 `Activation`、`Cleanup`、`Reminder`，不能因共用同一 PowerShell implementation 而互相冒充。
- Serena 不固定项目，也不根据 MCP 进程 cwd 推断项目。任务需要语义工具时，按当前 `environment_context` 的绝对 workspace root 显式激活。
- Serena activation 提示仅面向需要 symbol/LSP 导航的任务；检查配置后只汇报活动项目与 readiness，配置漂移排障时才展开详情。Reminder 对静态、显式数据文件路径的只读查询保持静默：识别 Markdown、文本、日志、JSON/JSONL、CSV/TSV 等后缀，以及受限的 `rg`、`grep`、`Get-Content`、`Select-String` 和数字裁剪 `Select-Object` 管线。分类检查实际操作数，不采信 description、查询模式或 session ID；目录搜索、源码路径、动态表达式、重定向及未知选项继续走原 reminder。该豁免只控制语义导航提醒，不授予 shell 权限，也不覆盖更高优先级指令。
- `approval_policy`、`sandbox_mode`、`features.hooks` 与 `unified_exec` 属于用户或受管策略边界，reconciler 不推断缺失值也不强写它们。官方默认 `hooks=true`；Windows 上省略 `unified_exec` 时默认关闭。
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

受 evidence 约束的恢复（仅在已明确授权时）：

```powershell
& .\scripts\Invoke-CodexHostHookReconciliation.ps1 -Mode Restore -EvidencePath 'D:\agents\run-evidence\host-hook-remediation\<run-id>' -Json
```

`Restore` 必须使用当前 Codex home 固定 evidence root 的绝对直接子目录，并与 `Repair` 共用受管 home 授权；它不把旧 evidence 当作配置或权限策略来源，且不会重建任何退役资源。

结构化结果包含 `schemaVersion`、`mode`、`ok`、`changed`、`driftCount`、`checks` 和 `evidencePath`。`Check` 发现 drift 时仍可能正常退出，因此自动化必须同时判断 `ok` 和 `driftCount`，不能只看进程退出码。

`-CodexHome` 可为只读检查指定 D 盘绝对路径。真实 `Repair` 与 `Restore` 只允许受管 live home；其他目录必须是带固定 marker 的测试 fixture，不能借此放宽写入范围。权限策略或 Serena 配置缺失时，不得从历史 evidence 推断值或执行 live 写入。

## 状态所有权

reconciler 只维护以下状态：

- `hooks.json` 中的用户级 lifecycle hook 注册；
- 明确 allowlist 内的旧 hook implementation；
- 稳定 hook surface，包括四个生产 wrapper 与 `hooks/lib/hidden-console-launcher.py`；生产 manifest 必须把 launcher 纳入固定文件闭包、hash 检查和部署。目标 `codex-file-tools.yml` 的写权限及其唯一根级 prompt 同样受管。协调器完整拥有该 prompt block：健康状态必须逐行精确等于唯一 canonical block（mandatory marker、Codex/Serena shell ownership、按当前绝对 workspace 执行 `activate_project` 并以 `get_current_config` 复验）；不健康时只按原始字符偏移替换 prompt body。description、tool lists、其他顶层字段、prompt 外原始字节、混合换行和 sibling context 保持不变；重复/外部 marker、引号或转义 scalar、错误缩进、folded/重复/歧义 prompt 继续 fail closed。

`config.toml` 是 Codex Desktop 可原子替换的 vendor-owned 文件。

## config reconciliation 退役（2026-09-06）

用户裁决退役 reconciler 的 `config` 检查与 `config.toml` 语义收敛：根因是 Codex Desktop 26.901 / codex CLI 0.153.x 起把 hook 注册的 `trusted_hash` 运行态持久化进 `config.toml [hooks.state]`，本地剥离策略与 vendor 运行时形成每日重写拉锯。退役后：

- reconciler 不再读取、规范化或改写 `config.toml`（Serena MCP 接线由官方 26.825+ 形态自管；`trustedProjects`/`retiredProjectTrusts` 清单继续供退役项目清理脚本族使用，但不再驱动 config 写入）。
- Check 不再有 `config` 检查项；Repair 的资源提交序收敛为 Serena context → `hooks.json` 两资源；evidence 与 manifest 不再快照 `config.toml`。
- Restore 对 committedResources 含 `config.toml` 的历史 evidence 明确 fail closed（`config.toml reconciliation 已退役`），不做 config 恢复；退役为单向删除项，Restore 不会重建。
- `[hooks.state]` vendor 运行态保持原样，不再被清理。

## 修复保证

- 所有路径必须位于 D 盘，且受管路径不得穿过 reparse point；受管文件不得是 NTFS hard link。
- TOML 固定由 `D:\Codex\tools\python314-official\python.exe`（ProductVersion 3.14、PSF 签名）及其标准库 `tomllib` 做完整语法验证，再由定向 parser 识别受管 section/key，生成结果也必须在写前复验；输入、输出与进程退出共用 5 秒截止时间。多行 array 或 inline table 内出现形似 table / array-table header 的元素时，定向 parser 无法安全判定其来源语义，必须 fail closed，而不是误作 section；不具该歧义的无关多行容器仍原样保留。runtime 根、必要 DLL 与 `Lib\tomllib` 源文件不得经过 reparse point 或 hard link；`-B` 配合唯一且确认不存在的 D 盘 `pycache_prefix`，强制从已检查源码加载且不生成 bytecode cache。启动器签名不是标准库内容证明，验证器继承现有 `D:\Codex\tools` runtime 的主机信任边界。JSON 在写入前严格解析。Serena context 使用仓库内可审计的受限 YAML 验证器，只接受唯一顶层 mapping、无引号简单 scalar/list、`{}` 空 mapping 和唯一 literal prompt；tab、重复 key、引号、反斜杠转义、未知标点/缩进、anchor/alias/tag/directive/document marker 均 fail closed。生成结果必须再次通过同一验证器与 canonical prompt 精确比较。
- 写入前保存受保护 evidence，随后按 Serena context → `hooks.json` 的顺序，使用同卷临时文件、原子替换、内容与 ACL 的 CAS 校验完成两资源提交。
- 历史 config evidence 与退役 trust 的清洗合同随 config reconciliation 一并退役；`scripts\Invoke-RetiredProjectSnapshotSanitizer.ps1` 仍是历史快照的受控清理入口（`-Mode Audit -Json` 后按 `-ConfirmRetiredProject` 显式确认才 `-Mode Apply -Json`），但不再由 reconciler 的 evidence/Restore 流程触发。
- 并发替换或文件提交、ACL 加固、legacy 退役中的不安全部分提交不会用旧 snapshot 覆盖较新 active state；可定位 backup 和 manifest 会被保留，状态按 `unsafe-partial` 报告。
- 只有固定 allowlist 内的旧实现可以退役；未知路径与文件内容必须保持不变，其 ACL 可随稳定 hook surface 收紧。
- 退役资源是单向删除项：Restore 不会重建任何已退役的实现、目录或注册。退役删除后的失败保留证据并按 `unsafe-partial` 报告，而不是回写旧 snapshot。
- `Repair` 按 Codex home 获取互斥锁；健康状态再次执行必须返回 `changed = false`。
- 生产 wrapper 的最终 PowerShell/Python 子进程必须满足 `GetConsoleWindow() == 0`，同时保持 stdin/stdout、真实退出码和 stderr 可观察；只检查外层 runner 或 `pythonw.exe` 不构成无窗口验收。

## 验证

回归测试：

```powershell
& .\tests\Test-HiddenConsoleHookLauncher.ps1
& .\tests\Test-CodexHostHookReconciliation.ps1
```

hidden launcher 回归必须让最终 PowerShell/Python 子进程自行读取 `GetConsoleWindow()`，严格断言句柄为 `0`，并同时覆盖 stdin/stdout 与非零退出码。live 终态以 `Check` 返回 `ok = true`、`driftCount = 0` 为准。执行过 `Repair` 后必须立即再次 `Check`，并复跑 `Repair` 验证幂等。Serena 的端到端验收还必须使用 fresh 任务证明激活前为中性状态、显式激活后可以解析当前项目符号；旧任务或仅观察进程日志不能替代这项 canary。
