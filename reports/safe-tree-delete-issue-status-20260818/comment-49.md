## 状态回写（2026-08-18）

**实现关口：** `DONE_WITH_CONCERNS`。票面三次冷启动 **<60s 未达**。
**GitHub：** 保持 OPEN。

入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`。pwsh 7.6.4。证据：`reports/safe-tree-delete-issue49-20260817/cold-summary.json`。

| 次 | 墙钟 s | elapsedMs | operations | entriesScanned | bytesHashed | zeroWrite | #48 MR |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 142.286 | 139627 | 2482 | 3952 | 912539936 | true | 42 |
| 2 | 141.992 | 139162 | 2482 | 3952 | 912539936 | true | 42 |
| 3 | 145.850 | 142979 | 2482 | 3952 | 912539936 | true | 42 |

`allUnder60s=false`，`metTarget=false`。认证未跳过。未消费 Apply/Purge `SessionHashCache`。并行 `ConvertFrom-Json` 未落地（子 runspace 会更慢）。成本仍在 activeResolve ~86s + archivedResolve ~48s。

对照优化前（2026-08-17）约 189/184/182s。现场 operations 现为 2482。未改 `policy.json`。实现仍在工作树。

leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 与 `D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json`。最近 Status 三联 SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`，lifecycle=`purge-resumable`，不在 blocking。属 #45 清空集，不是本票打扫对象。

本次只回写状态，不 `gh issue close`，不 `gh issue edit` checkbox，不 commit/push，不 Purge leftover `0ab1e1b6`，不 Archive #48 的 42 条 purged+manual-review。
