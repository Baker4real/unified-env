# #32 负优化诊断（2026-08-19）

## 现象

同一工作树与库，10k×4KB 互异文件，Apply `SessionHashCache` 对比 `-DisableApplyHashReuseForTest`：

- 历史 `reports/safe-tree-delete-issue32-20260817/summary.json`：349164 / 302992 = **0.868x**
- 同目录 `scale-10000.json`：553787 / 515007 = **0.93x**
- 本轮 200×4KB profile：5638 / 5437 = **0.964x**

复用路径比无复用更慢。独立审核约束：不得靠跳过 identity 校验或 snapshot 制造加速。

## 每文件验证路径（当前 HEAD）

Apply 对同一 `FileContentHashProvider` 做三次 `Get-CodexHookCapabilityDirectoryTreeSnapshot`：

1. unlocked preflight
2. locked preflight（随后 `Assert-CodexSafeTreeDeleteLiveStreamSet`，不读内容）
3. quarantine postcheck（rename 之后）

HostSafety 每个 file leaf（`CodexHostSafety.ps1`）：

1. **重新** `VerifiedDirectoryChainGuard.Acquire` 父目录（即使当前节点已持有 `$DirectoryGuard`）
2. `AcquireSafeTreeDeleteFileLease`（`FileShare.Read` + `GetFinalPath` + ADS 枚举 + 64-bit identity）
3. 无 provider（baseline）：`lease.ComputeSha256FromHandle()`
4. 有 provider（reuse）：`Invoke-CodexSafeTreeDeleteApplyFileHash`
   - 再按路径 `GetFileIdentityV2`（第二次 `CreateFile`）
   - 比 Plan `FileIdentityV2`
   - `SessionHashCache.TryGet`（命中则 `Clone` 后返回，不读内容）
   - 未命中才 `lease.ComputeSha256FromHandle()` 并 `Set`

`SafeTreeDeleteFileLease` **没有**公开句柄；reuse 无法从已持有 lease 读 identity。

## 本轮 profile（200 文件 × 4KB，200 次取样）

| 步骤 | 单次 |
| --- | --- |
| 父目录 guard Acquire+Dispose | **629.2 µs** |
| lease Acquire+Dispose | 149.7 µs |
| 路径 `GetFileIdentityV2` | 88.2 µs |
| lease `ComputeSha256FromHandle` 4KB | 90.0 µs |
| `SessionHashCache.TryGet`（含 Clone / PS 循环底噪） | 82.6 µs |
| 路径 identity + Equals | 122.6 µs |

单次 snapshot 墙钟：无 provider 1940ms / reuse-cold 1556ms / reuse-hot 1557ms。  
200 文件 × (629+150+90)µs ≈ 174ms 的 C# 原语，只占 snapshot 的约 10%。其余是 PowerShell `Get-ChildItem` / `Get-Item` / 每文件函数与对象分配。三次 snapshot 即整次 Apply 的主体（200 文件 Apply ≈ 5.5s）。

外推 10k：三次 PS 走树约 200–250s，三次 lease+hash 约 25–30s。4KB SHA-256 不是墙钟主体。

## 根因（已用数字证伪/证实）

1. **已证实：reuse 每文件净增工作。** 命中缓存仍走父 guard + lease，并多一次路径 `CreateFile` + identity 比较 + 缓存 Clone。4KB 哈希约 90µs，额外 identity 开路径约 88µs，复用省下的哈希被额外打开吃掉，再叠加 PS scriptblock provider，所以 **&lt;1x**。
2. **已证实：缓存命中判据本身不是主因。** `TryGet` 与 4KB 哈希同量级；真正贵的是三次整树 PS snapshot + 每文件父 guard/lease。
3. **已证伪：无条件重哈希。** 同 invocation 第二次验证已经 cache hit（既有 HashReuse 单测 + quarantine checkpoint）。
4. **已证伪：锁争用。** Apply 单线程，mutex 只包住 locked + rename + postcheck。
5. **结构结论：** 只跳过 4KB 内容哈希，保留三次 PS 走树和每文件 lease，10k×4KB **到不了 1.5x**。要达标必须让 snapshot 2/3 在 **identity 命中时免 exclusive lease + 免重哈希**，并把 Apply 的走树从每文件 PowerShell 热路径挪到 C#，且 **不得**跳过 identity 或少做 snapshot。

## 修复方向（安全合同内）

- 第一次 snapshot：仍 exclusive lease + 同句柄 identity + 内容哈希，写入 `SessionHashCache`。
- 同一 Apply 后续 snapshot：`FileIdentityV2`（FileId128 + size + mtime）命中且缓存命中则免重哈希；identity 不匹配抛 `IdentityMismatchException`；不可判则回退完整 lease+哈希。
- 命中路径仍走 `VerifySafeTreeDeleteFile`（普通文件 / 非 reparse / hardlink / 默认 ADS / GetFinalPath）。
- 三次 snapshot 都保留；比较仍用完整 treeManifest SHA。
- 生产 Apply（复用开）改走 C# `ApplyTreeSnapshotBuilder`，去掉每文件 PowerShell provider / 重复父 guard。
- `-DisableApplyHashReuseForTest` 保持历史无复用路径：HostSafety PowerShell snapshot + 三次 lease 哈希，不预填 cache。

## 修复后实测

| 比较 | reuse | baseline | speedup |
| --- | --- | --- | --- |
| 同 C# walker，只比哈希复用（200 文件 profile 外推后 10k） | 21479–22686ms | 23575–25397ms | **1.10–1.12x** |
| 票面协议：复用 C# walker vs 无复用 PS snapshot（10k×4KB，2 次） | 22444 / 22629ms | 268993 / 267942ms | **11.985x / 11.841x** |

同 walker 时 4KB 哈希跳过只能省约 3s / 25s，到不了 1.5x。票面 1.5x 来自 identity-first 之后可以不做每文件 PowerShell 走树；三次 snapshot 与 FileIdentityV2 门闩都还在。

2000 文件分解（复用 C#）：snap1 534ms / snap2 199ms / LiveStreamSet 465ms / snap3 197ms / baseline 单次 snap 345ms。
