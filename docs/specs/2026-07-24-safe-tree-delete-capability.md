---
type: reference
title: 受管安全树删除 capability
tags: [设计, 安全删除, capability]
intent: 说明受管目录树删除入口的安全边界和迁移状态
---

# 受管安全树删除 capability

## 目标

为 Codex 自动化提供固定、可审计的目录树删除入口，替代对 `Remove-Item -Recurse`、
`Directory.Delete` 或 `cmd rmdir` 等命令文本的零散判断。该能力不修改 Codex Desktop
内建执行器；它是 Codex/agent 发起的本机宿主递归删除的唯一受支持入口。仓库内部
fixture/staging 清理仍有既有调用，迁移状态为 `pending`，不得据此宣称全仓库已统一。

## 固定入口

- 宿主入口（2026-09-03 入口契约，canonical）：gate shim `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1`，POSIX shell 经托管 pwsh `-File` 直调，不经 cmd.exe；门禁失败契约与调用注意见 `D:\Codex\.codex\docs\agent-guidance\host-runbook\safe-tree-delete.md` 首节
- 宿主 cmd 语境兼容启动器：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`（只 pin pwsh 再调 shim；仓库源 `scripts\invoke-codex-safe-tree-delete.cmd`）
- 生产脚本：`scripts\Invoke-CodexSafeTreeDelete.ps1`
- 实现：`scripts\lib\CodexSafeTreeDelete.ps1`
- allowlist：`managed\safe-tree-delete\policy.json`
- evidence：`D:\agents\run-evidence\safe-tree-delete\<run-id>\`

2026-08-13 起新 Plan 会并列写出 `fileIdentitiesV2`（128-bit `FILE_ID_INFO`）。2026-08-15 起新 Plan 再并列写出 `leafStreamSetV1`（每个 treeManifest 条目的原始 stream 名集合、hardlink 计数与消费边界）；Apply 在 `apply-locked-preflight`、Purge 在 `purge-locked-preflight` 的各自 live freeze 内逐 leaf 复验 stream 集、文件 FileIdentityV2 与 hardlink 计数，冻结后增删换 stream/leaf 全部失败闭锁，缺少该节的旧 Plan 在 Apply/Purge 失败闭锁（Status/Archive 只读路径不受影响）。Purge 提交 `purged` 前在 run 目录 create-only 发布 `leaf-dispositions.json`，为每个 file/junction leaf 记录最终 disposition（`deleted`/`absent-at-purge-resume`）。缺少 `FILE_ID_INFO` 的卷上新 Plan 失败关闭。性能优化进度见 `docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`；操作者指南与实测表见该 spec「操作者指南」。uncertain 处理见下文 Purge 恢复段，不要从性能表推断删除是否完成。

`leafStreamSetV1.consumptionBoundary` 以 `requiresTreeManifestReverification='always'` 显式声明配对依赖：
stream-set 复验必须与 treeManifest SHA-256/identity 复验配对消费，不得单独信任。junction/directory
leaf 的 identity 不绑定进 stream-set，junction→junction 重定向在 stream-set 层不可检出，只能由
Apply/Purge 的 treeManifest sha/identity 比对层（含删除期逐 junction 重算 reparse sha）检出。
file leaf 携带命名流时 Plan 失败闭锁、记录后不放行——这是设计决策而非缺陷：下载文件常见的
`Zone.Identifier` ADS 会使整个 build-output 类目标无法规划，属有意为之的 fail-closed；目录命名流
按现状记录放行（`empty-project-state` 仍整体拒绝目录 named stream），漂移在各自 locked preflight
复验中失败闭锁。冻结保证以 locked preflight 为界：stream-set 断言与逐 leaf 删除之间的命名流增删
不再复检，新增流随 leaf 一并销毁且不进入审计。

宿主 PowerShell wrapper 是仓库 `scripts\invoke-codex-safe-tree-delete-host.ps1` 的受管副本，
直接转发到仓库生产脚本；因此仓库生产代码改动会进入宿主调用路径。wrapper hash 一致只证明
adapter 未漂移，不代表新的 policy schema 已激活。真实目标操作前仍须核对当前 policy 与 `Status`。

项目内 Codex 远程附件只允许以
`D:\Codex\projects\统一环境\.codex-remote-attachments` 为 capability root 删除其后代，
最小后代深度为 1；附件根本身和其他项目顶层目录不在该授权面内。

全局 .NET single-file bundle 解压缓存以 `D:\Codex\temp\.net` 为 capability root，
最小后代深度为 1、root 删除用途为 `none`，并精确拒绝
`D:\Codex\temp\.net\CodexProviderSync`。每个其他后代仍须单独完成受管计划与确认；
该条目不授权删除 `.net` 根或被拒绝的同级缓存。

用户 TEMP 以 `D:\Codex\temp` 为 capability root，最小后代深度为 1、root 删除用途为
`none`，并精确拒绝 `D:\Codex\temp\.net`（该子树只走上面的专用条目）。该条目不授权删除
TEMP 根本身；每个子目录仍须单独完成受管计划与确认。

Codex visualize 产物以 `D:\Codex\.codex\visualizations` 为 capability root，最小后代
深度为 1、root 删除用途为 `none`。该条目不授权删除 visualizations 根本身。

Codex memories 的过期子树退役以 `D:\Codex\.codex\memories` 为 capability root，最小后代
深度为 2、root 删除用途为 `none`，并精确拒绝
`D:\Codex\.codex\memories\extensions\ad_hoc`：该子树的 instructions.md 规定
"Never delete a note file"，其 notes 与 instructions.md 永不删除；denylist 只向下生效，
拒绝 `extensions` 不足以保护 `ad_hoc` 子树。该条目不授权删除 memories 根或 `docs`
等一级子目录本身；每个深度不低于 2 的候选后代仍须单独完成受管计划与确认。

解析器接受 policy schema v3、v4 与 v5；仓库当前生产 policy 仍是 v4，v5 激活尚未执行。
不得用 v5 fixture、benchmark 或源码存在推断生产 policy 已迁移。`schemaVersion` 与
`minimumDescendantDepth` 必须是真正的 JSON integer，不接受字符串或小数强转；v3 条目继续
严格拒绝链接树。v4/v5 的 `allowHardLinks` 与 `allowInternalDirectoryJunctions` 必须是 JSON
boolean；v4 缺失时为 `false`，v5 必须显式提供。任一为 `true` 时只允许
`minimumDescendantDepth=0`、
`rootDeletionPurpose=rebuildable-build-output`，且运行目标必须精确等于 capability root。
`minimumDescendantDepth` 通常至少为 1，且
`rootDeletionPurpose` 必须为 `none`。现役精确 root 删除用途为：

- capability root 自身是项目根之下的可重建构建产物根时，可设为 0 和
  `rebuildable-build-output`；项目 `.codex` 根不得冒充构建产物。
- capability root 精确匹配 `D:\Codex\projects\<project>\.codex` 时，可设为 0 和
  `empty-project-state`。该用途只授权 capability root 自身，不授权其后代作为独立目标；
  Plan 要求整棵树零文件，可以包含空子目录，任意普通文件、NTFS named stream 或 reparse
  point 都会失败关闭。
- capability root 精确匹配 `D:\Codex\projects\<project>` 且该项目已明确退役时，可设为 0 和
  `retired-project-root`。该用途只授权 policy 中逐项登记的 capability root 自身，不授权其
  后代作为独立目标，也不授权其他项目根。

第四种精确 root 删除用途 `retired-evidence-root` 不改写以上三条与 `none` 的语义；其安全边界、状态机、一次性授权、身份绑定、撤销语义与失败闭锁见 `docs/specs/2026-09-15-safe-tree-delete-retired-evidence-root.md`。

生产 policy 只为本项目退役的 `.codex` 精确声明 `empty-project-state`；
`retired-project-root` 只作为明确退役任务中的临时精确许可，成功 Purge 后必须在同一任务中
从生产 policy 撤销，避免未来同路径新项目继承旧授权。远程附件根仍保持最小后代深度 1 和
`none`，不在 root 删除授权面内。解析器继续拒绝未登记的 workspace/项目根和
项目外用户数据根。这不会授权父目录或同级目录。root 删除在 Apply 时仍只允许原子改名到
同父、随机 generation 绑定的 quarantine。Purge 仍校验原计划、transaction、当前树与文件
identity；只有 `purging` 中断恢复允许当前树成为原计划的未变子集，其他路径仍要求完整清单。

`rootDeletionPurpose` 在 Plan、Status、Apply、Restore 与 Purge 复验时都从**当前 policy 的对应
entry**读取，不从 plan 或 transaction 快照取值。plan 只持久化 `policyEntryId` 以及当时的
policy path/SHA，不写入 purpose 值。因此修改某 entry 的 purpose 会追溯翻转所有引用该 entry
的历史判定，尤其是 `purged` 且 target 仍存在：只有当前 purpose 仍是
`rebuildable-build-output` 才允许把重建目录与原 identity 区分开；改成其他值会把同一记录打成
namespace 仍存在。这与 policy SHA drift 同类，是已知架构选择，不是事务自身完成事实的独立
快照。改 entry purpose 必须按漂移对待。

生产 policy 只为以下五个精确可重建目录启用 hardlink；只有两个 `node_modules` 同时启用内部
directory junction：

- `D:\Codex\projects\codex-account-switch\src-tauri\target`
- `D:\Codex\projects\cc-switch\src-tauri\target`
- `D:\Codex\projects\cc-switch\node_modules`
- `D:\Codex\projects\开源分发 api\sub2api\frontend\node_modules`
- `D:\Codex\projects\serena\.venv`

directory junction 只能是普通父目录下的 mount-point 叶节点。句柄必须以
`FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS` 打开，绑定 file identity、reparse tag
与原始 reparse bytes SHA-256；target 只从原始 reparse data 解析为 D 盘绝对路径并验证位于原始
capability root 内，绝不打开或遍历 target。外部、symlink、未知 tag、根/祖先 reparse point
继续失败关闭。hardlink 只由 safe-tree-delete 专用 lease 按逐根 policy 放行；普通 hook/ACL/file
guard 仍拒绝 hardlink。两类专用 lease 都拒绝 share-write/share-delete 和非默认 ADS，删除前在同一
句柄复验 identity 与内容或 reparse bytes，并仅 unlink 当前目录项。

policy v5 还要求每个条目显式提供非负 JSON integer `minimumQuarantineAgeMinutes` 与
`producerFenceMode`。后者只接受 `manual-only` 或 `os-handle-required`：`manual-only` 仍允许逐笔、
显式确认的控制面操作，但拒绝 `BatchPurge`；批量清理只对已经让生产者持有
`New-CodexSafeTreeDeleteProducerLease` OS directory handle 的 `os-handle-required` capability 开放。
活动或挂起的生产者会以 Windows handle sharing 语义阻止 Apply rename；生产者退出或崩溃后句柄
由 OS 释放。这个 fence 只对实际接入 lease 的生产者成立，policy 字段本身不能证明所有 producer
已接入。

生产 CLI 不接受 policy 或 evidence override。测试替身仅位于 `tests\`，不得复制到宿主
脚本目录或作为生产入口。崩溃注入类子进程 helper（在指定阶段阻塞、持锁或 FailFast）不是
竞争性主 seam，也不构成第二生产入口。主 fixture 缺少对应 Mode 与 checkpoint 参数，结构上
无法承载这类探测；既有 Apply/Purge/Restore crash fixture 已建立同等先例。新增退出码或持锁
断言应挂在既有 fixture 或 ProductionSmoke 上，不得另开生产入口。

生产入口与主 fixture（`tests\Invoke-CodexSafeTreeDeleteFixture.ps1`）共用库内同一个 mode 分发
`Invoke-CodexSafeTreeDeleteMode`（#74）：确认拒绝对象、参数校验与库函数调用只在这里维护，入口只给出
各自的 policy / evidence 根，并负责输出与退出码。两个入口仍各自声明同一套 CLI 参数（Mode 的
ValidateSet 须在加载库之前生效）：新增 mode 或参数时两边同时声明，分发逻辑只改一处。fixture 钩子
按 mode 经 `-ModeArgumentsForTest` 追加，生产入口不传。CLI 合同一致与分发形状由
`tests\Test-CodexSafeTreeDeleteModeDispatch.ps1` 钉住。

## 部署门与维护窗口（2026-08-27，#56 Wave A）

宿主 wrapper 自 #56 起为 gate-aware shim（`scripts\invoke-codex-safe-tree-delete-gate-shim.ps1` 的受管安装）：每次调用在任何 dot-source 之前取得 current-user cross-session deployment mutex（名称内嵌 owner SID 命名空间实现用户隔离），检查固定 `D:\Codex\.codex\state\safe-tree-delete-deployment\maintenance.json`，并持锁到 child/本进程退出。marker 在场时新调用以可观察错误拒绝；abandoned marker 不被自动清除。

等锁超时报告持锁者（#77）：持锁者（gate shim、部署工具与 policy 维护工具）取锁后在同一状态根原子写 `gate-holder.json` 面包屑、释放锁前删除。内容只有 ASCII 的 `pid/processStartUtc/mode/acquiredAtUtc`：shim 的 `mode` 只取自 `-Mode` 参数（缺失或不合规为 `unknown`），部署工具为 `deploy`，policy 维护工具为 `policy-maintenance`；不记录目标路径或其它参数。面包屑写失败是有意降级，不阻塞调用；前持有者被杀（mutex abandoned）留下的残留由下一个获得者覆盖。shim 等锁超时的 JSON 保持 `ok=false`、`refusalReason=deployment-mutex-acquire-timeout`、exit 1 与 ASCII-only，追加 `holder:{pid,mode,acquiredAtUtc,heldSeconds,stale}`（PID 不存在或启动时间不符时 `stale=true`；面包屑缺失、不可读或格式不符时为 `{state:"unknown"}`）；部署工具等锁超时的消息保留 `deployment mutex acquire timeout` 前缀并追加 `holder=<同结构 JSON>`。写、读与 stale 判定只在 `scripts\lib\CodexSafeTreeDeleteGateHolder.ps1` 实现一次（policy 维护工具复用同一文件）：仓库 shim 源只以一行 dot-source 引用它，部署工具安装时把这一行替换为同一 project root 下该 lib 的原文，所以已安装 shim 自包含，取锁前不加载任何仓库代码。该 lib 属于 source closure 固定清单。

唯一部署 owner 是 `scripts\Deploy-CodexSafeTreeDelete.ps1`，只接受 `BootstrapGate | Deploy | RecoverRollback`，不复用业务 Mode，也不 commit/push。状态根固定为上述目录：`deployments/<deploymentId>/{00-intent.json, shim-backup.bin(+meta), phase-journal/, invocations/, final-receipt.json}` 与根级 marker。intent 为 create-only 且预绑定 `{deploymentId, ownerSid, previousClosureSha256, targetClosureSha256, shimBeforeSha256, shimTargetSha256}`；phase journal 为 create-only、前序 SHA 链接，顺序 `10 gate-bootstrap-started → 20 shim-cutover → 30 marker-active → 40 legacy-drained → 50 source-switch-started → 60 source-switched → 70 validation-passed → 80 complete`（或对应 `*-rollback-started/complete`），未知/重复/缺序/漂移均失败闭锁。

`BootstrapGate` 只推进到 shim cutover 并以"部署者持锁时新 invocation 必须等待"证明 gate 生效；`Deploy` 消费同 deploymentId 的已认证 bootstrap，写 marker、legacy drain（按 executable+PID+starttime+commandline 枚举旧版 safe-delete 调用进程，等待两次稳定零清单）、source switch（校验 live closure 等于 intent.targetClosureSha256；仓库工作树内容不属部署工具可写面，回滚由版本控制完成，工具只做"已就位"认证）、validation（native default variant 加载 + 小树 Plan 走 C# walker）后完成并删除 marker。marker-presence 矩阵是 `RecoverRollback` 的唯一 selector：phase 10–20 marker 必须缺席；30–70/rollback-in-progress 必须在场且四字段（schemaVersion/deploymentId/runPath/intentSha256）匹配；`complete`/`rollback-complete` 时 marker present 则验证后删除，absent 则验证 terminal phase 与 live 现场后幂等补 final receipt；其它组合失败闭锁。手工删 marker、raw cache/source 替换或另写临时恢复命令均不构成恢复。

`-StateRootForTest/-ShimPathForTest/-ProjectRootForTest/-MutexNameForTest/-StopAfterPhaseForTest` 是唯一测试 seam，仅进程内显式传参、生产调用不传递；部署测试（`tests\Test-CodexSafeTreeDeleteDeployment.ps1`）在 fixture state root/shim/mutex 上重放全矩阵且不触碰生产状态根；其 S10 经 fixture project root（仓库 gate shim 源、gate holder lib 与替身 entry）安装 gate shim，验证等锁超时带 holder（存活、持锁者被杀后 `stale=true`、目录不可写时 `{state:"unknown"}` 且调用照常完成）以及部署工具超时消息带 holder。

## policy 维护工具（#82，spec #73）

`scripts\Update-CodexSafeTreeDeletePolicy.ps1` 维护同 schema 的 policy 条目与 deny：独立脚本，不经 gate shim，不是生产入口的 Mode，也不属于 source closure，从仓库工作树运行。它与 shim、部署工具共用同名 deployment mutex（current-user 命名空间，等锁上限 5 分钟）与同一 maintenance marker，持锁期间写 `mode=policy-maintenance` 面包屑。等锁超时的 JSON 与 shim 同形：`ok=false`、`refusalReason=deployment-mutex-acquire-timeout`、exit 1，并附 `holder`。

参数：`-Mode DryRun|Apply`、`-ChangeSetPath`、Apply 必需的 `-ApprovedCandidatePolicySha256`（DryRun 输出的 `candidatePolicySha256`），以及可选的 `-ConfirmManualReviewOperationIds`。宿主 `.cmd` 链只能传单个字符串，所以单个值含 `::` 时按 `::` 拆成多个 operation id。变更集是 `{artifactType:"env-governance.codex-safe-tree-delete-policy-change-set", schemaVersion:1, changes:[...]}`，按声明顺序作用到现役 policy 原文：

| op | 字段 | 规则 |
|---|---|---|
| `add-deny` | `entryId`、`path` | 条目里不得已有同一路径（OrdinalIgnoreCase） |
| `remove-deny` | `entryId`、`path` | 必须恰好匹配一条 |
| `add-entry` | `entry` | 属性限于加载器的条目字段；`id` 是新的，`capabilityRoot` 不与现有 root 重复。新条目按仓库 policy 的字段顺序追加在末尾 |
| `retire-entry` | `entryId` | 移除整条，不改用途重用 |

变更集里的路径必须已是规范的 D 盘绝对路径：无相对段、无 `/`、无尾随分隔符。候选按仓库 policy 的书写格式序列化：`ConvertTo-Json -Depth 32` 两空格缩进、LF、末尾换行、UTF-8 无 BOM。现役文件不是这一格式时（`liveFormat.reserializesIdentically=false`，例如 CRLF），第一次 Apply 会顺带把它规范化。

两种 Mode 持锁执行同一条检查链，括号里是对应的拒绝代码：

1. 取锁，写面包屑。
2. 检查 marker（`deployment-maintenance-marker-present`）。
3. 用加载器读取并校验现役 policy（`live-policy-invalid`）。
4. 生成候选（`change-set-invalid`）。Apply 时候选 SHA 必须等于批准值（`candidate-sha-mismatch`）。
5. 候选原始字节只在内存里，不落盘。候选必须被加载器接受（`candidate-policy-invalid`），且按 `Get-CodexSafeTreeDeletePolicyStructureViolations` 不新增结构违例（`candidate-adds-structure-violations`）。现役已有的违例列入 `structure.liveViolations`，不阻止。
6. 在途检查（`in-flight-check-failed`、`in-flight-records-blocking`），规则见下。
7. DryRun 到此结束，输出 `ok=true` 与候选 SHA；除第 1 步的面包屑外不写任何文件，policy 目录与 evidence 根保持原样。Apply 用 policy 同目录临时文件原子替换：换名前复核现役字节未变，换名后复核候选 SHA（失败为 `policy-write-failed`）。成功时输出 `written=true` 与提示「policy 已对宿主立即生效，git 提交需另行完成」。
8. 删除面包屑，释放锁。

输出只有一行 ASCII-only JSON，`ok=false` 时 exit 1。字段有 `ok`、`mode`、`refusalReason`、`message`、`livePolicySha256`、`livePolicySchemaVersion`、`liveFormat`、`candidatePolicySha256`、`approvedCandidatePolicySha256`、`changes`、`entryCount`、`structure`、`inFlight`、`safeCleanupJob`、`written`、`notice`，超时另有 `holder`。脚本主体里的任何失败都输出这一行：参数检查在取锁之前进行，不合法时拒绝为 `invalid-arguments`；检查链之外的意外异常为 `unexpected-error`。参数绑定错误（未知参数、类型转换失败、`-Mode` 不在 `ValidateSet` 内、缺少必需参数）发生在脚本主体运行之前，由 PowerShell 报错，不产生这一行 JSON。`approvedCandidatePolicySha256` 只回显通过校验的批准值。输出只回显条目 id 与 operation id，不回显路径。

在途检查在进程内调用 Status 的 candidate-policy preflight（内存中的候选字节加候选 SHA，库参数 `-CandidatePolicyBytes` 代替 `-CandidatePolicyPath`），逐条读取 `policyCompatible` 与 `candidatePolicyCompatible`：

- `policyCompatible=true` 且 `candidatePolicyCompatible=false` 的记录按 lifecycle 处理：
  - `planned`：按 plan.json 的 `expiresAtUtc` 判断。未过期的阻止（`unexpired-plan`）；读不出过期时间的阻止（`plan-expiry-unreadable`）；已过期的只列入 `expiredPlans`，因为它不能再 Apply，变更后 Status 会把它报告为 `manual-review`。
  - `recoverable`、`purge-resumable`：阻止（`resumable-transaction`）。
  - `manual-review`、`inconsistent`：阻止（`manual-review-unconfirmed`），除非 operation id 列在 `-ConfirmManualReviewOperationIds` 中。已确认的列入 `confirmedManualReview`；没有用上的确认（无对应记录，或对应记录本就无需确认）列入 `unmatchedConfirmations`，不阻止。
  - 其他 lifecycle：阻止（`policy-bound-record`）。
- `policyCompatible=false` 的记录已绑定其他 policy 字节，只计入 `boundToOtherPolicyCount`。
- 阻止项列在 `inFlight.blocking[{operationId, lifecycle, transactionStatus, reason}]`。
- 不把 schema 2 transaction 重新解析成兼容。schema 4 policy 下 Apply 写的是 schema 2 transaction，所以任何变更都会阻止绑定现役 policy 的未过期 planned 与可恢复记录。

preflight 看不到的两处只列出、不阻止：

- **terminal 记录。** preflight 把 terminal 一律视为兼容。工具只检查未归档的 terminal：target 落在本次变更影响的路径内时（被移除、换 root 或改设置的条目 root，以及新增的 deny），用候选 policy 复核其 plan；不再解析的列入 `inFlight.terminalRecordsLosingResolution[{operationId, refusalReason}]`。变更后 Status 会把它们改报为 `manual-review`，所以 Apply 前先归档或接受这一结果。
- **SafeCleanupJob 描述符。** 它不在工具视野内。`safeCleanupJob` 按 job 的 policy 比对口径（原有条目全部不变，新增条目不与 job 的 capability root 重叠）列出 `changedExistingEntryIds` 与 `addedEntryIds`。仍需要的 job 先完成 Verify，再 Apply。

`-PolicyPathForTest/-EvidenceRootForTest/-MutexNameForTest/-MarkerPathForTest` 必须同时给出，`-StopAfterPhaseForTest`、`-GateWaitSecondsForTest` 与暂停 seam 只在这四个 seam 生效时可用。阶段序号是 10、20、30、40、50、60、65（换名前）和 70。暂停 seam 的 `-PauseAfterPhaseForTest` 与 `-PauseSignalDirectoryForTest` 必须同时给出：工具在第一个不小于该序号的阶段边界（仍持锁）在信号目录写 `paused-<阶段>`，等到同目录出现 `resume` 再继续，2 分钟内未放行即失败；测试据此在工具持锁期间观察面包屑与磁盘。这八个参数是该工具仅有的测试 seam，生产调用不传。回归套件 `tests\Test-CodexSafeTreeDeletePolicyMaintenance.ps1` 只在 fixture policy、evidence、mutex 与状态根上运行。

## 控制面与状态机

1. `Status`：只读枚举 evidence run，重新验证 plan、transaction、当前 policy、目标与 quarantine
   namespace、tree manifest 和 journal，逐项输出 `planned`、`recoverable`、`purge-resumable`、
   `terminal` 或 `manual-review` 等 lifecycle 及允许的下一步。异常或不完整记录必须隔离为
   `manual-review`，不能让单个坏记录掩盖其他健康记录。库内 candidate-policy preflight 只接受
   v5 或与现役 policy 同 schema 的候选，且必须给出精确 approved SHA-256；同 schema 候选只由
   policy 维护工具（#82）进程内调用。生产 CLI 不接受 policy override，schema 迁移仍须走受管激活
   流程，同 schema 的条目与 deny 变更走 policy 维护工具。

   `complete` 是整次扫描的聚合：仅当没有任何未终结、不一致或未解析 residual 时才为 `true`。
   可信 Archive 让合格历史记录退出 `blockingRecords` 并标为 `lifecycle=terminal`，但不蕴含
   `complete=true`。仍有未终结、不一致或未解析 residual 时，`complete=false` 是正确取值。
   不得把「归档全部合格 terminal 之后 `complete` 必为 true」当作验收。

   Archive 消除的是治理视图里的 blocking 噪声，不是 Status 每次全量枚举、重读并重哈希
   evidence 的扫描账。已归档记录仍要做 marker 与 namespace 认证。秒级返回不在本控制面史诗
   的验收范围内；日常顺手确认若仍不够快，另立项，不得靠放宽 Archive 或跳过认证换时间。

   历史 transaction schema v1 只在 `Status` 使用精简的只读观测解析，校验其与受管 plan 的
   generation、path 和 SHA 绑定后，输出真实 `transactionStatus`、`targetPath`、
   `quarantinePath` 与 `transactionUpdatedAtUtc`；该记录的 `schemaCompatible` 仍为 `false`。
   plan 的 policy SHA 与当前 policy 不同时，`Status` 以 `policyCompatible=false` 表达漂移，仍保留
   已验证的观测字段。`Purge` 与 `Restore` 的严格 transaction reader 继续只接受 schema v2/v3；
   v1 缺少 `directoryCommitAnchors`，不可由受管写入路径恢复或清理，也绝不通过补写空 anchors
   冒充 v2。

   范围查询（#80）：`Status` 可带 `TargetPaths`（经 `.cmd` wrapper 调用时同样以单个 `::` 分隔字符串
   传入），只回答这些目标。目标先于任何 policy / evidence 访问规范化为 D 盘全路径；拆分后为空或含
   空白、路径非法、规范化后重复（`OrdinalIgnoreCase`）都是普通 throw 的用法错误。记录完整认证后的
   `targetPath` 与任一目标按 `OrdinalIgnoreCase` 相等才算命中，不做 Unicode 规范化，与 `BatchPurge`
   一致；目标的祖先路径与后代路径都不算命中。命中记录照常完整认证并给出 lifecycle；无法确定
   `targetPath` 的记录（plan 解析失败、认证失败、空 run、evidence 根下的文件等）一律计入范围，为
   `manual-review`。结果在 `capturedAtUtc` 之后多出 `scope: {kind:"targets", targets[],
   matchedRecords, unattributableRecords}`，`targets` 是规范化后的目标、按传入顺序；`complete`、
   `blockingRecords` 与 `ready` 只针对范围内的记录。不带 `TargetPaths` 时输出与全量 `Status` 相同，
   没有 `scope` 字段。范围查询不持久化任何 receipt。

   范围查询在枚举阶段按声明预筛：run 目录有 `terminal-archive.json` 时读它，否则读 `plan.json`，只读到
   顶层 `targetPath` 为止（最多 64 KiB）。声明是合法 D 盘路径、且原样与规范化后都不等于任何目标时，
   该记录不读完整 plan、不做认证、不进参考路径，也不计入 `entriesScanned` 与 `bytesHashed`；读不到
   声明的记录一律保留并完整认证。完整认证得出的 `targetPath` 总与声明原样或规范化后相等，所以预筛
   不会漏掉命中记录，但声明只用于排除，不能代替认证。代价是：声明可读、完整认证却会失败的范围外
   记录（例如在 `targetPath` 之后被截断的 plan）不出现在范围结果里，全量 `Status` 仍把它报为
   `manual-review`。预筛依赖 safe-delete gate 的独占串行，即读声明与完整认证之间没有其他写入者，与
   `BatchPurge` 单次历史扫描的前提相同。fast scan 开或关都执行同一预筛；现有 kill switch（fast
   scan、tree fast、parallel fallback）照常生效，且不改变范围结果。

2. `Archive`：要求 `ConfirmArchive`、精确 transaction path 与 approved SHA-256，只为同时满足
   `status=purged`、quarantine 当前不存在、`restoreJournalAnchors` 为空的历史 transaction，在其
   operation run 内发布固定的 create-only `terminal-archive.json`。任一判据不满足时，以稳定原因
   拒绝且 operation run 零写入；重复归档必须认证并返回首份 marker，原始 bytes 与 file identity
   均不改变。marker 记录归档时点，并绑定固定 plan/transaction path、SHA-256、file identity、
   generation、schema、状态与 namespace；`Status` 重新读取这些受管内容并现场确认 quarantine
   仍不存在，不能只凭 marker 文件存在或其自报 metadata 判 terminal。可信 marker 让该历史记录
   退出 `blockingRecords`，但不改变 transaction schema compatibility，也不删除、重写或自动清理
   任何 evidence。归档合格 terminal 只改变该记录是否仍 blocking，不把整次 Status 的 `complete`
   翻成 `true`。权威合同禁止把「归档合格 terminal 后 `complete` 必为 true」当作验收。Archive
   与 Status 的 marker 认证均不补写 v1 `directoryCommitAnchors`，也不放宽 `Purge`/`Restore` 的
   严格 reader。

   schema v2/v3 的 Archive 与 `Purge`/`Restore` 复用同一 transaction schema、plan 绑定和 journal
   内容认证核心：v3 必须认证 quarantine-time 与 Restore journal 的 SHA-256、file identity 和引用链；
   purged transaction 的 directory commit anchors 必须认证 freeze/commit journals 并完整覆盖计划目录，
   无 anchors 时也不得遗留未锚定的 freeze/commit journal。合法但非空的 Restore anchors 仍以稳定
   `restore-journal-anchors-present` 原因拒绝，畸形 anchor/journal 则失败闭锁。该历史内容认证只读取
   operation run 内已绑定的 plan 与 evidence，不把当前 policy SHA 或 policy entry 可执行性混入判断，
   因此 current-policy 漂移不会永久阻断历史 v1/v2 Archive；`Purge`/`Restore` 仍须通过当前 policy
   可执行性校验，且其严格 transaction reader 仍只接受 schema v2/v3。

   多组 Archive（#85）用 `TransactionPaths` 与 `ApprovedTransactionSha256s` 按位置一一配对，一次归档
   多条 terminal 记录；经 `.cmd` wrapper 调用时，两者与 `TargetPaths` 一样各以单个 `::` 分隔字符串
   传入。多组参数不得与单组 `TransactionPath`/`ApprovedTransactionSha256` 混用；只给一半、拆分后组数
   不等、含空白组或拆分后为空时，在处理任何一组之前整体抛错且不写 evidence；缺少 `ConfirmArchive`
   时返回与单组相同的 `confirm-archive-required`。各组按输入顺序原样执行单组 Archive：独立认证
   approved SHA-256 与 operation run 绑定、独立持目标 mutex、独立 create-only 发布；任一组失败不影响
   其他组，失败的组不产生 marker。结果的 `results` 逐组给出 `transactionPath` 加单组返回字段，单组
   抛错收敛为 `refusalReason=archive-operation-failed`，并在 `error` 保留原异常消息。顶层只有
   `completed`（每组都处于已归档状态时为 `true`）、`transactionCount`、`archivedCount`（含
   `alreadyArchived`）、`alreadyArchivedCount`、`refusedCount`、`failedCount` 与 `results`，没有顶层
   `refusalReason`，因此 JSON 模式即使有组被拒绝或失败也 exit 0，由 `completed`、`refusedCount` 与
   `failedCount` 表达。多组参数只传一组时同样返回多组形状；单组参数的用法、输出与退出码不变，`terminal-archive.json` 格式不变。
   多组调用不放宽生产授权：对生产真实记录批量归档仍须用户另行授权。
3. `Plan`：规范化目标与 capability root，校验固定 allowlist、最小后代深度、denylist、
   root 删除用途、父链与完整子树；未授权 reparse point 一律拒绝，获准的内部 directory junction
   以 manifest schema v2 的不可遍历叶节点记录；`empty-project-state` 还会在发布计划前确认
   文件计数为零，并拒绝所有目录 NTFS named stream。通过后生成句柄绑定的文件 identity、
   SHA-256 和目录清单。
4. `Apply`：要求 `ConfirmApply` 与精确 `ApprovedPlanSha256`；复算完整树清单无漂移后，
   并再次确认 `empty-project-state` 没有 named stream，才通过目录句柄原子改名到同父
   `.codex-safe-delete-<generation>.quarantine`。此时可恢复。v5 Apply 生成 transaction schema v3，
   并以 create-only `quarantine-time.json` 绑定 wall clock、单调 uptime 与 boot session；v3 transaction
   允许 policy SHA 漂移后继续，但仍重新验证 policy path、entry id、target 与 tree policy，回退到 v4
   必须进入 `manual-review`。v3 crash recovery 如果缺少时间锚，只能在 mutex 内复验完整 quarantine
   后保守创建新锚，宽限期从该点重新起算。
5. `Restore`：要求 `ConfirmRestore`、精确 transaction path 与 approved SHA-256，只恢复尚未发生
   directory commit 的完整 v5 quarantine。它在目标 mutex 内复验 policy、identity 与完整 manifest，
   用 create-only intent、renamed、verified、complete journals 记录原子 rename 回原路径，并发布
   `restored` terminal transaction；中断重放必须幂等。`purging`、`purged`、`rolled-back`、部分删除、
   target 冲突或树漂移均拒绝恢复。
6. `Purge`：要求 `ConfirmPurge` 与精确 `ApprovedTransactionSha256`。`quarantined` transaction
   必须再次匹配完整计划清单；如果进程在发布 `purging` 后中断，则允许从 quarantine 中不超出
   原计划的节点子集恢复。恢复时 quarantine root identity 必须不变，仍存在节点的相对路径、kind、
   SHA-256 和 file identity 必须与原计划一致；只允许原计划节点缺失。`empty-project-state`
   的 quarantine 仍须再次通过 named stream 检查。v3 还必须证明 `minimumQuarantineAgeMinutes`
   已满足：boot session 变化、wall clock 回退、单调时间回退或 wall/monotonic 异常漂移均进入
   `manual-review`，不能从 transaction mtime 或 `updatedAtUtc` 推导隔离时长。最终删除每个目录时，
   先发布绑定 generation、
   relative path 和 file identity 的不可变 `freeze-prepared` journal，再在目录 DACL 首位加入对
   `Everyone` 的 `FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES`
   deny。实现必须读回实际 SDDL，并用原生新 ADS open 得到 `ERROR_ACCESS_DENIED` 来证明冻结真实
   生效；仅检查 ACE 文本不算通过。随后在同一句柄上完成最后一轮 empty/stream 复验，才发布引用
   freeze journal 精确路径与 SHA-256 的不可变 `commit-authorized` journal，并把目录标记为
   delete-pending 后关闭句柄。其他用途仍逐节点使用 handle-bound POSIX disposition 删除，包括
   ReadOnly 文件。完成后不可恢复。

   共享 handle-bound ACL writer 的合同面只包含 Owner、Group 和 DACL：Owner/Group 必须保持不变，
   desired SDDL 含 SACL 时必须在写入前失败闭锁且目标 ACL 保持不变。DACL protection 切换必须显式
   使用 protected/unprotected security-information 标志；切换到 protected 后，只允许 Windows 将
   inherited ACE 实体化为 explicit ACE 这一已知规范化差异，其他 Owner/Group/DACL 回读漂移仍失败闭锁。

   `Apply`、`Restore`、`Purge` 与 `Archive` 都在目标 mutex 内重新读取并复验各自受管输入，
   才允许写入 `prepared`、`quarantined`、`purging`、commit anchor、`restored`、`purged` 或 terminal
   archive marker。等待锁期间 capability 已变更时必须在
   写入前拒绝，不能用过期内存快照把已隔离或已完成 transaction 降级。

   journal 使用 create-only 原子发布：同一路径的第二次发布必须失败且不得改变原始 bytes 或 file
   identity。每个 `commit-authorized` 还必须在进入 delete-pending 前，由对应 transaction schema
   持久锚定 operation、目录 identity、freeze/commit 的精确路径、SHA-256 和 file identity。commit
   引用的 freeze 与 applied SDDL 必须可解析，并证明 requested SDDL 是原始 DACL 的首位有效 deny
   形态、applied SDDL 与其等价。`commit-authorized` 是删除线性化点：普通的 commit 前失败恢复首份
   freeze 记录的原始 SDDL 并发布 `aborted`；一旦开始 commit 发布，任何不确定失败都保持冻结，不得
   写出相互矛盾的 abort。FailFast 或重启后的重放复用最早 freeze 的原始 SDDL；已锚定 commit 直接
   重新核验 identity、DACL 和 stream 后完成删除，不生成第二份 operation。

   若 commit 后 quarantine 已不存在、transaction 尚停在 `purging`，只有 transaction 的锚定集合唯一
   覆盖全部计划目录，且每份 freeze/commit 都按路径、SHA-256、file identity、generation、operation、
   relative path 和 DACL 语义完整匹配，才允许收尾为 `purged`。任何未锚定 commit、未终结 freeze、重复
   identity、缺失 journal 或同一 operation 同时存在 commit 与 abort 都失败关闭。

   尚未 `commit-authorized` 的 `freeze-prepared` 是 in-flight pending。恢复时检查 journal
   记录的 `directoryPath`：路径仍在则列入 `pendingFiles`（可继续 Purge）；路径已不在则列入
   `uncertainFiles`，不得假设是本能力删除的，也不得收尾为 `purged`。用户应手工核验该路径后，
   再决定重新 Plan 或保持 `manual-review`。已 `commit-authorized` 且路径不在，仍按既有
   commit journal 规则计为已删除。`leaf-dispositions.json` 合法配对不含 uncertain。

   `leaf-dispositions.json` 的发布先于 `purged` 落盘。进程崩在两者之间的窗口时，恢复路径发现 run
   目录已存在 dispositions 证据，先做绑定校验（generation、plan SHA-256、transaction/quarantine
   path、`purging` 时点的 `updatedAtUtc`、stream-set 来源与 artifact/schema），再复核载荷：每行
   恰为 relativePath/kind/disposition/evidence 四字段，relativePath 必须是合法目录树相对路径，kind
   限定 `file`/`directory-junction`，disposition/evidence 限定合法枚举配对
   （`deleted`↔`exclusive-lease-reverification`；
   `absent-at-purge-resume`↔`purging-subset-resume`/`committed-missing-quarantine-journal`），
   行集合必须恰好一次覆盖 plan stream-set 的全部 file/junction leaf、无重复、无计划外行，summary
   计数必须与行重述一致。绑定与载荷均通过才以既有文档为准幂等收口为 `purged`，不重建、不做字节
   比对，审计记录保持首份内容；任一不一致、读取失败或形状漂移一律失败闭锁。该幂等收口同样覆盖
   `empty-project-state` 用途（纯目录树的 dispositions 恒为零行，空载荷合法）；绑定有效的
   dispositions 不豁免 `empty-project-state` 的 directory commit journal 完整性门禁，缺失锚定
   journal 仍以 `commit-authorized` 拒绝。无既有绑定证据时，非 `empty-project-state` 的缺失
   quarantine `purging` 仍按原条件硬拒绝，不得用空证据冒充完成。

   `leaf-dispositions.json` 的 SHA-256 只出现在 Purge/Complete 的返回值中，不锚入 transaction.json
   与 terminal-archive.json；终态发布后该文件的证据完整性不再受工具链保护，这是有意接受的取舍。
   不对称的理由：directory commit journal 锚进 `transaction.directoryCommitAnchors`，因为它是缺失
   quarantine 恢复的唯一授权依据，恢复决策必须能独立核验其身份与内容；dispositions 只是终态审计
   旁证与崩溃窗口幂等收口的载体，收口瞬间已由绑定+载荷双校验把关，终态之后不再参与任何授权
   决策，故不为它扩展 transaction/terminal-archive 的严格 schema。

   恢复入口前置读取 plan stream-set 的在途后果必须明示：`purging` + quarantine 缺失 + 旧 plan
   （无 `leafStreamSetV1`）的在途事务失去旧有的纯 commit-journal 恢复路径——stream-set reader
   在恢复入口即失败闭锁，该事务永久 wedge（Status 落 `inconsistent`/`manual-review`，Archive
   不可达）。这与"缺少该节的旧 Plan 失败闭锁"一致，是有意收紧；部署本版本前控制面必须先把
   全部在途事务收尾清空（呼应 #45/#50 的上线排序）。

批量清理使用 `BatchPurge`，调用方一次传入同一 capability root 下的多个 `TargetPaths`，并同时提供
`ConfirmApply` 与 `ConfirmPurge`。入口对每个目标仍逐项执行相同的 `Plan` / `Apply` / `Purge` 校验；
如果发现同一目标已有 `quarantined` 或 `purging` transaction，且原路径不存在、quarantine 仍存在，
则先按该 transaction 完成 `Purge`，再继续后续目标。这样批量调用中断后可以从受控 evidence 恢复，不需要
调用方手写循环、重新计算 transaction hash 或手工删除 quarantine。恢复匹配使用
`OrdinalIgnoreCase` 实现 Windows 路径大小写不敏感语义，但不做 Unicode 规范化；路径大小写变化不得
绕过或遗漏既有 transaction，NFC/NFD 等不同 UTF-16 路径也不得误配。通过 `.cmd` wrapper 调用时，
`TargetPaths` 使用单个 `::` 分隔字符串传入，避免 `cmd.exe` 把分隔符解释成管道或命令控制符。
policy v5 下，`BatchPurge` 还要求 capability 的 `producerFenceMode=os-handle-required`；
`manual-only` 条目必须逐笔处理。

只读预检使用 `Check`（#81）：输入 `TargetPath` 或 `TargetPaths` 二者择一（`TargetPaths` 同样接受 `::`
连接），`CapabilityRoot` 可省略。每个目标运行与 `Plan` 同一份目标解析判定
`Get-CodexSafeTreeDeleteTargetDecision`（`Resolve-CodexSafeTreeDeleteTarget` 只是把拒绝原样抛出的包装）：
路径合法、allowlist、root 包含、根删除用途与 link-aware 只允许精确 root、最小后代深度、denylist、
capability 路径校验、现存普通目录。每个目标返回 `{targetPath, allowed, policyEntryId, capabilityRoot,
depth, refusalReason, refusalMessage, candidates?}`，`refusalMessage` 与同一 CapabilityRoot 下 Plan 抛出的
拒绝原文逐字相同。省略 CapabilityRoot 时对每条条目运行同一判定，root 包含目标的条目都是候选：恰好一条放行
才采用；零条以 `no-capability-root`、多条以 `ambiguous-capability-root` 拒绝，并在 `candidates` 列出全部
候选及各自判定；目标路径本身非法时仍以 `invalid-target-path` 拒绝。Check 只读 policy 与目标路径的文件系统
属性，不读历史、不写 evidence、不建 run 目录；拒绝都在 JSON 里表达，顶层没有 `refusalReason`，退出码约定
不变；缺目标或两者都给是普通 throw 的用法错误。它只预报目标解析这一层：Plan 随后还会核对
retired-evidence-root 一次性授权是否已消费（读历史）、目标卷的 `FILE_ID_INFO` 能力和完整子树（未授权的
reparse point 或 hardlink、file leaf 的命名流、`empty-project-state` 的文件等），这些拒绝 Check 不预报。
Plan、Apply、Purge 仍要求显式 `CapabilityRoot`。

只读体检使用 `Lint`（#79）：不需要确认参数、不使用目标参数，只报告、不拦截。它另读一次 policy 原文并调用
现役加载器：加载器拒绝时报 `policy-load-refused`（加载器停在第一条违例），另按条目逐条报告重复 id、重复
capability root（规范化后大小写不敏感）与深度 0 未声明 root 删除用途。三条加载器结构规则只在
`Get-CodexSafeTreeDeletePolicyStructureViolations` 实现一次：deny 深度（与 Plan 同一口径，即 root 之后的路径
段数）不得大于最小后代深度；最小后代深度为 0 的条目不得带 deny；一条 root 严格位于另一条 root 之内时，父条目
必须有 deny 精确等于子 root。Lint 直接调用该函数，加载器的 fail-closed 执行属于 #84。以上都记 `error`；结果的
`nestedRoots` 列出全部严格嵌套对及其是否被覆盖。宿主规则记 `warning`：capability root 不存在（或是文件）、按
固定路径前缀推导的 owner 不存在（`Get-CodexSafeTreeDeletePolicyEntryOwner`；推导不出的为 host 级，不检查；
owner 不写入 policy）、deny 指向现存文件、deny 指向不存在的路径。evidence 根不存在时只报告、不创建；存在时
先过与 `Status` 相同的只读路径校验再枚举，不读文件内容、不跟随 reparse point。run 目录是 evidence 根顶层、
名字为 producer run id 的普通目录；规范 transaction 位置是 `<evidence 根>\<顶层目录>\transaction.json`（与
`BatchPurge` 历史扫描 C# 预筛的规范位置同口径；预筛的 `canonicalFiles` 另要求 producer 规范形态且读取、解析
成功），其余位置只按数量与相对 run 目录的位置报告，非 run 顶层
目录只报数量。每条 finding 为 `{rule, severity, entryId, denyIndex?, detail}`；deny 类只给条目 id 与 deny
序号，detail 不回显 policy 中的任何路径，也不回显非 run 目录名。

计划 30 分钟过期。缺少确认、哈希不匹配、policy 漂移、目标重新出现、目录内容或 identity
漂移、恢复时出现未计划节点或既有节点的 kind/SHA-256/file identity/root identity 漂移、
未授权或越界的 hardlink/junction/symlink/reparse point、越界路径以及并发 mutex 冲突均失败关闭。

DACL 冻结覆盖当前 NTFS 上遵守访问检查的普通新 ADS/子项创建，并跨进程退出与正常操作系统重启
保留。它不撤销 freeze 前已授予的句柄权限，也不声称约束 `WRITE_DAC`/`WRITE_OWNER`、父目录
`FILE_DELETE_CHILD`、`SeRestorePrivilege`、备份 API、内核驱动或突然断电后的介质落盘顺序；
最后的 handle-bound identity、empty 和 stream 复验用于在这些边界发生可观察漂移时失败关闭。

## 结果与可观测性

`Plan`、`Status`、`Apply`、`Restore`、`Purge` 与 `Archive` 都返回 metrics schema v1：phase、elapsed milliseconds、
scanned entries、logical bytes、hashed bytes 以及版本化 retry 记录。leaf delete 只对 allowlist 中的
sharing violation、lock violation 与 busy 做有界重试；生产合同最多 3 次 attempt、总预算 1000 ms，
退避为 10/25 ms。每次重试前仍须复验 handle identity 与内容，access denied、未知错误、identity/hash
漂移和 policy 扩张不得进入 retry；JSON `leaf-delete-failed` 以非零退出码返回结构化 metrics。
受管中间层（宿主 PowerShell wrapper）必须以 `$LASTEXITCODE` 转发内层退出码；变量不存在时按
0 处理。缺少确认的结构化 refusal 仍是 exit 0，只修传递、不改取值。`leaf-delete-failed` 的
非零退出码以生产脚本在发出该 JSON 后 `exit 1` 为准。持锁或 lease 失败若在发出该 JSON 前抛
错，不属于已证明的生产 Purge 失败观测，不得用未打出该 JSON 的路径声称合同已 live 验收。

`Lint` 不返回 metrics schema v1，结果为 `errorCount`、`warningCount`、`policy`（path、sha256、
schemaVersion、entryCount、evaluatedEntryCount、loadable）、`evidence`（root、exists、runDirectories、
nonRunTopLevelDirectories、transactionFiles、nonCanonicalTransactionFiles）、`nestedRoots` 与 `findings`。
结果没有 `refusalReason`，所以产出结果时按上述 JSON 合同退出 0：有 error 也不拦截，调用方按 `errorCount`
判断。policy 在两次读取之间发生变化、evidence 根未通过路径校验或 evidence 无法枚举时抛错，不给部分结果。

Purge/Status 的 `deletionOutcome` 必须分开表达 namespace 与存储事实：`namespaceAbsent=true` 和
`logicalCompletion=true` 只证明受管名称空间删除完成。没有独立文件系统 allocation 证据时，
`physicalReclaimStatus` 固定为 `unknown`；外部 hardlink、开放句柄、delete-pending 或 image mapping
场景都不得据此宣称物理空间已回收。`logicalBytes` 是 manifest 名称项口径，也不是物理占用。

`reports/safe-tree-delete-benchmark-20260809.json` 与
`reports/safe-tree-delete-metrics-evidence-20260809.json` 是 fixture 快照，不是生产激活凭证。当前证据
对 hash reuse 的结论为 `do-not-open-with-current-evidence`：不得用 benchmark 结果放宽逐字节内容认证、
改成 metadata-only approval，或透明替换 manifest。

## 上游边界

Codex Desktop 内建的破坏性命令预执行策略没有本机公开配置面。本 capability 不能阻止
调用者直接尝试语义等价 API；持续规则是 agent 与本机治理代码只使用固定入口。真正统一
所有删除语义仍需要上游执行器提供 typed delete capability。
