# GROK-FINAL-REPORT — GitHub #32 Apply 哈希复用

状态：`DONE_WITH_CONCERNS`  
证据目录：`reports/safe-tree-delete-issue32-20260819/`  
工作树：`wip/2026-08-18-host-and-safe-delete`（未 commit / 未 gh）

## 结论

负优化根因已经用 profile 钉死：复用路径在已持有 lease 时又按路径 `GetFileIdentityV2`，并且三次 snapshot 仍走 PowerShell 每文件父 guard + lease；4KB SHA-256 不是墙钟主体，所以 cache hit 比直接哈希还慢（历史 0.868x / 0.93x）。

修复后：

- Apply 热路径用 C# `ApplyTreeSnapshotBuilder` + `ApplySessionHashCoordinator`
- 首次 snapshot：lease + 同句柄 FileIdentityV2 + 哈希 + 写入 `SessionHashCache`
- 后续 snapshot：identity 命中且 cache 命中则免重哈希，但仍做 `VerifySafeTreeDeleteFile`
- identity 不匹配抛 `IdentityMismatchException` 并拒绝隔离
- `-DisableApplyHashReuseForTest` 仍走历史 HostSafety PowerShell snapshot（无 cache）

10k×4KB 两次取样均 ≥1.5x。三次 snapshot 与 identity 强度未放宽。

## 10 条 AC

| # | 条件 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | Apply 读 Plan `fileIdentitiesV2` | 通过 | `ConvertTo-CodexSafeTreeDeleteApplyFileIdentityMap` → coordinator |
| 2 | Apply 创建会话级 `SessionHashCache` | 通过 | `Invoke-CodexSafeTreeDeleteQuarantine`；`finally Clear()` |
| 3 | 每文件 `GetHashSafely` / 等价协议 | 通过 | 无 lease：`GetHashSafely`；有 lease / C# walker：同句柄 identity + cache + `ComputeSha256FromHandle` |
| 4 | `IdentityMismatchException` 拒绝 | 通过 | HashReuse 中途改文件；不隔离目标 |
| 5 | 正常完成清理 cache | 通过 | HashReuse checkpoint 后 `TryGet` miss |
| 6 | 单元：首次未命中 | 通过 | `Test-CodexSafeTreeDeleteHashReuse.ps1 -SkipScale` |
| 7 | 单元：第二次命中 | 通过 | 同上；quarantine checkpoint |
| 8 | 集成：1000 文件 Plan→Apply | 通过 | `scale-1000.json` elapsed 2623ms，`quarantined=true` |
| 9 | 10k 相对 baseline 1.5–2x | 通过（倍率高于 2x 上沿） | 见下表 |
| 10 | Apply 中途改文件 → mismatch | 通过 | HashReuse security 切片 |

## 基准数字（10k×4KB，≥2 组）

协议：两棵兄弟树；reuse = C# walker + `SessionHashCache`；baseline = `-DisableApplyHashReuseForTest`（HostSafety PS snapshot，无 cache）。

| 组 | baseline ms | reuse ms | speedup | bytesHashed baseline / reuse |
| --- | --- | --- | --- | --- |
| 1 | 268993 | 22444 | **11.985x** | 130237839 / 48317833 |
| 2 | 267942 | 22629 | **11.841x** | 130237839 / 48317833 |

稳定值取较高倍率组：baseline **268993ms** / reuse **22444ms** / **11.985x**。  
`summary.json`、`scale-10000.json`、`scale-1000.json`。

对照（不作为关票数字）：两边都用 C# walker 时 10k 为 1.10–1.12x（约 22s / 24s）。4KB 免重哈希本身不够 1.5x。

## 改动文件

| 文件 | 作用 |
| --- | --- |
| `scripts/lib/CodexSafeTreeDeleteApplySnapshot.cs` | C# Apply snapshot + identity-first coordinator |
| `scripts/lib/CodexSafeTreeDelete.ps1` | Apply 走 C# walker；baseline 旗标保持 PS snapshot；lease 路径从句柄读 identity |
| `scripts/lib/CodexSafeTreeDeleteHashCache.cs` | `SessionHashCache.Count` |
| `scripts/lib/CodexHookHandleBoundIO.cs` | `SafeTreeDeleteFileLease.Handle`；公开 `VerifySafeTreeDeleteFile` / `ReadFileIdentity` |
| `scripts/lib/CodexHostSafety.ps1` | 把 HandleBoundIO + identity/hash/snapshot/journal/purge C# 编到 `D:\Codex\temp\unified-env-addtype\CodexHostSafetyNative.dll` |
| `tests/Test-CodexSafeTreeDeleteHashReuse.ps1` | C# snapshot 与 Plan treeManifest 同形断言 |

## 相关测试

| 测试 | 结果 |
| --- | --- |
| HashReuse `-SkipScale` | 通过（含 AC 6/7/10 与 snapshot 同形） |
| HashCache / HashSafely / IdentityV2 / PlanIdentityV2 | 通过 |
| PurgeHashReuse（含其 10k） | 通过（`ok=true`；Purge 倍率仍是 #33 的 0.951x） |
| Phase1Integration | 通过（`ok=true`；完整流水线 1.758x，未达 #36 的 3x） |
| `git diff --check` | 通过 |

## 历史快照耦合

下列 tracked 快照曾被既有测试写回，已 `git checkout --` 恢复：

- `reports/safe-tree-delete-issue33-20260817/scale-1000.json`
- `reports/safe-tree-delete-issue33-20260817/scale-10000.json`
- `reports/safe-tree-delete-issue36-20260817/filesystem-probe.json`
- `reports/safe-tree-delete-issue36-20260817/scale-phase1.json`

HashReuse 仍硬编码 `reports/safe-tree-delete-issue32-20260817/`。本次留下未跟踪目录 `fixtures-7f708262197f4e698d6179aa248d7fae/`（candidate 已受管删除，余 policy/evidence）。未动 `reports/safe-tree-delete-parallelism-benchmark/work/`（非本票创建）。

## 风险与未决

1. **12x 不是「只少算两次 4KB SHA-256」。** 同 walker 只有 1.12x。票面达标靠 identity-first 之后用 C# 走树替代无复用的 PowerShell snapshot。三次 snapshot 和 FileIdentityV2 都还在；未跳过 mismatch。
2. HostSafety 首次加载会在 `D:\Codex\temp\unified-env-addtype\CodexHostSafetyNative.dll` 落盘编译缓存。源码更新后按时间戳重建。
3. C# walker 必须与 Plan 的 PowerShell snapshot 同形；HashReuse 已断言小夹具 manifest SHA 一致。未覆盖 junction 大树。
4. LiveStreamSet 仍是 locked preflight 后的第二次 PowerShell 走树，两边都付。
5. 未关闭 / 评论 GitHub #32。未 commit。
6. 全量 27 项属 #36，未跑。本票点名的测试无已知红。
