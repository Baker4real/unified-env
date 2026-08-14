# 草稿：Status 在 plan 被当前 policy 拒绝后仍只读观测历史事务

**不要在 #23 实施。不要用本文件直接 `gh issue create`。不放宽 allowlist、最小深度或 Archive 判据。**

## Parent

#18 / 接续 #23

## 问题

`Resolve-CodexSafeTreeDeleteStatusOperation` 先走 `Read-CodexSafeTreeDeleteApprovedPlan`（`AllowPolicyShaDrift`，但 **仍要求 capability root 在当前 allowlist，并执行当前最小深度**）。失败后：

- 无 `transaction.json`：直接失败，`transactionStatus` / namespace 标志保持 null。
- 有事务且 schema=1：只读观测 status/path，但 **不**探测 live namespace，然后固定 `manual-review`。
- 有事务且 schema≠1：设置 `transactionSchemaVersion` 后立刻再抛。v2 `purged` 在视图里变成“未解析”。

`#22` 归档候选要求 `transactionStatus=purged` 且 `quarantinePresent=false`。因此：

- 37 条磁盘已是 v2 `purged`、quarantine 不在、root 已从现场 policy 撤销的记录进不了 Archive。
- 4 条 v1 `purged`（`run-evidence` 下 depth=1）虽然 status 读出来了，但 `quarantinePresent=null`，同样被候选推导跳过。

Archive 源读取本身不查当前 allowlist（spec：current-policy 漂移不永久阻断历史 v1/v2 Archive）。缺口在 Status 观测，不在 Archive 合同。

证据见 `reports/safe-tree-delete-unresolved-20260814/REPORT.md`。

## 建议做

1. plan 批准失败且存在事务时，对 v2/v3 增加与 v1 对称的 **只读观测**：读出 `status` / `targetPath` / `quarantinePath` / `updatedAtUtc`，校验与 plan 的 generation/path/SHA 绑定。
2. 观测成功后探测 live namespace，写入真正的 `targetPresent` / `quarantinePresent`。
3. 保留现有错误（allowlist / 最小深度 / policy 语义拒绝），`schemaCompatible=false`，`safeActions` 不含 Apply/Purge/Restore。
4. 若观测到 `purged` 且 quarantine 当前不在，应能进入现有 Archive 候选推导；Archive 仍走现有历史内容认证，**不**回放已撤销 root。

## 明确不要做

- 不要把已撤销 root 写回 `policy.json` 来“修复”视图。
- 不要降低 `codex-run-evidence` 的最小深度。
- 不要让 Purge/Restore 的严格 reader 接受这些记录。
- 不要把无事务的过期计划扩成 Archive 对象。
- 不要删除 `acl-capability-probe-20260801`。

## 验收

- 上述 37 条 v2 在 Status 中不再是 `transactionStatus=null`；磁盘仍为 purged、quarantine 不在的，应出现 `quarantinePresent=false`。
- 上述 4 条 v1 purged 的 `quarantinePresent` 为布尔值，不再是 null。
- 现有失败关闭 fixture 与生产 smoke 不因“观测更完整”而放行写路径。
- 不把 10 条 2026-08-13 ui-references quarantined 不一致改判 terminal。
