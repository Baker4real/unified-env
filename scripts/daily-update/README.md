# daily-update 辅助脚本

每日更新用的受管辅助脚本。`<outDir>` 为当次证据目录
(如 `D:\agents\run-evidence\daily-codex-ecosystem-update\<ts>`),脚本不写死时间戳目录。

## 更新入口与收尾（默认路径）

更新按现役包 identity 选入口：Store 产品使用下方 `store-update-gate.py`；需要管理员权限的已有 PowerShell 事务通过 `Invoke-ElevatedUpdate.ps1` 绑定显式阶段。官方客户端、运行时或随附插件刷新后执行 `post-update-closeout.py`，健康状态只读；检测到缺口且已有修复授权时才用 repair。审计结果统一由 `report-summary.py collect` 保存完整证据、返回有界摘要。各入口不创建新的更新授权、不启动 GUI，不卸载现役组件。

### Microsoft Store 身份预检

`store-update-gate.py prepare --config <当次.json>` 核对微软官方 Store manifest 的产品 ID、包系列、x64、user 和 msstore。Codex 另读 Store 产品事件、AppX 暂存事件及 Windows 的实际暂存路径和 Store 来源。记录新版的 `stage_record` 后才能走精确注册分支。`occupied_record` 存在时记录此前的 `0x80073D02`。暂无可注册暂存时走原有 WinGet `msstore` 入口，发现已知新版仍待注册时保持人工核查。主应用缺失时，已获恢复授权后显式选择 `install`。

配置：
~~~json
{"run_directory":"D:/agents/run-evidence/daily-codex-ecosystem-update/<yyyyMMdd-HHmmss>","product_id":"9PLM9XGG6VKS","source":"msstore","package_family":"OpenAI.Codex_2p2nqsd0c76g0","operation":"upgrade","rollback_archive":"store-rollback/ChatGPT-x64-<旧版本>.msix"}
~~~

~~~powershell
python scripts/daily-update/store-update-gate.py prepare --config <当次.json>
python scripts/daily-update/store-update-gate.py apply --config <同一当次.json>
~~~

Codex 升级前将独立取得的旧版官方 x64 MSIX 保存在当次目录。`prepare` 比对归档签名、包身份及已安装旧版的 manifest、块映射、包签名、主程序。`apply_ready: true` 才可应用。`apply` 重验当次计划和归档 SHA-256，使用 `Add-AppxPackage -MainPackage <精确包名> -Register` 注册已证实的暂存包。精确服务和已知扩展宿主会暂时退出。发现其他应用进程时保留人工核查。

`installation_ok` 记录部署和注册观察。Codex 还须通过装载签名、沙箱服务镜像、实际插件采用及受管菜单和闭包验收。`official-client-refresh-pending` 退出 `2`，保留本次 Apply 收据，等待用户启动官方客户端。用新的回执名续验，避免重放安装。

~~~powershell
python -B scripts/daily-update/store-update-gate.py verify --config <同一当次.json> --receipt store-update/verify-after-client.json
python -B scripts/daily-update/codex-store-plugins.py --expected-appx-version <已注册版本>
~~~

独立插件探针为只读。`codex-plugins` 发布单位绑定已检验的 `verified` 版本明细和健康 `post-refresh` 收据。新流程可绑定同时包含这两项的 Store Apply 或 Verify 回执。修复失败并获准回退时，用 `store-update-gate.py rollback --config <同一当次.json>` 恢复旧注册包。保留 Apply 和 Rollback 的各自收据。另行核对应用配置中的版本化路径，以及回退后的客户端和插件行为。

### HTTP 发布包元数据

检查发布包长度、时间或摘要型 ETag 时使用 `python -B scripts/daily-update/http-metadata.py <公开无参数URL>`。默认遵循本机代理，显式直连加 `--direct`。输出只含 HTTP 状态码和通过格式检查的长度、UTC 时间、32 或 64 位十六进制 ETag。发生重定向或 HTTP 错误时只记录状态码，其他网络失败只记录固定错误码。包身份由请求前确定的官方产品和版本绑定，归档仍须独立验签。

### 提权前阶段合同

