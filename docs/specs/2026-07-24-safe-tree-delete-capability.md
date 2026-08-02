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

- 宿主入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd`
- 生产脚本：`scripts\Invoke-CodexSafeTreeDelete.ps1`
- 实现：`scripts\lib\CodexSafeTreeDelete.ps1`
- allowlist：`managed\safe-tree-delete\policy.json`
- evidence：`D:\Codex\.codex\run-evidence\safe-tree-delete\<run-id>\`

项目内 Codex 远程附件只允许以
`D:\Codex\projects\统一环境\.codex-remote-attachments` 为 capability root 删除其后代，
最小后代深度为 1；附件根本身和其他项目顶层目录不在该授权面内。

policy schema v3 要求 `schemaVersion` 与 `minimumDescendantDepth` 都是真正的 JSON integer，
不接受字符串或小数强转。`minimumDescendantDepth` 通常至少为 1，且
`rootDeletionPurpose` 必须为 `none`。root 删除只允许两种精确用途：

- capability root 自身是项目根之下的可重建构建产物根时，可设为 0 和
  `rebuildable-build-output`；项目 `.codex` 根不得冒充构建产物。
- capability root 精确匹配 `D:\Codex\projects\<project>\.codex` 时，可设为 0 和
  `empty-project-state`。该用途只授权 capability root 自身，不授权其后代作为独立目标；
  Plan 要求整棵树零文件，可以包含空子目录，任意普通文件、NTFS named stream 或 reparse
  point 都会失败关闭。

生产 policy 只为本项目退役的 `.codex` 精确声明 `empty-project-state`；远程附件根仍保持
最小后代深度 1 和 `none`，不在 root 删除授权面内。解析器继续拒绝 workspace/项目根和
项目外用户数据根。这不会授权父目录或同级目录。root 删除在 Apply 时仍只允许原子改名到
同父、随机 generation 绑定的 quarantine。Purge 仍校验原计划、transaction、当前树与文件
identity；只有 `purging` 中断恢复允许当前树成为原计划的未变子集，其他路径仍要求完整清单。

生产 CLI 不接受 policy 或 evidence override。测试替身仅位于 `tests\`，不得复制到宿主
脚本目录或作为生产入口。

## 状态机

1. `Plan`：规范化目标与 capability root，校验固定 allowlist、最小后代深度、denylist、
   root 删除用途、父链与完整子树 reparse point；`empty-project-state` 还会在发布计划前确认
   文件计数为零，并拒绝所有目录 NTFS named stream。通过后生成句柄绑定的文件 identity、
   SHA-256 和目录清单。
2. `Apply`：要求 `ConfirmApply` 与精确 `ApprovedPlanSha256`；复算完整树清单无漂移后，
   并再次确认 `empty-project-state` 没有 named stream，才通过目录句柄原子改名到同父
   `.codex-safe-delete-<generation>.quarantine`。此时可恢复。
3. `Purge`：要求 `ConfirmPurge` 与精确 `ApprovedTransactionSha256`。`quarantined` transaction
   必须再次匹配完整计划清单；如果进程在发布 `purging` 后中断，则允许从 quarantine 中不超出
   原计划的节点子集恢复。恢复时 quarantine root identity 必须不变，仍存在节点的相对路径、kind、
   SHA-256 和 file identity 必须与原计划一致；只允许原计划节点缺失。`empty-project-state`
   的 quarantine 仍须再次通过 named stream 检查。最终删除每个目录时，先发布绑定 generation、
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

   `Apply` 与 `Purge` 都在目标 mutex 内重新读取并复验当前 capability、树和 transaction，才允许
   写入 `prepared`、`purging`、commit anchor 或 `purged`。等待锁期间 capability 已变更时必须在
   写入前拒绝，不能用过期内存快照把已隔离或已完成 transaction 降级。

   journal 使用 create-only 原子发布：同一路径的第二次发布必须失败且不得改变原始 bytes 或 file
   identity。每个 `commit-authorized` 还必须在进入 delete-pending 前，由 transaction schema v2
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

批量清理使用 `BatchPurge`，调用方一次传入同一 capability root 下的多个 `TargetPaths`，并同时提供
`ConfirmApply` 与 `ConfirmPurge`。入口对每个目标仍逐项执行相同的 `Plan` / `Apply` / `Purge` 校验；
如果发现同一目标已有 `quarantined` 或 `purging` transaction，且原路径不存在、quarantine 仍存在，
则先按该 transaction 完成 `Purge`，再继续后续目标。这样批量调用中断后可以从受控 evidence 恢复，不需要
调用方手写循环、重新计算 transaction hash 或手工删除 quarantine。通过 `.cmd` wrapper 调用时，
`TargetPaths` 使用单个 `::` 分隔字符串传入，避免 `cmd.exe` 把分隔符解释成管道或命令控制符。

计划 30 分钟过期。缺少确认、哈希不匹配、policy 漂移、目标重新出现、目录内容或 identity
漂移、恢复时出现未计划节点或既有节点的 kind/SHA-256/file identity/root identity 漂移、
junction/symlink/reparse point、越界路径以及并发 mutex 冲突均失败关闭。

DACL 冻结覆盖当前 NTFS 上遵守访问检查的普通新 ADS/子项创建，并跨进程退出与正常操作系统重启
保留。它不撤销 freeze 前已授予的句柄权限，也不声称约束 `WRITE_DAC`/`WRITE_OWNER`、父目录
`FILE_DELETE_CHILD`、`SeRestorePrivilege`、备份 API、内核驱动或突然断电后的介质落盘顺序；
最后的 handle-bound identity、empty 和 stream 复验用于在这些边界发生可观察漂移时失败关闭。

## 上游边界

Codex Desktop 内建的破坏性命令预执行策略没有本机公开配置面。本 capability 不能阻止
调用者直接尝试语义等价 API；持续规则是 agent 与本机治理代码只使用固定入口。真正统一
所有删除语义仍需要上游执行器提供 typed delete capability。
