---
type: report
title: Run-Evidence 迁移与知识收尾交接
tags: [handoff, run-evidence, 迁移]
intent: 交接 jia-li 迁移终态、身份勘误、复查结果与后续待办
---

# Run-Evidence 迁移与知识收尾交接

**日期**: 2026-08-26 03:35  
**类型**: 基础设施迁移 + 知识收尾  
**状态**: 本机迁移完成，文档已更新并发布

## 勘误（2026-08-26）

按 Tailscale 登记核验，执行本次迁移的本机是 `jia-li`（家里，Windows 主机名 `Baker`），不是 `zi-xi-shi`（自习室）；`zi-xi-shi` 是另一台独立 Windows 设备。本文中“Device (zi-xi-shi)”“本机”等均指 `jia-li`；“其他设备迁移：home 和 office”应读作“`zi-xi-shi`（自习室）和 `ban-gong-shi`（办公室）待迁移；`jia-li`（家里，本机）已完成”。设备文档现行版本见 `docs/environments/jia-li.md` 与 `docs/environments/zi-xi-shi.md`。

## 复查（2026-08-26 live 核验，回答文末验证检查点）

- `Cursor Daily Codex Ecosystem Update`：2026-08-26 02:00 已运行且 LastResult=0；当前 State=**Disabled**，与 `docs/environments/jia-li.md`「日更已改由 ZCode 自动化执行、该任务必须保持 Disabled」一致。上文“恢复到 Ready、下次运行 02:00”为迁移恢复时刻快照，现役状态以设备文档为准。
- `Reconcile CC Switch Skill Links`：2026-08-26 16:54 运行成功（LastResult=0），周期调度正常。
- `Codex Remote Plugin Catalog Guard`：最后一次运行为 2026-08-24 17:01（迁前），LastTaskResult=267014（任务被终止），当前 Ready 且无 NextRunTime——常驻 watcher 迁后未再运行，**待单独任务定位处置**。
- 旧根非空：含 sub2api 漏网写方重建的 `daily-codex-ecosystem-update\` 一项（已登记为 jia-li 遗留债务，见 `docs/plans/2026-08-26-run-evidence-migration-plan-zi-xi-shi-ban-gong-shi.md` §3）。
- 新根：`D:\agents\run-evidence\` 378 个顶层条目，活跃。

## 用户目标

执行 `docs/plans/2026-08-24-run-evidence-migration-plan.md`（原 `D:\agents\handoffs\run-evidence-migration-plan-2026-08-24.md`，2026-08-26 迁入仓库）中的 run-evidence 迁移方案，将旧根 `D:\Codex\.codex\run-evidence\` 迁移到新根 `D:\agents\run-evidence\`，并完成知识收尾确保相关文档同步。

## 已完成

### 1. 迁移物理执行（2026-08-25 → 2026-08-26）

- **旧根清空**: `D:\Codex\.codex\run-evidence\` 现为空目录（0 条目）
- **新根就位**: `D:\agents\run-evidence\` 包含 376 个顶层条目
- **关键域验证**:
  - `safe-tree-delete`: 11,635 文件
  - `codex-hook-health`: 16,502 文件
- **Preflight 验证**: 通过（退出码 0）
- **计划任务恢复**: 三个任务已恢复到 Ready 状态
  - `Cursor Daily Codex Ecosystem Update`: 下次运行 2026-08-26 02:00
  - `Codex Remote Plugin Catalog Guard`: Ready
  - `Reconcile CC Switch Skill Links`: Ready

### 2. 知识收尾（2026-08-26）

**已更新文档**:

- `docs/environments/zi-xi-shi.md` (已 commit 并 push 到 GitHub)
  - 更新两处 run-evidence 路径引用
  - 标注迁移日期 2026-08-26
  - Commit: `c3b77048e64f5eb17d0c07395acd9e101fd14c3b`

- `D:\Codex\.codex\docs\agent-guidance\storage-and-junctions.md` (已就地更新，不在 Git 管理下)
  - 明确 2026-08-26 起新根是现役位置
  - 将旧根加入退役路径清单

**迁移证据位置**:
- `D:\agents\projects\统一环境\reports\run-evidence-migration-20260825T013156Z\`
- `MIGRATION-SUMMARY.md` 已生成

## 当前状态

### Git 状态

- **统一环境仓库**: 
  - 已 push 到 `origin/main` (https://github.com/Baker4real/unified-env.git)
  - 本地与远端同步确认
  - 仍有 116 个文件为之前迁移代码改动尚未 commit（不属于本次文档收尾范围）

### 运行态

- 旧根: 空
- 新根: 活跃
- 计划任务: Ready，等待下次运行验证

## 未决事项与下一步

### 短期（本周）

1. **验证计划任务**: 等待三个计划任务下次运行，确认它们能使用新根路径正常工作
   - 特别关注 `Cursor Daily Codex Ecosystem Update`（每日 02:00）

### 中期（本月）

2. **其他设备迁移**: home 和 office 机器各自执行相同的迁移方案
   - 每台机器需要独立授权和验证

### 长期（30 天后）

3. **双容兼容代码清退**: 
   - 条件: home/office 均迁移 + 连续 30 天 watcher 无事件/overflow/gap
   - 届时清退 remote schema 和 tools 中的旧根兼容代码

### 文档遗留

4. **历史引用**: 73 个文件仍引用旧根路径，但多数是历史报告、测试 fixture 和已完成任务的证据记录（属于历史 provenance，不应改写）

## 关键路径

### 项目文件

- 迁移方案: `docs/plans/2026-08-24-run-evidence-migration-plan.md`（2026-08-26 起自 `D:\agents\handoffs\` 迁入仓库，该目录只保留 handoff）
- 设备文档: `D:\agents\projects\统一环境\docs\environments\zi-xi-shi.md`
- 存储策略: `D:\Codex\.codex\docs\agent-guidance\storage-and-junctions.md`
- 迁移证据: `D:\agents\projects\统一环境\reports\run-evidence-migration-20260825T013156Z\`

### 重要位置

- 旧根（已退役）: `D:\Codex\.codex\run-evidence\`
- 新根（现役）: `D:\agents\run-evidence\`
- 统一环境仓库: `D:\agents\projects\统一环境`
- 远端仓库: https://github.com/Baker4real/unified-env.git

## 事实分类

### Project

- 迁移方案在统一环境项目的 `reports/` 和 `docs/handoffs/` 中
- 设备文档已更新并发布到 GitHub

### Device (zi-xi-shi)

- 本机迁移已完成
- 三个计划任务配置在本机 Windows 任务计划程序中
- Codex 运行时文档 `storage-and-junctions.md` 已就地更新（不在 Git 仓库中）

### Local

- 116 个迁移代码改动文件尚未 commit（来自之前的迁移实现，不属于本次文档收尾）
- Git index lock 文件曾出现 stale 状态（已清理）

### Evidence

- 完整迁移证据: `D:\agents\projects\统一环境\reports\run-evidence-migration-20260825T013156Z\`
- 包含状态机、manifest、backup、测试结果和 cutover 日志

## 建议 Skills

下次继续此工作时：

- `neat-freak`: 如需进一步文档同步或知识收尾
- `repo-clean-closeout`: 如需 commit 剩余的 116 个迁移代码改动
- 普通监控和验证不需要特殊 skill

## 注意事项

1. **不要手动修改新旧根**: 所有写入应通过程序和 hook 自然发生
2. **不要删除旧根目录**: 虽然已空，但保留目录结构直到双容清退完成
3. **验证失败时回滚**: 如果计划任务运行失败，参考迁移证据中的回滚步骤
4. **远端状态**: home 和 office 机器的 remote schema 仍指向旧根（有意保留，待它们各自迁移）

## 验证检查点

下次会话应该验证：

- [ ] 三个计划任务至少运行一次且成功
- [ ] 新根 `D:\agents\run-evidence\` 有新证据写入
- [ ] 旧根 `D:\Codex\.codex\run-evidence\` 保持为空
- [ ] Preflight 检查持续通过
