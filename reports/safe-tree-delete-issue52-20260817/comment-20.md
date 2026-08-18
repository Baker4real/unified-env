## 结论（先于关闭）

#20 只主张一件事：**受管中间层转发 `$LASTEXITCODE`**。缺确认的结构化 refusal 仍是 exit 0。传递修复已满足本票验收。

本评论**不吞并 #47 / #55**。`leaf-delete-failed` 失败合同、进程收口与 USN 零写入由那两张票持有；正式非零主证据只在关 #21 时引用 #47/#55 的 `leaf-delete-failed.json`。本票关闭不等于那两张票完成。

## Acceptance criteria

| AC | 结论 | 依据 |
| --- | --- | --- |
| 经完整受管 wrapper 链，`leaf-delete-failed` 返回非零 | **传递层已就位**；live 非零合同不由本票收口 | wrapper identity 一致（见下）。本票早期演示见已发评论副本，**不是** #47 关票证据 |
| 修复只改退出码传递，不改取值 | **满足** | `identity.json`：`ps1Equal=true`，live / 仓库 host wrapper SHA 均为 `636cb140…`（含 `exit $LASTEXITCODE`）。未改生产实现业务逻辑 |
| `exit 0` + 结构化 `refusalReason` 表示未执行的契约不变 | **满足** | `archive-unconfirmed`：`actualExitCode=0`，stdout `{"archived":false,"refusalReason":"confirm-archive-required"}` |
| 缺少确认意图的结构化 refusal 继续 exit 0 | **满足** | 同上 |
| 修复前确认 ownership；不属本项目则移交，不擅自改 | **满足** | `identity.json`：`cmdEqual=true`，`ps1Equal=true`。live / 仓库 `.cmd` SHA 均为 `45aeadf7…`；live / 仓库 host `.ps1` SHA 均为 `636cb140…` |
| 不改 policy、不改生产实现业务逻辑 | **满足** | 本收口未改生产 policy，未改生产实现取值。身份比对见 `identity.json`，不把未入 #50 包的源文件路径当引用真源 |
| 权威 spec 关于该退出码的表述与修复后行为一致 | **满足** | spec 要求 `leaf-delete-failed` 发出 JSON 后 `exit 1`；传递层不再把该 1 吞成 0。合同实证归 #47/#21 |

## 本票不主张

- 不主张 #47 的失败合同复核已完成。
- 不主张 #55 的确定性进程收口 / 代际核验已完成。
- 不主张用本票 JSON 关 #21。#21 只能引用 `reports/safe-tree-delete-issue55-20260816/leaf-delete-failed.json` 的 `exitCode=1`。

leftover `0ab1e1b6` 仍在，属 #45/#50 清空集，不是本票打扫对象。

## 引用（仓库相对路径）

- `reports/safe-tree-delete-issue55-20260816/identity.json`（`cmdEqual=true`，`ps1Equal=true`）
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.meta.json`（`actualExitCode=0`）
- `reports/safe-tree-delete-issue55-20260816/archive-unconfirmed.stdout.txt`
- `reports/safe-tree-delete-closeout-20260816/github-comments/issue-20.md`（已发评论副本；本条是关票结论）
- `reports/safe-tree-delete-closeout-20260816/issue20-production-purge-fail.json`（本票早期演示，`purge.exitCode=1`；**不是** #47/#21 非零主证据）
