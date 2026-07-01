# 备份清理 apply manifest 设计

生成时间：2026-07-01 16:27:40 +08:00

本文件是删除前 manifest 设计和二次校验结果，不删除、不移动、不迁移任何文件。即使所有路径验证通过，真实删除仍需要用户再次明确确认 manifest id、路径数量和预计释放体积。

## 汇总

- manifest id：backup-retention-apply-20260701-162739-ee2d4c61
- source dry-run：D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-162612\backup-retention-dry-run.json
- dry-run 年龄：0 小时
- 选择模式：all-dry-run-candidates
- 选中路径：0 个，0 MB
- 通过二次校验：0 个，0 MB
- 阻塞路径：0 个
- deleteAllowed=false
- executionReady=false

## 硬边界

- 本脚本只生成 manifest，不包含删除实现。
- 人工审查项和保护路径不会进入可删除集合。
- 每个路径都必须仍存在、仍在 D 盘、未命中 reparse point，且当前 bytes/files/dirs/SKILL.md/newestUtc/oldestUtc 与 dry-run 快照一致。
- 下一阶段如果实现真实 apply，必须要求用户逐字确认 manifest id、路径数量和预计释放体积。

## 最终授权短语

```text
我确认删除 manifest backup-retention-apply-20260701-162739-ee2d4c61 中的 0 个已验证路径，预计释放 0 MB
```

## 已验证路径

| id | 风险 | 组 | 排名 | 体积 MB | 路径 |
| --- | --- | --- | ---: | ---: | --- |

## 阻塞路径

| id | 状态 | 原因 | 路径 |
| --- | --- | --- | --- |

## 下一步

1. 人工审查本 manifest 的路径集合、数量和体积。
2. 如需真实删除，先实现单独的 apply 执行脚本，并要求用户使用上面的最终授权短语确认。
3. 真实删除前再次重新生成 dry-run 和 manifest；本 manifest 过期后不能直接执行。

