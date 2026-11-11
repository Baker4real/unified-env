# daily-update 辅助脚本

每日更新用的受管辅助脚本。`<outDir>` 为当次证据目录
(如 `D:\agents\run-evidence\daily-codex-ecosystem-update\<ts>`),脚本不写死时间戳目录。

## 1. gen-ledger-tsv.cjs(只读账本)

```
node D:\agents\projects\统一环境\scripts\daily-update\gen-ledger-tsv.cjs <outDir> [ledgerPath]
```

默认账本 `D:/Codex/.codex/skills/.downloaded-skills-source-state.json`。
输出 `<outDir>\ledger-github-sources.tsv`,并打印行数与状态计数。

## 2. sweep-lsremote.sh(网络只读,约 90 秒)

```
$env:HTTPS_PROXY=$PROXY
& 'C:\Program Files\Git\bin\bash.exe' D:/agents/projects/统一环境/scripts/daily-update/sweep-lsremote.sh <outDir> [prevLsremoteResults.tsv]
```

前置:`<outDir>` 已有 `ledger-github-sources.tsv`。输出 `lsremote-results.tsv`、
`lsremote-errors.log`、`tags-check.tmp`;传入上次结果时另输出 `sweep-diff-output.txt`。
`sweep-exclude.txt` 列出的 repo 键不请求网络,结果行为 `EXCLUDED`。只放非 GitHub
必败源,真实上游失败须查清原因,不得排除。代理由环境变量传入。

## 3. sweep-diff.cjs(纯本地,sweep 传入 prev 时已自动调用)
```
node D:\agents\projects\统一环境\scripts\daily-update\sweep-diff.cjs <prev.tsv> <cur.tsv>
```

## 4. mcp-smoke.cjs(仅 initialize + tools/list)

```
node D:\agents\projects\统一环境\scripts\daily-update\mcp-smoke.cjs <outDir>
```

启动 Serena 与 CodeGraph 的 MCP stdio 服务,写 `<outDir>\mcp-smoke-result.json`。
全部成功退出码 0,否则 1。建议在 `D:\agents\projects\统一环境` 下运行。

## 5. runtime-health.py（更新前后验收）

事务前先按当前版本跑通验收器，激活后按目标版本重跑；每次落独立结果文件。

~~~powershell
python scripts/daily-update/runtime-health.py shells --runtime python --expected-version <精确版本> --output <outDir>/python-shells.json
python scripts/daily-update/runtime-health.py shells --runtime pwsh --expected-version <精确版本> --output <outDir>/pwsh-shells.json
python scripts/daily-update/runtime-health.py shells --runtime git --expected-version <含windows后缀的版本> --output <outDir>/git-shells.json
python scripts/daily-update/runtime-health.py shells --runtime node --aliases node --expected-version <Node版本> --output <outDir>/node-shells.json
python scripts/daily-update/runtime-health.py shells --runtime node --aliases npm npx --expected-version <npm版本> --output <outDir>/npm-shells.json
python scripts/daily-update/runtime-health.py mcp --out-dir <全新MCP证据子目录>
~~~

三 shell 为全新 PowerShell、CMD、Git Bash，PATH 从当前注册表读取。Node 与 npm/npx 版本独立，不能混用目标。空输出、旧版本、超时均失败。子进程隐藏窗口；MCP 模式调用第4项脚本，同时验证退出码、全新结果、两服务 identity、完整 initialize 与非空 tools/list。真实 query 仍按组件合同验收；此工具不证明已有客户端采用新运行时。

## 6. python-update-gate.py（官方选择门）

仅在已获授权的 Python 更新事务中调用。prepare/verify 不安装运行时；备份、兼容性与回滚条件仍是前置。

~~~powershell
$manager = Join-Path (Get-AppxPackage PythonSoftwareFoundation.PythonManager).InstallLocation 'py.exe'
python scripts/daily-update/python-update-gate.py prepare --version <精确稳定版> --manager $manager --proxy $PROXY --out-dir <全新计划目录>
python scripts/daily-update/python-update-gate.py verify --plan <计划目录>/python-update-plan.json
~~~

