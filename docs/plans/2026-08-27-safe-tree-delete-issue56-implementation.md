---
type: report
title: 实施计划（审查通过，待授权）：safe-tree-delete #56 Plan 阶段 C# 单遍 walker
tags: [safe-tree-delete, 性能, 计划, issue56]
intent: 记录 GitHub issue #56 的 Wave A/Wave B 实施方案、验收协议，以及逐轮对抗审查的修订状态
---

# 实施计划（审查通过，待授权）：safe-tree-delete #56 Plan 阶段 C# 单遍 walker

> **终态（2026-08-28）：Wave A 已实施、部署并收口；正式性能认证未完成，#56 由维护者决定关闭。** 实现/测试/文档以 commit `fc73c05` 发布到 main；生产 deployment `wave-a-20260828` BootstrapGate→Deploy complete（gate 链路 live 冒烟通过，回退=env `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0`）；回归矩阵 5 profile 全绿。正式基准轮三轮全部 BENCH_INVALID（轮 1 宿主会话中断；轮 2/3 baseline 锚点 +29%/+68%/+110%，本机无法提供安静测量窗口），维护者决定不再安排重跑、按现状关闭 #56（结论评论 issuecomment-5450518070；G8 保持 NOT_READY，属决定路径而非协议完成路径）。候补参考：AC1 max=11231ms、typical≈7.11x、best≈7.32x。重跑命令与证据：`reports/safe-tree-delete-issue56-20260827/REPORT.md`。本文其余内容为实施前方案与审查记录。

> **状态（2026-08-27）：** 方案沿原 C# 单遍 walker + 条件 Wave B 路线完成多轮“fresh reviewer → independent verifier → 修订”闭环；最终两轴 reviewer 均为 `DONE`，独立 verifier 为 `FINAL_PASS`，无剩余 BLOCKER/MAJOR。**实施未授权**：票面原文“方案草案，未授权实施，实施前需另行确认”仍然有效。任何 #56 评论、commit、push、部署或 Wave A 实施均须另行明确授权；若 live issue、现行源码、权威合同或 loader/生产入口发生漂移，须重新打开方案审查。
>
> 本轮最终方案补齐 directory guard 同句柄 metadata seam、native compilation-unit/loader/deployment/recovery 边界、benchmark/fixture ownership、source/live-authority closure、typical/best 预注册、TOCTOU 负控、Wave B 生命周期及 AC/G1–G8 证据链。审查记录只说明计划成熟度，不构成实现、发布或关票证据。

## 1. 背景与目标

- #56 目标：Plan 阶段墙钟在 10k×4KB 场景降到 ≤40s（当前 88–96s），使端到端对 baseline 576238ms 最佳配置 ≥6x、典型不回退（≥4x）。
- 预算算术：6x 阈值 96039.7ms；六样本非 Plan 相位和 50917–55143ms（最差 = AC11 复跑 s1：Apply 22126 + Purge 33017）；Plan=40s 时最差样本余量仅 896.7ms，小于同日漂移先例（+3.5%），故 **40s 只是票面硬顶，设计运行点取 32s**（余量 8897ms ≈ 2.1× 非 Plan 极差 4226ms）。
- **方案核心转折**：票面草案假设主收益来自"并行哈希"，但证据不支持——#32 诊断 4KB 场景 SHA-256 仅占 ~10% 墙钟（90µs/文件，全集 ~0.9s），主收益来自把三遍 PowerShell 扫描换成一遍 C# 单遍 walker。并行哈希降级为条件触发的 Wave B。

## 2. 根因（现行实现，2026-08-26 快照）

`New-CodexSafeTreeDeletePlan`（`scripts/lib/CodexSafeTreeDelete.ps1:1017-1115`）对树做三遍独立扫描，每遍各自重新打开句柄：

1. PS 递归走树 `Get-CodexHookCapabilityDirectoryTreeSnapshot`（`scripts/lib/CodexHostSafety.ps1:881-1047`）：每文件 `Get-ChildItem`/`Get-Item`、`VerifiedDirectoryChainGuard.Acquire` 从卷根逐段打开全链、lease 内串行 SHA-256；
2. `New-CodexSafeTreeDeletePlanFileIdentitiesV2`（`:230-255`）逐文件再开句柄取 FileIdentityV2；
3. `New-CodexSafeTreeDeletePlanLeafStreamSet`（`:286-342`）逐 leaf 再开句柄取流集。

每文件 ≥4 次 CreateFileW、≥3 次句柄复验（含 `GetFinalPathNameByHandle` + ADS 逐字节清零枚举）、全串行 SHA、零哈希复用（`SessionHashCache` 只在 Apply/Purge 创建）。

参照数据：#32 的 C# `ApplyTreeSnapshotBuilder` 同构负载（完整 Apply 相位口径，含哈希与复验）22444/22629ms；单遍 C# 走树的仓库内参照是生产 Purge preflight `snapshotMs` ≈2798–2992ms（`reports/safe-tree-delete-issue42-20260819/iteration-2-benchmark.json`，`snapshotKind=csharp-apply-walker`）。两个口径不同、方向未定；**plan.json 的 PS 组装+ConvertTo-Json+回读成本零数据**——序列化 spike 前不承诺时间上界。

## 3. 分波、关票与口径治理（单一判定协议）

**Wave A** = C# 单遍 Plan walker（串行 lease 哈希，保留句柄复验）；**Wave B** = 条件触发的并行哈希。

### 3.1 预注册口径（不降低票面）

实施前的 #56 预注册评论只澄清可重复判定，不改变票面阈值；发布评论仍需用户明确授权：

- **AC1**：固定 100 目录 × 100 文件 × 4096B，恰好 3 个预注册正式 attempt，使用未取整原值的 `max(planElapsedMs) <= 40000` 判定；32s 仅是工程设计运行点，不是更改后的关票线。
- **AC2 typical**：固定生产默认 DOP2；每配置恰好 3 个预注册正式 attempt，以 `max(endToEndElapsedMs)` 为配置值，`576238 / value >= 4.0`。
- **AC2 best**：候选集预先固定为 `{DOP2, DOP4}`；按 `(max elapsedMs, median elapsedMs, DOP)` 升序唯一选出 best，DOP2 可以同时是 typical 与 best；`576238 / selected.max >= 6.0`。全部候选原值并列披露，不允许事后增加候选或按单次最快值选样。
- **AC3**：复用 AC2 的 3 个正式 DOP2 attempt，每个 attempt `journalOverheadPercent < 10.000`；任一达到或超过 10% 即 FAIL，不引入高于 10% 的 cap。
- 倍率和百分比使用未取整原值判定，只在展示层四舍五入。
- benchmark evaluator 固定退出码：`0=AC1-AC3 全过`、`2=有效测量但任一 AC 未达`、`3=baseline/source/DLL/样本协议无效`、`1=未处理执行错误`。