在现有单步 spec 增加 `"phase":"Apply"`，`parameters.Mode` 必须显式同值。Prepare/Apply/Rollback 是执行阶段，不接受缺省模式；业务 JSON 也必须返回同一 phase。提权 Apply/Rollback 还必须在 equals 固定 `ok=true`、目标 `version` 与成功 `status`，例如：
~~~json
{"command_id":"runtime-apply","kind":"powershell","script":"D:/authorized/update.ps1","parameters":{"Mode":"Apply"},"phase":"Apply","equals":{"ok":true,"status":"activated","version":"<精确目标版本>"},"timeout_seconds":180}
~~~

~~~powershell
pwsh -NoProfile -File scripts/daily-update/Invoke-ElevatedUpdate.ps1 -Mode Validate -Spec <当次spec绝对路径> -Receipt <当次新收据绝对路径>
pwsh -NoProfile -File scripts/daily-update/Invoke-ElevatedUpdate.ps1 -Mode Launch -Spec <同一spec> -Receipt <同一新收据> -ConfirmApply
~~~

Validate 不运行更新、不弹 UAC：校验阶段、参数名/必填参数/静态参数集/ValidateSet/标量类型、业务谓词、物理当次收据路径及所有生命周期 sidecar 均未使用。动态参数无法静态验证时拒绝。Launch 仅在明确提权授权后调用，先预留 intent/结果文件，再启动单个隐藏 Worker；Worker 复核管理员身份及 spec/脚本 SHA-256，实际执行前再核验，拒绝等待 UAC 期间的修改。`launched-not-yet-verified` 仅证明已启动；结束须收据 ok、目标 phase/version/status 和对应 PID 退出都可证明。启动后记录异常仍返回 PID 和已启动状态，不能说 rejected。这里只编排已存在事务，不替代其备份、验证和回滚。

### 官方刷新后的受管修复

~~~powershell
python scripts/daily-update/post-update-closeout.py check --run-directory <当次目录>
python scripts/daily-update/post-update-closeout.py repair --run-directory <全新修复目录>
~~~

check 仅调用现有 system provenance status、菜单/closure/catalog 审计；证据以 create-only 写入 post-refresh，健康状态不改 active。repair 使用已有授权，按已证实状态依次 preserve-official → system-only 菜单 dry-run/apply → 来源计划 → guarded dry-run/apply → skill-creator 兼容 overlay → 最终菜单、closure、catalog、来源状态。所有 active/SOURCE/ledger 写入由原 wrapper 执行，不执行工具返回的可读 next 命令串。已有中文化但无官方原文、部分缺来源、未知状态或身份警告一律 manual-review，保留证据；新英文缺 exact 译文时走既有补译流程后在新 run 重试。最终同时要求退出码与业务状态通过，不能用先前 healthy 快照代替最后一次写后的验收。

### 审计摘要默认出口

~~~powershell
python scripts/daily-update/report-summary.py collect --kind menu --run-directory <当次目录> --output menu.json
python scripts/daily-update/report-summary.py collect --kind closure --run-directory <当次目录> --output closure.json
python scripts/daily-update/report-summary.py collect --kind catalog --run-directory <当次目录> --output catalog.json
python scripts/daily-update/report-summary.py read --kind menu --input <完整menu.json> --max-bytes 1600
~~~

完整 JSON 留在新证据文件，stdout 默认只含状态/计数、最多八个唯一文件路径、omitted_count、来源字节数与 SHA-256，总预算最多 6000 UTF-8 字节。描述正文不回显；异常 schema 或未知状态拒绝，不把任意上游字符串当状态输出。发现问题仍非零退出。不可覆盖旧报告；缩小来源后再读需要人工判断的条目，不全文注入长报告。

### 包签名与桌面快捷方式

~~~powershell
pwsh -NoProfile -File scripts/Test-OfficialPackageSignature.ps1 -Channel StoreMain -AsJson
pwsh -NoProfile -File scripts/Test-OfficialPackageSignature.ps1 -Channel PrimaryRuntime -AsJson
pwsh -NoProfile -File scripts/New-MsixDesktopShortcut.ps1 -PackageName OpenAI.Codex -PackageFamilyName OpenAI.Codex_2p2nqsd0c76g0 -ApplicationId App -ShortcutPath D:/Desktop/Codex.lnk -IconPath D:/Codex/.codex/host-assets/shortcuts/Codex.ico
~~~

