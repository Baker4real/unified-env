# Issue #15 [OPEN] BatchPurge：挑选阶段 schema 过滤与单条目标错误隔离

## Parent

#11

## What to build

让 `BatchPurge` 具备错误隔离：单条无法处理的历史记录不再导致整批清理中断。

当前存在一个结构性缺陷：负责挑选可恢复事务的函数只做状态与文件系统过滤（状态在允许列表内、target 不存在、quarantine 存在），**不校验 schema 可执行性**。一旦某条 v1 记录恰好满足这些条件，它会被当作可恢复候选返回，随后的 `Purge` 调用命中 v1 拒绝并抛出，而该异常**不在批处理循环内被捕获**，会整批向上抛出、无错误隔离。表现为「挑选阶段说可恢复，执行阶段必失败，且拖垮整批」。

本 ticket 之后，无法被 `Purge` 接受的记录不进入候选集；单条目标失败时其余目标继续处理，被跳过的目标及原因出现在返回结构里。

**注意：此缺陷当前无法自然复现。** 现有 5 条 v1 记录各自被更早的过滤条件挡住（target 仍存在，或 quarantine 不存在），所以今天跑 `BatchPurge` 不会中断。**不要因为「复现不出来」而降低优先级或判定为不存在**——它是真实的结构性缺陷，一旦某条 v1 记录的 target 被删除而 quarantine 仍存在即会触发。验收需要用 fixture 构造该状态组合。

返回结构中被跳过目标的表达，沿用既有 action 词汇风格（`recovered-purged` / `already-absent` / `planned-applied-purged`）保持一致。

## Acceptance criteria

- [ ] 挑选可恢复事务时排除无法被 `Purge` 接受的记录，使其不进入候选集
- [ ] 用 fixture 构造「v1 事务 + target 不存在 + quarantine 存在」的状态组合，验证 `BatchPurge` 不再整批中断
- [ ] 单条目标失败时，同批其余目标继续被处理
- [ ] 返回结构表达被跳过的目标及其原因，词汇风格与既有 action 一致
- [ ] 汇总计数（`targetCount`、`purgedCount`、`recoveredCount`、`alreadyAbsentCount`）与实际结果一致，新增跳过类别不破坏既有计数语义
- [ ] `BatchPurge` 拒绝或跳过时对该目标零写入
- [ ] 既有 `BatchPurge` 行为不回归，特别是 `Test-CodexSafeTreeDeleteControlPlane` 中 manual-only v5 capability 必须拒绝且零写入的既有断言
- [ ] 既有全部 safe-tree-delete 测试保持通过
- [ ] 不新增测试 seam，新增测试挂在既有 fixture 入口上

## Blocked by

- #12
