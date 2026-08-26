---
type: report
title: run-evidence 迁移方案（zi-xi-shi / ban-gong-shi 双机执行契约）
tags: [迁移方案, run-evidence, 多设备]
intent: 定义两台待迁移设备的迁移合同、事实基线与验收口径；方案未授权执行
---

# run-evidence 迁移方案（zi-xi-shi / ban-gong-shi 双机执行契约）

- 日期：2026-08-26
- 状态：方案，未授权执行。本文只定义合同、事实基线与验收口径；未执行任何迁移、配置写入、计划任务改动、哨兵注册、对端推送冻结或 commit/push
- 目标：把 `zi-xi-shi`（自习室）与 `ban-gong-shi`（办公室）两台 Windows 设备各自的旧根 `D:\Codex\.codex\run-evidence\` 整树迁移到各自新根 `D:\agents\run-evidence\`；迁移后该机所有活跃写方默认写新根、不再写旧根；旧根空壳保留到全球清退（统一口径见 §3）
- 授权模型：本文不自授权任何执行动作。每台设备的迁移独立授权、独立执行窗口，逐项显式授权，笼统的"继续"不等于授权（迁移政策 :101）。以下各项各需单独授权：
  0. 迁移准备/只读取证授权（最先取得）：迁移报告目录建立、现场重核与闭包扫描、任务定义与 Action/Arguments 枚举及 XML 导出、scope/move manifest 建立、runner 向目标机推送与 hash 核验；本项不含任何 live 配置改写、任务禁用或数据移动；
  1. 真实迁移执行（candidate 发布与数据树 move）；
  2. 计划任务改动（禁用与恢复；定义与 Action/Arguments 的只读枚举、XML 导出属第 0 项取证；runner 以一次性计划任务形态启动时其注册并入本项）；
  3. 哨兵三任务注册（持续 watcher、每日健康检查、最终自清）；
  4. 外部状态变更（对端推送冻结协调、请用户关闭活跃交互会话的窗口安排）；
  5. 破坏性动作（reverse 之外的删除、ban-gong-shi preflight 空壳如被裁决为清理）；
  6. git commit/push（如执行分支采纳仓库同步候选或产生仓库改动）；
  7. ban-gong-shi C: 盘配置命中面改写（条件式授权点：仅当 §5.2 只读扫描在 C: codex home 命中旧根引用时触发，按命中面逐项授权；不命中则不启用）；
  8. 证据目录位置裁决（政策 :119 冲突程序）：本方案证据目录 `D:\agents\migration-reports\...` 偏离政策 :106 字面位置，见 §2.10-8 与 §8 waiver 登记；用户确认前证据目录条款不生效。
- 让步顺序：数据和安全元数据完整 > 可逆回滚 > 写方闭包与告警连续性 > 功能验证 > 速度。文中"必须/只允许/拒绝"是硬门槛，"建议"可由执行者用更强且有证据的办法替代并在迁移报告中说明
- 真源与先例：机器无关合同复用 jia-li 侧 v6 契约（`统一环境\docs\plans\2026-08-24-run-evidence-migration-plan.md`，含顶部 2026-08-26 勘误，行号引用以该文件 2026-08-26 读取为准）；jia-li 执行事实见 `统一环境\reports\run-evidence-migration-20260825T013156Z\MIGRATION-SUMMARY.md` 与 `统一环境\docs\handoffs\20260826-033540-run-evidence-migration-closeout.md`；迁移政策硬前置见 `统一环境\docs\env-governance\d-drive-layout-and-migration-policy.md` :97-107，本文 §2.10 逐条落实
- 事实口径：本文全部现场事实为 2026-08-26 只读 SSH 审计结果，属易变事实，不构成当前事实或执行授权；任何执行动作前必须按 §2.1 重新核验
- 设备指代与已修正误标严格一致：`jia-li`=家里（Windows 主机名 `Baker`，迁移已于 2026-08-25/26 完成，旧根空壳保留、新根现役）；`zi-xi-shi`=自习室（独立设备）；`ban-gong-shi`=办公室（主机名 `PC-20250421IVIW`）。本文设备一律使用这三个标签
- 断点续作只读写迁移报告目录中的状态机 checkpoint；不新建 `PROGRESS.md`

## 1. 设备身份与目标机锚定

- 身份权威：设备身份以 Tailscale 登记名为准（`jia-li` / `zi-xi-shi` / `ban-gong-shi`），当前三台均在线（2026-08-26 审计）。
- **Baker/Baker 碰撞警告**：`zi-xi-shi` 的 Windows 主机名也是 `Baker`，与 `jia-li` 完全相同。hostname 不得作为设备区分依据；任何脚本、runner、状态机证据内禁止用 hostname 判断目标机身份，hostname 只作弱参考记录。
- 双锚定规则（执行写动作前的硬前置，缺一不可）：
  1. 锚一（登记名）：会话建立后在目标机内核验 Tailscale 登记名与预期设备标签一致；核验步骤以 ssh-mesh 权威文档为准，本文不抄录。
  2. 锚二（连接方向）：会话必须由授权发起机（默认 `jia-li`）按 ssh-mesh 登记的目标条目建立；发起侧记录所用目标条目名与发起时刻 UTC。
  3. 双锚不一致、任一锚无法证明、或会话来源不明时，停止一切写动作，只读取证不受影响。
- state.json、move manifest、decisions-ledger 与全部验证输出必须记录双锚核验证据（登记名 + 连接方向 + UTC + runner identity）。
- 保密边界：本文与执行证据中禁止出现 Tailscale IP、tailnet 域名、邮箱/账号、SSH 用户、密钥路径；连接细节一律以 ssh-mesh 权威文档为真源，不在方案或证据中复制。

## 2. 通用执行合同（机器无关，两机同构）

### 2.1 状态机与现场重核

- 状态链：`preparing -> ready-for-quiesce -> quiesced -> moving -> validating -> reopened -> monitoring`。禁止向前跳阶段；回退跃迁合法，须在 state.json 记录 from/to/原因/UTC/runner identity。
- 每次跃迁记录前置证据路径、UTC、runner identity 与双锚证据（§1）。状态不匹配时停止。
- state.json 唯一真源位于该机迁移报告目录（§8）；**终段必须留在 runner/状态机内完成，禁止事后手工重建 state.json 或审计链**（jia-li 教训 5：事后重建使审计链可信度受损）。
- 现场重核（政策硬前置 1）：阶段 0 第一步重新运行只读 inventory——设备登记名、OS 版本、pwsh 实测路径与版本、旧根顶层计数、新根存在性与内容、D: 盘余量、计划任务清单与状态、codex 进程数、仓库存在性与 HEAD。与本文 2026-08-26 审计值不符时，停止并更新事实基线后重新取得差异部分的确认。
- quiesce 准入闸（恢复 v6 零 delta 动态闸，范围按机裁剪）：进入 `quiesced` 必须同时满足——①`Get-Process codex*` 为空（交互会话由用户手工关闭，runner 只等待，不强杀）；②写方任务 Disabled/非 Running（通道维护任务按 §2.3 例外定性保持原状）；③零 delta 核验：范围=旧根、新根、计划任务定义导出（zi-xi-shi 另含 `D:\Codex\.codex\hooks\`；ban-gong-shi 无 hooks/automations，只盯旧根/新根+任务定义导出），口径=相对路径+类型+length+LastWriteTimeUtc 的名称级清单（不做全量 hash：体积大且对"无写入"判定无增量价值），工具=同工具同旗标导出排序后比对，判据=**两份相隔 ≥10 分钟的导出零差异**；不满足则回到 writer 定位，不能强杀或宽松放行。

### 2.2 writer/default/doc/task 闭包扫描（执行时硬前置）

- 扫描模式固定为绝对旧根双形态 `(?i)D:[\\/]+Codex[\\/]+\.codex[\\/]+run-evidence`；裸 `rg 'run-evidence'` 会命中新根 leaf 名与 fixture 相对构造，不可用。
- 扫描根集合 12 类，逐项覆盖、逐项分类：
  1. 生产源码仓（该机存在的全部仓库）；2. hooks managed + deployed 双份；3. deployed scripts（`D:\Codex\.codex\scripts\`）；4. automations 三形态（prompt.txt / automation.toml / memory.md，含 PAUSED）；5. skills 实体 + symlink 消费方；6. 现役设备文档与 runbook；7. **全部计划任务 Action/Arguments 枚举**；8. 环境变量（Machine/User/会话）；9. 入口 shim 与 hash 钉 manifest/常量；10. 常驻 watcher 维护模式；11. schema/校验 pattern；12. 会真实建目录的测试/fixture 与 AI agent 行为写方。
- 分类口径：`local-new` / `remote-old` / `fixture/history` / `must-fix` / `frozen-repo-debt`（第五类）。`frozen-repo-debt` 成立须三条同时具备：①候选 B 部署冻结已生效（§4.3 R2：该机仓库禁止作为部署来源）；②债务已具名写入 decisions-ledger（类别 debt，含文件清单与旧根命中行）；③具名指向 §10 仓库布局迁移后续任务作为闭环出口。任一条件不成立的仓内旧根命中一律按 `must-fix` 处理。硬门：`must-fix=0` 且 `unclassified=0` 且 `frozen-repo-debt` 全部具名登记；任何未分类旧根命中、不可读的现役文件或新增写方都阻塞 cutover；历史报告与 provenance 只进白名单，不改写。
- **不接受"已知清单核对"**（jia-li 教训 2：`UuHeartbeatWatchdog` 在 Arguments 内嵌 `-EvidenceRoot` 旧根、每 2 分钟跑一次，漏网后推翻了第一版清单）。第 7 类必须对该机**全部**计划任务逐一导出 Action/Arguments 正文后分类，两机均列为执行时硬前置。
- 冻结范围只覆盖真写方进程族（jia-li 教训 1）：runner 只等待 `Get-Process codex*` 为空，不要求关闭 Cursor/Claude/Grok——除非闭包扫描证明它们是写方；runner 不执行 `Stop-Process`，交互会话由用户手工关闭。

### 2.3 计划任务合同

- 对每个 Codex 相关任务：记录原状态（State/LastTaskResult/触发器/进程树）并 XML 导出到报告目录 → 禁用 → 确认非 Running → 迁移完成后**逐一按原状态恢复**（Disabled 的恢复为 Disabled），禁止统一 `Enable`。
- 通道维护类任务的例外定性（ban-gong-shi 见 §5.2/§5.3 R5；zi-xi-shi 见 §4.3 R6 通道依赖性二分）：Action/Arguments 不含旧根引用且职责为通道维护的任务，迁移窗口保持原状不动；是否含旧根引用以枚举正文为准，不凭任务名推断。
- **迁移后第一次计划任务真实运行属于 required 验证**（jia-li 教训 6：迁后 02:00 日更即暴露 sub2api 漏网写方，旧根被重建）：每个恢复原状态且会写证据的任务，其迁后首次真实运行结果必须落证据目录；历史运行超时的等待真实终态，不按固定时刻假阴性。

### 2.4 搬运合同（同卷顶层 rename）

- 两机旧根与新根均同卷 D:；只允许对顶层单位 `Move-Item -LiteralPath <旧根\条目> -Destination <新根\同名条目>` 的 rename 语义搬运；destination 必须写全且事前不存在。
- 禁止 robocopy/Copy-Item fallback、merge、覆盖、`/XO`、递归遍历、先建同名 destination；计数不得替代 ACL/owner/stream 与对象 identity 证明。
- scope manifest 冻结全部顶层单位（含顶层散落文件，按文件单位处理）；每个单位状态只允许 `pending/moved/reversed/failed`；move 前记 source file ID/volume identity，move 后立即核 target file ID 与类型相同、source 不存在，再原子更新为 `moved`。
- 同名冲突零容忍：任一祖先是 reparse point、source/destination 不同卷、或任一顶层目标同名时，第一次 move 前失败闭锁，不做 merge 或"较新者优先"裁决。
- 任一单位失败：停止后续 move，在写方仍冻结时按 move manifest 逆序 reverse（§7）。
- 树内 reparse point（如有）一律作为 opaque evidence 随顶层父目录 rename；不删除、不重建、不改 target；迁后断链只登记。

### 2.5 敏感域递归完整性 manifest

- 每机敏感域清单在各自章节冻结（zi-xi-shi：`codex-hook-health`、`safe-tree-delete*`；ban-gong-shi 执行时按体积与业务选定，至少含 `safe-tree-delete`）。
- manifest 字段：相对路径、类型、length、mtime、regular-file raw SHA-256、owner、ACL SDDL、stream name/size/hash；迁后逐项重算对账，任何 unreadable/error 单位必须与迁前同 identity、同错误类别，不能用总数抵消差异。

### 2.6 解封闸

- 验证阶段最先执行：live preflight `--check-only` 要求 ok；通过前保持 quiesce，不重开任何写方。该机无 preflight 等价物时（ban-gong-shi 初判；zi-xi-shi 须在阶段 0 先核验 preflight 存在性，缺失同样落入本分支，见 §4.4），以 §2.2 复扫 + identity 对账作为等价闸并登记差异。
- 等价闸残余风险显式绑定：等价闸只证明"旧根引用清零"，**不证明"新根引用可工作"**；补偿=任务定义核验（改写 candidate 的 Action/Arguments 逐项复核）+ 迁后第一次计划任务真实运行（§2.3 required 项），两者证据入档前不得写 `state=reopened`。

### 2.7 runner 合同（逐机实测绑定）

- 最终冻结、发布、搬运与早期回滚由外部 runner 接管，不由交互会话内联执行；runner 钉 pwsh 版本逐机实测绑定，**不可照抄 jia-li**（jia-li 教训 8）：
  - zi-xi-shi：`D:\Codex\tools\PowerShell\7.6.3\pwsh.exe` 显式路径（该机 PowerShell 5.x 被本机策略封锁，一切自动化包括 runner、状态机、闭包扫描、任务枚举必须走该显式路径，禁止任何 `powershell.exe` 隐式调用）；
  - ban-gong-shi：pwsh 7.6.4，全路径执行时实测绑定（2026-08-26 审计仅确认远程会话版本，未取全路径）。
- runner-manifest 绑定脚本 raw SHA-256、pwsh 路径、cwd、允许路径、状态机与回滚动作；runner 不结束未知进程、不建 branch/worktree、不 commit/push。
- **启动形态**（jia-li 实证：SSH 断开会杀会话进程树）：runner 必须以脱离 SSH/交互会话的形态在**目标机本地**启动——一次性计划任务或 detached 进程，形态选择钉入 runner-manifest；采用一次性计划任务形态时其注册属计划任务改动授权（头部授权模型第 2 项），任务结束后登记删除或自清。会话只负责启动 runner 与轮询状态文件；runner 进程树不得挂在会话进程树下。
- **发布门重述**：candidate 发布前逐目标核 pre-image identity/hash/ACL，原子替换后核 post-image raw SHA-256；任一目标 pre-image 不符即停，不发布该批任何文件。
- **runner 进程路径自证**：runner 启动后第一动作=自证当前进程可执行文件路径与 runner-manifest pinned pwsh 路径逐字符一致，不一致即退出（防 `powershell.exe` 隐式劫持，zi-xi-shi 5.x 封锁环境下尤为关键）。
- **执行身份绑定**：runner 与哨兵的执行身份钉入 runner-manifest；哨兵若以 SYSTEM 等非审计会话身份运行，注册前必须验证该身份下 pinned pwsh 路径可用且报告目录可写，证据入档。
- **日志编码统一 UTF-8**（jia-li 教训 8 伴生：UTF-16/ANSI 混合增加审计成本）；runner、状态机、manifest、ledger 全部 UTF-8 无 BOM。

### 2.8 pre-cutover 门与 stray 处置

- pre-cutover 运行只能写 fixture 或唯一 `migration-preflight-<ts>` 证据子树，不得预建与旧根同名的 production 目标域。
- **stray 处置预案先生效**（jia-li 教训 3：默认值改完后 required 测试套件写 production 同名域导致 destination collision）：pre-cutover 结束后、quiesce 前复扫新根，任何新增同名条目按 §2.4 同名冲突失败闭锁；处置路径=定位产生者→移入本次 preflight 证据域或登记后清理（清理属破坏性动作单独授权）→重跑 pre-cutover 门。
- Quiesce / Cutover / Validate 分 phase 可重入：任一 phase 失败修复后从该 phase 入口重跑，不重做已通过 phase；重跑输出按 §2.9 留存。
- **`moving` 态重入的歧义单位裁决**（jia-li runner 实证：`Invoke-Cutover` 入口硬要求 `state=quiesced`、转移表无 `moving→moving` 自环；Move-Item→核验→写 manifest 的顺序会产生"manifest=pending 但对象已在新根"的歧义单位，既不能续搬也不能逆滚）：重入 moving 只允许经 runner 的 resume 入口（§2.12）；对每个 `pending` 单位先核验 destination 存在且其 file ID 与该单位 move 前记录的 source file ID 一致——一致则补记 `moved` 并续跑下一单位，**禁止对该单位 throw 或 reverse**；destination 不存在或 file ID 不一致时按原合同停止，并仅对已确认 `moved` 的单位逆序 reverse。

### 2.9 证据留存与审计链

- **通过的验证输出必须留存证据目录**（jia-li 教训 4：Validate 失败重跑后只留了失败那份）：每次 required 门运行无论红绿都落盘，通过版与失败版同目录并存，文件名带序号与 UTC。
- preflight `--check-only` 通过输出必存（验收硬项，§8）。
- 全程登记写入报告目录 `decisions-ledger.jsonl`，最小字段：UTC、身份（agent/runner）、类别（debt/registration/waiver/decision）、主题、证据路径、内容。

### 2.10 迁移政策硬前置逐条落实（自查清单）

对 `d-drive-layout-and-migration-policy.md` :97-107 八条硬前置：

1. 重新运行只读 inventory → §2.1 现场重核（每机阶段 0 第一步）。
2. dry-run 计划明确来源/目标/风险/root policy/排除项 → 本文 + 每机 scope manifest（阶段 0 产物）。
3. 用户显式授权、笼统"继续"不算 → 头部授权模型。
4. 验证步骤（工具命令、inventory 对比、smoke） → §8 验收门。
5. 回滚步骤（恢复配置、恢复旧路径、保留旧副本、重新验证） → §7 四层联合回滚点。
6. 来源、目标、输出路径及所有已存在父级不穿过 junction/symlink/reparse point → 阶段 0 对旧根、新根、`D:\agents` 全部父级与迁移报告目录逐层 reparse 检查，命中即停人工审查。
7. 输出路径位于 D 盘 → 两机新旧根与证据目录全在 D:。
8. 迁移证据写入 `D:\agents\run-evidence\env-governance\` 或项目 `reports\`，不写 C 盘 → **偏离，待用户裁决**（政策 :119 程序：冲突时先停止、记录、由用户确认）：§8 证据目录 `D:\agents\migration-reports\...` 不在政策 :106 字面的两个位置内；偏离条款、理由与补偿见 §8 waiver 登记，裁决项已回流头部授权模型第 8 项，用户确认前证据目录条款不生效。

### 2.11 30 天哨兵合同

- 注册哨兵三任务（持续 watcher / 每日健康 / 最终自清）属单独授权（头部授权模型第 3 项）；未授权时单机迁移最多停在"本机切换已验证、哨兵未注册"，不得声称 30 天门槛已覆盖。
- **哨兵必须实际注册并验证武装**（jia-li 教训 7：jia-li 哨兵未注册，30 天时钟至今未开始）：注册后立即以受控事件验证 watcher 真实捕获、heartbeat 真实落盘、每日健康检查真实运行，三者证据入档后才写 `state=monitoring`。
- 合同口径同 v6 阶段 7：watcher 监视旧根顶层 exact 名，事件/overflow/heartbeat gap 任一发生即裁决失败；连续 30 个完整 24h 窗口满足旧根事件=0、overflow=0、gap=0 才形成 monitoring-complete；**任一旧根事件：冻结相关 writer，前移 straggler，修复并复验写方，30 天时钟归零重计，不自动删除证据**。
- 两机哨兵与 jia-li 哨兵共同构成全球清退前提（§9）。

### 2.12 断线与重入续作合同（两机通用）

- 通道事实：两机执行会话均经 SSH→Tailscale 链路（ban-gong-shi 另多一段该机 v2rayN 环节，特化见 §5.3 R5），长会话存在断线风险；jia-li 实证 SSH 断开会杀会话进程树，故 runner 启动形态按 §2.7 脱离会话。
- 断线处置=**冻结保持在中点**：写方保持冻结、状态机停留当前态、已搬单位不反向移动；恢复后按 state.json checkpoint 续作，**禁止盲目反向迁移**。
- 断线后第一判据=runner 死/活二分：①runner 仍存活（目标机本地进程存在、状态文件持续推进）→ 会话只恢复轮询，不重启、不二次启动 runner；②runner 已死（进程不存在且状态文件停滞）→ 按死亡时刻所处状态走合法重入入口：`moving` 之前死亡从该阶段入口重跑；`moving` 之中死亡按 §2.8 歧义单位裁决续跑；`validating` 及以后死亡重跑当前验证门。
- 重入合法性衔接 §2.1"禁止事后手工重建 state.json/审计链"（教训 5）：一切重入必须经 runner 合法入口（resume/重跑参数），**禁止外部直接改写 state.json、move manifest 或任何状态文件**；runner 重入时按 §2.7 自证 pinned pwsh 路径与脚本 raw SHA-256。
- 迁移窗口不得触碰通道本体（v2rayN/Tailscale 配置与通道维护任务）；通道相关计划任务的处置见 §2.3 例外定性与逐机二分（§4.3 R6 / §5.2）。

## 3. jia-li 遗留债务登记（全球清退前提，本方案不执行修复）

以下债务只登记、不修复；修复属后续独立授权任务：

1. **旧根空壳被重建一次**：2026-08-26 02:17，jia-li 旧根出现 `daily-codex-ecosystem-update\20260826-021500-sub2api-0183\sub2api-upgrade-state.json`，系 sub2api 升级辅助写方所为，写方未定位。按 v6 :237 规则（旧根重现→状态保持 validating、定位 writer、不用递归删除清场）属未闭环事件。
2. **哨兵未注册**：jia-li 30 天哨兵从未注册，时钟未开始；本方案两机的哨兵合同（§2.11）执行后，jia-li 哨兵注册仍是独立的全球前置债务。
3. **新根差额未核对**：jia-li 新根 2026-08-26 实测 378 个顶层条目 vs 迁移完成时 376，差额未逐条核对。
4. **旧根空壳"删/留"口径定死（本方案决议）**：v6 阶段 4.9 曾设计验证通过后删除空旧根，closeout 决定保留到双容清退。本方案统一三机口径：**旧根空壳一律保留到全球清退，任何机器的旧根重现都按 v6 :237 回到 validating 定位写方，禁止递归删除清场**。两机阶段 4 相应去掉"删除空旧根"步骤，改为"空壳存在性 + 零子项"核验并写 T+0 sentinel 基线。
5. **两机侧出向推送配置未定位（v6 :44 已登记互操作债的补全）**：zi-xi-shi/ban-gong-shi 侧可能存在的、指向 jia-li 已退役旧根的出向推送/部署配置尚未定位与处置；发现程序与冻结/监视口径见 §6，处置本身属后续独立授权任务。

## 4. zi-xi-shi（自习室）执行章节

### 4.1 现场事实块（2026-08-26 审计，易变事实，执行前按 §2.1 重核）

- 登记名 `zi-xi-shi`；Windows 主机名 `Baker`（**与 jia-li 碰撞，§1 双锚定适用**）；Windows 11 家庭中文版 10.0.26200。
- pwsh 7.6.3：`D:\Codex\tools\PowerShell\7.6.3\pwsh.exe`；**PowerShell 5.x 被本机策略封锁，一切自动化必须走 pwsh 7.6.3 显式路径**。
- 旧根 `D:\Codex\.codex\run-evidence\` 存在，**101 个顶层条目**（100 目录 + 1 散落文件 `v2rayn-guiNDB-readonly-20260702-115919.db`）；代表性条目：codex-hook-health、ssh-transfer-benchmark、storage-migration、replicator、safe-tree-delete*、大量 skill-*、12 个 retired-skill-menu-surface-* 快照、ccswitch-*、temp、tmp、unclassified-temp-artifacts、cleanup-quarantine、host-maintenance。
- 新根 `D:\agents\run-evidence\` 不存在，`D:\agents` 整树不存在（全新创建，零同名冲突）。
- D: 盘 Free ≈685.7 GB，充裕。
- 计划任务 4 个 Codex 相关：`CodexProxyHealth`（Disabled）、`CodexPwshRouterDriftCheck`（Ready）、`CodexStoreUpdateHealthGuard`（Ready）、`CodexSwitchDedicatedProxy`（Ready）；**任务 Action 正文未取证**（§2.2 第 7 类硬前置）。
- `D:\Codex\.codex\config.toml` 存在但 run-evidence 零引用；`automations\` 不存在。
- `hooks\` 存在（4 文件）：**`hooks\lib\CodexHookRuntime.ps1:254,283` 硬编码旧根 codex-hook-health 根**；`:255` 耦合 `D:\Codex\projects\统一环境\reports`（仓库路径，非 run-evidence）。
- 统一环境仓库位于旧布局 `D:\Codex\projects\统一环境`（工作区干净，HEAD `08c194d`，**落后 jia-li main**）；`D:\agents\projects\统一环境` 不存在。
- 2026-08-26 审计时刻 0 个 codex 进程；`D:\Codex\.codex\docs\agent-guidance\` 已同步（14 条目）。
- 未知项：旧根总字节数；4 任务 Action 是否引旧根；grep 范围外是否还有其他旧根引用。

### 4.2 写方清单与改写项（初判，以执行时闭包扫描为准）

- 已证实写方面：`hooks\lib\CodexHookRuntime.ps1:254,283`（deployed）——candidate 以**本机现役文件为基**套用与 jia-li v6 阶段 2.1 等价的换根改写；`:255` 仓库耦合行**保留不动**（仓库布局迁移是非目标，§10）；禁止整文件照抄 jia-li 现役版本（其仓库耦合指向新布局，与本机旧布局不符）。
- 其余 hooks 3 文件、hash 钉 manifest/常量（如扫描发现存在）按 v6 2.2 原子单元规则同批处理；不存在则登记零面。
- 4 个计划任务：Action/Arguments 枚举后分类；含旧根引用者生成改写 candidate 并纳入 §2.3 合同。
- skills、deployed scripts、设备文档（agent-guidance 14 条目）按 §2.2 扫描结果逐项分类；本机条款换根、他机条款不动。
- 顶层散落文件 `v2rayn-guiNDB-readonly-20260702-115919.db` 作为文件单位进 scope manifest，与目录单位同规则 rename。
- 敏感域：`codex-hook-health`、`safe-tree-delete*` 生成 §2.5 递归完整性 manifest。

### 4.3 特殊风险与决策

- R1（pwsh 5.x 封锁）：见 §2.7；runner-manifest 绑定 `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe` raw SHA-256，执行时重测。
- R2（仓库旧布局且落后 main，二选一决策）：
  - 候选 A（gated 同步）：先把 `D:\Codex\projects\统一环境` fetch 并快进到 main 再做迁移改动。**否决理由**：jia-li 侧 116 个迁移代码改动文件尚未 commit（2026-08-26 closeout），origin/main 不含完整迁移实现，同步后仍拿不到真源；且把仓库同步混入迁移窗口扩大授权面。
  - 候选 B（部署侧替代，**建议采纳**）：仓库整体不动；迁移所需 live 改写以本机现役 deployed 文件为基生成 candidate（§4.2）；仓库内 managed/scripts 旧根引用登记为债务，并入仓库布局迁移任务（§10 非目标，另立）。
  - 候选 B 伴生硬门槛：该机仓库在债务闭环前**禁止作为部署来源**再发布 hooks/scripts 到本机 live 面（部署冻结并入 §6 互操作窗口）。
  - 候选 B 伴生条款一（v6 原子单元例外裁决）：v6 阶段 2.2 要求 managed+deployed 同批同改以保哈希原子单元；候选 B 下该机 managed 源留在旧布局仓库不动，本方案显式声明该机例外——理由：managed 真源经 origin/main 不可得（jia-li 116 个迁移改动文件未 commit），在落后 main 的仓内改 managed 会与未来仓库布局迁移冲突。例外成立前提=部署冻结生效（仓内 managed 不再成为 deployed 来源）+ 仓内旧根命中全部按 §2.2 第五类 `frozen-repo-debt` 具名登记。
  - 候选 B 伴生条款二（drift 检查面 waiver）：cutover 前执行时枚举该机全部 drift/consistency 检查面（至少含 `CodexPwshRouterDriftCheck` 的 Action/Arguments 与 hooks 自检）；凡以仓内 managed 为 oracle 的检查面逐项登记具名 waiver（到期条件=§10 仓库布局迁移任务闭环、该机仓库恢复为可部署真源），waiver 清单入 §8 必存证据；不以仓内 managed 为 oracle 的检查面必须保持绿色。
- R3（hostname 碰撞）：§1 双锚定；runner 日志与 state.json 逐条带双锚证据。
- R4（旧根体积未知）：preflight 先测体积与文件/目录计数，作为 §2.5 对账基线；同卷 rename 下体积不构成阻塞。
- R5（grep 范围外未知引用）：§2.2 十二类闭包扫描执行时取证，不接受"已知清单核对"（教训 2）。
- R6（通道依赖性二分，§2.12 通用合同的本机特化）：4 个任务 Action/Arguments 枚举后先做通道依赖性二分——`CodexProxyHealth`、`CodexSwitchDedicatedProxy` 等是否承载 SSH/Tailscale 通道（代理可用性守卫、专用代理切换可能影响控制面可达性）；凡通道相关任务，**无论是否含旧根引用都需显式处置决策**（保持原状/冻结/改写），决策与依据入 decisions-ledger；通道相关任务默认保持原状，含旧根引用时优先生成改写 candidate 而非冻结。

### 4.4 阶段计划（套 §2 骨架）

1. 阶段 0 preparing：双锚核验 → 现场重核（§2.1，逐项对照 §4.1）→ `D:\agents` 父链 reparse 检查（§2.10-6）→ 旧根体积/计数测量 → **preflight 存在性核验**（`codex-state-preflight` 等价物是否在 hooks 4 文件内存在并可运行；缺失则解封闸落入 §2.6 等价闸分支并登记）→ §2.2 闭包扫描（含 4 任务 Action/Arguments 枚举与 XML 导出、§4.3 R6 通道依赖性二分、§4.3 R2 伴生条款二 drift 检查面枚举）→ scope manifest（101 单位冻结，含 1 文件单位）→ 敏感域 manifest → runner 生成与 hash 绑定（§2.7，含脱离会话启动形态）→ 记录任务原状态并禁用含旧根引用的任务（§2.3）。
2. 阶段 1 目标根合同：新根整树新建，`D:\agents` 不存在故零同名冲突；不预建任何与旧根顶层同名目录。
3. 阶段 2 准备改动：§4.2 candidate bytes + SHA-256 manifest；仓库不动（候选 B）。
4. 阶段 2.15 pre-cutover 门：可用测试组合以部署侧实况执行时定（本机无新布局仓库，required 集以 hooks 自检 + 闭包复扫 + preflight（如阶段 0 存在性核验通过）为下限）；stray 处置预案先生效（§2.8）。
5. 阶段 3 cutover：runner 校验 quiesced 全部前置（含 §2.1 零 delta 闸）→ 发布 candidate → 逐单位 rename（101 单位）→ 旧根仅剩空壳。
6. 阶段 4 验证：解封闸（§2.6）→ 顶层 identity 对账 → 敏感域 manifest 重算 → 计数/字节补充门 → §2.3 任务恢复与首次真实运行验证 → **空壳保留**（§3 决议 4，不删除）+ T+0 sentinel 基线。
7. 阶段 6 reopen：闭包复扫 must-fix=0/unclassified=0/`frozen-repo-debt` 全部具名登记（§2.2 第五类）→ `state=reopened`。
8. 阶段 7 哨兵：单独授权后按 §2.11 注册并验证武装 → `state=monitoring`。

### 4.5 回滚与验收

- 回滚：§7 四层联合点，本机 L1=deployed live 文件 pre-image（无 git 层改动，候选 B）；L2/L3/L4 同构。
- 验收：§8 统一门；本机特有项=双锚证据链完整、101 单位 moved 落定、空壳零子项、4 任务原状态恢复且首次真实运行成功。

## 5. ban-gong-shi（办公室）执行章节

### 5.1 现场事实块（2026-08-26 审计，易变事实，执行前按 §2.1 重核）

- 登记名 `ban-gong-shi`；Windows 主机名 `PC-20250421IVIW`（与登记一致）；Windows 11 专业版 10.0.26200；远程会话 pwsh 7.6.4。
- 旧根存在，**32 个顶层条目**：bazi-*、cc-switch-install、6 个 clock-countdown-*-tests、document-read、nodesek-image-generation、多个 office-* 历史运维证据、powershell-upgrade-20260715、replicator、safe-tree-delete、skill-install-guarded、usb-repair-*、windows-update-repair-* 等。
- 新根 `D:\agents\run-evidence\` **已存在**，顶层 1 项 `migration-preflight-20260825T013156Z\`（2026-08-25 留下的 6 个 clock-countdown-* **空壳**目录）。
- D: 盘 Free **74.3 GB**（相对紧张）。
- 计划任务 6 个 office 特有 Codex 任务均 Ready：`Codex Office Proxy FailSafe`、`Codex Office Tailscale Unattended Guard`、`Codex Office v2rayN Autostart`、`Codex Office Win11 Upgrade Stage`、`CodexOfficeSystemWhoami20260709T134120`、`CodexOfficeWuauservEnable20260709T134120`；**任务 Action 正文未取证**（§2.2 第 7 类硬前置）。
- **无 `config.toml`、无 `hooks\`、无 `automations\`**（D: 受管引用面初判为零）；Codex 实际配置位置未查明，可能在 C: 用户 profile。
- 统一环境仓库**不存在**于该机；SSH 会话中 git 不在 PATH。
- **2 个 codex 进程活跃**（Id 19312、41496，2026-08-26 审计时刻）。
- 通道依赖链：SSH → Tailscale 控制面 → 该机 v2rayN（127.0.0.1:10808，实测在听）。
- `docs/environments/ban-gong-shi.md`（jia-li 侧仓库）声称的仓库路径与现场不符——登记为后续文档修正跟踪项（§10，本方案不修）。

### 5.2 写方清单与改写项（初判，以执行时闭包扫描为准）

- D: 受管引用面初判为零（无 config.toml/hooks/automations），但**不得以"零引用"跳过闭包扫描**；C: 用户 profile 的 codex home 候选位置列入只读扫描范围（扫描本身不违反 C: 不迁移条款；若命中需改写 C: 配置，属单独授权项，且不涉及迁移任何 C: 内容）。
- 6 个计划任务逐一枚举 Action/Arguments 后二分：
  - 写方任务（含旧根引用）→ §2.3 冻结/改写/恢复合同；
  - 通道维护任务（Proxy FailSafe / Tailscale Unattended Guard / v2rayN Autostart 等，不含旧根引用且职责为保活）→ **迁移窗口保持原状不动**（R5）。
- 活跃写方进程：2 个 codex 进程属冻结范围（§2.2 教训 1），由用户协调窗口手工关闭，runner 只等待零进程。
- 敏感域：至少 `safe-tree-delete`；执行时按 §2.5 体积与业务选定增补。

### 5.3 特殊风险与决策

- R1（preflight 空壳定性前置，硬门槛）：新根既有 `migration-preflight-20260825T013156Z\`（含 6 个 clock-countdown-* 空壳）必须在 scope manifest 冻结前完成定性裁决，三选一：
  1. 保留（默认建议）：登记为 pre-existing 集合，与 moved 集合分别对账（v6 阶段 3 对账口径），本次 preflight 改用新的唯一 `migration-preflight-<新ts>` 域，避免与正式迁移输出冲突；
  2. 清理：须先证明各空壳目录递归为空，且清理属破坏性动作单独授权；
  3. 续作：查明来源任务（2026-08-25 preflight）后并入本次证据链。
  未裁决前禁止进入 moving；空壳在新根顶层仅 1 项，与旧根 32 项逐一核同名，同名即 §2.4 失败闭锁。
- R2（活跃 codex 会话协调）：quiesce 需用户协调窗口；runner 只等待 `Get-Process codex*` 为空，不强杀（§2.2）。
- R3（磁盘 74.3 GB 紧张）：preflight 必须先测旧根体积；同卷 rename 不复制数据、体积不直接构成阻塞；但 §2.5 hash 对账需读全树，且 backups-live 只允许覆盖配置类小文件，数据树不做副本（rename 语义 + move manifest 即回滚凭据）；若实测旧根体积使 hash 全量计算不可行，敏感域缩减清单须登记 waiver 并给替代完整性证据。
- R4（无仓库/git，自包含 runner）：runner、状态机、manifest 工具全部自包含，从 jia-li 侧经受管通道推送（ssh-mesh；计时与完整性验收口径以发起侧 jia-li 的 `D:\Codex\.codex\skills\ssh-transfer-ledger\SKILL.md` 为准——该 skill 实体位于发起侧，其口径适用于 jia-li 的推送动作），推送后在目标机逐文件核验 raw SHA-256；目标机不执行任何 git 操作。
- R5（通道断线处置，§2.12 通用合同的本机特化）：本机通道链多一段——SSH → Tailscale 控制面 → 该机 v2rayN（127.0.0.1:10808），迁移窗口**不得触碰 v2rayN/Tailscale**（含对应计划任务，见 5.2）；断线中点冻结、runner 死/活二分判据与重入续跑规则一律按 §2.12 执行；本机附加前置：runner 脱离会话启动形态（§2.7）与状态文件持久化（每次跃迁前 state.json 与 move manifest 落本机报告目录，D:、两根之外）未就绪不得进入 `ready-for-quiesce`。
- R6（无 config/hooks/automations）：见 5.2；C: 扫描命中面改写属单独授权。
- R7（pwsh 7.6.4）：§2.7 逐机绑定，全路径执行时实测。

### 5.4 阶段计划（套 §2 骨架）

1. 阶段 0 preparing：双锚核验 → 现场重核（逐项对照 §5.1）→ **R1 空壳定性裁决** → 旧根体积/计数测量（R3）→ §2.2 闭包扫描（含 C: codex home 候选只读面、6 任务 Action/Arguments 枚举与 XML 导出）→ 任务二分（5.2）→ 用户协调窗口约定（R2）→ runner 自包含推送与 hash 核验（R4）→ scope manifest（32 单位 + pre-existing 1 项分账）。
2. 阶段 1 目标根合同：pre-existing 集合登记；不预建同名目录。
3. 阶段 2 准备改动：以扫描结果为准（初判零改写面；命中项按 §5.2 生成 candidate 或另行授权）。
4. 阶段 2.15 pre-cutover 门：闭包复扫 + stray 处置预案生效（§2.8）；本机无测试仓库，required 集以闭包门 + 任务定义核验为下限。
5. 阶段 3 cutover：quiesced（含 2 进程归零、写方任务 Disabled/非 Running、通道任务保持原状确认）→ 逐单位 rename（32 单位）→ 旧根仅剩空壳。
6. 阶段 4 验证：等价解封闸（§2.6）→ identity 对账（含 pre-existing 分账）→ 敏感域 manifest → 写方任务恢复与首次真实运行验证 → 空壳保留 + T+0 sentinel 基线。
7. 阶段 6 reopen 与阶段 7 哨兵：同 §4.4-7/8。
8. 全程断线条款（R5）生效；任一阶段断线按中点冻结续作。

### 5.5 回滚与验收

- 回滚：§7 四层联合点，本机 L1/L2 初判为零面或小面（视 C: 扫描结果），L3/L4 同构；断线不构成回滚触发（R5）。
- 验收：§8 统一门；本机特有项=R1 裁决记录、32 单位 moved 落定、pre-existing 分账对账、2 进程协调窗口记录、通道全程未触碰证据（v2rayN 监听与 Tailscale 在线状态前后一致）。

## 6. 执行顺序与互操作冻结窗口

- 两机迁移**无互相硬顺序**，各自独立授权、独立执行窗口。建议（非硬门槛）：先 zi-xi-shi（无活跃 codex 进程、磁盘充裕、新根零冲突），后 ban-gong-shi（需会话协调窗口、磁盘紧张、通道依赖复杂）。
- **推送/部署入口冻结（硬门槛，范围="指向任一已退役旧根的全部入口"）**：zi-xi-shi/ban-gong-shi 的部署/推送配置以各自旧根为 inbound staging；jia-li 旧根已退役，两机侧指向它的出向入口同样会在对端重建旧根（v6 :44 已登记该互操作债，§3 债务 5）。任一机进入 `ready-for-quiesce` 起，对端（含 jia-li 与另一台待迁移机）指向该机的入口必须冻结；jia-li 迁移完成时起，两机侧指向 jia-li 旧根的出向入口同样纳入冻结或监视。
  - 入口发现程序（使"全部"可执行可验收）：发起侧逐机扫描三处——①各对端机的部署/targets 配置（replicator targets、deploy 脚本 target manifest、设备文档中的可复制命令）；②相关计划任务 Action/Arguments 全量枚举（部署/同步/传输类任务不得按名跳过）；③ssh-mesh 权威文档登记的连接方向与已知推送通道。发现结果逐项分类 `push-target`（指向任一已退役旧根）/ `unrelated` / `unclassified`，硬门 `unclassified=0`；全部 `push-target` 具名入 decisions-ledger 后，目标机才允许进入 `ready-for-quiesce`。
  - 冻结动作在发起侧执行（暂停对应 target/入口/任务），属外部状态变更，单独授权（头部授权模型第 4 项）；无授权冻结能力的入口（如一次性手工推送通道）以"监视+迁后核对"降级处置并具名登记 waiver；
  - 目标机 `reopened` 后推送**保持冻结**——其旧根已退役；解冻条件二选一：全球双容清退统一换根，或单独授权的推送配置换根任务（均不在本方案范围）。
- remote-only schema/tools 双容代码一律不动（保留到 30 天清退任务）；**禁止在任何一端未迁移前放宽 remote-only 校验**；两机迁移过程中亦不改任何 schema/工具。
- 窗口记录：每次冻结/解冻写入两侧 decisions-ledger（发起侧 + 目标机侧），含 UTC、操作者、target 清单。

## 7. 回滚合同（四层联合点，per machine）

- 四层联合回滚点（每层 per machine 建立，缺一不可）：
  - L1 代码 git anchor/pre-image：zi-xi-shi 采纳候选 B 时无 git 层改动，L1=deployed live 文件 pre-image（raw SHA-256 钉）；若执行中改采候选 A，须先取得 git 授权并按 v6 阶段 0.3 锚定。ban-gong-shi 无仓库，L1=零面或 C: 配置 pre-image。
  - L2 live 配置备份：`backups-live\` manifest 逐项记录真实路径、length、mtime、raw SHA-256、ACL SDDL、owner、stream 清单；恢复逐项核验，不得只恢复部分文件。
  - L3 数据树 move manifest 逆序 reverse：每个 `moved` 单位 rename 回旧根并核原 file ID；任一 reverse 失败即 `manual-review`，禁止保留混合态继续。
  - L4 计划任务恢复计划：XML 导出 + 原状态记录，逐一恢复原状态，禁止统一 Enable。
- **联合一致性硬门**：四层必须能同时回到同一一致组合；任一层无法证明即整体失败闭锁，禁止"脚本新根 + 数据旧根"等混合态继续运行。
- 阶段化中止合同（复用 v6 §3）：
  - moving 前中止：未搬运，candidate 不发布，任务恢复原状态，preflight 证据域保留登记；
  - moving/validating 中止：保持写方冻结 → L3 逆序 reverse → L1/L2 pre-image 恢复 → L4 任务恢复 → 复验后才允许 reopen；
  - reopened 后失败：新根可能已有新写入，**不自动反向迁移**；立即冻结具名 writer，保存新写入 identity/hash，前移旧根 straggler，修复漏写方并重跑验证；整树回滚须另获授权。
- 同一 required 验收连续失败 3 次停止该分支，保存最后有效 checkpoint，报告原始错误、退出码、业务字段与未完成单位；禁止用 disable/stub/ignore/skip、放宽断言或删除测试伪装恢复。
- 断线特例（ban-gong-shi R5）：通道断线不是回滚触发；冻结保持中点，恢复后续作。

## 8. 验收与证据归档

- 每机证据目录：`D:\agents\migration-reports\run-evidence-migration-<machine>-<ts>\`（两根之外、D: 盘、两机同构、不依赖仓库存在）。**waiver 登记（偏离政策 :106 字面位置，待用户裁决——见 §2.10-8 与头部授权模型第 8 项）**：偏离条款=政策 :106 只允许 `D:\agents\run-evidence\env-governance\` 或项目 `reports\`；理由=迁移进行期写新根内部会污染 scope manifest、ban-gong-shi 无项目仓库、zi-xi-shi 仓库在旧布局且落后 main；补偿=①目录在 D: 盘两根之外，守住政策"不写 C 盘"底线，②全球收尾任务统一归档回 jia-li `统一环境\reports\`（另立任务），③用户裁决不通过时回退政策字面位置并同步更新本节与 §2.10-8。
- 目录必存内容：state.json（**状态机链完整**：每次跃迁的前置证据/UTC/runner identity/双锚证据，回退跃迁带原因；禁止事后手工重建，教训 5）、decisions-ledger.jsonl、scope manifest、move manifest（含 file ID 前后值）、backups-live、任务 XML 导出与原状态记录、闭包扫描全量结果与分类表（含 `frozen-repo-debt` 具名登记）、runner-manifest 与 hash 绑定记录、推送入口发现与冻结记录（§6）、drift 检查面 waiver 清单（§4.3 R2 伴生条款二）、零 delta 闸两份导出与比对结果（§2.1）。
- 验证输出留存：**preflight `--check-only` 通过输出必存**；每次 required 门红绿全留（教训 4）；迁移后第一次计划任务真实运行结果必存（教训 6）。
- 编码：全部 UTF-8 无 BOM（教训 8 伴生）。
- 单机验收门（全过才算单机完成）：§2.6 解封闸 ok → 顶层 identity 对账（moved 单位 source 不存在、target file ID 不变；failed=pending=reversed=0；pre-existing 集合 identity 不变）→ 敏感域 manifest 逐项一致（§2.5）→ 计数/字节补充门 → 闭包复扫 must-fix=0/unclassified=0/`frozen-repo-debt` 全部具名登记 → 任务按原状态恢复且首次真实运行成功、旧根未重现 → 空壳零子项核验 + T+0 sentinel 基线 → `state=reopened` → （授权后）哨兵注册并验证武装 → `state=monitoring`。

## 9. 完成条件与 30 天清退前提

1. **方案级完成（本次交付）**：本文落盘；§2.10 政策八条、v6 通用合同、jia-li 八条教训在文中逐项落实；不执行任何迁移动作。
2. **单机迁移完成（后续执行）**：§8 单机验收门全过，`state=reopened`；哨兵授权并注册武装后 `state=monitoring`。未授权哨兵时如实停在 reopened，不声称 30 天覆盖。
3. **双机完成 ≠ 清退**：全球清退前提 = 全部机器迁完 + jia-li watcher 连续 30 天无事件/overflow/gap；而 30 天前提又依赖 jia-li 债务先闭环（§3：哨兵注册、sub2api 写方定位、378/376 差额核对）。本方案两机完成后，这些共同构成全球清退的前置债务清单。
4. **30 天哨兵合同（复用 v6 阶段 7）**：连续 30 个完整 24h 窗口旧根事件=0、overflow=0、heartbeat gap=0、每日 writer scan 无新增旧根生产引用，才形成 monitoring-complete；任一旧根事件：冻结相关 writer、前移 straggler、修复复验、时钟归零重计，不自动删除证据。旧根空壳在三机一律保留到清退（§3 决议 4）。
5. 任一 required 单位 failed/pending/manual-review、任一未授权动作发生，都不能使用 complete；交付必须指出精确 checkpoint、证据路径、原始错误和下一授权边界。

## 10. 明确非目标

- 不迁移仓库路径布局（zi-xi-shi 的 `D:\Codex\projects\统一环境` → 新布局另立任务，含其 managed/scripts 旧根引用债务）。
- 不改任何 remote-only schema/tools 与双容兼容代码（保留到 30 天清退任务）。
- 不删除任何旧根空壳（三机统一保留到全球清退，§3 决议 4）。
- 不修 `docs/environments/ban-gong-shi.md` 的仓库路径记载落差（登记为后续文档修正跟踪项）。
- 不执行 jia-li 遗留债务修复（§3 只登记）。
- 不触碰 v2rayN/Tailscale 配置与通道维护任务；不做任何 C: 内容迁移（C: 仅只读扫描，命中配置的改写属单独授权）。
- 不在本方案注册哨兵、不冻结对端推送、不关闭任何用户会话——以上均为执行期的单独授权动作，本文只定义合同。
- 不做 git commit/push/branch；zi-xi-shi 仓库按候选 B 整体不动。