StoreMain 保持主包 Store identity；PrimaryRuntime 要求对应 Developer 分发 identity、OpenAI signer、有效 CMS、绑定的 RFC3161 时间戳以及签名时两条可信链。只读/离线验签不检查撤销或重算包载荷 digest，输出明确标注范围；当前证书过期但可信签名时有效不误判。测试专用 supplied-evidence 的根证书与时钟覆盖不能从 live 参数集进入。

快捷方式默认 Plan，只读已注册健康 Store 包 manifest 与官方 targetsize PNG；Apply 显式写入 D 盘 .lnk/.ico 并保存精确备份，要求包含 256 像素素材，以原尺寸 DIB 帧生成，不放大 EXE 默认小图标。已存在链接必须是同一 AppsFolder identity，且只改 IconLocation；未知目标拒绝，失败按原始字节回滚。仅通知该项 Shell 刷新，不启动应用、不重启 Explorer、不清缓存。CLI 无 fixture/provider 绕过。回归验证真正的 Windows Shell 渲染。无需将这些规则复制到全局 AGENTS.md。

## 1. gen-ledger-tsv.cjs(只读账本)

```
node D:\agents\projects\统一环境\scripts\daily-update\gen-ledger-tsv.cjs <outDir> [ledgerPath]
```

默认账本 `D:/Codex/.codex/skills/.downloaded-skills-source-state.json`。
从 `sources` 导出现役来源，排除已标为 `deleted-by-user` 的来源和没有现役技能的显式空组。`deleted` 历史只用于统计。输出 `<outDir>\ledger-github-sources.tsv`，并打印行数与状态计数。每次执行网络扫描前在本次目录重新生成 TSV。

## 2. sweep-lsremote.sh(网络只读,约 90 秒)

```
$env:HTTPS_PROXY=$PROXY
& 'C:\Program Files\Git\bin\bash.exe' D:/agents/projects/统一环境/scripts/daily-update/sweep-lsremote.sh <outDir> [prevLsremoteResults.tsv]
```

前置:`<outDir>` 已有 `ledger-github-sources.tsv`。输出 `lsremote-results.tsv`、
`lsremote-errors.log`、`tags-check.tmp`;传入上次结果时另输出 `sweep-diff-output.txt`。
`sweep-exclude.txt` 列出的 repo 键不请求网络，结果行为 `EXCLUDED`。只放非 GitHub
必败源，真实上游失败须查清原因，不得排除。扫描器在联网前拒绝列数错误或含退役状态的 TSV。收到 `regenerate ledger-github-sources.tsv` 时重新生成当次输入。代理由环境变量传入。

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

没有已记录文档状态时省略 `--document-state`。索引绑定 scope、checkpoint、RESULT、证据引用和文档状态哈希。核对证据漂移后显式刷新索引。恢复输出含 `run_status` 和 `checkpoint_conflict`，以及变化项、未完成清单和裁决。按 `run_status` 判断整体结果，按 `checkpoint_conflict` 定位范围与检查点的冲突。

从第一次查询总手册或技能指引开始，给 `Read-SessionDocument.ps1` 传同一个 `<当次目录>/document-reads.json` 和任务需要的范围。

~~~powershell
& 'D:/Codex/.codex/scripts/Read-SessionDocument.ps1' -LiteralPath 'D:/Codex/.codex/docs/agent-guidance/skill-operations.md' -StatePath '<当次目录>/document-reads.json' -MarkdownSection '新装共享 skill'
~~~

恢复时沿用索引返回的 StatePath 和章节选择。确实缺少正文时传 `-Refresh` 读取所需范围。

## 有界导航、工作树与代理摘要

开始日更时只投影目标模块，不全文读取 manifest。代理端口从现场 loopback LISTENING 与配置取证；监听不明确时返回 unknown/ambiguous，不猜端口。此入口不改代理配置；连通性仍用现役 `Test-LoopbackProxy.ps1` 验证真实 HTTP 204。

