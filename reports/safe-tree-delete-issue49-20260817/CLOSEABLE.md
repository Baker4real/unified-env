# Issue #49 实现关口

**判定：`DONE_WITH_CONCERNS`。`metTarget=false`。** 未 commit、未 push、未 `gh issue comment|close|edit`。未 Purge leftover，未 Archive 42 条 #48。

协议：`protocol.md`。三次冷启动：`cold-1.json` / `cold-2.json` / `cold-3.json`，汇总 `cold-summary.json`。

## 关口

| 项 | 结果 |
| --- | --- |
| 冷/热协议已写且可证伪 | 是。`protocol.md`。冷 = 新 pwsh 7.6.4 + live `.cmd` + 上一 child 已退出 + 无 Status 磁盘缓存。OS standby **未**刷。本三联前同会话已跑过 Status，三次都偏 OS-warm。 |
| 三次独立冷启动墙钟 <60s | **否。** 142.286 / 141.992 / 145.850 s |
| 每次可复核 operations / entries / bytesHashed / elapsedMs / 墙钟 / identity | 是。见下表与各 `cold-N.json` |
| terminal-archive 内容认证 + 现场 namespace | 是。不靠 marker 存在。夹具：篡改 marker、plan 字节漂移、quarantine 再现 → `manual-review` |
| `complete` / blocking / 未终结语义 | 是。`complete=false`，leftover `purge-resumable` 不在 blocking，#48 purged+MR 仍为 42 |
| 未放宽 allowlist / 最小深度 / quarantined-to-terminal；纯 Status 零写入 | 是。未改 `policy.json`。三次 evidence 计数不变；leftover SHA 三次均为 `4e73aedc…339d7` |
| 与 #26–#43 边界 | 是。未消费 `SessionHashCache`。`consumptionBoundary=status-invocation-local-not-session-hash-cache` |
| 不用 VSS | 是 |

## 三次冷启动

入口：`D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd -Mode Status -Json`。pwsh 7.6.4。wrapper SHA `45aeadf7f758a1cafce106f66e7eaecc5f60176d2017630e2af461a2a37bca12`。

| 次 | 墙钟 s | elapsedMs | operations | entriesScanned | bytesHashed | exit | childPid | leftover | #48 MR | zeroWrite |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- | ---: |
| 1 | 142.286 | 139627 | 2482 | 3952 | 912539936 | 0 | 52808 | purge-resumable / 不 blocking | 42 | true |
| 2 | 141.992 | 139162 | 2482 | 3952 | 912539936 | 0 | 6120 | 同上 | 42 | true |
| 3 | 145.850 | 142979 | 2482 | 3952 | 912539936 | 0 | 57332 | 同上 | 42 | true |

对照本票优化前（2026-08-17）：墙钟 189.179 / 184.361 / 181.586s，operations 2383，未归档约 185。现场现在 operations 2482、未归档 prefetch 281。

## 成本段（cold-1）

| 段 | ms | 还在吗 | 说明 |
| --- | ---: | --- | --- |
| directoryEnumeration | 50 | 还在 | 不是主因 |
| prefetch（未归档句柄读） | 3316 | 新增 | 281 条 plan 句柄绑定读；SHA 计入 metrics |
| planTransactionRead | 445 | 还在 | 归档 plan/tx 句柄读（warm） |
| terminalArchiveAuth | 14 | 还在，未跳过 | marker SHA + 绑定；plan 顶层字段不再 DOM 化整棵 treeManifest |
| archivedResolve | 48678 | 还在 | 约 2201 条归档 Resolve（capability + namespace + 认证） |
| treeMaterialization | 33737 | 还在 | 10 棵独特 live 树；调用内 StatusTreeCache |
| sha256 | 47 | 还在 | 认证仍重算字节 |
| activeResolve | 85856 | 还在 | 281 条未归档：一次 `ConvertFrom-Json` + capability + ApprovedPlan 结构核验（含 live 树 33s） |

