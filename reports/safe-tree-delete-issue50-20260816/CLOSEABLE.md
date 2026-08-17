# Issue #50 AC 对照（工作区清单关口）

本文件只解释本目录清单。不是 GitHub comment/close/edit 授权，不是 leftover `0ab1e1b6` 清空授权。**未** git add / commit / push。

判定对象：工作区文件是否齐、边界是否可审查。发布与远端回读标为 **未做**。

| AC | 本关口 | 证据 |
| --- | --- | --- |
| #55 的 smoke 产出、source identity、采集时点、退出码、stdout/stderr、进程收口和 pre/post manifest/USN 证据已可读取 | **工作区满足**；默认分支 **未做** | `reports/safe-tree-delete-issue55-20260816/summary.json` exit/墙钟/2350；`identity.json`；`invocations.json`；各 `*.meta.json` + stdout/stderr；`leaf-delete-failed.json` exit 1；`timeout-contract.json` / `timeout-drill.json`；`status-generation-binding.json` + `status-pre-usn.json` / `status-post-usn.json`；`status-zero-write.stdout.txt`（smoke Status 原文，SHA `1d069f8a…`） |
| 建立证据清单，逐项说明哪些脚本、原始快照和派生报告是复算 #22–#24 结论所必需的 | **满足** | `MANIFEST.md`、`include.json` |
| 对 PID、progress、heartbeat、临时锁或其他瞬态文件逐项说明排除理由，不以整个 reports 代替审查 | **满足** | `exclude.json` 分类 + 逐文件 |
| 证据包保留 source identity、采集时点、关键计数、哈希或 generation 绑定以及可复算入口 | **满足** | `include.json` `bindings`；入口均为相对仓库路径 |
| 所有被旧 issue 评论引用的证据在仓库默认分支上可直接读取，且引用不会依赖本机绝对路径 | **工作区路径已列入**；默认分支可读 **未做** | `github-comments/` 副本 + `include.json` `citedRelativePathsMustStayInInclude`。评论里的本机绝对路径（wrapper、leftover quarantine）不是引用真源；相对 `reports/…` 路径才是 |
| 不夹带 Serena #44、Sub2API、safe-tree-delete policy allowlist 或其他工作树改动，也不要求全仓工作树干净 | **满足** | `exclude.json` `foreignWip`。ProductionSmoke 工作树 diff **在包内**（smoke 真源），生产 lib / policy **不在** |
| 所属模块验证、证据自检和 `git diff --check` 通过；提交范围与清单一致 | **部分** | 自检脚本见下。`git diff --check` 只跑清单内已跟踪能检查的部分（ProductionSmoke）。**未 stage**。未重跑 host-safety 全量；#35 FileSystem 为已知 waiver。新 reports 前缀尚未写入干净的 `modules/manifest.json`（该文件另有无关 WIP，本关口不改） |
| 发布完成后立即独立回读默认分支内容和证据哈希；回读失败时停止，不进入 #47/#52 | **未做** | 编排禁止 commit/push。不得把工作区哈希写成默认分支哈希 |

## 非零主证据（给后续 #47/#52 用，本关口不关票）

关 #21 只能引用 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` 的 **exitCode=1**。`revert-forwarding.json` 是 exit 0。`summary.json` `ok=true` 不能替代。

## 提交默认分支

**未做。** 将来一次 `git add` 的精确相对路径见 `STAGED-FILE-LIST.txt`。本关口没有执行 `git add`。

## 独立回读默认分支哈希

**未做。**

## 模块与自检

- 本关口未重跑 host-safety 全量。
- #35 FileSystem 为已知 waiver。
- 自检：`python reports/safe-tree-delete-issue50-20260816/verify-issue50-pack.py`
- `git diff --check -- tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1`（不 stage）

## 未解决问题

- GitHub #50 仍 OPEN；本目录不构成 comment/close。
- leftover `0ab1e1b6` 仍在工作树，不在本包。
- 工作树仍有他人 WIP；不要求干净。
- `modules/manifest.json` 提交关口需要为新 reports 前缀补 owner，但不能夹带当前脏 diff。
- live smoke 当时工作树也有生产 lib WIP；本包不收录该 lib。用干净默认分支 **重跑** smoke 以证明可复现 = **未做**（且本关口禁止重跑）。