~~~powershell
python scripts/daily-update/preflight-summary.py module --id workstation-operations
python scripts/daily-update/preflight-summary.py proxy
python scripts/daily-update/preflight-summary.py worktree --repo D:/agents/skills-manager/skills --run-directory <当次目录> --started-at <带时区的实际开始时间>
python scripts/daily-update/preflight-summary.py runtime-command --component npm --expected-version <npm版本>
~~~

返回最多 6000 UTF-8 字节，裁剪明示 `omitted_count`。proxy 只显示 loopback 监听、PID/进程名和脱敏配置一致性，不枚举连接；`ok` 表示端口可唯一确定，`three_faces_consistent` 单独表示 Git、User HTTPS_PROXY 与监听是否一致。runtime-command 返回 argv 数组；npm/npx 固定映射到 `--runtime node --aliases npm npx`，与 Node 分开传 expected version。执行仍使用上文 runtime-health 的三 shell 验收，不用该 recipe 声称已完成验收。

`worktree` 输出变更分类计数、代表路径及 `dirty_age_gate_failed`。保存摘要作为当次前置验收 JSON。`skills-worktree.porcelain.z` 保留 Git 的原始 NUL 分隔清单，摘要记录文件 SHA-256。恢复时读取已登记的摘要。同一运行目录的原始清单采用首次写入。

## 当日成功结果发布

完成最后一项验收及 `RESULT.md` 后，登记 `scope-manifest.json`、`scope-checkpoint.json` 和最新的恢复索引。每个 `processed` 单位在 `evidence` 中列出本次相对路径，在 `checks` 中列出该单位适用的业务谓词。两种检查可按单位组合。

~~~json
{"status":"processed","evidence":["git-before.json","health-step.json","health-spec.json"],"checks":[{"path":"git-before.json","equals":{"ok":true,"dirty_age_gate_failed":false}},{"path":"health-step.json","spec":"health-spec.json"}]}
~~~

单步 spec 的 `equals` 包含 `ok: true` 和该事务所需的版本、状态等谓词。新装共享技能保留各阶段收据，并核验 `deliver` 的 `ok: true` 和 `status: "distributed"`。已分发技能的同名 guarded 更新核验 `verify` 的 `ok: true`、`status: "verified"` 和 `guarded_operation: "update"`。待核查的 Magpie 写入仍阻塞发布。检查点使用 `finalize_schema_version: 1`，记录时区明确的实际 `completed_at`、`scope_manifest_sha256`、`scope_total`、`status` 和全部五项计数（`processed`、`failed`、`pending`、`skipped`、`running`）。只有稳定位于已核验 scope 内的可跳过项记录 `skipped`。出现失败的硬门槛时，在对应单位和检查点保持 `failed`。

~~~powershell
python -B scripts/daily-update/finalize-run.py --run-directory <当次目录> --index-path <当次目录>/resume-index.json
~~~

发布命令复核索引绑定、各单位证据和检查点状态。Asia/Taipei 当天第一份通过验收的 `RESULT.md` 原子发布为 `LATEST.md`。同日后续成功返回 `already-published`。旧格式的 `LATEST.md` 首次接管时用 `--legacy-latest-run-directory <原发布运行目录>` 指定内容匹配的成功收据。收到 `same-day-publication-pending` 时，用已登记的当次目录恢复发布。保留待发布的 RESULT 原件，恢复索引可在核对证据后刷新。

## 逐项暂存技能候选

使用已有本地克隆和精确 Git 提交。为一个技能在当次证据目录保存配置。

~~~json
{"run_directory":"D:/agents/run-evidence/daily-codex-ecosystem-update/<ts>","repository":"D:/path/to/upstream-clone","active_root":"D:/agents/skills-manager/skills","name":"<skill>","mode":"update","upstream_path":"skills/<skill>","old_commit":"<精确旧提交>","new_commit":"<精确新提交>"}
~~~

~~~powershell
python -B scripts/daily-update/stage-skill-candidates.py stage --config <当次单技能配置>
python -B scripts/daily-update/stage-skill-candidates.py verify --config <同一配置>
~~~

