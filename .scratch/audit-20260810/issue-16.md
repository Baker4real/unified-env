# Issue #16 [OPEN] rebuildable-build-output：区分目标重建与删除失败

## Parent

#11

## What to build

让 `rebuildable-build-output` 用途下「目标被重建」不再被误报为不一致。

当前有 80 条记录被 `Status` 报成问题，它们全部落在 8 个 `rebuildable-build-output` 条目（`bin` / `obj` / `app` / `verification`，各 10 条）。语义上这些完全正常：删掉 `bin`，重新编译，`bin` 又出现了。但 `purged` 事务的 namespace 复验无条件要求目标缺席，于是把「删除后被重建」判成了「删除没生效」。

本 ticket 之后，对 `rootDeletionPurpose` 为 `rebuildable-build-output` 的条目，目标重新出现不再无条件视为不一致，80 条误报从治理视图中消除。

**必须保留区分能力，这是本 ticket 的风险点。** 「删除后被重建」与「从未被删除」不能混同——后者是真实的删除失败，放宽误报绝不能把它一起掩盖掉。判定依据应是事务自身记录的完成事实与当前 namespace 状态的组合，而非仅凭目标是否存在。**无法可靠区分时保持报错，失败关闭优先。**

`physicalReclaimStatus` 继续固定为 `unknown`，本 ticket 不改变其语义——它有明文规格依据（缺少独立文件系统 allocation 证据）。

## Acceptance criteria

- [ ] `rebuildable-build-output` 用途下，`purged` 事务的目标重新出现不再被报为不一致
- [ ] 用 fixture 验证「删除成功后目标被重建」的场景被判为 terminal
- [ ] 用 fixture 验证「目标从未被删除」的场景仍然被报为问题
- [ ] 无法区分上述两种情形时保持报错，不静默放过
- [ ] 非 `rebuildable-build-output` 用途的 namespace 复验严格性不变
- [ ] `physicalReclaimStatus` 继续为 `unknown`，语义未改
- [ ] 对当前生产证据根跑 `Status`，此前 80 条该类误报消除，且未新增其他类别的记录变化
- [ ] 既有全部 safe-tree-delete 测试保持通过
- [ ] 不新增测试 seam，新增测试挂在既有 fixture 入口上

## Blocked by

- #12
