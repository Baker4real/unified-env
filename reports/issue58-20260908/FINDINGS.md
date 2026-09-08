# issue #58 N1 调查：全量 Status 冷启动分段计时基线（2026-09-08）

HEAD = `518a5c3a0c6d6671f542eed79989b6d2661aaab9`（= origin/main，工作树干净）。测量日 2026-09-08，本机 D 盘，pwsh 7.6.5。所有测量只读；零写入证明见末节。

## 1. 全量冷启动复测（完成标准 1）

- 命令：`pwsh -NoLogo -NoProfile -File scripts/Invoke-CodexSafeTreeDelete.ps1 -Mode Status -Json`，环境变量 `CODEX_SAFE_TREE_DELETE_STATUS_SEGMENTS=1`，deadline 2h（harness：`cold-run.ps1`）。
- **实际耗时 5,073,603 ms ≈ 84.6 分钟**，exit 0，stdout 5,419,997 bytes，4467 个 operation，`complete=false`。
- 与历史对照：09-06 首轮在 60,000ms deadline 被 kill（60,555ms，无输出），当时无法知道真实全程；本次证明真实全程 ≈ deadline 的 **84.6 倍**。evidence root 较 09-06 已增长（4399 → 4467 run，25,325 → 25,863 entry）。
- 原始数据：`cold-run-result.json`（含 statusSegments/metrics）、`cold-run-stdout.json`（完整 Status 输出）。

## 2. 分段计时表（完成标准 2）

总墙钟 5,073,603 ms 的划分（statusSegments 是运行内嵌计数器；注意 planTransactionRead/terminalArchiveAuth/sha256 三个计数器由 fast scan 与 fallback resolver 共同累加，与 fastScanMs/activeResolveMs **嵌套不可相加**）：

| 阶段 | 耗时 ms | 占总时 | 测量方法 |
|---|---:|---:|---|
| pwsh 启动 + dot-source 两个 lib + native/Add-Type 缓存加载 + 最终 `ConvertTo-Json -Depth 12` + 退出 | 1,338 | 0.03% | 墙钟 − metrics.elapsedMs；其中序列化实测 229ms（`serialize-bench.json`，5.4MB/4467 ops 解析 250ms + 重序列化 229ms），lib 加载 713ms（recon 实测） |
| policy 读取（Read-CodexSafeTreeDeletePolicy） | ~190 | 0.004% | recon 实测（运行内未单独分段） |
| evidence 目录枚举（Get-ChildItem + Sort） | 55 | 0.001% | statusSegments.directoryEnumerationMs |
| **C# fast scan**（StatusScanCoordinator.Scan，DOP=4；handled 4345 / fallback 122） | 10,406 | 0.21% | statusSegments.fastScanMs。嵌套计数：planTransactionRead 1,294 + terminalArchiveAuth 3 + sha256 459；残差 ~8.6s 为 ~1.5GB evidence JSON 的严格校验/JsonDocument 解析（含 09-02 巨型归档 plan）。recon 冷盘时同项 22,015ms |
| **逐 operation 解析循环** | ≈5,061,600 | 99.76% | metrics.elapsedMs − 上述各项 |
| ├─ fallback 参考路径 resolve（122 ops；activeResolveMs） | 5,059,196 | 99.72% | statusSegments.activeResolveMs |
| │ ├─ **live tree snapshot（treeMaterializationMs，28 棵去重树 / 142,052 entries）** | **4,889,301** | **96.37%** | statusSegments.treeMaterializationMs → `Get-CodexSafeTreeDeleteStatusCachedTreeSnapshot`（`CodexSafeTreeDelete.ps1:3196-3264`）→ `Get-CodexHookCapabilityDirectoryTreeSnapshot`（`CodexHostSafety.ps1:789-955`）。34.4 ms/entry |
| │ └─ resolver 其余（plan ConvertFrom-Json、plan/live manifest JSON+SHA、transaction/journal/namespace 等） | 169,895 | 3.35% | activeResolveMs − treeMaterializationMs；细分见 §4 |
| └─ 4345 个 fast-handled 结果转换 + 循环簿记 | ≈2,400 | 0.05% | 差值推导（~0.5ms/op） |

fast/slow 分布：fastScanHandled=4345（terminal 688、rebuildable-terminal-identity-pending 340、manual-review 3294、inconsistent 23）；fallback=122（117 `plan-approved` + 5 `missing-plan`）；approvedPlanValidationReuseCount=117（receipt 全部复用）；archivedResolveMs=0（归档 ops 全部走 C# terminal fast path，修正版 B 生效）。

### 谁实际支付了 tree 验证（与 09-07 结论的偏差）