### 3.2 判定与状态机

1. AC1–AC5 live 通过且 AC6 的证据/commit/default-branch 前置已完成，只形成 `READY_TO_CLOSE`；评论与 close 仍需独立外部授权。授权执行后再以 post-close 模式验证结论评论、closed state、commit/index 绑定，只有该模式可报告 AC6/issue `COMPLETE`，避免把“尚未 close”循环定义为“不允许 close”。
2. AC1 未达 40s → 按 §6 的分段归因决定是否触发 Wave B；32s 只用于提前暴露端到端余量风险。
3. AC2 未达 → 不路由到并行哈希；先判定 source/baseline 协议是否有效，再归因非 Plan 相位或另立问题。
4. AC3 未达 → 阻塞关票并进入 journal 稳健性专项；并行 Plan 哈希不改变 Purge journal 行为。
5. 任一协议无效（退出 3）不产生 AC 结论；修复环境或证据闭包后整轮重测，固定分母仍为 576238ms。
6. 关票后任一 AC live 复测回退 → reopen #56，并按本节同一协议重验；不保留“确认/未确认”双口径。

## 4. Wave A 设计

### 4.1 新 walker 与窄目录 metadata seam

Wave A 先做一个行为不变的 compilation-unit prefactor：把 `CodexHookHandleBoundIO.cs` 现有 `HostSafetyParallelPurge*` adapter（当前约 L3150–3499，依赖 `FileIdentityV2`、`SessionHashCache`、`IParallelPurgeLeafDeleter`）移到新 `scripts/lib/CodexSafeTreeDeleteHostSafetyPurgeAdapter.cs`。新文件进入 safe-delete 两份 loader 的 base/default source 集；`CodexHookHandleBoundIO.cs` 恢复 BCL-only standalone `Add-Type`，供 remote catalog guard 单文件部署/加载。移动前后做类型清单与行为回归，不借 prefactor 改 Purge 语义。

`PlanTreeSnapshotBuilder.Build`，单遍递归：

- 每目录：枚举 + **稳定排序**（等价 PS `Sort-Object Name`：稳定 OrderBy + `CurrentCultureIgnoreCase`，平局保持枚举序）。规避 Apply walker `Array.Sort`（`scripts/lib/CodexSafeTreeDeleteApplySnapshot.cs:328-333`，不稳定）与 U+212A KELVIN SIGN/'k' 平局发散。目录条目安全复核（Apply 先例 `:307-314`）。
- file leaf：**成功获取 safe lease 是该 leaf 的权威线性化点**；枚举只提供路径与初步 kind，不声称拥有 open 前 identity。lease 获取后先从同一句柄捕获 baseline `{FileIdentityV2 stable fields, streamNames, hardLinkCount}`，触发测试 checkpoint，再调用 `lease.ComputeSha256FromHandle()`，随后从同一句柄重捕获同一组字段并逐项比较；`capturedAtUtc` 之外任一字段漂移均 throw，只有 pre/post 相等才输出 identity/hash/stream set。Wave A 不引入零复验直连路径（邻接性能 spec L466 "Skip identity verification — Will not do" 红线）。
- **junction 条目**：保留 per-path `LeafStreamSetReader.CaptureLeafStreamSet(path)` 重开（与 PS 现路径同源：open/share/flags 完全一致，`scripts/lib/CodexSafeTreeDeleteFileIdentity.cs:483-511`；受控 policy 下 junction 数量少）。`SafeTreeDeleteReparseLeafLease` 不暴露 raw handle；junction 的 reparse data sha 仍走 `ReparseDataSha256` 现路径，并记录与目录/file 同句柄捕获不同的已知观察边界。
- **directory/'.' root**：把 `scripts/lib/CodexHookHandleBoundIO.cs` 纳入 Wave A，给 `VerifiedDirectoryChainGuard` 增加 assembly-internal `CaptureSafeTreeDeleteDirectoryStreamSet()`，返回自包含只读 DTO `{ StreamNames, NumberOfLinks }`，**不公开 `SafeFileHandle`**。实现顺序固定为 `ThrowIfDisposed → VerifyDirectoryHandle → 前置 identity/link → 同句柄枚举并 ordinal 排序 streams → 后置 identity/link → 与 guard identity/前置 link 对比`；任一漂移 throw。该实现自包含 FILE_STREAM_INFORMATION 解析，避免 HandleBoundIO 反向依赖 `CodexSafeTreeDeleteFileIdentity.cs`；差分测试钉住两套 parser 的同值结果。
- C# 只返回原始数据（typed entries）；**全部 JSON 面对象由 PS wrapper 用现有构造器重建**（`ConvertTo-CodexSafeTreeDeleteFileIdentityV2Record` 等），保住词法双形态合同：`treeManifest.identity` 元素 lower-hex-8/16 字符串（`CodexHostSafety.ps1:810-818` 正则强校验）vs `fileIdentitiesV2.volumeSerialNumber` 十进制 JSON number、`fileSize` 整数、UTC 'o' InvariantCulture 文本、`streamNames` 空集 `[]` 非 null、`hardLinkCount` 整数、`topLevelEntries` 空态 `[]`。
- `PlanTreeSnapshotBuilder.Build(...)` 保持无测试 hook；另设 `BuildForTest(..., checkpoint)`，同步触发 `after-entry-observed-before-open` 与 `after-file-baseline-captured-before-hash`，不吞异常。第一个 checkpoint 只证明 file→directory/reparse 等 kind 漂移会在 open 时拒绝；同类普通文件若在 lease 前被替换，walker 合法地以新对象为本次 Plan 快照，不承诺检测替换历史。第二个 checkpoint 用于证明 lease 阻止普通写/rename/ADS/hardlink 变更，并用 synthetic capture fault 验证 pre/post 比较可变红。PS wrapper 只在库层 `PlanWalkerCheckpointForTest` 非空时调用测试入口；生产 CLI 不透传该参数。

### 4.2 fail-closed 双向对照表

PS 全量 throw → 新归属（walker / wrapper / guard 语义替代 + 理由）；C# walker 有而 PS 无 → 显式差异声明。要点：

