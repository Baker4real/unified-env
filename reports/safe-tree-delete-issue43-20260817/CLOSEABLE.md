# CLOSEABLE.md — GitHub #43 文档和用户指南更新

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。未 commit / push / comment / close #43。

## 关口结论

`DONE_WITH_CONCERNS`

票面 16 条 AC 已落到现役真源：性能 spec 新增「操作者指南」（三阶段落地、FILE_ID_INFO、哈希复用、并行仅夹具、FS 探测、两层实测表、故障排查、迁移、发布说明、API）。`modules/host-safety/CONTEXT.md` 只留短指针。能力 spec 只加交叉引用，不复制 uncertain / `leafStreamSetV1` 长文。性能表用已测 JSON，写明未达票面 4x/6x；生产 Purge 未接 `ParallelPurgeCoordinator`。未改生产热路径、policy、hooks。未 Purge leftover。未回退 #42 的 0.962x 句。

## 逐条 AC

1. **通过。** 「三阶段实际落地」表：Phase 1 已接 Apply/Purge；Phase 2 验证已接、删除仍 HostSafety 串行；Phase 3 coordinator 未接生产。
2. **通过。** 「FILE_ID_INFO」：128-bit `VolumeSerialNumber` + `FileId128`，size/mtime 来自 `GetFileInformationByHandle`，缺则新 Plan 失败关闭。
3. **通过。** 「哈希复用与会话缓存」：invocation-local `SessionHashCache`、`FileShare.None`、identity 门闩、缓存命中不哈希；写明 `GetHashSafely` 不对照 Plan 内容哈希（现役行为，不是过期设计稿）。
4. **通过。** 「并行仅夹具」+「文件系统探测」：生产串行；`DetectFileSystem` / `FromDetection` / `DeletionAllowed` 硬门；`RecommendParallel` 只约束夹具 DOP。
5. **通过（实测，不是票面 4x/6x）。** 两层表：生产 HostSafety 与 coordinator 夹具分开。标题写「未达票面 4x/6x」。未把设计 Compatibility Matrix 的 6x 写成已上线。
6. **通过。** 故障排查：生产 Purge 本就是串行；夹具在 `RecommendParallel=false` 时 DOP=1；#35 未提权验证。
7. **通过。** FAT32/exFAT 强制无 `FILE_ID_INFO`，`DeletionAllowed=false`，新 Plan 失败关闭。
8. **通过。** journal flush 慢只适用于夹具；#41 = 18.659%，`IsWithinTarget=false`；先查磁盘再降夹具 DOP。生产 HostSafety 无这条 flush 占比合同。
9. **通过。** uncertain 指向能力 spec pending / uncertain 段：手工核验后重新 Plan 或保持 `manual-review`；不得收成 `purged`；不要 Purge leftover。
10. **通过。** 旧 Plan 缺 `fileIdentitiesV2` / `leafStreamSetV1`（票面所称 schema v4 evidence）必须重新 Plan。现役检测是缺节失败闭锁，不是自动升级。
11. **通过。** 向后兼容：缺节失败闭锁并要求重 Plan；Status/Archive 只读不受影响；缺 `leafStreamSetV1` 的在途 wedge，不建议 Purge leftover。
12. **通过。** `GetFileIdentityV2` 两重载：参数、返回、异常。
13. **通过。** `GetHashSafely`：独占打开、identity、缓存、异常；指向源码 XML。
14. **通过。** `ComputeHashFromHandle`：seek 0 → 哈希 → seek 0。另写 `ComputeSha256FromHandle`：置 0 后停在 EOF，不复位。
15. **通过。** `FileSystemCapabilities` 七个字段及 `FromDetection` 现役规则。
16. **通过。** 「发布说明」：已测 1.02x / 0.962x、已接/仅夹具、破坏性必须重 Plan。

## 两轴审查（文档对照票面 AC + 实测数字）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入的四个路径。未派子代理（本会话是实现子代理）。