recon（`recon-scan.json`）+ 冷跑 stdout 交叉对账：当前有 live tree 的活跃 op 共 49 个（242,763 entries），但：

- **只有 32 个 planned-target op 实际执行了 tree 验证**（142,052 entries；两棵 68,770/68,506-entry 大树占 96.6%）。其中 20 个验证通过后因 plan policySha 漂移降级 manual-review（`CodexSafeTreeDelete.ps1:4102-4107`），12 个验证时发现 manifest 漂移（`:3804`）。
- **15 个 purging + 2 个 quarantined op（100,711 entries，含 81,854-entry 最大树）在 plan 审批阶段即被拒**（`safe-delete policy 自计划生成后已漂移`，`CodexSafeTreeDelete.ps1:4557-4559` 的 policyPath 不等；旧 plan 记录的 policy 路径与当前仓库路径不同），**未支付 tree 验证**。当前冷跑里 purging 深验证路径（含 `Assert-CodexSafeTreeDeletePartialPurgeManifest` 的逐 entry PS 循环）实际执行次数为 0。
- statusTreeCacheEntries=28 < 32 个验证 op：5 个 506-entry op 共享同一 targetPath，4 次 cache 命中（`:3223-3242` 只重验 root identity），数字自洽。

09-07 结论需据此修正：当前瓶颈不是「32 planned + 28 purging 约 42.9 万 entries 的 SHA-256 与 identity 验证」，而是 **32 个 planned op、14.2 万 entries 的逐 entry 路径安全验证**；SHA-256 内容哈希实测可忽略（见 §3）；purging 路径成本当前为零（但若 policyPath 漂移被修复，10.07 万 entries 会重新进入验证集）。

## 3. 主导热点：文件:行号与证据（完成标准 3）

**热点 = `scripts/lib/CodexHostSafety.ps1:884-887`** —— `Add-CodexHookCapabilityDirectoryTreeSnapshotNode` 递归内**对每个 child 调用 `Assert-CodexHookCapabilityPath`**（被调函数 `:452-479`）。

证据：`snapshot-sections.ps1` 把生产递归（`CodexHostSafety.ps1:827-941`）逐段复制插桩（库调用完全一致，只加秒表），在两棵生产实际验证的树（1,126/534 entries）上实测：

| 段（源代码行） | 树1（1,127 entries, avgDepth 6.35） | 树2（535 entries, avgDepth 4.45） |
|---|---:|---:|
| **assertChildPath（`:884-887` → `:452-479`）** | **15,411ms / 74.2%** | **5,794ms / 81.4%** |
| enumChildren（`Get-ChildItem -Force \| Sort-Object Name`，`:845`） | 1,090 / 5.3% | 32 / 0.4% |
| dirGetItem（`:834`）/ childGetItem（`:849`） | 521 / 2.5% + 503 / 2.4% | 13 + 13 / 0.4% |
| dirGuardAcquire（`:889-892`）/ fileGuardAcquire（`:904-907`） | 185 / 0.9% + 105 / 0.5% | 7 + 116 / 1.7% |
| leaseAcquire + **ComputeSha256FromHandle**（`:910-927`） | 2 + 28 / 0.1% | 1 + **117 / 1.6%** |
| pscustomobject 登记（`:838-843`/`:929-934`）+ observer | ~3 / 0.0% | ~2 / 0.0% |
| 残差（PS 函数调用/递归开销） | 2,913 / 14.0% | 1,022 / 14.4% |
| 合计 | 20,761ms（18.4ms/entry） | 7,117ms（13.3ms/entry） |

单次 `Assert-CodexHookCapabilityPath` ≈ 10.8-13.7ms，内部构成（`:460-477`）：`Assert-CodexHookDPath`×2（`:96-126`，每次调用都对 path 与 capabilityRoot 重做 GetFullPath + 正则 + 逐 segment 拆分校验，root 每 entry 重复验证）、`Test-CodexHookPathWithin`（`:128-140`）、`Assert-CodexHookNoReparseAncestor`（`:429-450`，**对每个祖先段各做一次 `Test-Path` + `Get-Item`**）。成本随树深度线性增长（avgDepth 4.45→10.8ms、6.35→13.7ms/entry），总体是 **O(entries × depth)** 的 cmdlet 调用与 syscall。两棵 68K 大树在真实冷跑中摊到 34.4ms/entry（树更深，推断 assertChildPath 占 ~75-80% ≈ 3.7-3.9k s；此比例为小树实测占比的外推，未在 68K 规模直接测量——预算约束，标注为估计）。