| PS 现行 throw | 新归属 |
| --- | --- |
| FAT32/exFAT/no FILE_ID_INFO 硬门（`CodexSafeTreeDelete.ps1:1012-1013`） | wrapper 前置不变 |
| `Assert-CodexHookCapabilityPath`（含 noReparseAncestor，`CodexHostSafety.ps1:544-573`） | wrapper 前置全套保留（Apply wrapper `:1334-1357` 同款）+ 祖先 reparse 负路径用例 |
| junctionTargetRoot 空白/越界（`:903-911`） | wrapper（Apply 先例 `CodexSafeTreeDelete.ps1:1347-1357`） |
| 未授权 reparse / junction 越界（`:943-944`/`:956-957`） | walker |
| 目录条目非安全普通目录（`:927-928`） | walker（Apply 先例） |
| leaf kind 漂移（`:312-313`，三遍交叉） | walker 内“目录枚举属性 vs 句柄 IsDirectory/IsReparsePoint”双观察；open 前 checkpoint 覆盖 kind 漂移，lease 后 checkpoint 覆盖受保护窗口；open 前同 kind 替换在 lease 线性化点前，不伪称可检测 |
| file/junction leaf 命名流、relativePath 重复、'.' 边界（`:316-321`/`:241-242`/`:143-146`） | walker |
| empty-project-state ADS / tree policy（`:713-740`） | wrapper 对 walker 输出运行 |
| junction leaf/child 路径断言（`:946-949`/`:976-979`） | guard `ValidateChildPath` + 句柄链验证替代（Apply walker 同款，显式声明理由） |

directory/junction 子项走 guard.Acquire（Apply walker 同款），不额外 ValidateChildPath（避免设备名/长度超集收紧）。每条 throw 至少一个可失败负路径；仅比较未变树的等价性不能替代竞态负控。

### 4.3 接线与开关

- `New-CodexSafeTreeDeletePlan`：前置链不变 → wrapper → 组 document（字段/顺序/schemaVersion=1 不变）→ `Set-CodexHookCapabilityJson` 原子发布 + planSha256 回读不变。BatchPurge 经同一函数自动继承。
- 库层 `-DisablePlanCSharpWalkerForTest`（先例 `-DisableParallelPurgeForTest`）只切换**已成功加载后的算法行为**；它不是编译/加载回滚。
- 新 `scripts/lib/CodexHostSafetyNativeLoader.ps1` 集中唯一的 source 选择、digest、编译、发布和加载逻辑；`CodexHostSafety.ps1` 与 `CodexSafeTreeDelete.ps1` 只提供固定有序 source 集并调用它，禁止复制第二套 cache 算法。env `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0` 必须在 source 集构造及任何 PlanSnapshot `ReadAllBytes`/`Add-Type` 前读取：env=0 选 base source 集，默认选 base + PlanSnapshot；env=0 不得读取、散列或编译 PlanSnapshot source。
- cache 使用不可变内容寻址 generation：`<productionRoot>/<variant>/<compileCompositeSha>/`。compile composite 不只含 variant 与有序 source SHA，还绑定 native-loader contract version、PowerShell/.NET/compiler identity、target framework/architecture 与全部编译 options；任一合同变化产生新 generation。
- native loader 用内嵌、无磁盘依赖的最小 Windows bootstrap 获取每个 source 的 deny-write/delete handle，读取同一 handle 字节并保持 lease 到 staging 完成；只把已验 byte[] create-new 写入 no-reparse 私有 staging，编译子进程仅读取这些仍受 lease 保护的 staging 文件，不再按原 source path 重开，因此 source A→B→A 不能污染 compilation。编译输出在 staging 内完成，父进程以 guarded snapshot 读取 DLL byte[]/SHA；generation 目录写入 DLL 与 manifest（variant/compile contract/source hashes/DLL SHA）后 no-replace rename 发布。加载现有或新 generation 时均从已验 DLL snapshot 调 `Assembly.Load(byte[])`，不在 verify 后按 path 重开。
- final generation 已存在时验证 winner manifest/compile contract/实际 DLL SHA；失败 generation 不覆盖或删除任何已认证 generation。禁止固定 DLL 名、`-Force` 覆盖或路径式 verify→load。source ABA 与 DLL verify→load 替换 checkpoints 必须证明零错误加载/零发布。
- native loader helper 维护只读 process-local registry `{loadedVariant, compileCompositeSha, assemblySha256, assembly, requestedAlgorithm}`；两份 PS loader 每次调用都校验 registry。首载 default 后 env 切 0 保持 `loadedVariant=default` 与 PlanSnapshot 类型存在，只把 `requestedAlgorithm`/resolved walker 改为 PS，不再加载重复 base types；只有**首载即 base / registry loadedVariant=base** 时才断言 PlanSnapshot 类型不存在。首载 base 后请求 default 明确 throw `fresh-process-required`；同 variant/composite 幂等，任何其它转移拒绝。两种 dot-source 顺序、default→0 后真实 PS Plan 成功、base→default 拒绝均入测试。
- 编译时 source 前后 digest 不同、generation manifest/DLL 发布失败或 winner 校验不一致均失败且零 plan/evidence 发布；既有已认证 generation 不被未认证临时产物覆盖。env 开关**不承诺**救援 loader/helper 语法错误、`CodexHookHandleBoundIO.cs` 等 base source 编译失败或基础 generation 损坏，这些故障走 §9 的部署回滚。
- PS 三遍路径保留（Restore/Measure/Apply 回退仍在用，`Measure-CodexSafeTreeDelete.ps1:39`、`CodexSafeTreeDelete.ps1:5060/5128/5225` 等）。
- production loader 始终使用硬编码生产 root，不读取任何 test env/CLI/全局变量。内嵌 bootstrap 对 production root→variant→generation 全链执行 no-follow、handle-bound 普通目录验证；publish/load 全程持有 root/variant parent identity lease，final generation 必须是普通目录且 manifest/DLL 必须是普通非 reparse 文件，路径操作后复验 parent/final identity。variant/final-generation junction/symlink 替换 checkpoint 必须零加载/零发布。
- native loader helper 另提供**不被生产自动加载路径调用**的 fixture compilation seam；测试通过显式、仅进程内对象引用传入 test capability，不能序列化、不能由环境继承。capability factory 只在固定 D 盘 test parent 下创建 no-reparse、create-new、唯一空子目录并绑定 nonce/root marker；fixture 调用结束即失效。生产调用签名不接受该 capability。fixture 前后枚举并哈希生产 generation，证明字节集合完全不变。
- 覆盖：等价性测试按 §5 模式矩阵运行；在隔离 fixture source + test cache 中用故意损坏的 PlanSnapshot source 证明默认失败且 env=0 不读取该 source、可走 PS Plan。`CodexHookHandleBoundIO.cs` 还须 fresh process standalone `Add-Type`，并运行 codex-host 的 directory guard、remote catalog guard fixture/host-live 消费面；host-live 不透传库层 walker 开关，生产回退只验 env。
- 新 .cs 登记两处加载清单：`CodexHostSafety.ps1:14-21` `$nativeSources`（复合 SHA DLL 缓存自动失效重编）与 `CodexSafeTreeDelete.ps1:11-19` 兜底 Add-Type 批次。

