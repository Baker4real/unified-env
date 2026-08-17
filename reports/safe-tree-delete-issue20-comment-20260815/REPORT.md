# GitHub #20 复验报告（2026-08-15 代码对齐审查）

本目录是一次性证据，不是关票、归档、Purge 或工作树整理授权。权威是 #20 最新一条评论（2026-08-15T06:23:46Z，[issuecomment-5300924272](https://github.com/Baker4real/unified-env/issues/20#issuecomment-5300924272)）。前一条审计评论只作关闭链说明。

## 结论

**DONE_WITH_CONCERNS。票保持 OPEN。未取得生产 Purge `leaf-delete-failed` JSON。**

- 受管 wrapper 的 `$LASTEXITCODE` 转发仍在；仓库源与宿主副本哈希一致，且与旧 issue20 证据哈希相同。
- 经真实 `.cmd` 再打一次无确认 Archive：exit 0 + `confirm-archive-required`，生产证据根未写。
- 在不吞并 #47/#55、不改生产实现的前提下，#20 **没有**属于本票的路径能得到「生产 Purge 发出的、含 `purged=false` + 完整 metrics + `refusalReason=leaf-delete-failed` + 非零退出码」的证据。
- 最新评论要求的稳定工作树不在本执行者授权内；现场仍是 15 个已跟踪文件、`+1487/-34`。

## 对照最新评论

| 评论项 | 本次结果 |
| --- | --- |
| LASTEXITCODE 转发已在宿主 wrapper | **仍在。** `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1` 第 5 行与仓库源 `scripts/invoke-codex-safe-tree-delete-host.ps1` 均为 `exit $(if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 })`。两边 SHA-256 均为 `636CB140720BF15681364459269C2D5DC4638E339F2589AD2A3A53B6E17B9373`；`.cmd` 两边均为 `45AEADF7F758A1CAFCE106F66E7EAECC5F60176D2017630E2AF461A2A37BCA12`。四个入口文件都不在 dirty 集合中。 |
| 旧 `evidence.json` 仍是 synthetic probe，不是生产 Purge JSON | **仍成立。** 只读了 `reports/safe-tree-delete-issue20-exitcode-20260815/evidence.json`，未覆盖。本次也未再跑 synthetic 探针，避免再造一份不合格证据。 |
| 工作树 15 文件 `+1487/-34`，不能证明只改传递 | **仍成立。** 本次未回退、未覆盖、未整理他人 dirty 文件。 |
| 建议：真实 Purge `leaf-delete-failed` JSON | **未取得。** 见下一节。不是本票可独立完成的验收。 |
| 前一条关闭链：#55 → #50 → #47，再补 e2e | **沿用，不吞并。** #55 被 #54 阻塞，#47 被 #50 阻塞。 |

无确认 Archive 现场（2026-08-15T06:48:15Z）：

```text
invoked: D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Archive -Json
$LASTEXITCODE=0
stdout={"archived":false,"refusalReason":"confirm-archive-required"}
evidenceRoot lastWriteUtc 前后均为 2026-08-14T17:01:59.7562796Z
```

PowerShell Core 7.6.4。`$LASTEXITCODE` 在 `.cmd` 返回后立即读取。

## 是否取得生产 Purge JSON

**没有。未尝试打出。**

要经生产链打出该 JSON，必须同时满足：

1. 真实 `.cmd` → 宿主 `.ps1` → `scripts/Invoke-CodexSafeTreeDelete.ps1`。生产 CLI 只在 `Purge -Json` 时传 `-ReturnFailureMetrics`，**没有** `FixtureBeforeDirectoryTreeDelete` / `FixtureLeafDeleteFault`。
2. 生产 `Invoke-CodexSafeTreeDeletePurge` 在删除前先跑 `Get-CodexHookCapabilityDirectoryTreeSnapshot`（`name=safe-delete purge locked preflight`），对每个文件 `AcquireSafeTreeDeleteFileLease`。Purge 开始前持锁会在发出 JSON 之前抛错或卡住。
3. 权威 spec `docs/specs/2026-07-24-safe-tree-delete-capability.md` 236–240 行禁止用 JSON 发出前的持锁/lease 抛错冒充 live 验收。
4. `tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1` 166–172 行已写明：live 套件不能用 Purge 前持锁打出生产 `leaf-delete-failed`；该 JSON 由 ControlPlane fixture 在 preflight **之后**持锁覆盖。
5. 预检后钩子 `BeforeDirectoryTreeDeleteForTest` 只在 fixture 入口接线（约 `CodexSafeTreeDelete.ps1` 4545–4546 行）。经 `.cmd` 无法注入。
6. `BatchPurge` 调 Purge 时不传 `ReturnFailureMetrics`，失败会 throw，不会发出该 JSON。
7. 改 Purge 业务逻辑、弱化 exit-0 refusal、改 `scripts/lib/CodexSafeTreeDelete.ps1` 或测试文件均被本票边界禁止。

因此：用 fixture 再打一份 JSON 仍不是「生产 Purge 真实发出」；用 Purge 前持锁走生产链只能得到 spec 明确否定的抛错；在预检后抢锁做 live 负向 smoke 就是 #55，且 #55 被 #54 阻塞。#20 没有第三条实现路径。

## 剩余工作指回哪张票

关闭前动作保持前一条审计评论的顺序，并补上用户给定的阻塞边：

1. **#54** 先结束（阻塞 #55；工作树里未提交的 `CodexSafeTreeDelete.ps1` / `CodexSafeTreeDeleteFileIdentity.cs` 属于别人，本票未动）。
2. **#55** 真实受管负向 smoke：经生产 wrapper 打出 `purged=false` + 完整 metrics + `refusalReason=leaf-delete-failed` + 非零退出码。
3. **#50** 可复算证据包（阻塞 #47）。
4. **#47** 真实失败合同复核。
5. 再补端到端断言 / 全套回归。这不是 #20 的授权范围。

#20 自己的传递修复已经在宿主 wrapper 上，可用无确认 Archive 证明「只修传递、不改 exit-0 refusal 取值」。它不能代替 #55 的生产失败 JSON。

## 改动文件

只新增：

- `D:\Codex\projects\统一环境\reports\safe-tree-delete-issue20-comment-20260815\REPORT.md`
- `D:\Codex\projects\统一环境\reports\safe-tree-delete-issue20-comment-20260815\evidence.json`

未改旧 issue20-exitcode 目录，未改生产库、测试、policy、hooks、`AGENTS.md`、`modules/manifest.json`。未 commit / push / 建 branch / 开 PR / `gh issue comment` / close。

## 风险与未验证

- 工作树仍脏，不能用本次哈希证明「全仓库只有传递被改过」。wrapper 四个入口本身干净，且与 2026-08-13 已验收哈希一致。
- 生产 `CodexSafeTreeDelete.ps1` 有他人未提交改动（#35/#54 方向）。本次只读了 Purge 预检/catch 顺序，未把该 dirty 实现当成已发布合同。
- 未跑生产 Status、未跑 ProductionSmoke、未跑全量 host-safety、未核 CI `31762651560`。
- 本报告不能关闭 #20。
