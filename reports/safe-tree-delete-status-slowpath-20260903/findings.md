# safe-tree-delete Status 慢路径排查结论（09-02 30+ 分钟反常）

排查会话产出，2026-09-03。任务快照见 `docs/handoffs/20260902T164751Z-safe-tree-delete-status-slow-path.md`（不可变，本文不改写它）。本文是独立结论与证据，供立票与修复决策使用；未做任何代码修改。

## 结论（一句话）

根因是 #49 快扫的**原设计缺口**遇到**数据形态突变**：有效（approved）plan 一律回退 PowerShell 参考路径（`CodexSafeTreeDeleteStatusScan.cs:745`，随 #49 本体 `c0f77b0` 引入），而参考路径对 plan 的 `treeManifest.entries` + `fileIdentitiesV2` 做**逐条 PowerShell 对象验证**；09-02 hermes-retired 批量退役产生了 9 个 >10MB、合计 726MB 的巨型 plan（最大 370MB / 121 万条），逐条验证的成本随条目数超线性增长，单笔即可烧掉几十分钟，Status 全量聚合因此从 ~10s 基线劣化到小时级（观测的 30+ 分钟只是被终止前的局部）。

## 证据链（全部本机实测，可复现）

| 事实 | 数值 | 来源 |
|---|---|---|
| 证据根总量 | 4154 笔事务、1.5GB；09-02 单日 208 笔 | 文件系统普查 |
| run 构成 | 2200 已归档（terminal-archive）、~1954 带 plan+transaction | 同上 |
| >10MB 巨型 plan | 17 个共 909MB，其中 9 个 726MB 产自 09-02 | find -size +10M |
| 条目量 | 5.8MB plan=21,940 条；104MB=381,647 条；370MB=1,207,760 条 | rg -o relativePath |
| kill switch | machine/user/process 三级全未设置（假设 2 排除） | [Environment]::GetEnvironmentVariable |
| 采样回退比例 | 30 笔样本 25 笔回退（83%）：20x `plan-approved`（含全部 09-02 大 plan）、5x 旧归档记录 terminal-archive 校验失败（设计内回退，单笔仅 15-54ms） | status-sample-probe.ps1 |
| ConvertFrom-Json 速率 | 25.6 MB/s（5.8MB plan 解析 225ms）——**解析不是瓶颈** | 微基准（同参数 -Depth 128） |
| 参考路径单笔成本 | 5.8MB/2.2 万条 = **14.9s**（~1470 条/秒）；104MB/38 万条 **>35 分钟仍未完成**（终止前 CPU 1306s、工作集 3.0GB）——**每条成本随规模超线性恶化** | status-bigplan-probe.ps1 |
| 外推总量 | 仅 17 个 >10MB plan 约 330 万条，按实测降速外推需 **数小时**；观测 30 分钟与「按名字序先撞上 05:24Z 的 370MB/121 万条 monster」一致 | 同上 |
| journal/dispositions 无辜 | leaf-dispositions 全库最大 7.3MB 合计 65MB、最大 journal 目录 4.2MB | find |

关键代码位：
- `scripts/lib/CodexSafeTreeDeleteStatusScan.cs:745` —— approved plan 校验通过后**故意** `throw new StatusScanFallbackException("plan-approved")`，注释明言 approved 流程继续走 PS 参考路径（namespace/transaction/tree materialization 语义归 PS）。
- `scripts/lib/CodexSafeTreeDelete.ps1:4440` —— 参考路径 `ConvertFrom-Json -Depth 128`（快，已排除）。
- `scripts/lib/CodexSafeTreeDelete.ps1:1439-1470`（及其 Apply 侧孪生 1803+）—— `foreach ($entry in @($Plan.treeManifest.entries))` + 每条 `fileIdentitiesV2` 记录一次 `ConvertFrom-CodexSafeTreeDeleteFileIdentityV2Record` 调用 + 集合对账。这是成本熔炉。

## handoff 三假设裁决

1. 「09-02 新批次形态不满足快扫裁决→回退」——**方向对、机制错**：回退不是因为形态不合规，而是 approved plan 按设计必回退（#49 原设计，`git log -S plan-approved` 确认随 c0f77b0 引入，与 09-02 脏改动无关）。
2. kill switch —— **排除**（三级全空）。
3. 超大 journal 逐文件处理 —— **排除**（journal/dispositions 全库很小；大的是 plan.json）。

定性：对 #49 的 9.7s 性能合同构成**数据触发的回归级缺陷**（数据形态突变 × 设计内慢路径），不是 09-02 gate-failure-hardening 引入的回归（其脏改动未触碰 Status 聚合语义，`.cs` 干净未改）。

## 修复方向（选项，未实施；动 shim/生产须走 Deploy 全仪式）

- A. 快扫补齐 approved-plan 结果复刻（把 PS 参考路径对 approved plan 的终态裁决复刻进 C#，fast-vs-slow 对照回归）。CONTEXT.md 已预留此契约（「改认证链时须同步复刻或依赖回退并重跑对照」）。根治但工作量最大。
- B. 最小修：把 `treeManifest`/`fileIdentitiesV2` 的逐条验证循环下沉为 C# 单次遍历（Add-Type helper 吃 JsonElement/数组，一次调用返回对账结果），PS 只接收结论。改动面小，5.8MB 单笔 14.9s 预期降到亚秒。
- C. 语义修：对 lifecycle=terminal 且 quarantine 缺席的操作，跳过深层 manifest 重验证（C# 已算出大部分终态字段）。需先论证终态判定的安全性。
- 不作为修复的：削减/压缩历史 evidence 大 plan（证据不可变，policy 禁止）；`FAST_SCAN=0`（方向相反，更慢）。

## 复现与验证工具

`status-sample-probe.ps1`（采样回退普查+小笔参考路径计时）、`status-bigplan-probe.ps1`（单笔大 plan 参考路径计时）已随本目录归档；原始运行目录 `D:\Codex\tmp\std-diag\`（临时，可清）。修复验收建议复用 `reports/safe-tree-delete-issue49-20260823/` 协议 + 本两脚本做 fast-vs-slow 对照。

## 未完成 / pending

- 全量 ground-truth（`-Mode Status` 带 `SEGMENTS=1` 的完整跑完数据：精确 fastScanHandled/Fallback 计数与分段耗时）未取得——预计需数小时，已在取证充分后主动终止（PID 64160，CPU 586s 时）。需要精确全量数字时重跑即可，命令形态见 handoff 步骤 1。
- 立票与修复选择待用户授权；仓库另有 09-02 gate-failure-hardening 会话的 4 个脏文件未收尾，任何提交不得吸收它们。
