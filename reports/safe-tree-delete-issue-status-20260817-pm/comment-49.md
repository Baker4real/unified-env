## 状态回写（2026-08-17 续）

**实现关口：** `DONE_WITH_CONCERNS`。`metTarget=false`。
**GitHub：** 保持 OPEN。未 commit。

三次独立冷启动（live `.cmd -Mode Status -Json`，每次新 pwsh 7.6.4）：

| 次 | 墙钟 | elapsedMs | operations | entriesScanned | bytesHashed |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | **189.179s** | 187074 | 2383 | 3539 | 757MB |
| 2 | **184.361s** | 182578 | 2383 | 3539 | 757MB |
| 3 | **181.586s** | 179135 | 2383 | 3539 | 757MB |

对照 #24：493.768s / 2356 / 6622 / 1.81GB。归档认证降到亚秒，仍做 marker 内容 + plan/tx SHA/identity + 现场 namespace。同一 Status 调用内树缓存**不是** Apply/Purge `SessionHashCache`。未归档整棵 `treeManifest` `ConvertFrom-Json` 仍约 160s，不能跳过认证再砍。

#48 purged+MR 仍 42。leftover 仍 `purge-resumable`、不在 blocking。未用 VSS。

证据：`reports/safe-tree-delete-issue49-20260817/`（工作树，未进默认分支）。

leftover 仍在：`reports/.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine` 与 `D:\Codex\.codex\run-evidence\safe-tree-delete\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\transaction.json`。SHA-256 仍是 `4e73aedc260c43c536ab9df3d3f6d5f73a065a8a17c26d1706998f583a0339d7`。属 #45 清空集，不是本票打扫对象。

本次只回写状态，不 `gh issue close`，不 commit/push，不 Purge leftover `0ab1e1b6`，不执行 #52 关票序列。
