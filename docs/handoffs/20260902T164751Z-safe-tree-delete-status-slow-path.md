---
type: report
title: safe-tree-delete Status 慢路径排查交接快照
tags: [safe-delete, performance, handoff]
intent: 保留 2026-09-03 的排查输入与证据；当前修复状态以性能 spec 和 GitHub issue 58 为准
---

# Handoff: safe-tree-delete Status 慢路径排查（09-02 30 分钟反常）

不可变时间点快照，创建于 2026-09-03（UTC 2026-09-02T16:47Z）。给接手的会话：目标是查清
`-Mode Status` 为什么在 09-02 的证据体量下从 ~10s 基线劣化到 30+ 分钟，并按项目规则修复或
出具回归结论。

## 用户目标与约束

- 排查 safe-tree-delete `Status` 只读模式 09-02 观察到的 ~180x 性能反常（基线见下），定位根因；
  是否修复由排查结论和用户授权决定。
- 仓库当前有**另一会话未提交的 4 个脏文件**（`docs/environments/jia-li.md`、
  `managed/safe-tree-delete/policy.json`、`scripts/Invoke-CodexSafeTreeDelete.ps1`、
  `scripts/invoke-codex-safe-tree-delete-gate-shim.ps1`，为 09-02 深夜 gate-failure-hardening
  部署方留下）：不得吸收进本次任何提交，需与其会话协调收尾。
- 改 shim/入口/生产脚本须走 `Deploy-CodexSafeTreeDelete.ps1` 全仪式（BootstrapGate→deploy，
  期间闭包内文件含 policy.json 不能动）；调用删除入口绝不绕过受管控制面。

## 已确认事实

### evidence（09-02 实测现象）

- 2026-09-02 本地 21:53–22:28（UTC 13:53–14:28）：从 Git Bash 按新契约直调
  `pwsh -NoProfile -File D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1 -Mode Status -Json`，
  运行 30+ 分钟无输出（重定向文件 0 字节），pwsh 进程 CPU 累计 1025+ 秒（活跃计算非阻塞等待），
  被主动终止。Status 为合同测试过的零写入模式，终止无副作用；该次未取得最终 JSON。
- 背景体量：09-02 当天 hermes-retired 批量退役在 `D:\agents\run-evidence\safe-tree-delete\`
  产生约 90 笔新事务（仅 09:20Z–13:45Z 窗口即 44+ 笔，每笔含 `plan.json`、`transaction.json`、
  `parallel-purge-journal-<id>\`、部分含 `leaf-dispositions.json`），总量较此前膨胀约一个量级；
  深夜另有 gate-failure-hardening 部署事务。

### project（基线与实现指针）

- 基线（`modules/host-safety/CONTEXT.md` 记录）：#49 Status 冷启动 2026-08-23 达标，正式三联
  9.762 / 9.791 / 9.237 秒（同日基线 199.357 秒）；协议与证据在
  `reports/safe-tree-delete-issue49-20260823/`。
- 实现：C# 并行 fast scan（`scripts/lib/CodexSafeTreeDeleteStatusScan.cs`，DOP=4，kill switch
  环境变量 `CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0` 强制回退）；CONTEXT.md 明言
  「只裁决 producer 规范形态输入，其余一律回退 `Resolve-CodexSafeTreeDeleteStatusOperation`」。
- 入口契约（2026-09-03 起，已同步 runbook/spec/项目 AGENTS.md，commit `4af6afc`）：canonical =
  gate shim `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1` 经固定 pwsh 直调；`.cmd` 为
  cmd 语境兼容启动器。门禁失败输出 ASCII 结构化 JSON + exit 1（09-02 hardening 契约）。

### 假设（未验证，按优先级）

1. 09-02 新批次 journal/transaction 的形态不满足 fast scan 的「producer 规范形态」裁决 →
   整体或大比例回退 `Resolve-CodexSafeTreeDeleteStatusOperation` 慢路径（10s→30min 需~180x，
   线性体量放大不足以解释，回退+单笔大 journal 更合理）。
2. kill switch `CODEX_SAFE_TREE_DELETE_STATUS_FAST_SCAN=0` 在机器或会话环境被设置（查
   machine/user/process 三级环境变量）。
3. 个别超大 `parallel-purge-journal-*` 或 `leaf-dispositions.json`（hermes 批次单树数万文件）
   在 Status 聚合路径上被逐文件处理。

## 下一步建议（接手会话）

1. 复现计时：用新契约调用形重跑 `-Mode Status -Json`（注意 deployment mutex：一次 BatchPurge
   全程持锁可达数小时，先看证据目录事务流是否静止、有无并发删除批次）。
2. 核 kill switch 三级环境变量；若未设置，在 fast scan 裁决处加临时探针或用 fixture 复刻
   09-02 形态的 journal，验证是否回退慢路径。
3. 用 `reports/safe-tree-delete-issue49-20260823/` 的协议做对照计时，定位回退比例。
4. 结论落 spec/CONTEXT（若判定为回归缺陷，按项目 issue 流程立票；修复动 shim/生产须走
   Deploy 全仪式）。

## 已完成提交与验证（背景，非本次范围）

- `4af6afc`（main，已推 Baker4real/unified-env）：safe-tree-delete 入口契约文档三处
  （项目 AGENTS.md、host-safety CONTEXT.md、capability spec）。仅文档，不涉 Status 代码。

## suggested skills

- `diagnosing-bugs`（根因排查主线）
- `neat-freak`（结论落文档与收尾）
- 不建议 `private-patch-stack`：远端为用户拥有（Baker4real/unified-env，main），无私有
  default branch 发布需求。