### 文档对照票面 AC

- 16 条均有落点，没有另造第三份用户指南长文。
- 没有把票面/旧 spec 的 3x/4x/6x 写成已交付。
- API 对照 `CodexSafeTreeDeleteFileIdentity.cs` / `CodexSafeTreeDeleteHashCache.cs` / `CodexHookHandleBoundIO.cs` / `CodexSafeTreeDelete.ps1` 现役行为：`GetHashSafely` 不校验 Plan 哈希；生产不读 `RecommendHashReuse`；`ComputeSha256FromHandle` 不复位指针。
- 判断：票面「网络自动降级到串行」按现役写成「生产本来串行 + 夹具 DOP=1」，没有抄设计稿「网络关闭哈希复用」——生产哈希复用不看 `RecommendHashReuse`。
- 判断：票面「schema v4」映射为缺 `fileIdentitiesV2` / `leafStreamSetV1`，与 reader 失败闭锁一致。

### 实测数字

| 引用 | JSON | 文档数字 | 核对 |
| --- | --- | --- | --- |
| #36 | `reports/safe-tree-delete-issue36-20260817/scale-phase1.json` | 527846 / 517444 = 1.02x | 一致；`metTarget=false` |
| #42 | `reports/safe-tree-delete-issue42-20260817/scale-phase3.json` | 513510 / 534034 = 0.962x | 一致；`metTargetTypical=false` |
| #32 | `reports/safe-tree-delete-issue32-20260817/scale-10000.json` | 0.868x | 一致 |
| #33 | `reports/safe-tree-delete-issue33-20260817/scale-10000.json` | 0.921x | 一致 |
| #37 | `reports/safe-tree-delete-issue37-20260817/scale-10000.json` | 1.02x / 0.964x | 一致；注明已撤回 collect-then-process、未重跑 |
| #40 | `reports/safe-tree-delete-issue40-20260817/analysis.json` | DOP4=13255ms / DOP1=59439ms = 4.48x；DOP2=2.17x；墙钟最快 DOP16=4926ms | 一致；标明夹具 `File.Delete` |
| #41 | `reports/safe-tree-delete-issue41-20260817/scale-10000.json` | 18.659%，`IsWithinTarget=false` | 一致；线程求和 |
| #35 | `reports/safe-tree-delete-issue35-livefs-20260815/REPORT.md` | waiver，未提权 | 一致；不列入倍率 |

Implementation status 的 #42 **0.962x** 句未改回旧文。设计 Compatibility Matrix 仍保留 6x 目标格，已标注「设计预期，不是已测生产倍率」。

**文档轴 0 条缺失 AC；数字轴 0 条写错。** 最差是设计段仍含 4–6x 目标语（已标明非已测），以及 #35 实卷未验证。

## 本票文件与 `git diff --check`

- `docs/specs/2026-08-13-safe-tree-delete-performance-optimization.md`
- `docs/specs/2026-07-24-safe-tree-delete-capability.md`
- `modules/host-safety/CONTEXT.md`
- `reports/safe-tree-delete-issue43-20260817/CLOSEABLE.md`

未改 `scripts/`、`managed/safe-tree-delete/policy.json`、hooks。`git diff --check` 对本票四个路径退出码 0。

对照 HEAD 时，能力 spec / CONTEXT 的大 diff 含进入本关口前已在工作树的 #54 / uncertain / #42 句；本票只在那些现役句上加了「操作者指南」指针，没有把它们改回 HEAD 旧句。

## 未解决问题

- #35 FAT32/网络实卷 e2e 仍未提权验证；文档已写 waiver，没有编造这些卷上的倍率。
- 同文件后部设计段仍写 4–6x 目标；操作者指南与 Implementation status 禁止把它读成已上线。
- 生产 Purge 仍未接 `ParallelPurgeCoordinator`；夹具 4.48x 不能当删除加速。
- 工作树原本就脏；本票未回退他人 WIP，未 commit，未 close #43。