先确认现役官方包 identity、InstallLocation、包签名状态和实体文件哈希。WindowsApps app execution alias 不能作为可哈希实体，不猜版本目录。包内 exe 的单文件 Authenticode 可能为 NotSigned，不能声称已验证其文件签名，应按已安装 AppX 包身份与完整性验收。既有官方索引快照用 `--index <文件> --index-sha256 <已核实摘要>`；摘要本身不证明来源，调用方须另有官方获取证据。

门禁接受精确 stable 版本、唯一 PythonCore x64 记录、固定官方 archive URL 和 SHA-256。索引只留一个候选且不分页；官方 manager dry-run 必须明确选择目标，exit0 fallback、旧版和未知结构均失败。manager/index 在 dry-run 前后核对哈希。verify 通过后仅在原授权事务中执行精确 `install_argv`，随后仍做三 shell 与依赖验收。

## 6.1 evidence_io.py（当次 run 写入边界）

`RunEvidence(<当次 run 目录>)` 要求目录名是 `<yyyyMMdd-HHmmss>`（允许受管后缀），拒绝 reparse、越界和既有文件。`output_path` 只做路径核验；`write_text_new` / `write_json_new` 以 `x` 模式创建新证据。`daily-update-step.py` 从 spec 路径的 run 祖先推断 receipt 根；spec 不在 run 内时显式传 `--run-directory`。receipt 指向其他 run 时命令不会执行。

## 6.2 python-runtime-transaction.py（授权 apply/rollback）

~~~powershell
python scripts/daily-update/python-runtime-transaction.py plan --config <事务配置.json>
python scripts/daily-update/python-runtime-transaction.py apply --config <事务配置.json>
python scripts/daily-update/python-runtime-transaction.py rollback --config <事务配置.json>
~~~

配置绑定 `run_directory`、唯一 `attempt_id`、旧/新版本、默认/Manager/staged 三棵树、官方 ZIP、backup、gate plan、safe Python，以及可选 `stop_command` / `restore_command` / `manager_config`。`health_imports` 是候选导入集合，plan 只记录现场实际存在的模块，不假定 pandas 等包已安装。

plan 在两棵运行时树备份及逐文件哈希一致后才生成；apply 先执行占用停止命令，再调 gate verify，只运行其精确 `install_argv`。官方 ZIP 的每个运行时 payload 与 staged 文件逐条 SHA-256 对齐，允许新增文件、排除 Scripts 和 site-packages。三 shell 统一调用 `runtime-health.py`，随后检查 stdlib、基线导入和 pip。任何激活后失败都回滚两树并删除仅由新官方包引入的文件；占用恢复命令在 finally 执行。plan 同时绑定除 attempt 外的完整配置 SHA-256，apply/rollback 发现配置漂移会在停止占用前失败。成功、失败和回滚收据均绑定 attempt，不能重放覆盖；后台恢复发生在成功收据之前，恢复失败只留错误收据。回归：`tests/Test-PythonRuntimeTransaction.py`。

## 7. Read-DailyUpdateEvidence.ps1（有界差分）

~~~powershell
& 'D:/agents/projects/统一环境/scripts/daily-update/Read-DailyUpdateEvidence.ps1' -RunDirectory <当次目录> -PreviousRunDirectory <上次目录> -MaxTotalBytes 6000
~~~

只接受 `D:/agents/run-evidence` 下的 scope manifest/checkpoint，核验绑定与哈希后投影变化项和 RESULT 的「需要用户裁决」。开始、恢复、交接时先用此入口，再按变化项读取具体证据；不是重跑组件或重复 stage 的授权。旧收据或证据无法验证时退出非零，按具体文件/章节窄读补齐，不把失败当空清单。预算不足会明示省略。

## 8. 回归与复盘

`node scripts/Run-ManifestTests.cjs --module workstation-operations` 执行模块 fixture，测试已接入现有 manifest CI。retro 维护源在 `modules/skill-supply-chain/overlays/retro/`，现役 skill 经 guarded update 部署；回归为 `python -B tests/Test-RetroTranscriptAudit.py`。复盘区分外层失败、嵌套 reported 非零与 pending/unknown；仅在命令语义已证实时用 `audit --expected-exit <结果行>:<退出码>` 标记预期非零。