**SHA-256 内容哈希不是瓶颈**：实测 ComputeSha256FromHandle 吞吐 ~1.4-1.6GB/s，全部 live tree 5.66GB ≈ 3.5-4s（占 treeMaterialization 的 <0.1%）。identity 获取（lease/guard）同样占比 <2%。

## 4. 次级成本（resolver 余项 169.9s 的细分证据）

`plan-manifest-cpu.ps1` 对两棵大树（plan.json 60.3MB/57.7MB，manifest 68,771/68,507 entries）实测：

| 阶段 | op1 | op2 | 生产是否支付 |
|---|---:|---:|---|
| plan 读取+SHA（Read-CodexHookSafeUtf8FileSnapshot） | 139ms | 211ms | 否（receipt 复用 scan 快照） |
| Assert-CodexHookStrictJsonText | 27,894ms | 29,860ms | **否**（receipt 复用时跳过，`:4518`）；无 receipt 的参考路径才支付 |
| **plan ConvertFrom-Json（`:4524`）** | 1,968ms | 2,421ms | **是**（receipt 复用仍全量解析 plan 文本） |
| ConvertTo-CodexHookExpectedDirectoryTreeManifest（plan manifest，`CodexHostSafety.ps1:957-1033`） | 24,881ms | 26,234ms | **否**（receipt 时跳过，`:4570-4574`）；Apply/无 receipt 路径支付 |
| plan manifest ConvertTo-Json+SHA（`Get-CodexSafeTreeDeleteManifestSha256`，`:4421-4424`） | 1,655ms | 1,261ms | 是（每唯一 plan 一次，`:3172-3181` 缓存） |
| 同型序列化重测（≈ live manifest JSON+SHA，`:3185-3194`） | 3,270ms | 1,241ms | 是（每个验证 op 一次） |

即两个大 op 的 resolver 余项 ≈ 各 5-7s（parse+两次 manifest 序列化），其余 ~110 个 fallback op 分摊剩余 ~155s（平均 ~1.3s/op 的 PS 函数调用开销，无单一热点）。**169.9s 余项是下沉 tree snapshot 之后的下一个天花板**，但它由大量小额调用构成，治理方式应与主热点不同（并行化或批量下沉）。

## 5. 下沉/并行化建议与收益依据

1. **主下沉点：把 tree snapshot 递归整体下沉 C#**（建议落在 `CodexSafeTreeDeleteStatusScan.cs` 同文件的自包含 BCL+P/Invoke 模式，复用其 handle/identity/SHA 基建；调用点 `CodexSafeTreeDelete.ps1:3244-3252`，PS 参考路径保留给非规范输入回退）。语义保持不变的关键：entry schema（relativePath/kind/sha256/identity）、抛错条件、root 的 VerifiedDirectoryChainGuard.Acquire、reparse/junction 政策逐一同构。
   - 收益依据：消除 per-entry `Assert-CodexHookCapabilityPath`（实测占比 74-81%；C# 枚举时每个目录 entry 只查一次 reparse 属性即可等效 NoReparseAncestor——兄弟节点共享祖先，O(entries) 替代 O(entries×depth)）+ 消除 per-child Get-Item/Sort 的 PS 开销 + PS 函数调用残差。recon 实测纯 .NET 枚举（PS 循环 + 2 syscall/entry）242,763 entries 仅 31.4s（129µs/entry）；紧凑 C# 枚举器典型 10-30µs/entry → 142K entries ≈ **1.5-4.5s** + 3.1GB 哈希 ≈ 2-3.5s。**treeMaterialization 4,889s → 预计 5-8s（−99.8%）**；即使保守按 129µs/entry 也仅 ~18s。
2. **次下沉点（达成 <60s 必需，否则余项 170s 成为瓶颈）**：manifest 规范化+哈希下沉（`Get-CodexSafeTreeDeleteManifestSha256`/`ConvertTo-CodexHookExpectedDirectoryTreeManifest`，68K-entry manifest 实测 1.2-1.7s / 25s → C# 亚秒级），以及在 receipt 上直接携带 C# 侧从 plan 文本算出的 manifest SHA（Utf8JsonReader 流式），可省掉大 plan 的 `ConvertFrom-Json`（2-2.4s/个）与 plan manifest 序列化。预计余项 169.9s → ~130-140s。
3. **fallback 循环并行化**：122 个 fallback op 的 resolve 相互独立（各自读 evidence/run 与 live tree；注意 statusTreeCache/planManifestShaCache 需并发安全或按 op 分区）。余项 ~140s 在 DOP≈4 下 → ~35-40s。
4. **fast scan 可选优化**：归档路径每次全量重读+重哈希+全量 tokenize 09-02 巨型 plan（726MB），冷盘 22s。ReadWanted 改流式提前退出（集齐目标顶层字段即停，非规范顺序回退全量）+ 读哈希流水化，预计 → 5-8s。非必需。
5. 组合预测：1.3s（进出）+ 10-22s（scan）+ 5-8s（tree C#）+ ~35-40s（余项并行化后）≈ **52-70s**；再叠加 2、4 可稳定落入 <60s。只下沉主热点而不处理余项，**不能**达成三次 <60s 合同（余项 170s 超预算）——这是与单点优化直觉相反的关键结论。

