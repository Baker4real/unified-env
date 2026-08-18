# CLOSEABLE.md — GitHub #33 Purge 哈希复用

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。

## 关口结论

`DONE_WITH_CONCERNS`

功能 AC 已用 live 测试证明：Purge 读 Plan `fileIdentitiesV2`，消费 #54 stream-set / leaf disposition，每个 invocation 自建空 `SessionHashCache`，首次走 `GetHashSafely` miss，同 invocation 后续 hit，跨 invocation 再 miss，IdentityMismatch / stream-set 漂移拒绝且不删除。1000 文件 Plan→Apply→Purge 成功。10k 实测 **0.921x**（复用 224320ms / 无复用 206496ms），未加速，按票面实事记录，不伪造。

## 逐条 AC

1. **通过。** `Invoke-CodexSafeTreeDeletePurge` 用 `ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap` 读 Plan `fileIdentitiesV2`；`Read-CodexSafeTreeDeletePlanStreamSet` + `Assert-CodexSafeTreeDeleteLiveStreamSet` + `leaf-dispositions.json` 仍在。
2. **通过。** 首次访问走 `Get-CodexSafeTreeDeleteHashSafely`（`Invoke-CodexSafeTreeDeletePurgeFileHash` L1234）；同 key、同 invocation 的 snapshot 之后删除热路径可 hit。
3. **通过。** Purge 入口新建空 cache；`finally` `Clear()`（L5052）；测试证明 Apply cache 不会预填 Purge，完成后 cache 为空。
4. **通过。** `-Mode Purge` / 库函数首次访问为 miss；未声称 Apply 跨进程填充 Purge。
5. **通过。** IdentityMismatch 记录稳定拒绝并保留 quarantine；目录 ADS stream-set 漂移同样拒绝；unknown/error disposition 不放行。`Test-CodexSafeTreeDeleteLeafStreamSet` exit 0。
6. **通过。** 单元：首次 miss、同 invocation hit、跨 invocation miss、cache 不绕过 identity/内容复验。
7. **通过。** 1000 文件 Plan→Apply→Purge：`purged=true`，`leafDispositionsDeleted=1000`，`streamSetSource=plan.leafStreamSetV1`，`purgeElapsedMs=31639`。
8. **通过（数字未达加速）。** 10k 复用 224320ms / 基线 206496ms = **0.921x**。方法：两棵兄弟树，每文件 4096B；Apply 建树走 `-DisableApplyHashReuseForTest`；Purge 对比 SessionHashCache vs `-DisablePurgeHashReuseForTest`。未扩到 Status / CLI BatchPurge。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。

### Standards

- 无硬违反仓库编码标准。`git diff --check` 对本票文件通过。
- 判断：`Invoke-CodexSafeTreeDeletePurgeFileHash` 与 Apply helper 形状相近（Duplicated Code），但 Purge 有 lease 路径和独立错误文案，未抽共享以免拆坏 Apply。
- 判断：删除热路径在 cache hit 时仍 `Get-CodexSafeTreeDeleteFileIdentityV2` 再开一次（与 snapshot dispose+再开同味）。未为刷 10k 数字放宽 `FileShare.None` 或跳过 identity 核对。
- Status / Restore / 未传 provider 仍走原 `ComputeSha256FromHandle`。

### Spec

- 票面要求的 Purge invocation-local 复用、#54 消费、拒绝路径、单元/集成/基准都在。
- 没有 Plan 预填、跨进程 reuse、用 cache 授权删除、Status / BatchPurge 扩围。
- 性能 spec 的 1.5–2x / 3x 不是本票硬门槛；票面要求实事报告。实测 0.921x 与 #32 Apply 0.868x 同类，根因是小文件上额外 open 超过省下的内容哈希。

**Standards 0 硬违反 / 2 判断味道；Spec 0 缺失要求，最差是 10k 未加速。**

## 未解决问题

- 10k 未加速（0.921x）。snapshot 仍是 dispose lease 再 `GetHashSafely` `FileShare.None` 二次打开；删除热路径 cache hit 仍会按路径再读一次 FileIdentityV2。
- `bytesHashed` 在 cache hit 时仍按文件长度记账，不能当物理读字节。
- 未重跑 #32 10k Apply 基准（墙钟约 11 分钟，数字已在 `reports/safe-tree-delete-issue32-20260817/scale-10000.json`）。
- 未改 guard / policy / hooks。未 commit / comment / close #33。
- Status、CLI BatchPurge、#34 批量、#36+ 并行仍不在本票。