## 9. daily-update-step.py（一步一份新收据）

常见 JSON 只读探测与验收经此入口执行。每个 spec 只启动一个进程；PowerShell 分支拼成单次脚本调用，再经过现役 Invoke-CheckedPowerShell 的 Parser/终止错误检查。原生分支禁止 shell 和 agent 执行器，不拼接 shell 字符串。脚本内部的业务完整性仍由其本身及显式谓词负责，不把退出 0 当全面验收。

~~~powershell
python scripts/daily-update/daily-update-step.py run --spec <outDir>/sm-step.json --receipt <outDir>/sm-step-receipt.json
~~~

spec 示例（参数为字典，bool/int/string 保留类型，不放秘密）：

~~~json
{"command_id":"sm-state","kind":"powershell","script":"D:/agents/projects/统一环境/scripts/daily-update/Get-SkillsManagerState.ps1","parameters":{},"required_fields":["process_query_ok","running","processes","lock.status"],"equals":{"process_query_ok":true},"timeout_seconds":60}
~~~

原生 JSON 命令改为 `kind=native` 和 `argv` 字符串数组，例如 runtime-health.py；不与 powershell 的 script/parameters 混用。required_fields 只检查非 null 存在性，false/0 合法；equals 逐字段严格比较类型和值，`ok=false` 不会匹配 true。输出非空且单份 JSON、退出码 0、字段与谓词全部通过才记 ok。字段可用点分路径。receipt 只留 command_id、spec/输出哈希、字节数、退出码、超时和合同结果，不保存命令、原始 stdout/stderr 或配置内容；原始错误需要另走脱敏证据入口。新建收据拒绝覆盖，重试另取文件名，汇总不得把失败收据改成成功。receipt 必须与 spec 推导出的当次 run 一致，跨 run 在执行命令前拒绝；spec 位于其他位置时用 `--run-directory` 显式绑定。此入口只用于同步验收，不负责后台服务生命周期。

SM 探针从文本锁提取 operation/start_time，并列进程名、PID、running 状态；missing/missing-fields/unreadable-or-invalid 必须原样报告，不能把探针成功当锁存在或 SM 正在运行。业务要求锁完整时在 equals 增加 `lock.status=ok`。单步测试中的三项宿主 wrapper 用例在未安装该入口的 CI 上会显式 skip 并注明原因，其余用例照常运行；本机整组运行应无 skip。

## 10. 恢复索引（定位后复用现有 reader）

先完成 scope manifest/checkpoint，显式登记当前与上次目录，不按目录名猜最新。每次 scope/引用证据/RESULT/文档读取状态变化后重建索引；首次创建不传 replace，刷新显式传 `--replace`。索引不是授权或健康证明。

~~~powershell
python scripts/daily-update/daily-update-resume.py index --run-directory <当次目录> --previous-run-directory <上次目录> --document-state <当次目录>/document-reads.json --index-path <当次目录>/resume-index.json
& 'D:/agents/projects/统一环境/scripts/daily-update/Resume-DailyUpdate.ps1' -IndexPath <当次目录>/resume-index.json -MaxTotalBytes 6000
~~~

没有已记录文档状态时省略 document-state。索引绑定 scope/checkpoint/RESULT/引用证据及文档状态哈希，拒绝越界、重解析点、未知 schema 和漂移；漂移时核对具体变化再显式刷新，不能自动吸收。恢复输出复用 Read-DailyUpdateEvidence 的裁决与计数，优先压缩变化项和未完成清单，省略数量明确；预算不足以保留裁决/计数时失败。文档只返回 Read-SessionDocument 状态指针，继续用其同一 StatePath 获得未变文档指针，不再次全文输出。入口不改 LATEST、不重跑组件。

## 有界默认导航与代理摘要

