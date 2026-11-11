---
type: reference
title: 组件退役只读验收合同
tags: [skill, retirement, verification]
intent: 定义退役成功条件、明确扫描范围和未知状态的失败闭锁
---

# 组件退役只读验收

入口为 `python scripts/verify-component-retirement.py --spec <范围.json> --output <D盘新结果.json>`；默认仅查询，不写 active、ledger、Magpie、policy、任务、注册表或回收站。output 只接受 D 盘普通路径、create-only。测试 seam 是 `verify(spec, probe)`；production CLI 始终调用真实宿主 observer，不接受外部提供的“成功观察”。宿主只读查询位于 `scripts/Get-ComponentRetirementObservation.ps1`，由 host-safety 拥有。

## 范围输入

UTF-8 JSON，schema_version=1。以下字段均显式给出；没有该类对象时提供空列表，不从旧日志推导授权：

- `skills`: `{name, source_id}` 列表，name 为 canonical skill identity。
- `active_root`、`ledger`、`magpie_library`、`policy`: 必需的当前路径；ledger 是统一来源账本。
- `consumer_roots`: 各消费者的明确实体 skills 根；拒绝以 reparse 祖先扩大覆盖范围。
- `scan_roots`: 必需的明确实体根列表，递归只读扫描 SKILL.md/SOURCE.md。根已不存在表示该根下没有 payload；访问失败、reparse 或无法解析 identity 则保留 unknown，不当空清单。
- `temporary_policy_ids`、`absent_paths`、`tasks`、`products`（MSI product code）、`process_names`: 必须不存在的精确对象。
- `manual_pending`: 尚须用户完成的动作标识，例如 empty-recycle-bin；工具不执行这些动作。

SKILL identity 只读首段 YAML frontmatter 的顶层 name；SOURCE identity 使用供应链唯一 parser 的末尾 current record Skill 字段。正文示例、旧 provenance 段、作者名和其他 skill 不作为命中。超大或不可读 marker 明记扫描不完整。扫描结果只用于验收，不是删除清单或删除授权。

## 结果和成功条件

active、消费者链接（含断链）、Magpie、产品、任务、进程、已声明路径、来源 ledger、临时 policy 和 marker 扫描全部通过才有 `machine_retired=true`。来源要求 deleted-by-user、无 active skills/backup、backup_status=no-local-backup-by-user-rule；相关 deleted 行不得仍带 backup_path 或未完成 purge 状态。Windows 名称按大小写不敏感的精确比较；任务或进程查询异常为 unknown。MSI 使用原生 MsiQueryProductState，只有文档定义的产品未注册结果可记 absent，不把任意 COM 异常吞成 absent。

`status` 为 unknown、residual、manual-pending 或 retired。仅 retired 且没有 manual_pending 时 `ok=true`、退出0；其他均退出1。机器侧清理已完成但仍有回收站待办时，保留 machine_retired=true、status=manual-pending、ok=false，避免在总报告中隐藏人工动作。输入无效也返回 unknown，不能复用历史成功回执。

## 测试和路由

Python 回归是 `tests/Test-ComponentRetirement.py`，覆盖各独立失败条件、异名 payload、正文/历史负例和 manual pending。真实 observer seam 由 `tests/Test-ComponentRetirementObservation.ps1` 验证大小写与查询拒绝，两者登记现有 module manifest/CI。skill 纯退役验收从供应链 CONTEXT 到达本合同；日更仅在显式授权的退役任务中调用，不把已经退休组件恢复成更新候选。

批量目录处置继续使用 `New-SafeCleanupJob.ps1` 和现有 SafeCleanupJob 生命周期；本工具没有删除功能，不修改删除 policy，也不为明确退役的 payload 创建备份。
