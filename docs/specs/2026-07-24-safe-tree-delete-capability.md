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

生产 CLI 不接受 policy 或 evidence override。测试替身仅位于 `tests\`，不得复制到宿主
脚本目录或作为生产入口。

## 状态机

1. `Plan`：规范化目标与 capability root，校验固定 allowlist、最小后代深度、denylist、
   父链与完整子树 reparse point，生成句柄绑定的文件 identity、SHA-256 和目录清单。
2. `Apply`：要求 `ConfirmApply` 与精确 `ApprovedPlanSha256`；复算完整树清单无漂移后，
   通过目录句柄原子改名到同父 `.codex-safe-delete-<generation>.quarantine`。此时可恢复。
3. `Purge`：要求 `ConfirmPurge` 与精确 `ApprovedTransactionSha256`；再次复算完整清单后，
   逐节点使用 handle-bound POSIX disposition 删除，包括 ReadOnly 文件。完成后不可恢复。

计划 30 分钟过期。缺少确认、哈希不匹配、policy 漂移、目标重新出现、目录内容或 identity
漂移、junction/symlink/reparse point、越界路径以及并发 mutex 冲突均失败关闭。

## 上游边界

Codex Desktop 内建的破坏性命令预执行策略没有本机公开配置面。本 capability 不能阻止
调用者直接尝试语义等价 API；持续规则是 agent 与本机治理代码只使用固定入口。真正统一
所有删除语义仍需要上游执行器提供 typed delete capability。
