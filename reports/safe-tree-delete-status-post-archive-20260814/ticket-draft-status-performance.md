# 草稿：生产 Status 独立性能立项

**不要用本文件直接 `gh issue create`。不要在 #24 实施。不要改 Archive 判据，也不要把这张票并进 #26–#43 的删除哈希复用。**

## Parent

#18 / 接续 #24（#11 US1 未兑现）

## 问题

生产 `-Mode Status` 仍然要数分钟，做不到「日常清理前顺手确认」。

已观测墙钟（同一类全量生产 Status，不是 fixture）：

| 时点 | 来源 | operations | entriesScanned | bytesHashed | elapsedMs |
| --- | --- | ---: | ---: | ---: | ---: |
| #11 原文 | 更早审计 | 1828 | — | ≈279MiB（当时口径） | ≈267s |
| 2026-08-10 | #19 基线 | 1980 | 4815 | ≈1.63GB | 501018 |
| 2026-08-13T19:33Z | #22 窗口 | 2300 | 6205 | 1803705569 | 708080 |
| 2026-08-13T19:59Z | #24 live | 2300 | 6205 | 1803705569 | 321851 |

#24 与 #22 的扫描量和哈希量逐字节相同，耗时差一倍以上，采集间隔约 21 分钟。成本是反复认证整棵证据根，对缓存温度敏感。归档把 2191 条标成 terminal 之后，**扫描账一笔没少**。

这和「删 GB 级 node_modules 要一小时」不是同一个瓶颈。现役性能 spec / #26–#43 盯的是 Plan/Apply/Purge 的内容哈希复用。Status 即使在那些票落地之后，仍会每次重读重哈希全部历史 plan/transaction/tree。

## 建议做

1. 为 **Status** 单独立项，验收改成：冷缓存下对当前生产证据根达到「可顺手确认」的数量级（秒级或明确的个位数分钟上限），并保留现有认证。
2. 先量冷/热两次，拆开：枚举 run 目录、读 plan/transaction、认证 terminal-archive marker、按需物化 tree、SHA-256。
3. 只对已通过 Archive 合同的 terminal 记录考虑「文件 identity 未变则复用已认证哈希」。marker 本身仍必须现场读回并确认 quarantine 不存在。
4. 不把无事务过期计划、quarantined 不一致或 v1 未终结从 blocking 里拿掉来「加速」。

## 明确不要做

- 不要为了快而跳过 terminal-archive 的内容认证。
- 不要放宽 allowlist / 最小深度 / quarantined→terminal。
- 不要把 Status 扫描优化伪装成 Apply/Purge 已加速。
- 不要在本草稿上直接改生产代码。

## 验收

- 冷启动 Status 的 `elapsedMs` / 墙钟有重复测量，并写明 evidence 规模（operations、entriesScanned、bytesHashed）。
- `complete` / `blockingRecords` / 5+1 未终结识别与 #24 判定集语义一致（允许随后合法新增 smoke operation）。
- 证据根在纯 Status 路径上仍零写入。
