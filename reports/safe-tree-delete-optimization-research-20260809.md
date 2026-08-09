---
type: report
title: 全局受管安全树删除优化调研
tags: [host-safety, safe-delete, windows, research]
intent: 基于当前实现与高采用度一手项目，判断受管删除的可优化方向与实施优先级
---

# 全局受管安全树删除优化调研

调研日期：2026-08-09

对抗审查整合：2026-08-09

实施权威：[GitHub Issue #1](https://github.com/Baker4real/unified-env/issues/1)。本报告保留调研事实、
机制来源与决策依据；具体行为合同、验收标准和阻塞关系以 Issue #1 及其子 tickets 为准。

## 结论

当前流程可以优化，但不应替换核心入口或降低现有 fail-closed 保证。现役实现已经具备固定
allowlist、句柄绑定 identity、内容认证树清单、同父 quarantine、显式确认、crash journal、恢复重放，
以及逐根授权的 hardlink/internal junction 处理。普通文件和专用 link lease 拒绝非默认 ADS；
`empty-project-state` 还对目录 named streams 执行专门的冻结与删除合同。高价值改进集中在四个方面：

1. 增加单一只读 `Status -Json`，全局枚举 transaction、quarantine 和 evidence 的真实状态。
2. 增加受管 `Restore`，覆盖正常 `quarantined` 与 rename 后强杀留下的合法 `prepared` 状态。
3. 为自动化清理增加不可变 grace anchor 和 OS-backed producer fence，并把逐叶 retry 限定在已知瞬态错误。
4. 先加入阶段耗时和实际哈希字节观测；任何性能优化继续保留 `content-authenticated` 批准合同。

外部项目应作为机制参考，不应直接替换
`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`。尤其不能用 `rimraf`、`trash-cli`、
系统回收站或 `rclone purge` 冒充现有安全合同。

## 调研问题与范围

问题：在 Windows/NTFS、固定 capability root、Plan -> Apply -> Purge 和 fail-closed 的现状下，
哪些高采用度项目的机制能提升安全性、可恢复性、可运维性或性能？

证据标准：

- 本机事实来自当前源码、policy、live wrapper、evidence 和现役测试。
- 外部事实来自项目官方 GitHub API、固定 commit 的源码/文档和 Microsoft Learn。
- stars、最近 push、license 和主语言在 2026-08-09 通过 GitHub API 重新读取。
- 本轮不安装候选项目，不执行真实候选目录删除，不做 NTFS 原生故障注入。

### 本机证据闭包

以下是 2026-08-09T04:39:40Z 的快照，不是未来执行授权：

| 证据 | 值 |
| --- | --- |
| 调研固定代码基点 | `d68f7732319d6769f7b7cdf95339e0f20a674880` |
| source/live CMD SHA-256 | `45aeadf7f758a1cafce106f66e7eaecc5f60176d2017630e2af461a2a37bca12` |
| source/live PowerShell wrapper SHA-256 | `d3155a23184e531aa8f8c5e981eeea98ce3f4d4ddfc649773e7f830e7cba2772` |
| policy SHA-256 | `62bbb4bf1a292d3fd79595d53e21faa5372321407cb3e07880673cfd8288a82f` |
| policy snapshot | schema v4；30 entries；5 hardlink；2 internal junction；21 exact-root |
| evidence snapshot | 1,675 run directories；1,647 transactions；125,379,960 bytes（119.57 MiB） |
| 非终态 snapshot | 5；对应 quarantine 均不存在，结论保持 `manual-review` |
| fixture command | `node .\scripts\Run-PowerShellTests.cjs --module host-safety`；exit `0` |
| fixture result | `CodexSafeTreeDelete` 12 slices；`CodexSafeTreeDeleteCrashSafety` 11 scenarios |
| host-live command | `node .\scripts\Run-PowerShellTests.cjs --module host-safety --profile host-live`；exit `0` |
| host-live evidence | run `20260809T043833Z-b615e86e-997d-4905-adc0-32ebcbb7f97e`；batch recovered `1` |

GitHub stars 与最近 push 也是 2026-08-09 的 API 快照；表中链接用于追溯来源，不保证未来仍返回相同元数据。

## 当前基线

### 已验证能力

- live `.cmd`/`.ps1` wrapper 与仓库 source wrapper 的 SHA-256 分别完全一致；精确值见上表。
- 生产 policy schema v4 的 capability 计数见上表。
- 公开模式只有 `Plan`、`Apply`、`Purge`、`BatchPurge`；没有全局状态视图，也没有公开
  `Restore` 模式。入口见
  [`scripts/Invoke-CodexSafeTreeDelete.ps1`](../scripts/Invoke-CodexSafeTreeDelete.ps1)，合同见
  [`docs/specs/2026-07-24-safe-tree-delete-capability.md`](../docs/specs/2026-07-24-safe-tree-delete-capability.md)。
- fixture 与 host-live smoke 的本轮命令、退出码和结果见上表。
- evidence 快照有 5 份仍标记为 `prepared`/`quarantined`/`purging`，但相应 quarantine 均不存在。
  这不能直接判定为可删除残留，却证明全局 `Status` 控制面缺失。

### 已观察到的成本与缺口

1. 成功路径对每个普通文件执行 7 次内容 SHA-256 读取：5 次完整树 snapshot，再在临删句柄内
   连续计算 2 次。调用点见
   [`scripts/lib/CodexSafeTreeDelete.ps1`](../scripts/lib/CodexSafeTreeDelete.ps1) 的 302、511、567、
   613、1188 行，以及
   [`scripts/lib/CodexHostSafety.ps1`](../scripts/lib/CodexHostSafety.ps1) 的 1028、1036 行。
   这保留了强漂移检测，并对大树形成理论读放大；真实耗时和可优化空间仍须 benchmark。
2. `Apply` 的内部异常路径能 rollback，但公开 CLI 没有让操作者主动恢复 quarantine 的模式。
   因而“可恢复隔离”目前主要表示故障恢复能力，不是完整的用户撤销能力。
3. per-target named mutex 只协调删除器实例，不表示项目、编译器或其他消费者仍在使用目标树。
4. 已知 transaction 路径与当前 SHA-256 时，直接 `Purge` 已能重放 `prepared`、`quarantined` 和
   `purging`；`BatchPurge` 额外提供按 target 自动发现。当前缺少统一列出 recoverable、purge-resumable、
   terminal、inconsistent、drifted 和 manual-review 的入口。
5. 成功结果没有区分“目录项已经从 namespace 消失”和“hardlink/open handle 对应的物理空间已经释放”。
6. 仓库内部 fixture/staging 的递归删除迁移仍为 `pending`；本能力也无法拦截所有语义等价删除 API，
   后者仍需要 Codex 上游提供 typed delete capability。

## 高采用度候选

| 项目 | Stars | 最近 push (UTC) | 主要价值 | 结论 |
| --- | ---: | --- | --- | --- |
| [nodejs/node](https://api.github.com/repos/nodejs/node) | 118,835 | 2026-08-09 | Windows 错误分类与有界重试 | 参考，不替换 |
| [git/git](https://api.github.com/repos/git/git) | 62,477 | 2026-08-07 | roots、expiry、dry-run、cruft | 参考 grace/retention |
| [rclone/rclone](https://api.github.com/repos/rclone/rclone) | 59,020 | 2026-08-09 | dry-run、删除预算、sharing retry | 参考控制面 |
| [restic/restic](https://api.github.com/repos/restic/restic) | 35,422 | 2026-08-01 | 可续租独占锁、reconcile、crash-safe prune | 核心参考 |
| [dotnet/runtime](https://api.github.com/repos/dotnet/runtime) | 18,173 | 2026-08-09 | Windows reparse/mount point 删除语义 | 核心参考 |
| [NixOS/nix](https://api.github.com/repos/NixOS/nix) | 17,472 | 2026-08-08 | 永久根、临时根、GC 协调与删除前复验 | 核心参考 |
| [isaacs/rimraf](https://api.github.com/repos/isaacs/rimraf) | 5,849 | 2026-05-15 | 两阶段 Windows purge、有界瞬态重试 | 局部参考 |
| [andreafrancia/trash-cli](https://api.github.com/repos/andreafrancia/trash-cli) | 4,460 | 2026-08-07 | metadata-first、恢复冲突保护 | 只参考 Restore UX |

stars 不是安全评分。排序时同时考虑源码机制是否适合当前 Windows/NTFS 边界、维护活跃度和引入复杂度。

## 最值得借鉴的机制

### 1. Nix：liveness roots 与删除前二次复验

Nix 为进程维护临时 roots，以全局 GC 锁协调，并允许 GC 运行期间动态通知新 roots；最终删除循环还会
再次检查新增临时 root。来源：
[临时 roots 与全局锁](https://github.com/NixOS/nix/blob/85f1926dac5d2075169133041a5727d466eee5ea/src/libstore/gc.cc#L54-L110)、
[动态通知](https://github.com/NixOS/nix/blob/85f1926dac5d2075169133041a5727d466eee5ea/src/libstore/gc.cc#L475-L492)、
[删除前复验](https://github.com/NixOS/nix/blob/85f1926dac5d2075169133041a5727d466eee5ea/src/libstore/gc.cc#L715-L747)。

适配方式：借鉴“生产者持有 liveness root、删除器在不可逆动作前复验”的机制，但把 Windows 权威门槛
放在 OS handle 上。合作生产者整个使用期持有拒绝 delete sharing 的目标目录句柄；`Apply` rename 是
原子 fence 点：生产者先取得句柄时 rename 失败，rename 先完成时后来生产者无法打开原目标。heartbeat
只作诊断，不能因 TTL 过期授权删除；没有 producer fence 的 capability 保持 manual-only。

不照搬：不采用 symlink gcroots，不跟随 reparse target，也不改成 Nix 式直接删除 store path。

### 2. restic：可续租独占操作与全局 reconcile

restic 的非 dry-run prune 要求独占锁；锁需要刷新，刷新失败会取消操作；执行顺序先保留活跃内容并
更新索引，再删除旧 pack，官方明确普通 prune 在任意中断点保持仓库可用。来源：
[独占锁](https://github.com/restic/restic/blob/a80be1478a4c537f8396e0db2b05120aa78f11e0/cmd/restic/cmd_prune.go#L164-L183)、
[锁刷新](https://github.com/restic/restic/blob/a80be1478a4c537f8396e0db2b05120aa78f11e0/internal/repository/lock.go#L124-L177)、
[执行顺序](https://github.com/restic/restic/blob/a80be1478a4c537f8396e0db2b05120aa78f11e0/internal/repository/prune.go#L588-L673)、
[中断保证](https://github.com/restic/restic/blob/a80be1478a4c537f8396e0db2b05120aa78f11e0/doc/060_forget.rst#L513-L519)。

适配方式：在现有删除器上方增加只读 `Status` 控制器，统一分类 evidence 与 quarantine。需要实际动作时
仍调用现有 Plan/Apply/Purge/Restore，不让控制器直接删除。restic 的续租取消机制只作为失败闭锁参考；
当前 Windows 方案不把 heartbeat 或过期 registry 当成 producer 已死亡的权威证据。

不照搬：不引入 pack repack、对象索引或完整图数据库。

### 3. .NET runtime 与 Microsoft：Windows 对象语义

Windows hardlink 的多个名称引用同一卷上的同一文件对象，内容、属性、DACL 和 ADS 共享；删除一个名称
不等于释放对象。`FILE_ID_INFO` 提供 `VolumeSerialNumber + 128-bit FileId`，
`FILE_STANDARD_INFO` 提供 link count、`DeletePending` 和 directory 标志。来源：
[Hard links and junctions](https://learn.microsoft.com/en-us/windows/win32/fileio/hard-links-and-junctions)、
[FILE_ID_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)、
[FILE_STANDARD_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_standard_info)。

`.NET runtime` 会区分 name-surrogate reparse tag，避免对 symlink/junction 递归，并单独处理 volume mount
point；但其通用路径递归不具备当前 transaction/hash 合同，不能直接替换。
[实现源码](https://github.com/dotnet/runtime/blob/9904b9343c89c898fea3a9dfa68a6aba7fa8f3c1/src/libraries/System.Private.CoreLib/src/System/IO/FileSystem.Windows.cs#L250-L411)。

适配方式：原生 helper 升级到 `FILE_ID_INFO` 与 `FILE_STANDARD_INFO`，明确记录 reparse tag、link count、
`DeletePending`，并把结果拆成 `namespaceAbsent` 和 `physicalReclaimVerified`。后者无法证明时必须报告
`unknown/pending`，不能根据路径消失推断物理释放。

### 4. rimraf/Node：限定错误集合的有界重试

rimraf 的 Windows 实现先处理非目录，再处理目录；只对指定瞬态错误做有界退避，并要求 move-remove
保持同设备。来源：
[Windows 两遍删除](https://github.com/isaacs/rimraf/blob/051e6c72a703854a029344be188d14dbe1b326c7/src/rimraf-windows.ts#L1-L9)、
[有界 retry](https://github.com/isaacs/rimraf/blob/051e6c72a703854a029344be188d14dbe1b326c7/src/retry-busy.ts#L7-L40)、
[同设备 move-remove](https://github.com/isaacs/rimraf/blob/051e6c72a703854a029344be188d14dbe1b326c7/README.md#L189-L206)。

Node 当前实现也按错误类型限制 retry；但 `lstat -> path delete` 仍有 TOCTOU，`chmod` 会影响 hardlink
共享属性，不能成为安全边界。
[Node rimraf 实现](https://github.com/nodejs/node/blob/cbe18d813c070ffe8c03b54278c4bcbe26e3867e/lib/internal/fs/rimraf.js#L37)。

适配方式：只在已经完成同父 quarantine 的 Purge 中，对尚未 commit 的单个叶节点处理明确的 sharing
violation/busy，并设置次数与总时限预算。每次 backoff 后重新取得受限句柄并复验 identity 与内容 hash；
`ACCESS_DENIED`、未知错误、identity/hash/policy drift 继续立即失败。任一节点已 commit 后，剩余树只能
标记为 purge-resumable，不能再声称 Restore-eligible。

## 可借鉴但不应成为核心的项目

- Git 的 roots、grace period 和 expiry 适合 terminal evidence retention；其文档也明确并发保护并不完整，
  不能替代 Windows 句柄边界。
  [GC roots 与并发风险](https://github.com/git/git/blob/010afd3166ddc64c9863b1506f12cbcdda0d4ea1/Documentation/git-gc.adoc#L141-L169)。
- rclone 的 `--dry-run`、`--max-delete`、`--max-delete-size` 和 Windows sharing retry 适合预算与可观测性；
  但 `purge` 明确忽略 filters 并删除全部内容，不能接入生产入口。
  [purge 源码](https://github.com/rclone/rclone/blob/387b4b5e11d611780a283db01c493e21ba7826f0/cmd/purge/purge.go#L18-L45)、
  [Windows retry](https://github.com/rclone/rclone/blob/387b4b5e11d611780a283db01c493e21ba7826f0/backend/local/remove_windows.go#L13-L33)。
- trash-cli 的排他 metadata 创建和恢复拒绝覆盖值得借鉴；它是 Freedesktop/POSIX 方案，
  并且安全保证弱于当前 Windows/NTFS 实现。
  [事务顺序](https://github.com/andreafrancia/trash-cli/blob/673552d829b14808e26457c68e17d45c8266e708/trashcli/put/janitor.py#L57-L83)、
  [恢复冲突保护](https://github.com/andreafrancia/trash-cli/blob/673552d829b14808e26457c68e17d45c8266e708/trashcli/restore/restorer.py#L16-L29)。

## 建议路线

### P0：只读状态与观测，不改变删除语义

1. 新增单一 `Status -Json`：在固定 evidence root 内进行 handle-bound、no-follow 枚举，逐记录隔离
   invalid JSON、未知 schema、不可访问项和 reparse point，同时输出全局 `complete` 标志。
2. 使用中性分类：planned、recoverable、purge-resumable、terminal、inconsistent、drifted、manual-review。
   quarantine 缺失本身不能推导 stale、purged 或可删除。
3. 报告 plan/transaction schema、target/quarantine existence、policy entry、identity、journal 完整性、
   age 和安全下一步；Status 不自动修复、不自动删除。
4. 为 Plan/Apply/Purge/Status 增加 `elapsedMs`、`entriesScanned`、`logicalBytes`、`bytesHashed` 和 retry 结果，
   并为每次验证保留采集时间、哈希、命令、退出码和 evidence 指针。
5. 验收时重新扫描全部非终态记录；调研时观察到的 5 份只作为上方带时间戳快照。

### P1：补齐恢复与自动化安全门槛

1. 先扩展兼容读取：policy v5、transaction v3 与现役旧 schema 并存。Status 提供 migration preflight；
   任何不兼容非终态 transaction 都阻止 policy 激活，历史 ledger 不自动改写。
2. 新增 `Restore`：同时要求 `ConfirmRestore`、transaction 引用和精确 SHA-256。它接受完整验证的
   `quarantined`，也接受 `target missing + quarantine present + no commit anchors` 的合法 `prepared`
   Apply crash 状态；可能已部分删除的 `purging` 永不 Restore。
3. Restore 与 Purge/BatchPurge 共用 target mutex，禁止 merge、覆盖和跨卷 copy-delete。rename 后重放必须
   重新验证目标侧完整 manifest、逐节点内容 hash/identity、hardlink、reparse、ADS 和当前 policy；只检查
   root identity 不足以发布 `restored`。
4. transaction v3 使用 create-only quarantine-time anchor；`minimumQuarantineAgeMinutes` 不从可重写的
   `updatedAtUtc` 推导。缺失 anchor 的 crash 恢复在完整复验后重新开始保守 grace；时钟异常进入
   `manual-review`。
5. producer liveness 采用 OS-backed handle fence，并在 `Apply` rename 前原子生效。没有 producer fence 的
   capability 保持 manual-only；heartbeat、PID 或 registry TTL 只能诊断，不能授权删除。

### P2：Windows 边界与有界重试

1. Purge 只在单个尚未 commit 的叶节点上，对 allowlist 中的 sharing/busy 错误做有界 retry；每次重试
   重新取得受限句柄并复验 identity 与内容。ACL、identity、manifest、policy 和未知错误立即失败。
2. 任一节点已 commit 后，剩余 quarantine 只能 purge-resumable，不能再报告 recoverable。
3. 原生 helper 可记录 128-bit file ID、link count、DeletePending、reparse tag 和 stream 摘要，但这些字段
   不能单独证明物理空间已释放。
4. 输出区分 namespace absence、logical completion 和 physical reclaim；缺少独立文件系统分配证据时，
   physical reclaim 固定为 `unknown`。
5. 当前 reparse 授权不扩面：已批准 internal junction 只 detach、不 follow；symlink、真实 mount point、
   未知或云 reparse tag 继续拒绝。新增 tag 另行论证和测试。

### P3：性能优化实验，不改变批准内容合同

先用 P0 指标确认 7 次 SHA-256 读放大在真实大树上的成本。现有 Plan 内容摘要是用户批准基线；
file identity、kind、size 和 timestamps 无法证明同一 file ID 的内容没有被改写，因此不能引入只靠
entry metadata 的轻量 profile。

后续实验只能在保留 `content-authenticated` 合同的前提下减少重复工作，例如研究能否用持久、
write-excluding 的句柄或等价文件系统保证复用某一阶段的内容摘要。若 Apply 前必须重新生成内容认证
manifest，则必须把它视为新 Plan 并取得新的显式批准，不能在旧批准下透明替换。任何方案都必须通过
benchmark、并发同 identity 改写、crash injection 和独立安全评审。

## 不应采用

- 不把 rimraf、Node `fs.rm`、rclone、trash-cli、系统回收站或 `Remove-Item -Recurse` 作为生产入口。
- 不使用跨卷 copy+delete 伪装原子 quarantine；Windows 明确允许 copy 成功而源删除失败。
  [MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)。
- 不跟随 symlink/junction target，不把 reparse attribute 当作完整 tag 判断。
- 不使用 TxF；Microsoft 已建议采用替代机制。
  [Alternatives to TxF](https://learn.microsoft.com/en-us/windows/win32/fileio/deprecation-of-txf)。
- 不根据 quarantine 缺失自动终结任何非终态 transaction，不直接改写历史 ledger。
- 不把 heartbeat/PID/TTL 过期当成 producer 已死亡的删除授权。
- 不使用同一 safe-delete evidence root 和普通受管入口做 terminal evidence GC；该能力需要树外 evidence
  与独立 capability，当前规格明确 out of scope。
- 不引入 metadata-only 轻量批准 profile，也不在旧批准下透明替换 manifest。
- 不把 logical deletion、namespace absence 和 physical reclaim 混为同一个成功状态。

## 实施追踪

| 顺序 | Tracker | 交付 |
| ---: | --- | --- |
| 1 | [#2](https://github.com/Baker4real/unified-env/issues/2) | 只读 Status 控制面 |
| 2 | [#3](https://github.com/Baker4real/unified-env/issues/3) | 阶段指标与 evidence 闭包 |
| 3 | [#4](https://github.com/Baker4real/unified-env/issues/4) | schema 兼容读取与迁移预检 |
| 4 | [#5](https://github.com/Baker4real/unified-env/issues/5) | crash-safe Restore |
| 5 | [#6](https://github.com/Baker4real/unified-env/issues/6) | immutable grace 与 policy v5 |
| 6 | [#7](https://github.com/Baker4real/unified-env/issues/7) | OS-backed producer fence |
| 7 | [#8](https://github.com/Baker4real/unified-env/issues/8) | 逐叶 bounded retry |
| 8 | [#9](https://github.com/Baker4real/unified-env/issues/9) | namespace / physical reclaim 分离 |
| 9 | [#10](https://github.com/Baker4real/unified-env/issues/10) | 受约束 benchmark 与最终回归 |

每个 ticket 的完整验收标准和真实阻塞边以 GitHub 正文为准。截至 2026-08-09，父 Issue #1 与
#2-#10 均为 `ready-for-agent`；这表示规格可执行，不表示代码已实现、宿主已部署或 live 已验收。

## 后续实施完成标准

1. 验收时 live 扫描出的全部非终态记录均获得稳定、可重复、有证据的分类；不要求自动修复。
2. Restore、schema rollout、grace、producer fence、retry 和 reclaim reporting 分别通过其 ticket 定义的
   成功路径、可达失败路径、并发与强杀回归。
3. 现有 fixture、crash-safety、production smoke、module boundary 和 `git diff --check` 全部通过。
4. 未获授权的 host deploy、live policy 变更或真实 capability 删除保持未执行，并明确列为未验证。

## 未验证项

- 没有安装或运行外部候选项目。
- 没有对真实 16 GiB 级构建树执行 benchmark，因此性能收益仍是待测假设。
- 没有完成 `FileRenameInfoEx`、POSIX disposition、mapped image、并发 hardlink alias 等 Win32 原生实验。
- 纯 user-mode 且面对持有既有高权限句柄或特权的主动对手时，DACL freeze 无法给出绝对 TOCTOU 保证；
  当前威胁模型仍应保持合同中已声明的边界。