开始日更时只投影目标模块，不全文读取 manifest。代理端口从现场 loopback LISTENING 与配置取证；监听不明确时返回 unknown/ambiguous，不猜端口。此入口不改代理配置；连通性仍用现役 `Test-LoopbackProxy.ps1` 验证真实 HTTP 204。

~~~powershell
python scripts/daily-update/preflight-summary.py module --id workstation-operations
python scripts/daily-update/preflight-summary.py proxy
python scripts/daily-update/preflight-summary.py runtime-command --component npm --expected-version <npm版本>
~~~

返回最多 6000 UTF-8 字节，裁剪明示 `omitted_count`。proxy 只显示 loopback 监听、PID/进程名和脱敏配置一致性，不枚举连接；`ok` 表示端口可唯一确定，`three_faces_consistent` 单独表示 Git、User HTTPS_PROXY 与监听是否一致。runtime-command 返回 argv 数组；npm/npx 固定映射到 `--runtime node --aliases npm npx`，与 Node 分开传 expected version。执行仍使用上文 runtime-health 的三 shell 验收，不用该 recipe 声称已完成验收。

## Kimi 独立回滚事务

正常 Kimi 更新使用 `kimi-runtime-transaction.py`，不再临时编写升级 wrapper 或依赖安装器的 `.bak`。配置为 UTF-8 JSON：

~~~json
{"run_directory":"D:/agents/run-evidence/daily-codex-ecosystem-update/<yyyyMMdd-HHmmss>","executable":"C:/Users/WINDOWS/.kimi-code/bin/kimi.exe","current_version":"<当前精确稳定版>","target_version":"<目标精确稳定版>"}
~~~

~~~powershell
python scripts/daily-update/kimi-runtime-transaction.py plan --config <当次配置.json>
python scripts/daily-update/kimi-runtime-transaction.py apply --config <同一配置.json>
~~~

plan 先校验当前版本，将旧二进制独立保存在当次 D 盘 run 的 `kimi-transaction/old-kimi.exe`，前后 hash 一致后从固定官方 HTTPS 地址直连保存 installer；不执行安装。apply 复验配置、备份、installer 和 live hash，发布 create-only intent，再执行官方安装器（精确允许 code.kimi.com 到 cdn.kimi.com 的官方脚本跳转，保留官方发布物 checksum 检查，设置 KIMI_NO_MODIFY_PATH=1、KIMI_VERSION=目标版本、KIMI_INSTALL_DIR=经核验的 bin 父目录）。成功要求 installation_ok、health_ok、rollback_available 全为 true；已退出但失败的安装恢复原二进制并复验版本/hash。超时或无法证明 installer 终态时返回 manual-review，不能与尚在运行的安装器竞速回滚或重启一次安装。收据拒绝覆盖；失败保留 apply-error，不能用后续成功覆盖。此备份合同不适用于用户明确要求退役删除的 payload。回归：`tests/Test-KimiRuntimeTransaction.py`。

## 退役与批量清理路由

显式退役任务使用 `scripts/verify-component-retirement.py --spec <明确范围.json> --output <D盘新结果.json>`，字段和只读覆盖边界见 `docs/specs/2026-11-11-component-retirement-verification.md`。任一产品、任务、进程、路径、active、链接、Magpie、ledger、临时 policy 或内容扫描条件失败均不返回 retired；查询错误记 unknown。回收站人工项单列 manual_pending。

批量目录删除先用 `scripts/New-SafeCleanupJob.ps1 -TargetPaths <以::连接的明确绝对目标> -JobDirectory <新建空D盘目录>` 按 gate Check 分组并保存 scope/ledger/审核 Plan；授权执行时逐个 job 使用 `Invoke-SafeCleanupJob.ps1 -Mode Run -JobPath <job.json> -ConfirmRun`。首次执行由 Worker 针对不可变基线生成新 Plan 与 intent，避免审核 Plan 在排队时过期；已开始的事务继续绑定原 intent 恢复。失联后先 Status，再 Reconcile/Verify，不用原路径不存在作为完成证据。只准备，不扩大 policy，不自动执行提权。详见 `docs/specs/2026-10-10-safe-cleanup-job.md`。