新安装用 `mode: "install"` 和 `old_commit: null`。从仓库根提取时用 `upstream_path: "."`。每项写 `skills/staging/<skill>/receipt.json`，记录上游提交、当前 active 载荷和候选哈希。`stage` 可复用校验通过的候选，`verify` 只读。无完成收据时从新 attempt 暂存该项。遇到合并冲突或哈希漂移时记录对应阻塞。

调整 overlay 时在当次证据目录内创建独立审阅副本。生成 guarded decision 后、激活前，使用 `verify --config <原配置> --reviewed-candidate <审阅副本绝对路径>`。比对返回的 `candidate_tree_sha256` 和 `skill_md_sha256` 与 decision 的 `candidate_integrity`。二者对应同一副本后，让 guarded wrapper 以该份 decision 复验并激活，显式指定 `--name <skill>`。`candidate-line-ending-crlf` 指向相对于已绑定上游新增 CRLF 的文本。修复审阅副本后重新生成指纹，保留上游原有 CRLF。原暂存和收据均作为审阅基线。

## 共享技能分发

对 guarded wrapper 新安装成功的单个技能使用 `shared-skill-delivery.py`。每次动作都指定同一事务、目标预设和调用策略，写一份新的当次收据。

~~~powershell
python -B scripts/daily-update/shared-skill-delivery.py register --run-directory <当次目录> --receipt delivery/<skill>-dsh.json --transaction-manifest <成功事务manifest绝对路径> --name <skill> --preset cordis --cwd <使用工作区> --model-invocable no --user-invocable yes --like <已采用的同源技能>
python -B scripts/daily-update/shared-skill-delivery.py deliver --run-directory <当次目录> --receipt delivery/<skill>-hosts.json --transaction-manifest <同一manifest> --name <skill> --preset cordis --cwd <使用工作区> --model-invocable no --user-invocable yes --like <同一技能>
~~~

示例采用手动调用。按该候选的已审阅策略填写两项调用标志。用户指定宿主时，用 `--agents 'dsh,<宿主列表>'` 代替 `--like`（PowerShell 逗号列表须加单引号）。本机受管入口支持 `dsh`、`claude`、`claude-desktop`、`codex`、`kimi` 和 `antigravity`。`register` 首轮登记 `dsh`，`deliver` 在分发前再实测正文加载和调用策略，`verify` 只读核验已经分发的同一载荷。在失败收据中查看阶段和原因；只有排除需人工核查的写入后再重试。

验收探针用已安装的 Harness SDK，在隔离作用域核验 Desktop 预设的技能发现与正文加载。Magpie 分发同时核对勾选、应用记录、宿主链接或副本，以及实际写入收据 `magpie_write_audits`。

### Magpie 限定宿主的写入入口

