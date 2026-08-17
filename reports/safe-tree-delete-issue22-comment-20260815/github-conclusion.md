## 结论回写（2026-08-15）

结论：**本票的归档范围已完成；GitHub 状态保持 OPEN。** 本次只回写结论，不执行 `gh issue close`。正式关 #20–#24 仍走 #45 / #52。

这是对前几条评论的更新，不是新的 Archive 授权。

### 归档范围（本票要做的事）

- 合格 terminal 已在此前逐条 Archive。2026-08-14 live Status 重推候选为 **0**，因此本轮没有新的 Archive 写入，这不是失败。
- `complete=false` 不是本票失败。票面写过：归档后 `complete` 不必翻转。
- 票面「blocking 1674 → 约 79」是 #19 过期投影。live 为 **110**；相对 20260814 收口后的 109，多 1 条 allowlist 拒绝记录，不是 Archive 候选。
- 5 条 v1 未终结与历史 v2 `20260805T083256Z-1ba06d2f-…` 仍在视图中，未被归档。
- 未新增 `BatchArchive`；三条 Archive 判据、证据根三层保护、policy schema v4 未被本票改动。
- ControlPlane fixture 的逐条错误隔离仍在且曾绿。

证据：`reports/safe-tree-delete-issue22-20260815/`（Status 快照 SHA-256 `59cd72358e18201ee0ab66d65f5541bc4aa7a62bb2b7cbcb89094141d49ecec8`）。

### 11 条 marker 差（已解释，不是漏归档）

对照 2026-08-15T06:46:51Z 磁盘与上述 Status 快照：

| 集合 | 数量 |
| --- | ---: |
| Status `lifecycle=terminal` | 2211 |
| 磁盘 `terminal-archive.json` | 2200 |
| 两边都有 | 2200 |
| 有 terminal、无 marker | **11** |
| 有 marker、无 terminal | 0 |

这 11 条全是 v2 `purged`、`journalStatus=not-applicable`、现场无 marker。Status 凭 live 观测直接标 `terminal`，因此不满足本票候选式 `purged ∧ quarantine 不在 ∧ lifecycle != terminal`。不应补写 marker，也不应再 Archive。

| operationId | 分类 |
| --- | --- |
| `20260814T020720Z-7fe528f4-5f51-4990-9818-ba3b99e96a69` | reports/smoke 清理，namespace 已空 |
| `20260814T022358Z-84436ddd-b95d-4608-beda-410897d3cec3` | 可重建构建产物，target 已重建 |
| `20260814T022434Z-f0c6f9ec-d42b-40a6-9a94-4637319d8d7f` | 可重建构建产物，target 已重建 |
| `20260814T022509Z-32c3ebd7-2083-4db4-a65f-e9d32dae719f` | 可重建构建产物，target 已重建 |
| `20260814T022544Z-5abb4a9d-d885-4e8f-9a7c-94f0845d8c63` | 可重建构建产物，target 已重建 |
| `20260814T022650Z-83de648e-cfaf-4c51-83e6-a40f84b54e96` | 可重建构建产物，target 已重建 |
| `20260814T022826Z-aa6ba336-40ab-439e-a9ef-d5dedbe21097` | 可重建构建产物，target 已重建 |
| `20260814T022920Z-a447bd4a-2951-4570-8658-9d9bdd0d61c7` | 可重建构建产物，target 已重建 |
| `20260814T023016Z-9d982bb3-a5e8-46b4-bc78-93dd4648ca9a` | 可重建构建产物，target 已重建 |
| `20260814T090756Z-54246ac3-9bd5-4ed0-b07d-cce9249e4700` | run-evidence 后代，namespace 已空 |
| `20260814T170159Z-cf25c042-24c4-4c30-b1e6-fd3a49f52964` | scratch fixture，namespace 已空 |

详细分类：`reports/safe-tree-delete-issue22-comment-20260815/`。

### 测试与未验证

评论跟进时单独跑过：IdentityV2 / PlanIdentityV2 / FileSystem / Status 为 exit 0。HashSafely 当时 exit 1（sharing-probe 后 exclusive open；当时工作树有他人 identity WIP）。之后在同一工作树单独重跑 HashSafely 为 exit 0。这不能改写成「干净树上全量 host-safety 已绿」。

仍未做（也不构成本票漏归档）：

- 稳定工作树后的新生产 Status
- ProductionSmoke
- `node .\scripts\Run-PowerShellTests.cjs --module host-safety` 全量
- 把 reports 证据提交到远端可读取位置

这些仍归 #45 / #52 收口链，不在本票再开一轮 Archive。

### AC 对照

| AC | 判定 |
| --- | --- |
| 执行时重推候选 | 满足 |
| 1674 → 约 79，偏差有解释 | 满足（live 110，79 作废） |
| 5 条 v1 + 1 条历史 v2 仍在 | 满足 |
| 零 evidence 删除/重写 | 满足 |
| 逐条结果可读 / 单条失败不中断 | 满足（fixture + 本轮 0 次调用） |
| 每条归档有时点证据 | 满足（既有 marker；本轮无新写入） |
| 未新增 BatchArchive | 满足 |
| 判据 / 三层保护 / policy v4 未改 | 满足 |
| fixture 错误隔离 | 满足 |
| 既有全部测试保持通过 | **未在干净树上证明** |

保持 OPEN。若要关票，需要另一次明确授权，并决定是否接受「全量测试 / smoke / 干净 Status」不归本票。
