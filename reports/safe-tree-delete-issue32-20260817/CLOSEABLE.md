# CLOSEABLE.md — GitHub #32 Apply 哈希复用

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。

## 关口结论

`BLOCKED`

功能 AC 已在工作树：Apply 读 Plan `fileIdentitiesV2`，invocation-local `SessionHashCache`，lease 路径 identity 后再 `ComputeSha256FromHandle`，无 lease 走 `GetHashSafely`，IdentityMismatch 拒绝且不隔离，完成后 `Clear()`。数字 AC **不能**在 10k×4KB 互异文件上达到 1.5–2x：同一 invocation 虽对同一 `FileIdentityV2` 内容哈希三次，缓存已消掉后两次 SHA-256，墙钟仍由三次整树 snapshot / lease 获取主导；lease 路径每次再 `GetFileIdentityV2(path)` 开一次，复用路径比无复用更慢。

未削弱 identity 门闩，未用缓存授权删除，未跳过内容哈希假装加速，未改 Status / `#49` hunk。

## 同一 invocation 哈希次数（结构证据）

`Invoke-CodexSafeTreeDeleteQuarantine` 对同一 `$applyFileHashProvider` 做三次 `Get-CodexHookCapabilityDirectoryTreeSnapshot`：

1. unlocked preflight — `scripts/lib/CodexSafeTreeDelete.ps1:3995-4004`
2. locked preflight — `scripts/lib/CodexSafeTreeDelete.ps1:4058-4067`
3. quarantine postcheck — `scripts/lib/CodexSafeTreeDelete.ps1:4111-4120`

HostSafety 每个 file leaf 在仍持有 lease 时调用 provider（`scripts/lib/CodexHostSafety.ps1:916-927`）。provider 进入 `Invoke-CodexSafeTreeDeleteApplyFileHash`（`1217-1262`）：有 lease 时先 `Get-CodexSafeTreeDeleteFileIdentityV2` 再 cache TryGet，miss 才 `Lease.ComputeSha256FromHandle`（`1231-1242`）；无 lease 走 `GetHashSafely`（`1245-1248`）。

`tests/Test-CodexSafeTreeDeleteHashReuse.ps1:239-244` 证明同 key 第二次 hit。同文件 `376-385` 在 rename 之后、postcheck 之前对 live identity `TryGet` 必须 hit——即前两次 snapshot 已写入 cache。因此 **不是**「每个文件只哈希一次」。

`Assert-CodexSafeTreeDeleteLiveStreamSet`（`4076-4080`）只复验 stream 集 / FileIdentityV2 / hardlink，不读文件内容，不构成第四次内容哈希。

## 数字 AC 为何与 10k×4KB 互异文件冲突

| 项 | 值 |
| --- | --- |
| 旧 10k | reuse 349164ms / baseline 302992ms = **0.868x**（`summary.json`） |
| 磁盘 JSON | reuse 553787ms / baseline 515007ms = **0.93x**（`scale-10000.json`） |
| 方法 | 两棵兄弟 10k 树，每文件 4096B；`SessionHashCache` vs `-DisableApplyHashReuseForTest`（provider 为 `$null`，三次 snapshot 均从已持有 lease `ComputeSha256FromHandle`，**不是**已不存在的「7 次读盘」路径） |
| 目标 | 1.5–2x |
| 本次 | **未重跑 10k**（无合法热路径改动能改变该结构） |

`-DisableApplyHashReuseForTest` 只去掉 provider：baseline 仍走三次 snapshot，只是不经过 SessionHashCache / 额外 path identity。复用路径在 cache 已命中时仍为每次 snapshot 多一次 `GetFileIdentityV2(path)` `CreateFile`；4KB SHA-256 相对这次 open 更便宜，所以实测 <1x。

要靠缓存达到 1.5–2x，必须让内容哈希成为墙钟主体。10k×4KB 互异文件上三次 snapshot 的 lease 获取与树遍历才是主体；缓存不能跳过 snapshot，也不能跳过 FileIdentityV2 门闩。从 lease handle 读 identity 需要改 `CodexHookHandleBoundIO.cs` / HostSafety，超出本票唯一写入范围，且即使用已打开句柄做 identity，三次走树仍无法给出 1.5x。

禁止项已遵守：不削弱 identity、不把 cache 当删除授权、不跳过内容哈希、不把 SessionHashCache 引进 Status、不跨 Mode 预填。

## 逐条 AC

1. **通过。** Apply 从 Plan `fileIdentitiesV2` 建 map；`New-CodexSafeTreeDeleteApplyFileHashProvider` 接到三次 snapshot。
2. **通过。** 首次 miss，同 invocation 同 key 后续 hit（HashReuse 单测 + quarantine checkpoint）。
3. **通过。** 每个 Apply invocation 自建空 cache；`finally` `Clear()`（`4189-4190`）。测试证明完成后 cache 为空。
4. **通过。** 未跨进程 / 跨 Mode 预填。
5. **通过。** IdentityMismatch 拒绝；Apply 中途改文件不隔离目标。
6. **通过。** 预确认 seam：首次 miss、同 invocation hit、IdentityMismatch、缓存不授权删除。无新 seam。
7. **通过（历史）。** 1000 文件 Apply 成功；`scale-1000.json` `quarantined=true`。本次 HashReuse `-SkipScale` 只回归功能切片。
8. **失败（结构）。** 10k×4KB 要 1.5–2x；现测 0.868x / 0.93x。见上一节。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树。本关口 **未改** `CodexSafeTreeDelete.ps1` Apply 热路径、未改 Status、未改测试 seam。只写本目录证据。

### Standards

- 无生产 diff。`git diff --check` 仅对本票写入的报告文件。
- 判断：未为刷数字把 identity 核对改成 lease 64-bit `FileIndex`，也未在 cache hit 时跳过 `GetFileIdentityV2`。
- 判断：未回退 `#49` Status 预加载 / `#48` 切片。

### Spec

- 票面功能（GetHashSafely / invocation-local cache / 拒绝路径 / 会话清理）已在工作树。
- 票面数字 1.5–2x 与「10k 互异 4KB + 必须保留三次 snapshot 与 FileIdentityV2 门闩」结构冲突。
- 没有用旧 7 次读盘当无复用基线。

**Standards 0 硬违反；Spec 数字 AC 不可达，关口 BLOCKED。**

## 未解决问题

- 数字 AC 在当前 Apply 形状下不可达。要改目标（更大文件、接受 <1.5x）或另开票改 snapshot/lease 合同（超出 #32 写入范围）。
- `bytesHashed` 在 HostSafety snapshot 上按文件长度记账，cache hit 时不能当物理读字节（`CodexHostSafety.ps1:935`）。
- 未重跑 10k。未 commit / comment / close #32。未 Purge leftover，未 Archive #48。
