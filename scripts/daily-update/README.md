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

## 7. compare-cc-switch-migration.py（快照验收）

使用受保护的一致 SQLite 前后快照和升级前审查的 policy，逐条验证原 provider/MCP、允许新增与 schema。合同及 CLI 见 `docs/automation/cc-switch-migration-check.md`。不能直接传 live DB，不能从 after 自动生成允许规则；本工具不代替备份、程序签名、其他表或 host Check。

## 8. Read-DailyUpdateEvidence.ps1（有界差分）

~~~powershell
pwsh -NoProfile -File scripts/daily-update/Read-DailyUpdateEvidence.ps1 -RunDirectory <当次目录> -PreviousRunDirectory <上次目录> -MaxTotalBytes 6000
~~~

只接受 `D:/agents/run-evidence` 下的 scope manifest/checkpoint，核验绑定与哈希后投影变化项和 RESULT 的「需要用户裁决」。开始、恢复、交接时先用此入口，再按变化项读取具体证据；不是重跑组件或重复 stage 的授权。旧收据或证据无法验证时退出非零，按具体文件/章节窄读补齐，不把失败当空清单。预算不足会明示省略。

## 9. 回归与复盘

`node scripts/Run-ManifestTests.cjs --module workstation-operations` 执行模块 fixture，测试已接入现有 manifest CI。retro 维护源在 `modules/skill-supply-chain/overlays/retro/`，现役 skill 经 guarded update 部署；回归为 `python -B tests/Test-RetroTranscriptAudit.py`。复盘区分外层失败、嵌套 reported 非零与 pending/unknown；仅在命令语义已证实时用 `audit --expected-exit <结果行>:<退出码>` 标记预期非零。
