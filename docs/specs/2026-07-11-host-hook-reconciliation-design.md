# Codex 主机钩子 reconciler 设计

本项目用 `scripts/Invoke-CodexHostHookReconciliation.ps1` 检查并收敛 Codex 主机钩子状态。它是唯一当前生产权威，也是显式调用的冷路径维护工具；不注册 watcher、计划任务或新的启动 hook，也不占用每个任务的生命周期热路径。

旧 `New-CodexHookDeploymentPlan.ps1`、`Invoke-CodexHookDeployment.ps1`、`Restore-CodexHookDeployment.ps1` 的 ProductionFull / registration-repair 参数集只为兼容调用者而保留，参数绑定后立即返回 `superseded-by-host-hook-reconciler`，不会加载旧 production runtime、读取 live 状态、生成报告或写入文件。对应 fixture/core 只作为历史算法测试材料，不是生产入口。

## 目标状态

- 受管 `hooks.json` 的用户级 lifecycle hook 注册严格收敛为 manifest 声明的四项：`codex-state-preflight`、`serena-activate`、`serena-cleanup` 和 `serena-reminder`。active config layer 中合法的 inline `[hooks]` 也是有效来源；reconciler 只维护 manifest 定义的受管注册和退役项，不删除合法 inline hooks。省略 `features.hooks` 时遵循官方默认启用；`[features]` 与根级 dotted（含 quoted key）形式的显式关闭、或与废弃别名 `codex_hooks` 冲突时 fail closed。将这两个开关写成 `[features]` 内 dotted descendant，或写成 table / array-table，同样因不可安全解释而拒绝。根级 `features = { ... }` inline table 不属于 reconciler 的安全解释范围，也必须拒绝继续写入。
- Serena 不固定项目，也不根据 MCP 进程 cwd 推断项目。任务需要语义工具时，按当前 `environment_context` 的绝对 workspace root 显式激活。
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
& .\scripts\Invoke-CodexHostHookReconciliation.ps1 -Mode Restore -EvidencePath 'D:\Codex\.codex\run-evidence\host-hook-remediation\<run-id>' -Json
```

`Restore` 必须使用当前 Codex home 固定 evidence root 的绝对直接子目录，并与 `Repair` 共用受管 home 授权；它不把旧 evidence 当作配置或权限策略来源，且不会重建任何退役资源。

结构化结果包含 `schemaVersion`、`mode`、`ok`、`changed`、`driftCount`、`checks` 和 `evidencePath`。`Check` 发现 drift 时仍可能正常退出，因此自动化必须同时判断 `ok` 和 `driftCount`，不能只看进程退出码。

`-CodexHome` 可为只读检查指定 D 盘绝对路径。真实 `Repair` 与 `Restore` 只允许受管 live home；其他目录必须是带固定 marker 的测试 fixture，不能借此放宽写入范围。权限策略或 Serena 配置缺失时，不得从历史 evidence 推断值或执行 live 写入。

## 状态所有权

reconciler 只维护以下状态：

- `config.toml` 中明确列出的 Serena 项目选择参数，以及失效的用户级 hook trust state；manifest `trustedProjects` 所列精确项目根的 trust 会补齐并归一化为 `trusted`。`retiredProjectTrusts` 是结构化 denylist：按大小写不敏感的精确 project 根删除对应普通 table、array table，以及该 table 在 TOML dotted-key 下的全部 descendant；evidence 与 Restore 均不得保留或回流退役 trust，其他 project 根、用户 trust 与未知内容保持不变。`approval_policy`、`sandbox_mode`、`features.hooks`、`unified_exec` 与合法 inline hooks 不属于 reconciler 的写入所有权。就 unified-exec 兼容键而言，provider guard 只清理废弃的 `experimental_use_unified_exec_tool`。
- `hooks.json` 中的用户级 lifecycle hook 注册；
- 明确 allowlist 内的旧 hook implementation；
- 稳定 hook surface；目标 `codex-file-tools.yml` 的写权限，以及其唯一根级 prompt。协调器完整拥有该 prompt block：健康状态必须逐行精确等于唯一 canonical block（mandatory marker、Codex/Serena shell ownership、按当前绝对 workspace 执行 `activate_project` 并以 `get_current_config` 复验）；不健康时只按原始字符偏移替换 prompt body。description、tool lists、其他顶层字段、prompt 外原始字节、混合换行和 sibling context 保持不变；重复/外部 marker、引号或转义 scalar、错误缩进、folded/重复/歧义 prompt 继续 fail closed。

`config.toml` 是 Codex Desktop 可原子替换的 vendor-owned 文件。工具维护其列明字段的语义，但不把该文件或整个 Codex home 的 ACL 当作持久安全边界，也不改写无关 vendor state、Serena sibling context 或其他主机 guard。

## 修复保证

- 所有路径必须位于 D 盘，且受管路径不得穿过 reparse point；受管文件不得是 NTFS hard link。
- TOML 固定由 `D:\Codex\tools\python314-official\python.exe`（ProductVersion 3.14、PSF 签名）及其标准库 `tomllib` 做完整语法验证，再由定向 parser 识别受管 section/key，生成结果也必须在写前复验；输入、输出与进程退出共用 5 秒截止时间。多行 array 或 inline table 内出现形似 table / array-table header 的元素时，定向 parser 无法安全判定其来源语义，必须 fail closed，而不是误作 section；不具该歧义的无关多行容器仍原样保留。runtime 根、必要 DLL 与 `Lib\tomllib` 源文件不得经过 reparse point 或 hard link；`-B` 配合唯一且确认不存在的 D 盘 `pycache_prefix`，强制从已检查源码加载且不生成 bytecode cache。启动器签名不是标准库内容证明，验证器继承现有 `D:\Codex\tools` runtime 的主机信任边界。JSON 在写入前严格解析。Serena context 使用仓库内可审计的受限 YAML 验证器，只接受唯一顶层 mapping、无引号简单 scalar/list、`{}` 空 mapping 和唯一 literal prompt；tab、重复 key、引号、反斜杠转义、未知标点/缩进、anchor/alias/tag/directive/document marker 均 fail closed。生成结果必须再次通过同一验证器与 canonical prompt 精确比较。
- 写入前保存受保护 evidence，随后按 Serena context → `config.toml` → `hooks.json` 的顺序，使用同卷临时文件、原子替换、内容与 ACL 的 CAS 校验完成三资源提交。
- 保存 `config.toml` evidence 前，只结构化剥离 `retiredProjectTrusts` 命中的普通/array table 及 descendants，其他字节不做归一化；因此 evidence 不会成为恢复退役 trust 的旁路。Restore 会在写入任何 live 内容前使用同一 denylist 复核 evidence，发现历史快照仍含退役 trust 即失败关闭，须先经受控 retired project snapshot sanitizer 清理。
- 受控入口固定为 `scripts\Invoke-RetiredProjectSnapshotSanitizer.ps1`：先运行 `-Mode Audit -Json`，仅在 audit 无 blocked 且对 manifest 内每个 retired project 显式传入 `-ConfirmRetiredProject` 时才允许 `-Mode Apply -Json`；它不改写 live `config.toml`，也不保留 retired payload backup。
- 并发替换或文件提交、ACL 加固、legacy 退役中的不安全部分提交不会用旧 snapshot 覆盖较新 active state；可定位 backup 和 manifest 会被保留，状态按 `unsafe-partial` 报告。
- 只有固定 allowlist 内的旧实现可以退役；未知路径与文件内容必须保持不变，其 ACL 可随稳定 hook surface 收紧。
- 退役资源是单向删除项：Restore 不会重建任何已退役的实现、目录或注册。退役删除后的失败保留证据并按 `unsafe-partial` 报告，而不是回写旧 snapshot。
- `Repair` 按 Codex home 获取互斥锁；健康状态再次执行必须返回 `changed = false`。

## 验证

回归测试：

```powershell
& .\tests\Test-CodexHostHookReconciliation.ps1
```

live 终态以 `Check` 返回 `ok = true`、`driftCount = 0` 为准。执行过 `Repair` 后必须立即再次 `Check`，并复跑 `Repair` 验证幂等。Serena 的端到端验收还必须使用 fresh 任务证明激活前为中性状态、显式激活后可以解析当前项目符号；旧任务或仅观察进程日志不能替代这项 canary。
