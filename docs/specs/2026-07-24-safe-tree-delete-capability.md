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

policy schema v2 的 `minimumDescendantDepth` 通常至少为 1，且 `rootDeletionPurpose` 必须为
`none`。仅当 capability root 自身就是项目根之下的可重建精确构建产物根时，才可以同时设为
0 和 `rebuildable-build-output`；解析器会拒绝 workspace/项目根、`.codex` 状态根和项目外
用户数据根。这不会授权其父目录或同级目录。此类根在 Apply 时仍只允许原子改名到同父、
随机 generation 绑定的 quarantine。Purge 仍校验原计划、transaction、当前树与文件
identity；只有 `purging` 中断恢复允许当前树成为原计划的未变子集，其他路径仍要求完整清单。

生产 CLI 不接受 policy 或 evidence override。测试替身仅位于 `tests\`，不得复制到宿主
脚本目录或作为生产入口。

## 状态机

1. `Plan`：规范化目标与 capability root，校验固定 allowlist、最小后代深度、denylist、
   父链与完整子树 reparse point，生成句柄绑定的文件 identity、SHA-256 和目录清单。
2. `Apply`：要求 `ConfirmApply` 与精确 `ApprovedPlanSha256`；复算完整树清单无漂移后，
   通过目录句柄原子改名到同父 `.codex-safe-delete-<generation>.quarantine`。此时可恢复。
3. `Purge`：要求 `ConfirmPurge` 与精确 `ApprovedTransactionSha256`。`quarantined` transaction
   必须再次匹配完整计划清单；如果进程在发布 `purging` 后中断，则允许从 quarantine 中不超出
   原计划的节点子集恢复。恢复时 quarantine root identity 必须不变，仍存在节点的相对路径、kind、
   SHA-256 和 file identity 必须与原计划一致；只允许原计划节点缺失。校验通过后逐节点使用
   handle-bound POSIX disposition 删除，包括 ReadOnly 文件。完成后不可恢复。

批量清理使用 `BatchPurge`，调用方一次传入同一 capability root 下的多个 `TargetPaths`，并同时提供
`ConfirmApply` 与 `ConfirmPurge`。入口对每个目标仍逐项执行相同的 `Plan` / `Apply` / `Purge` 校验；
如果发现同一目标已有 `quarantined` 或 `purging` transaction，且原路径不存在、quarantine 仍存在，
则先按该 transaction 完成 `Purge`，再继续后续目标。这样批量调用中断后可以从受控 evidence 恢复，不需要
调用方手写循环、重新计算 transaction hash 或手工删除 quarantine。通过 `.cmd` wrapper 调用时，
`TargetPaths` 使用单个 `::` 分隔字符串传入，避免 `cmd.exe` 把分隔符解释成管道或命令控制符。

计划 30 分钟过期。缺少确认、哈希不匹配、policy 漂移、目标重新出现、目录内容或 identity
漂移、恢复时出现未计划节点或既有节点的 kind/SHA-256/file identity/root identity 漂移、
junction/symlink/reparse point、越界路径以及并发 mutex 冲突均失败关闭。

## 上游边界

Codex Desktop 内建的破坏性命令预执行策略没有本机公开配置面。本 capability 不能阻止
调用者直接尝试语义等价 API；持续规则是 agent 与本机治理代码只使用固定入口。真正统一
所有删除语义仍需要上游执行器提供 typed delete capability。
