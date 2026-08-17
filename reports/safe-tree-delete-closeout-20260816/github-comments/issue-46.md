## 结论回写（2026-08-16）

结论：**本票 Serena session 互斥验收已满足；保持 OPEN，本次不 close。** `tests/Test-CodexHookInventory.ps1` 失败 **不属于** 本票互斥 AC。

### 已验证

- `tests/Test-CodexSerenaBehaviorHooks.ps1` exit 0（33.1 s）：同 session 竞争 fail-open、不同 session 不互挡、Cleanup 超时/abandoned mutex、并发 Cleanup 终态一致。
- live 与 managed `serena-behavior-guard.ps1` SHA-256 均为 `85D78B8533A47F8A9F3419E1BC4DB33E3351522D7E8C1FE1AA861C0399F4EA3A`。这是身份 pin，不是生产 session 上的 host-live 行为验收。
- `modules/manifest.json` 的 codex-host `host-live` 只有 launcher / catalog / IFEO / retired-artifact，没有 Serena mutex 项。本次未对生产 Serena session 跑 live Reminder。

### 完整 fixture 红的归因（不在本票修）

`tests/Test-CodexHookInventory.ps1` exit 1，原文：

> 已退役 state policy wrapper 必须作为缺失依赖观察，不得假定仍在线

当前脏工作树 `managed/codex-hooks/manifest.json` 把 `codex-state-policy` 标为 `lifecycle=active`，`wrapperPath=D:\Codex\.codex\hooks\codex-projectless-root-d.cmd`（文件存在）。inventory 因此看不到「缺失 wrapper」。这是他人 WIP，本票未回退、未改该 manifest。`Get-CodexHookDependencyFacts` 也不消费 `KnownRetiredRegistration` 的 retired 语义。

### 本票不主张

- 不主张完整 codex-host fixture profile 已绿。
- 不主张生产 Reminder 竞争已 live 验证。

本次未 close、未改 hooks、未 commit/push。
