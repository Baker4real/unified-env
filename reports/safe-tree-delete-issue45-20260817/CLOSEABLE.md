# Issue 45 核验关口可关闭对照（2026-08-17）

本文件只对照 GitHub #45 的 Acceptance criteria（tracker DAG 与票面纠正）。证据是本次只读 GraphQL / `gh issue view`，落在同目录 `dag-live.json`（`generatedAt=2026-08-16T17:23:31Z`）。

不是 GitHub comment / close / edit 授权，不是 commit / push，不是 Purge，也不是“删除能力已实现”。本关口**未**执行 `gh issue edit`。不要把本关口写成实现已完成。

**本关口（本地核验产物）：DAG 已对照并落盘。**
**#45 GitHub 关闭：不可关。** 须等四个直属子票 #47 / #50 / #52 / #53 全部读回 `CLOSED` 且 `state_reason=completed`。本关口不关任何票。

## 判定

| 项 | 结论 |
| --- | --- |
| 计划 blocked-by 边 | **35/35 原生可读**（0 条只在正文） |
| 计划 parent / sub-issue 边 | **12/12 原生可读**（0 条只在正文） |
| 否定断言（#49 不是 #45 child / blocker） | **2/2 原生成立** |
| 计划外额外原生边 | 6 条 blocked-by + 17 条 parent（#26 对 #27–#43） |
| #54 / #55 `ready-for-agent` | **仍在**；parent 分别为 #26 / #47；未见同名重复 marker |
| #45 四个直属子票 | 全部 **OPEN** |
| 本关口是否关票 / 改票面 | **否** |

## #45 Acceptance criteria

| AC | 本关口 | 证据 |
| --- | --- | --- |
| Native parent and blocked-by relationships match the DAG above and are independently readable | **满足** | `dag-live.json`：计划 35 条 blocked-by、12 条 parent 均为 `native-match`。双向可读（`blockedBy` ∩ `blocking`，`parent` ∩ `subIssues`）。GitHub 票面 AC 仍是 `[ ]`，因为本关口未 `gh edit`。 |
| L (#54) and H (#55) have the `ready-for-agent` label, unique parent relations and no duplicate marker issues | **满足** | #54 labels=`ready-for-agent`，parent=#26。#55 labels=`ready-for-agent`，parent=#47。标题检索只命中这两张，无重复 marker。 |
| All edited bodies distinguish live tracker state, evidence publication and future closure; no ticket claims that this shaping action completed implementation or evidence | **满足（只读回读，未改票）** | 先前写回已在远端：#33 正文已是 invocation-local；#35 AC 已是 FAT32/exFAT `SupportsFileId128=false` / `RecommendParallel=false` / 失败闭锁；#45 / #49 写明 #49 独立且不挡 #45。#45 正文写 evidence 先于 #52/#53/#45 关闭，且 “this tracker writeback closes no existing issue”。没有任何票把**本 shaping 动作**写成实现或证据已完成。 |
| No existing issue is closed by this writeback | **满足** | 本关口零 close。#45 四子票仍 OPEN。已 CLOSED 的 #19 / #27–#31 是更早完成，不是本关口。 |

## 已匹配的原生边

`A → B` 表示 B.`blockedBy` 含 A，且 A.`blocking` 含 B。

### Control plane

- parent：#19–#24 都是 #18 的 native sub-issue。
- blocked-by：#19 → #22 → #23 → #24；#20 → #21；#22 + #23 → #24；#21 + #24 → #18。

### Performance

- parent：#54 parent=#26（#26.`subIssues` 含 54）。
- blocked-by：#27 → #35；#30 → #54；#54 → #32, #33, #55；#31 → #32, #33；#33 → #34；#32 + #33 + #34 + #35 → #36 → #37 → #38 → #39 → #40 / #41 → #42 → #43 → #26。

### Status and closeout

- parent：#47 / #50 / #52 / #53 是 #45 仅有的四个直属 sub-issue；#55 parent=#47。
- blocked-by：#48 → #49；#55 → #49；#55 → #50 → #47；#47 + #50 → #52 → #53。
- 否定：#49 parent=null，不在 #45.`subIssues`；#45.`blockedBy` 为空，#49 不挡 #45。

## 缺失的原生边

**无。** 计划 DAG 没有“只存在于 #45 正文、远端读不到”的 parent 或 blocked-by。

## 额外原生边（计划未点名，远端可读）

这些边不否证计划边，但说明“精确等于正文 DAG”不成立。

| 边 | 说明 |
| --- | --- |
| #26 parent of #27–#43 | 性能系列 epic 子票；#45 只点名 #54 是 #26 的 native sub-issue |
| #27 → #28, #27 → #31 | 计划未写 |
| #29 → #30 | 从 #30.`blockedBy` 读到；#28/#29 未做顶层 alias 查询 |
| #30 → #32, #30 → #33 | 计划路径是 #30 → #54 → #32/#33；另有直连 |
| #39 → #42 | 计划路径是 #39 → (#40 + #41) → #42；另有直连 |

## #54 / #55

| 票 | state | `ready-for-agent` | parent | 重复 marker |
| --- | --- | --- | --- | --- |
| #54 | OPEN | **仍在** | #26 | 标题检索仅 #54 |
| #55 | OPEN | **仍在** | #47 | 标题检索仅 #55 |

## 票面纠正（只读）

| 要求 | live |
| --- | --- |
| #33 invocation-local，禁止 Plan 预填 / 跨进程复用 / 缓存授权删除 | 正文 AC 已写；本关口未 edit |
| #35 FAT32/exFAT 失败闭锁 | 正文 AC 已写 `RecommendParallel=false` 与失败闭锁。What to build 仍只说“保守策略（禁用并行化）”，弱于 AC。2026-08-15 / 2026-08-16 评论已有维护者 waiver：实卷 e2e 不再作为关 #35 的必要条件。#35 仍 OPEN。 |
| #45 保持 #49 独立，不把 Status 算进 #26–#43 | #45 / #49 正文已写；原生关系也独立 |
| 本 writeback 不关既有票 | 本关口未关 |

## 未解决问题

- **#45 不能关。** 四个直属子票 #47 / #50 / #52 / #53 均为 OPEN。#45 必须等它们全部 `CLOSED` + `state_reason=completed` 之后才是最后一张。
- GitHub #45 正文 AC 仍全部 `[ ]`。本关口禁止 `gh issue edit`，因此远端 checkbox 未勾。
- 额外原生边仍在；若后续 shaping 要求“精确等于正文 DAG”，需要另授权的关系编辑，本关口不做。
- #35 仍 OPEN；正文 AC 与 fail-closed 已对齐，但 What to build 偏软，关票依赖已有 waiver 评论，不是本关口对象。
- 本目录不是 comment / close / commit / Purge 授权，也不证明删除能力已实现。