## 6. 零写入证明（完成标准 4）

方法沿用 `reports/issue58-20260906/`：测量窗口前后对 evidence root 做全量 manifest 指纹（`Get-CodexHookCapabilityDirectoryTreeSnapshot` + manifest SHA-256，脚本 `evidence-fingerprint.ps1`），policy.json 单独指纹。

- before（2026-09-08T03:06:24Z，耗时 256,540ms）：entryCount=25,863、operationCount=4,467、manifestSha256=`8f25b06fdf35e7b5cee423dd0a115b20930af92429af3a8ab6ebed81ed81effa`、rootIdentity=[`5d26df61`,`001900000009a9f2`]（见 `evidence-fingerprint-before.json`）
- after（2026-09-08T04:51:55Z，耗时 225,232ms）：**逐字段全等**（同 entryCount/operationCount/manifestSha256/rootIdentity；`evidence-fingerprint-after.json`）
- policy 前后全等：sha256=`6acba1e816fd75572f25d26ee5a353a6583b1cc48969e566eec7191fe75c7fcc`，length/identity/sddl 不变
- 窗口覆盖：冷跑（03:07:31Z-04:32:07Z）与被停止的 substage 探针（04:33-04:48Z，只读）。recon（~02:55Z）早于 before 指纹，但其仅使用枚举/读取 API；其后三个小探针（sections/plan-cpu/serialize）在 after 指纹之后运行，只读 evidence 文件与 evidence root 之外的 live tree，不写任何受观测对象。

## 7. 风险与未知项

- 未跑逐 op 全量 profile（`perop-profile.ps1` 已备未执行）与大树级 substage（`substage-profile.ps1` 启动后被预算决策停止，未产出）：逐 op 耗时分布为「32 个验证 op × 各自 entry 数 × 统一 entry 均价」的有界估计；两个 68K op 占验证 entry 的 96.6%，但严格 per-op 数值未知。
- sections 解剖在 1,126/534-entry 树上实测；68K 树的 assertChildPath 占比（75-80%）为深度外推，未在 68K 规模直接测量。
- purging/quarantined 深验证路径（含 `Assert-CodexSafeTreeDeletePartialPurgeManifest`，`CodexSafeTreeDelete.ps1:4427-4459` + `CodexHostSafety.ps1:957-1033` 逐 entry 循环）当前生产零执行，其成本未实测；参考类成本：68K-entry manifest 单次结构转换 ~25s。若 17 个 policyPath 漂移 op 的漂移被修复，验证集将增加 100,711 entries（含 81,854-entry 树），按现价 ~35ms/entry 外推新增 ~59 分钟 + purging 专属的逐 entry 断言开销。
- fast scan 的 22s（recon）与 10.4s（冷跑）差异为磁盘缓存温度；三次冷启动验收的首轮应按 ~22s 预算。
- 09-07 结论中的「42.9 万 entries / 28 purging」与本次实测（49 树 242,763 entries，其中 17 op/100,711 entries 未支付）不一致；以本次 recon+冷跑交叉对账为准（可能期间有 purging 完成或退役改变了数据集）。
- 冷跑期间机器无其他重负载（串行执行全部测量）；单次测量未取多次中位数（预算）。84.6min 为单点值，量级结论（>60s 合同 84 倍）不受抖动影响。

## 8. 证据文件清单（reports/issue58-20260908/）

- `cold-run.ps1` / `cold-run-result.json` / `cold-run-stdout.json` — 全量冷启动 harness 与结果
- `recon-scan.ps1` / `recon-scan.json` — fast scan 普查 + 49 棵 live tree 规模
- `evidence-fingerprint.ps1` / `evidence-fingerprint-before.json` / `evidence-fingerprint-after.json` — 零写入对照
- `snapshot-sections.ps1` / `snapshot-sections.json` — 热点递归逐段解剖（插桩复制品）
- `plan-manifest-cpu.ps1` / `plan-manifest-cpu.json` — 大 plan 的解析/manifest 转换/序列化成本
- `serialize-bench.ps1` / `serialize-bench.json` — 入口序列化微基准
- `substage-profile.ps1`（已停止未产出）、`perop-profile.ps1`（未执行）— 被预算决策收缩的探针，留档备复用