### 4.4 序列化 spike（Wave A 第一步）

- 10k 树实测现行 PS 组装 + `ConvertTo-Json -Depth 100` + 回读，≥2 样本。
- 分段计时 8 段：preflight/enumerateOpen/identityStream/hashReadCompute/assemble/serialize/publish/readback；preflight 覆盖 policy、target resolve 与 filesystem capability。`ComputeSha256FromHandle()` 内部读与 SHA compute 不可分离，不伪造 read/compute 子段。另计算 `residualMs = totalElapsedMs - Σsegments`，要求 `abs(residualMs) <= max(250ms, totalElapsedMs*2%)` 且不得为显著负值；越界使分段证据无效。Wave B 归因中的 hash 段只指 `hashReadCompute`，residual 主导或证据无效时禁止触发。
- 阈值以区间表达（**4–8s，方向性未定**；锚点口径标注：#32 22.6s 是完整 Apply 相位含哈希，单遍参照 2.8–3.0s，两者间 ≥1s 的 walker 附加开销假设未推导；"hash ~0.9s"项为显式冗余余量，22.6s 已含哈希）。
- spike 仅早期预决策；**C# 序列化默认决策挂改造后 AC1 分段 serialize 段实测**，产物字节经等价性判据验证。
- spike 前提（PS 大 JSON 成本、#32 三次 snapshot 计数）标为未验证项直至实测。

### 4.5 metrics

- metrics schema v1 属性集**完全不变**（`tests/Test-CodexSafeTreeDeleteControlPlane.ps1:48-51`、`tests/Test-CodexSafeTreeDeleteMetricsEvidence.ps1:44-45` 精确 pin）。
- walker 分段计时写入独立版本化 evidence 产物，不进 metrics 对象。
- per-entry observer 事件由 wrapper 在 walker 结果上回放（Apply wrapper `:1378-1380` 先例；file=length、directory=0/0、junction=0/ReparseDataLength、hash-read 不计 entriesScanned、plan 发布后补一次 hash-read）。
- metrics 恒等式断言使用现行 observer 的完整来源：`bytesHashed = policyBytes + Σfile length + Σjunction reparseDataLength + planBytes`；policy/tree/plan 各自单列，双模式均断言，不能拿 walker 子段直接冒充 metrics 总值。

## 5. 等价性测试（新增）

- 协议：同一未变树先后跑两模式；对 treeManifest/fileIdentitiesV2/leafStreamSetV1 三块**保序逐位对比**（不按 relativePath 重排——排序设计点保留验收锚）+ 值类型断言。
- 排除固有差异字段按**字段名递归**生效（generationId、createdAtUtc/expiresAtUtc、**记录级** capturedAtUtc、planSha256、runDirectory/planPath）；`lastWriteTimeUtc/fileId128/fileSize/volumeSerialNumber` 必须参与对比。
- corpus：小规模多形态（目录 ADS 记录放行、junction、空目录、empty-project-state、Unicode 平局对 U+212A/'k' 与 'A'/'a'、文化敏感对（重音字符）、非 ASCII 名），不做 10k 规模（CI 时长）。
- 词法断言清单（§4.1 双形态合同逐条 + `treeManifest.schemaVersion=2`、directory 条目 `sha256=null`、identity 二元字符串数组、summary 计数数值类型）对**双模式产物**执行；PS 版本 + culture 固定进测试记录；Wave B 线程显式固定 culture。
- Status fast-scan 证据挂靠既有 fast-vs-slow 对照（`tests/Test-CodexSafeTreeDeleteStatus.ps1:1066-1086`）+ fast-scan 内 producer 形态冒烟。
- 跨版本回滚演示：经生产入口（env 切换）执行"C# 产物 plan → 在途 transaction → 切回 PS → Apply/Purge/Status 完成"；演示覆盖项 vs 真实 revert 差异矩阵（`$nativeSources` digest 驱动 DLL staleness、host 部署面、在途 transaction 代码版本归属）入证据。
- 新 `tests/Test-CodexSafeTreeDeletePlanWalkerEquivalence.ps1` 同时承担：directory guard 空流/ADS/ordinal 排序/DTO 防变异/disposed 拒绝的差分测试；枚举后 file→directory/reparse kind 漂移；lease 后普通默认流覆盖、rename、新增 ADS、未授权 hardlink alias 被 OS 拒绝；以及 synthetic pre/post metadata 漂移被 walker 检出。拒绝/检出用例要求 throw、`plan.json` 零发布、原目标与外部 alias 无损；另有同 kind file 在 lease 前替换后以新对象形成自洽 Plan 的明确正例，钉住线性化语义。
- 不改通用 runner 语法；在 `modules/manifest.json` 新增显式 profile：host-safety `fixture-base`（当前 fixture 全集减仅需 PlanSnapshot 类型的等价性套件）与 codex-host `handle-consumers`（directory guard、remote catalog guard fixture 三件套及 vendor-abort stress）。模式矩阵与命令固定为：① default env 跑 host-safety `fixture` 全集，等价性套件在 default generation 内用 C# 默认路径与库层 disable 的 PS 路径逐位对比；② process-scoped env=0 跑 host-safety `fixture-base`；③ host-safety `host-live` 分别以 default/env=0 跑两轮；④ codex-host `handle-consumers` fresh process 跑一轮；⑤ in-memory test capability + isolated cache seam 覆盖 default/base generation、损坏 source 与并发发布。每个 profile 的 expected list 来自 manifest 并在执行前固化，记录 listed/discovered/executed/skipped；未调度的 suite 不伪装成 skip。
- benchmark evaluator 用 synthetic evidence 负控植入 `40001ms`、best `<6x`、journal `10.000%`、source closure 漂移，分别断言退出 2/3 且不得输出 PASS；另有全绿向量断言退出 0。

## 6. Wave B（条件触发）