`bytesHashed` 0.76GB → 0.91GB（现场树/记录变多，不是跳过哈希）。

## 做了什么

1. Status 把已读 snapshot 与已加载 policy 传入 `Read-CodexSafeTreeDeleteApprovedPlan`（`PreloadedSnapshot` / `PreparsedDocument` / `LoadedPolicy`）。第二次读盘、第二次哈希、第二次 `ConvertFrom-Json`、第二次读 policy 被跳过。SHA 与 capability 仍发生：`ApprovedPlan` 校验 snapshot.sha256 对 `ApprovedPlanSha256`，并走 `Assert-CodexHookCapabilityPath` 与 `Resolve-CodexSafeTreeDeleteTarget`。
2. 未归档 plan 句柄绑定**串行**预读。`ConvertFrom-Json` 留在同一 runspace 的 Resolve 里做一次。`ForEach-Object -Parallel` 把 PSCustomObject 留在子 runspace，后续访问与整表预解析会把墙钟打到 230s+，故未采用。
3. 按 plan SHA 缓存 `treeManifest` 的 canonical SHA；live 树仍比对，调用内按 snapshot 记住 live SHA。
4. 归档 `Get-CodexSafeTreeDeleteStatusJsonBindings` 改为 `Utf8JsonReader` 只取顶层字段并对 `treeManifest` `Skip()`，避免 `JsonDocument` 为归档 plan 建整棵 DOM。文件 SHA 与 marker 绑定不变。

## 为什么不能再砍到 <60s

- 未归档 281 条仍必须 `ConvertFrom-Json` 整棵 `treeManifest` 并走 `ConvertTo-CodexHookExpectedDirectoryTreeManifest`（`CodexSafeTreeDelete.ps1` 3936-3939）。warm 下 activeResolve 仍约 86s（含树 33s）。
- 归档约 2201 条仍要 marker/plan/tx SHA、identity、现场 namespace。warm 下 archivedResolve 仍约 48s。不能靠跳过认证换时间。
- 现场比 8-17 基线多 99 条 operations、多 96 条未归档。
- Apply/Purge `SessionHashCache` 不能拿来冒充 Status 已优化。

## 行为与测试

`tests/Test-CodexSafeTreeDeleteStatus.ps1` slices=22，exit 0。未加新测试 seam。现有夹具继续钉：篡改 marker / plan 字节 / quarantine 再现 → `manual-review`；共享 live 树只哈希一次。

## `git diff --check`

对本票文件执行，exit 0（仅有 CRLF 将被 git 规范化的警告，无 whitespace error）。

## 两轴审查（相对本票 hunk，不是整棵脏工作树）

### Standards

- Status 冷路径辅助函数留在 `CodexSafeTreeDelete.ps1`，未新建跨模块入口，未改 `policy.json` / live wrapper / Apply/Purge / `ParallelPurgeCoordinator`。
- `metrics` 属性集未扩大。分段在可选顶层 `statusSegments`，仅 `CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS=1`。
- 判断：`Get-CodexSafeTreeDeleteStatus` 继续变胖（Divergent Change）。为守住 #26 边界，没有把 Status 拆文件。
- 判断：`jsonParseThrottleLimit=4` 已计算但未用于并行解析（并行会回归）。属未完成切片，不是 SessionHashCache 泄漏。
- 判断：归档 JSON 抽取不再递归检查 `treeManifest` 内重复键；完整字节 SHA 仍与 marker 绑定。夹具篡改 plan 字节仍 `manual-review`。

### Spec

- AC「三次 <60s」未满足。认证、判定语义、零写入、ownership、禁 VSS、不改 #48 观测合同满足。
- 未把 60s 写进能力 spec 当已上线。
- 切片 2「并行 ConvertFrom-Json」未落地为生产行为：同进程串行一次解析。

## 未验证

- 未再跑 ProductionSmoke / #55。
- 未刷 OS standby；本三联偏 warm。更接近磁盘的同实现样本（重复 StrictJson 未删时）曾到 258s，不影响 `metTarget=false`。
