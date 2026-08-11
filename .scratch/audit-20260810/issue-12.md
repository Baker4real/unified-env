# Issue #12 [OPEN] Prefactor：把 Status 的单条记录判定抽成独立单元

## Parent

#11

## What to build

纯重构，`Status` 的对外行为**完全不变**。

今天 `Get-CodexSafeTreeDeleteStatus` 是一个约 460 行的单函数，内含 17 个 `throw`。每个 `throw` 都会跳到同一个 catch，使那条记录丧失全部已解析字段——`transactionStatus` 和 `targetPath` 变成 `null`，只留一条错误串。这是「不同原因的记录在输出里长得一模一样」的直接结构原因，也是后续每个功能 ticket 都要绕开的障碍。

本 ticket 把「判定单条 evidence 记录」抽成一个独立单元，使一次判定失败只影响该记录自身的那部分结论，而不是塌缩整条记录的全部字段。抽取后的单元要能表达「某一步失败了，但此前已经查明的事实仍然有效」。

这是 make the change easy, then make the easy change —— 本 ticket 不修任何缺陷，只把边界理干净，让 #11 的其余 ticket 能在干净接缝上落地。

## Acceptance criteria

- [ ] `Status` 的 JSON 输出契约逐字段不变：`artifactType`、`schemaVersion`、`complete`、`policyPath`、`policySha256`、`policySchemaVersion`、`migrationReadiness`、`operations`、`metrics` 全部保持原有名称、类型与语义
- [ ] 对当前生产证据根跑 `Status`，`operations` 数量、每条的 `lifecycle`、`errors` 内容与重构前一致（可先记录重构前基线再比对）
- [ ] 单条记录判定被抽成独立单元，判定过程中的失败只影响该记录自身结论，不再清空该记录此前已解析的字段
- [ ] 既有全部 safe-tree-delete 测试保持通过，特别是 `Test-CodexSafeTreeDeleteStatus`、`Test-CodexSafeTreeDeleteCrashSafety`、`Test-CodexSafeTreeDeleteGrace`、`Test-CodexSafeTreeDeleteSchemaCompatibility`、`Test-CodexSafeTreeDeleteControlPlane`
- [ ] 写入路径（`Apply` / `Purge` / `Restore`）代码路径未被本次重构改动
- [ ] 不新增测试 seam；如需新增测试，挂在既有 fixture 入口上

## Blocked by

- None — can start immediately