- 触发：Wave A 落地后 Plan 独立基准（生效 AC1 判定线口径）超线。
- 触发后按分段归因选分支：serialize 段主导 → C# 序列化；enumerateOpen/identityStream 主导 → walker/seam 实现复查；`hashReadCompute` 主导 → **先复核分段累计口径再谈并行**（守则：该段 >3s 先审计；串行哈希全集 ~0.9s，hash 主导大概率是口径或存储状态问题）；assemble/publish/readback 主导或无主导段 → 不开并行哈希，另立归因票。
- 并行哈希前置硬门（全部满足才实施）：
  - (a) positioned/OVERLAPPED 读或每任务独立句柄（现 `ComputeSha256FromHandle` 用包装句柄共享 FileStream 且无锁，`CodexHookHandleBoundIO.cs:2143-2151`/`:2177-2185`，多线程竞争文件指针会产生**错误摘要**）；
  - (b) lease 持有上限 + 队列深度上限（快走树慢哈希背压下避免累积大量 DELETE 句柄）；
  - (c) 发布前对并行结果串行复算抽验或等价防线；
  - (d) 哈希负载 DOP 扫描实测定值（DOP=2 出自 Purge 删除负载 `reports/safe-tree-delete-parallelism-benchmark-20260819/analysis.json`，跨负载外推，"≤2"为待验证上限非默认）；
  - (e) `RecommendParallel==false`（网络/非 NTFS 族）强制串行 + kill switch `-DisablePlanParallelHashForTest`；
  - (f) spec 修 L450 + L468 + 操作者指南门控条款；
  - (g) **任何新增哈希执行例程必须声明句柄绑定/复验契约 + 同句柄 identity/hash 时序负路径用例；独立句柄模式必须完整走 `AcquireSafeTreeDeleteFileLease`**。
- Wave B 生命周期固定为单 producer + DOP workers + bounded channel（capacity=DOP）；每个 work item 独占一个 `SafeTreeDeleteFileLease`。独立总量 semaphore 容量 `2*DOP`，覆盖 producer-local staging + queued + running：producer 必须在 retain owner/acquire lease **之前**取得 permit；任何 producer 失败路径或 worker `finally` 在 dispose lease 后释放 permit，因此实时 lease 总数硬上限才真正是 `2*DOP`。directory guard 由 ref-count owner 管理：遍历持 base ref，入队前保留 owner ref再 acquire lease，worker `finally` 必须先 dispose lease、release permit、再 release owner，最后一个 ref 才 dispose guard。
- 首错以原子 first-error + CTS 停止新派发/新 acquire；producer `finally` 完成 channel。成功 `WriteAsync` 是 permit/owner/lease 的唯一 ownership transfer 点：此前任何 retain 后 acquire 失败、acquire 后 write 失败/取消都由 producer `finally` 按状态 dispose lease、release owner、release permit；成功入队后三者只由 worker 释放。worker 不因取消直接退出 reader，而是 drain 并释放全部已入队项；`WhenAll` join 后才抛首错，清理错误不得覆盖首错。每个 transfer checkpoint 断言 permit/ref/lease 归零；producer 完成、channel drained、workers joined、无首错/取消、scheduled=completed、ordinal 结果无缺失/重复前禁止发布。
- 发布前固定抽样串行重开 safe lease 复算：`min(total, max(32, ceil(total*1%)))`，上限 128；样本选择算法与 seed 写入 evidence。任一 identity/hash 漂移即零发布失败。并发测试覆盖 worker/producer/取消首错、阻塞 worker 下 lease 上限、guard 不早退、双故障首错稳定及全路径释放。
- AC4 的"FAT32/网络仍串行"：Wave A（全局串行）下由 `tests/Test-CodexSafeTreeDeleteFileSystem.ps1` 实卷段（skip 语义）+ #35 waiver 证明；Wave B 另加并行门控负路径用例。

## 7. 验收（票面 AC 与本地 Gate 分层）

### 7.1 票面 AC 映射

| #56 原始 AC | 原判据（不重编号、不降低） | 本地实现 Gate |
| --- | --- | --- |
| AC1 | 10k×4KB Plan 两组最低要求、每组 ≤40s | G1/G2/G4；本计划加强为 3 个正式 attempt 且取 max |
| AC2 | typical ≥4x、best ≥6x，固定分母 576238ms | G1/G2/G4；固定候选与 max 聚合见 §3.1 |
| AC3 | 推荐配置 journal overhead <10% | G2/G4；3 个 DOP2 attempt 全部 <10.000% |
| AC4 | TOCTOU/crash/uncertain/网络降级安全回归，FAT32/网络串行 | G3/G5/G6 |
| AC5 | 全量回归，仅允许既有 #35 waiver | G3/G5/G7 |
| AC6 | 版本化证据发布到默认分支后，结论评论并关闭 | G1/G7/G8；外部动作仍需后续授权 |

本地 Gate 不冒充新票面 AC：**G1 source/live-authority closure、G2 attempt ledger/attestation、G3 producer 等价与竞态、G4 benchmark evaluator、G5 regression/skip、G6 loader/rollback、G7 ownership/module boundary、G8 top-level pre/post-close evaluator/evidence replay**。G8 pre-close 只能输出 `READY_TO_CLOSE`；G8 post-close 才能输出 `COMPLETE`。G4 只能输出 `BENCH_PASS|BENCH_FAIL|BENCH_INVALID`，不得输出最终 PASS。

### 7.2 Source 与测试闭包（G1/G7）

- 记录 HEAD；只对本次闭包保存 `git status --porcelain=v1 -- <closurePaths>` 原文及 SHA，不因无关脏文件阻塞。闭包必须包含 `modules/manifest.json`、module boundary validator/test、benchmark/close evaluators、`Deploy-CodexSafeTreeDelete.ps1`、生产 shim/入口、两份 PS loader、native loader helper、policy、loader 实际选择的全部 Add-Type source（含 PlanSnapshot 与新 Purge adapter）、`Run-PowerShellTests.cjs`、runner 动态解析出的 profile/命令清单和全部 discovered test 文件；每项记录 `{repoRelativePath,length,sha256}`，ordinal path 排序后折叠 `closureSha256`。
- warm-up 后、每个正式 attempt 前后、每个 test profile 前后重算闭包；任一漂移整轮退出 3。记录所选 content-addressed generation path、manifest SHA、DLL SHA/mtime 与 native composite SHA；目录名、manifest source SHA、实际 DLL SHA 任一不匹配即无效。
- `CodexHookHandleBoundIO.cs` 的消费影响矩阵同时覆盖 host-safety 与 codex-host：fresh standalone `Add-Type`；`Test-CodexHookDirectoryGuard.ps1`；remote catalog guard fixture 三件套；`Test-CodexRemotePluginCatalogGuardVendorAbortStress.ps1` host-live；并执行 module boundary validator/test。
- G1 不信任本地 remote 名称：预注册后通过 GitHub API 固定 repository database id/nameWithOwner/default branch 与 #56 issue id/body SHA/pre-close `updatedAt`，并绑定预注册 comment id/body SHA/createdAt。body SHA、预注册 comment 与 pre-close `updatedAt` 在 benchmark 和 `READY_TO_CLOSE` 前必须稳定；repo identity/body/comment 漂移使结论失效并回到计划审查。post-close 不要求 `updatedAt` 保持旧值，而只接受 G8 明确定义并授权的 conclusion-comment→close 转移。尚未获授权发布预注册评论时，本地方案只能保持“审查完成、不可实施”。

