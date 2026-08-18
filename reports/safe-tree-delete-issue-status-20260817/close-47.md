## 结论（关闭）

#47 失败合同已由真实 wrapper 证明，且证据可从默认分支读取。#50 现已关闭。本次关闭。

**非零主证据（关 #21 只能引这一条）：**

`reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json`

默认分支 `6937642` 回读：`exitCode=1`，`purged=false`，`refusalReason=leaf-delete-failed`。不能用 fixture、套件 `ok=true`、或 `reports/safe-tree-delete-issue21-20260816/revert-forwarding.json`（`exitCode=0`）冒充。

入口 / wrapper / 仓库源 identity 见 `reports/safe-tree-delete-issue55-20260816/identity.json`。合法 exit-zero refusal 未改。

leftover `0ab1e1b6` 仍在，不是本票清空对象。#52 现在可以启动；本评论不执行 #52。