[Magpie 写入补丁](magpie-v0.1.4652-library-scope.patch) 基于官方 [v0.1.4652](https://github.com/yetone/magpie/tree/b704e4f9d835e410af35737b137cb6891c4f8391)。在独立 D 盘源码树中执行 `git -c core.autocrlf=false apply --check --whitespace=error <补丁绝对路径>`，再去掉 `--check` 应用补丁。验证和构建都在该树运行，Go 缓存和测试临时路径放在 D 盘。

~~~powershell
go test -mod=readonly -tags nogui -count=1 -run 'TestLibraryScoped|TestEveryRouteIsNamedForTheCLI|TestEveryRouteHasACommandOrIsNamed' ./internal/gui ./internal/cli
go build -mod=readonly -tags nogui -trimpath -ldflags '-s -w -X main.version=v0.1.4652+libraryscope.1' -o <D盘候选产物路径> .
~~~

`register`、`deliver` 和 `scoped-mcp` 使用独立的 [Magpie 限定写入器](D:/Codex/tools/magpie-scoped-library/magpie-scoped-library.exe)。在候选验收和批准后部署。分发前核对 `--version` 的 `+libraryscope.1` 能力标识、`GET /api/library/scoped` 的 `scopeVersion` 和后端实际 `statePath`。任一不匹配则停止分发。`verify` 只读。

受管写入按同一 Library 状态文件加跨进程锁，撞到正在进行的写入时返回 `magpie-scoped-write-busy`。在锁持有期间暂缓普通 Magpie 的 Library 页面、CLI 写入及云同步。普通 Magpie 使用自己的进程内锁，Library 读取、应用启动和全库 `sync` 也可能触发独立调和。

API 调用方启动 `magpie-scoped-library.exe web --library-scoped --addr 127.0.0.1:<port>`，为该进程单独生成 `MAGPIE_WEB_KEY`，请求用 `magpie_web_<port>` cookie。通过能力核对后，将授权的 Magpie 宿主 ID 逐项传入 `agents`。本地技能支持 `POST /api/library/scoped/skills/{probe,install,agents}`。MCP 批量操作用 `POST /api/library/scoped/servers/agents-some`，传入 `names`、`agents`、`on`，同一批全部服务器用 `agents-all` 并省略 `names`。启动与应答都只走专用后端，不请求普通 Library 页。MCP 路由或技能共享目录、技能路由启用时，对应操作需要另行确认范围。若已配置的 `agy` 和 `antigravity` 共用目的地，只授权其中一个会在写入前被拒绝。

MCP 操作指定已登记服务器名称与宿主 ID，并选择 `--enable` 或 `--disable`。以下命令使用已有的当次证据目录，回执名称须为新文件。

~~~powershell
python -B scripts/daily-update/shared-skill-delivery.py scoped-mcp --run-directory <当次目录> --receipt delivery/mcp-antigravity.json --agents 'antigravity' --servers '<服务器名称>' --enable
~~~

`--servers` 限定要修改勾选的服务器。Magpie 应用所选宿主的 MCP 配置时也会调和该宿主已有的待同步条目。

### 核对 Magpie 实际写入

`register`、`deliver` 和 `scoped-mcp` 比较动作回执和前后文件指纹。`magpie_write_audit_status=not-observed` 只说明这次没有观测到写入，旧收据继续适用。若 `review-required` 且不是写入前预检拒绝，保留原收据，核对 `unexpected_changed_hosts`、`changed_artifacts`、`unavailable_artifacts`，确认恢复或继续的范围。finalizer 按原收据保留人工核查闸门。

手工调用限定范围的批量分发也用同一审计，例如 MCP 动作的目标 ID 为 `antigravity`。

1. 操作前执行 `python -B scripts/daily-update/shared-skill-delivery.py audit-before --kind mcp --agents 'antigravity'`，确认 `preflight-ready`，将 JSON 保存在当次 D 盘证据目录。审计单个技能时仍须显式传 `--agents`：`--kind skill --name <技能名> --agents 'dsh,claude,claude-desktop,codex,kimi,antigravity'`（单次输出约 5 KB 全宿主指纹；同轮核对多个技能时落盘或经管道只投影 `ok`/`status` 与目标 `*.skill` 指纹）。
2. 仅执行已经授权的分发。将上一步 JSON 放入 `before`，把本次动作回执投影到 `result`：`changed` 只保留已登记宿主 ID（未映射用 `null`），`problems` 每项只保留 `{ "agent": "<ID>" }`（未知用空字符串），可另附 `backup_reported` 布尔。不保存原始配置、问题消息、备份路径或认证头。没有动作回执时填 `result: null`。
3. 将 `{ "before": …, "result": … }` 从 stdin 传入 `python -B scripts/daily-update/shared-skill-delivery.py audit-after`。`observed-within-scope` 表示回执与已覆盖文件的指纹相符；`review-required` 或非零退出表示不能确认。两个审计入口只读本机文件，不执行 Magpie 同步。

审计覆盖六个受管 Windows 宿主的已登记 MCP 配置、Claude Desktop 已发现的 Cowork manifest、Library 状态及指定技能的部署位置。`antigravity` 的 MCP 和技能路径也供 `agy` CLI 使用；仅勾选桌面版不构成配置隔离。比较基于文件身份和内容哈希，不归因到具体 JSON 字段，也不覆盖其他项目、未登记宿主、其他技能、备份、异步后续同步、并发或改后恢复的写入。

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