### 7.3 正式 attempt 状态机与验真（G2/G4）

- 固定 schedule：`baseline-pre → AC1-s1..s3 → DOP2-s1,DOP4-s1,DOP2-s2,DOP4-s2,DOP2-s3,DOP4-s3 → baseline-post`。每次 spawn 前 create-only 写入带单调 sequence/固定 scenario label/UUID 的 `attempt-started` 文件；结束时 create-only 写入独立 `attempt-terminal` 文件。两者同时记录 UTC 与单调时钟，selector 要求 started/terminal 精确一一配对且 UUID/sequence/label 相同、attempt 零重叠、baseline 后 gap≥120s、其余正式 attempt gap≥60s；禁止覆盖、双终态、孤儿、乱序、额外 attempt 或信任预聚合 summary。原始字节进入输入 manifest。
- **不允许排除、替换或隐形重试任何正式 attempt。** 非零退出、超时、缺字段、closure/DLL 漂移使整轮退出 3；有效但阈值未达退出 2。环境修复后只能在新 evidence 目录重跑完整 schedule，旧轮保留为 invalid。
- 每个 child 都使用 fresh `pwsh -NoProfile -NonInteractive`，并记录/强校验：attempt/parent/child PID 与进程开始时间、完整 argv、相关 env、PowerShell/PSEdition/.NET/OS build、culture/UICulture、processor count、process priority、`walkerKind`、native variant/generation/DLL digest、树目录/文件/字节数、Apply/Purge hash-reuse 实际状态、parallel purge used/reason/actual DOP、8 段计时与 residual。storage attestation 还须记录 canonical capability/fixture parent、volume GUID/serial、filesystem/drive type、FileSystemCapabilities、network/reparse 状态、可解析时的 disk/device/model/bus/media facts，以及确定性 fixture definition/tree digest；整轮 baseline/candidate 前后必须同卷同设备同能力，任一漂移或不可比退出 3。若现有生产结果未暴露某字段，新增**版本化 benchmark-only diagnostics**，不得修改 plan.json 或 metrics schema。
- default 场景必须回报 `walkerKind=csharp-plan-snapshot` 与 PlanSnapshot variant；env=0/baseline 必须回报 `walkerKind=powershell-three-pass` 与 base variant。DOP2/DOP4、reuse 与串行 baseline 均以生产代码 resolved configuration 为准，不按标签或 argv 推断。synthetic evaluator 对错 walker、错 DLL、错 DOP、错 reuse/fallback reason 分别设退出 3 负控。

### 7.4 运行与票面判定（AC1–AC3）

- 先运行一次完整 Plan warm-up，仅允许生成/加载磁盘 DLL，不计时；warm 只代表 DLL cache，不宣称跨进程 JIT/hash cache。前后 legacy baseline 必须复用 iter1 runner/树形/场景，启用 `DisablePlanCSharpWalkerForTest`、`DisableApplyHashReuseForTest`、`DisablePurgeHashReuseForTest`、`DisableParallelPurgeForTest`，resolved configuration 必须证明 Plan=PS 三遍、Apply/Purge 无 hash reuse、Purge 串行。两次 baseline 均须在 576238ms ±10%，只作环境 sanity、不替换分母；任一越界退出 3。
- baseline 后冷却 ≥120s，正式 attempt 间 ≥60s；预计完整轮次 45–60 分钟，脚本超时覆盖该上界，计时期间不并行运行其它测试/负载。
- **AC1**：`Invoke-Issue56PlanBenchmark.ps1` 复用 iter2 `New-ScaleTree` 同一路径，每 attempt 重建确定性 100×100×4096B 树；3 个 attempt 的 `max(planElapsedMs) <= 40000`。同时报告 32s 设计目标、8 段计时与 residual，不以 32s 替换票面线。
- **AC2**：DOP2/DOP4 按 schedule 交错；typical 与 best 使用配置 max，固定 576238ms 分母，分别要求 ≥4x 与 ≥6x。
- **AC3**：3 个 DOP2 attempt 全部 `<10.000%`；历史 2/6 超线只表示风险，不用于放宽阈值。

### 7.5 回归、skip 与证据闭包（AC4–AC6 / G3/G5/G6/G8）

