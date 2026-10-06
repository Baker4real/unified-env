# daily-update 辅助脚本

每日更新用的只读辅助脚本。`<outDir>` 为当次证据目录
(如 `D:\agents\run-evidence\daily-codex-ecosystem-update\<ts>`),脚本不写死时间戳目录。

## 1. gen-ledger-tsv.cjs(只读账本)

```
node D:\agents\projects\统一环境\scripts\daily-update\gen-ledger-tsv.cjs <outDir> [ledgerPath]
```

默认账本 `D:/Codex/.codex/skills/.downloaded-skills-source-state.json`。
输出 `<outDir>\ledger-github-sources.tsv`,并打印行数与状态计数。

## 2. sweep-lsremote.sh(网络只读,约 90 秒)

```
$env:HTTPS_PROXY='http://127.0.0.1:17897'
& 'C:\Program Files\Git\bin\bash.exe' D:/agents/projects/统一环境/scripts/daily-update/sweep-lsremote.sh <outDir> [prevLsremoteResults.tsv]
```

前置:`<outDir>` 已有 `ledger-github-sources.tsv`。输出 `lsremote-results.tsv`、
`lsremote-errors.log`、`tags-check.tmp`;传入上次结果时另输出 `sweep-diff-output.txt`。
`sweep-exclude.txt` 列出的 repo 键不请求网络,结果行为 `EXCLUDED`。只放非 GitHub
必败源,真实上游失败须查清原因,不得排除。代理由环境变量传入。

## 3. sweep-diff.cjs(纯本地,sweep 传入 prev 时已自动调用)
```
node D:\agents\projects\统一环境\scripts\daily-update\sweep-diff.cjs <prev.tsv> <cur.tsv>
```

## 4. mcp-smoke.cjs(仅 initialize + tools/list)

```
node D:\agents\projects\统一环境\scripts\daily-update\mcp-smoke.cjs <outDir>
```

启动 Serena 与 CodeGraph 的 MCP stdio 服务,写 `<outDir>\mcp-smoke-result.json`。
全部成功退出码 0,否则 1。建议在 `D:\agents\projects\统一环境` 下运行。
