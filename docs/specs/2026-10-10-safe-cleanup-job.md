---
type: reference
title: 批量安全清理任务合同
tags: [safe-delete, recovery, status]
intent: 定义批量清理的进程身份、原子账本、策略证据和目录身份验收
---

# 批量安全清理任务

入口：`scripts/Invoke-SafeCleanupJob.ps1 -Mode Status -JobPath <job.json>`。
实现：`scripts/lib/SafeCleanupJob.ps1`。生产删除仍委托既有受管 gate，未扩大 policy。

## 描述文件

必填：`scopePath`、`scopeSha256`、`ledgerPath`、`statePath`、`intentRoot`、`policyPath`、`policySnapshotPath`、`policySnapshotSha256`、`transactionEvidenceRoot`。
历史状态缺少 executable 时须提供 `launchPath`。额外历史策略快照使用 `policySnapshots: [{path, sha256}]`。
所有路径使用真实绝对路径。描述文件、immutable scope 与策略快照是操作者审核的信任根，不从任意旧日志推导授权。
旧任务可加 `readOnly: true`：禁止 Run、Worker、Reconcile，只允许状态、策略比较与验收。

scope 定义唯一目标和 baseline；ledger 的目标集合与每项 baseline 必须一致。
执行 baseline 必须含 `rootIdentity`（volume serial、file index）与 `treeManifestSha256`；旧 scope 缺少身份时仅可作历史回执复核，不允许补身份后继续删除。

## 状态与生命周期

Status 读取任务账本与当前进程观察，核对 PID、进程启动时间、可执行路径及 owner token。已失效 running 返回 interrupted；taskFailure 与 failedCount 分开。
`lastProgressUtc` 表示最近账本进度，不代表进程正在工作。无法取得进程观察时保持保守失败结果。
Run 要求 `-ConfirmRun`，只接受生产 policy 与 evidence 路径，启动独立 Worker 并观察退出码。
同一规范化 JobPath 受 mutex 保护；拒绝的启动不能覆盖已有 Worker 状态。父进程只回写自己子进程的 PID、启动时间与 owner token 对应状态。
Worker 只有在队列无未决项且回执、目录身份验收通过后才写 completed。父进程终止不自动杀子进程；Status 直接观察 Worker。

## 删除和恢复

首次 Plan 核对 immutable baseline；Apply 前发布 intent，绑定 scope SHA、目标、原身份、Plan SHA、调用前 policy SHA 与实际 Plan policy SHA。
恢复已有 intent 必须重新验证 approved Plan、原身份与 tree hash，不能仅凭路径重试。
Plan -> Apply -> Purge 全部经过受管 gate。Reconcile 仅从同 run 的 terminal purged transaction 与完整 journal 补记；绑定 Plan SHA、身份、目标和 scope。
账本通过 capability 原子 compare-and-replace 写入；mutex 保护本工具的更新，重复 Reconcile 为零补记。
任务描述、账本与 evidence 的范围外直接写入不受本工具 mutex 协调；发现 SHA 或 baseline 不一致即失败。

## 策略与验收

独立策略比较要求所有原条目及 global 字段不变，只允许与本 capability 不相交的新增条目。属性顺序不影响比较。
Plan 前兼容新增可接受；已有 Plan/transaction 跨 Apply/Purge 的 policy SHA 漂移由 gate fail-closed，须人工复核，工具不自动改写旧 Plan 或豁免生产 SHA 校验。
历史回执的 policy SHA 必须对应当前策略或经 SHA 绑定且独立比较通过的历史快照。
Verify 绑定已有 ledger transactionSha256（若记录），验证 terminal receipt，再比较当前目录身份。不存在或新一代目录可以验收；原目录仍在、身份未知或证据不全则失败，新目录保留。
历史 ledger 缺少 transactionSha256 时采用历史证据模式：验证现有 Plan/transaction/journal 与已绑定 scope，不能证明自旧任务以来从未改写。旧 scope 缺身份时原身份来自已认证 Plan，并在结果标注历史来源。
输出只能写任务目录内非输入、非 intent、非 transaction evidence 路径。logical bytes 不等于物理释放，`physicalReclaimStatus=unknown`。

## 测试与测量

`tests/Test-SafeCleanupJob.ps1` 覆盖进程失效/PID复用、策略比较、baseline/intent漂移、真实子进程强制终止、原子发布中断、幂等恢复与同路径重建保留。
`tests/Test-CodexSafeTreeDeleteHistoryBenchmark.ps1` 验证历史规模测量输出，fixture 使用小规模，绝对时延只记录。
两套测试登记 host-safety fixture 与 fixture-base（现有 CI 使用 fixture）。
性能入口：`scripts/Measure-CodexSafeTreeDeleteHistory.ps1`，分别记录冷启动、finder hit/miss、Plan/Apply/Purge；合成 terminal 回执副本只代表 finder skip 历史压力，不等价于完整真实历史认证。