- 按 §5 模式矩阵和 manifest 动态集合记录 `listed/discovered/executed/passed/failed/skipped`。唯一允许 skip tuple 是 `{suite=CodexSafeTreeDeleteFileSystem, leg=liveFsLeg, reason=skipped-non-elevated, condition=(isElevatedProcess=false && nativeFatFamilyDriveCount=0), waiverIssue=35}`；该套件须新增并类型钉死 `processId/processStartTimeUtc/isElevatedProcess/nativeFatFamilyDriveCount/skipReason/waiverIssue`，evaluator 从同一输出的结构化 live drive inventory 重算 FAT-family count，不解析人类文本。reason/condition/waiver 漂移或任何额外 skip 均退出 3。当前 host-safety fixture=27，登记一个新等价性测试后预期 28，但 Gate 以动态集合而非硬编码数量裁决。
- `Test-CodexSafeTreeDeletePhase3Integration.ps1` 不再把历史 `D:\Codex\.codex\run-evidence\...0ab1...` artifact 的存在性当作 #56 Gate；该旧 leg 只记录 `historicalLeftoverObservation=present|absent`，不输出 skip、waiver 或 PASS 条件。确定性“不触碰无关对象”覆盖改为在 test-owned current fixture/evidence root 下 create-new 建立独立 sentinel，记录 identity/bytes，Phase3 前后强制不变并清理测试自有对象。所有条件 leg 输出结构化 `{suite,leg,status,reason,condition,assertionsExecuted}` receipt，G5 不扫描 `[SKIP]` 文本也不只看进程退出 0。
- G4 synthetic 负控至少包含 `40001ms`、best `<6x`、journal `10.000%`、source closure/storage 漂移、attempt 缺失/重复/孤儿/双终态/乱序/额外/错 UUID/错 label/重叠/短 gap、runtime 配置错标，以及能区分 `min`/`max`、median、tie-break 的原始向量；分别断言 BENCH_FAIL/BENCH_INVALID 且不得输出 `READY_TO_CLOSE`，另有全绿向量输出 BENCH_PASS。
- benchmark evaluator 只消费有序 `attempt-input-manifest.json`；该 manifest 哈希全部 attempt ledger、raw/stdout/stderr、runtime/storage attestation 与 source closure `{path,length,sha256}`，结果记录 `inputManifestSha256` 与 evaluator source SHA。
- G1–G7 各自定义固定 schema、allowlisted input manifest 与纯 evaluator；receipt 的 PASS 字段不具权威。G8 必须从 cited commit blobs 读取每个 Gate 的 evaluator 与原始 allowlisted inputs，重新执行语义判定并逐字段比较 receipt；伪造 PASS、空 input manifest、未知输入文件、evaluator SHA 漂移均拒绝。benchmark 全绿但 crash/module-boundary 失败的向量必须拒绝 close。
- G8 pre-close 在重放 G1–G7 后生成排除自身的 `evidence-index.json`（覆盖其余 evidence 每个 `{relativePath,length,sha256}`），重新读取验证 index；AC1–AC5 与 AC6 发布前置全满足才输出 `READY_TO_CLOSE`。任何后续字节修改都必须重跑受影响 Gate 与 G8。
- 未来获得 commit/push 授权后，G8 commit 模式通过 GitHub API 校验固定 repository identity，要求权威 default branch SHA 等于 `citedCommit`；逐文件用 `git cat-file <commit>:<path>` 取得 blob并与 source closure/evidence-index 字节比较，再从 cited commit blobs 重放 evaluator/G8，不信任本地 `origin`。未来结论评论同时引用 cited commit 与 index SHA。
- 获得 comment/close 授权后，先发布绑定 commit/index/Gate 摘要的结论评论再关闭。G8 post-close 绑定 conclusion comment `{id,bodySha,author,createdAt}` 与 GitHub close timeline event `{actor,closedAt}`，要求 `comment.createdAt < closedAt`，pre-close 后无 body edit、未授权评论、reopen/reclose 或其它 state transition，并要求最终 issue `updatedAt` 等于/对应授权 close event 后状态；随后再验证 state=closed、预注册评论、repository/default branch、commit/index 和 pre-close result。全部匹配才输出 `COMPLETE`；任何漂移保持未完成或按 §3.2 reopen。
- 选定实际日期并创建 `reports/safe-tree-delete-issue56-YYYYMMDD/` 后，manifest 精确登记 `CodexSafeTreeDeletePlanSnapshot.cs`、`CodexSafeTreeDeleteHostSafetyPurgeAdapter.cs`、`CodexHostSafetyNativeLoader.ps1`、`Invoke-Issue56PlanBenchmark.ps1`、`Invoke-Issue56CloseGate.ps1`、`Deploy-CodexSafeTreeDelete.ps1`、`Test-CodexSafeTreeDeletePlanWalkerEquivalence.ps1`、`Test-CodexSafeTreeDeleteDeployment.ps1` 到 ownership；两个新测试、`fixture-base` 与 codex-host `handle-consumers` profiles 到测试清单；实际 report 目录到 prefixes。commit/push、结论评论与 close 仅在用户后续分别授权后执行。

## 8. 文档一致性

- Wave A 同批修订**现役**性能 spec（`docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`）：**L448（Plan 优化入范围）+ L451（Plan 走树 C# 重写入范围——Wave A 直接触碰该 non-goal）**、L6 状态行、L29 移交语；勘误“3/6 ≥10%”→“2/6”（L29/L111/L121），13.045% 统一为原始 JSON 四舍五入的 13.046%。历史 REPORT/GROK/JSON 是时间点 evidence：原始 JSON 与原叙事不改，只在独立 dated errata 中引用原始 SHA 并记录更正，避免把旧快照静默改写成新结论。
- `modules/host-safety/CONTEXT.md` 权威合同行（"6x 移交 #56"）收尾。
- 记录项：directory/file 同句柄 capture、junction per-path capture 的观察差异；guard 目录句柄（FileShare.Read）vs junction per-path（ReadWrite|Delete）在“并发写者已持句柄”极端时序下的打开成败差异；ValidateChildPath 不用于 directory/junction 子项的决策；两个 test checkpoint 只存在于库层测试入口。
- capability spec（`docs/specs/2026-07-24-safe-tree-delete-capability.md`）纳入 Wave A 同批修订：记录 deployment gate 的 current-user cross-session identity/ACL、所有 mode 在 dot-source 前取得并持有到退出的顺序、maintenance marker/state-root schema、`Deploy-CodexSafeTreeDelete.ps1` 三 Mode 与 create-only phase-journal 状态机、abandoned gate/残留 marker 的 `RecoverRollback`、首次激活 legacy drain、部署/回滚和可观察拒绝语义。Wave B 触发时再修性能 spec L450/L468 与操作者指南并行门控；不得用“只是实现细节”跳过新增的全局并发/恢复合同。

## 9. 回滚

- 范围：host-safety 单模块 + shared `modules/manifest.json`；plan.json schema 不变 → 新旧 producer 产物可互换，在途事务绑定已落盘 plan 字节（planSha256）不受 producer 切换影响。
- 行为止血：fresh process 设置 `CODEX_SAFE_TREE_DELETE_PLAN_CSHARP_WALKER=0`，选择 base DLL 变体并走 PS producer；不读取 PlanSnapshot source。它覆盖 PlanSnapshot 缺失/编译失败和已加载后的 walker 行为回退。
- 新增唯一版本化部署 owner `scripts/Deploy-CodexSafeTreeDelete.ps1`；只接受 `BootstrapGate | Deploy | RecoverRollback`，不复用业务 Mode，也不 commit/push。它独占与生产 shim 相同的 deployment mutex，固定 state root 为 `D:\Codex\.codex\state\safe-tree-delete-deployment\`，认证 current-user SID、普通目录/no-reparse 父链及 marker/run identity。任何部署、shim cutover、maintenance 解除或崩溃恢复只能经该工具；手工删 marker、raw cache/source 替换或另写临时恢复命令均不构成恢复。
- `BootstrapGate -DeploymentId <new>` 是唯一可 create-new 建立 `deployments/<deploymentId>/00-intent.json` 的 Mode；intent 预绑定完整 workflow `{deploymentId,ownerSid,createdAtUtc,previousClosureSha,targetClosureSha,shimBeforeSha,shimTargetSha}`，不把单次 CLI mode 写成 transaction identity。`Deploy -DeploymentId <same>` 与 `RecoverRollback -DeploymentId <same>` 只能认证并打开既有 run，禁止创建/改写 intent；每次调用另写 create-only `invocations/<sequence>-<mode>-<uuid>.json` 审计 receipt，不能改变 phase selector。
- 固定 maintenance marker 只有一份不可变 schema：`{schemaVersion,deploymentId,runPath,intentSha256}`；owner、previous/target closure 与当前状态均从已认证 intent和 create-only、前序 SHA 链接的 phase journals推导，不在 marker 重复可漂移字段。phase 顺序为 `10-gate-bootstrap-started`、`20-shim-cutover`、`30-marker-active`、`40-legacy-drained`、`50-source-switch-started`、`60-source-switched`、`70-validation-passed`、`80-complete`，或对应 `*-rollback-started/*-rollback-complete`；未知、重复、缺序或 hash/identity 漂移均失败闭锁。
- `BootstrapGate` 只允许推进到 shim cutover并验证新 gate，不切业务 source；`Deploy` 必须消费同 deploymentId 的已认证 bootstrap，写 marker、drain legacy、切换/验证 target closure 后完成；`RecoverRollback` 读取同 deploymentId 的 intent/完整 journal 链，并按下述 marker-presence 矩阵认证现场，依最后已认证 phase 确定性恢复 previous closure或完成已验证 target，不接受人工选择跳过阶段。
- marker-presence 矩阵是 selector 的唯一规则：① phase 10–20 时 marker 必须 absent，Recover 以 intent+journal+live shim 认证并回滚 bootstrap；② phase 30–70 或 rollback-in-progress 时 marker 必须 present 且四字段完全匹配；③ `80-complete`/`rollback-complete` 时，marker present 则验证现场后删除，marker absent 则允许验证 terminal phase 与 live closure/shim/generation 后幂等补写缺失 final receipt；④其它 phase/marker 组合一律失败闭锁。只有 terminal phase 已落盘且现场与对应目标一致时才可删除 marker；删除后回读 absence并 create-only 写 final receipt。phase20 后无 marker 的 Bootstrap→Recover、phase30–70 marker 缺失拒绝、marker 删除后/final receipt 前崩溃重放均为必测 checkpoint。
- 部署/回滚不声称多文件替换天然原子。先以独立授权完成两阶段 gate bootstrap：
  1. **外层 shim cutover**：把唯一宿主 wrapper 作为一个文件原子替换为 gate-aware shim，记录 shim SHA 与 `cutoverEpochUtc`；shim 在启动 repo/loader 前取得 current-user cross-session deployment mutex，检查固定 `D:\Codex\.codex\state\safe-tree-delete-deployment\maintenance.json`，并持 mutex 到 child/本进程退出。先用“部署者持锁时新 invocation 必须等待/拒绝”证明 shim 生效，尚不切换其余 source。
  2. **legacy drain**：部署者取得同一 mutex并 create-new 写入/flush上述四字段 schema v1 maintenance marker，阻止所有 gate-aware 新调用；随后按精确 executable、PID、process start time 与 command line 枚举所有 `cutoverEpochUtc` 前可能经旧 wrapper/repo entry 启动的 safe-delete/native-compile 进程。任一进程事实不可读即失败闭锁；持续等待到两次稳定 inventory 均为零，且“旧版无 mutex holder 仍存活”负控证明 source switch 被拒绝，才进入多文件 maintenance 窗口。
- bootstrap 完成后，**每个** Plan/Apply/Purge/BatchPurge/Status/Restore/Archive 都在任何 dot-source 前走同一 shim/mutex/marker 协议。marker 只按四字段 schema定位并认证 run，状态只读 phase selector；abandoned mutex 或 marker 残留都不自动清除。成功核对整套 source/loader/helper/manifest 与 generation 后按已认证 terminal phase 删除 marker并释放 mutex；崩溃释放 mutex但保留 marker，后续调用仍失败闭锁。调用启动与 cutover/mutex/marker/legacy-drain 各 checkpoint 均有交错负控。
- env 不覆盖 loader/native-helper 语法、base source 或 generation 故障；此类失败在 maintenance 窗口恢复上一已验证整套字节与 generation hash。不得 raw delete cache、覆盖 immutable generation 或用不匹配旧 generation 冒充恢复；fresh process env=0 生产 Plan 核验成功后才解除 maintenance。
- `Test-CodexSafeTreeDeleteDeployment.ps1` 对 Bootstrap→Deploy、Bootstrap→Recover、Deploy 各 source-switch/validation/marker-removal phase 崩溃→Recover 逐一重放；覆盖第二份 intent、新 deploymentId 接管旧 run、marker/intent/journal 替换、错 owner/closure、双恢复者、旧版无 mutex holder、恢复后过早解除 marker，要求幂等或失败闭锁且原始 journal 字节不变。
- 其余证据：base/default immutable generation 的并发同/异 source 编译、winner 验证、source-ABA、DLL verify→load、坏 manifest/DLL 测试；process-local variant 转移表；HandleBoundIO standalone 与 adapter 移动前后回归；maintenance 切换中途启动/崩溃负控；等价性测试；经生产入口的“C# plan → 在途 transaction → fresh process env=0 → Apply/Purge/Status 完成”；合同不变性论证（planSha256 字节绑定、fast-scan producer 形态、terminal-archive 源 plan SHA）。

## 10. 未验证项（实施时收敛）

1. plan.json PS 序列化成本零数据（§4.4 spike 补位）。
2. Wave A walker 时间锚点区间宽（单遍参照 2.8–3.0s vs 完整相位 22.6s，方向未定）。
3. `Sort-Object Name` 的 culture-ignore-case 平局顺序能否跨受支持 PowerShell 版本逐位复刻，须由等价性 corpus 与固定 culture 记录收敛。
4. DOP=2 对哈希负载无实测（仅 Wave B 触发后才需要）。
5. 新 PlanSnapshot/Purge-adapter、native loader helper 与 content-addressed generation 的首次编译成本、并发发布行为和 HandleBoundIO standalone Add-Type 兼容尚无数据；AC 计时排除一次性编译，但部署验收必须单独记录。

## 11. 下一步（需用户决定）

1. 方案审查已收敛；除非 live issue/源码/合同/生产入口漂移，不再增加审查轮次或扩展范围。
2. 下一授权点是在 #56 发布 §3.1 预注册评论；未授权前只保留本地计划。
3. 预注册完成后另行请求 Wave A 实施授权（含 source/spec/tests/manifest/evidence），不从计划审查通过自动推导实施、部署或发布权限。
