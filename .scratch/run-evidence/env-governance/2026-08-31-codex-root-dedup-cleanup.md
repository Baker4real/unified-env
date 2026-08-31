# 2026-08-31 D:\Codex 归属梳理与运行时去重执行摘要

- 源项目：`D:\agents\projects\统一环境`
- 目标机器：本机 `jia-li`（家里）
- 操作类型：归属盘点（goal-first 决策）+ 获授权迁移/删除/重指向
- 结果：完成（含一项延期、一项数据事件，见下）

## 全局证据

- 盘点与分类决策证据：本会话只读调查 + 对抗复核（两拨只读 worker + 一拨 reviewer）。
- 第一批执行证据：`D:\agents\run-evidence\env-governance\20260831-codex-root-dedup-cleanup\`（索引 `EVIDENCE-INDEX.md`）。
- 7.6.5 收敛证据：`D:\agents\run-evidence\env-governance\20260831-pwsh-765-consolidation\`。
- 受管删除 run：`D:\agents\run-evidence\safe-tree-delete\` 下 20260831T0804…0807（python 7 子树 purged）与 20260831T123157Z（pwsh 7.6.3 purged）；7.6.4 的 Plan 20260831T125141Z / 132345Z Apply 均被锁闭锁，无 quarantine 残留。

## 归属决策（decided）

共享层不迁出 `D:\Codex`：`.codex\skills` 是五宿主唯一 skill 真源（经 `.cc-switch` 链接层，政策记录在案留守）；`docs\agent-guidance` 与 `scripts` 被 Kimi/ZCode 全局规则绝对路径引用，治理权在 Codex；工具链/XDG 缓存/TMP 由用户级环境变量共享，按政策冻结待"第四阶段专项"。本轮只执行错放项归位与零引用重复项清除。

## 关键变更

1. temp 个人文件 5 个迁回 `D:\Documents\restored-from-codex-temp-20260831\`。
2. 悬空 `GSD_HOME` 用户环境变量删除（GSD 已退役，目录早不存在）。
3. `python314-official-3.14.6` 删除（现役 `python314-official`=3.14.7）；`PowerShell\7.6.3` 删除；全部 pwsh 入口收敛到 7.6.5（计划任务经 UAC 提权重指向，Claude 白名单、WT profile、`.codex\scripts`、sub2api 三处同步改）。
4. sub2api 栈经项目受管路径重启，容器全 Healthy，端到端 socks5 探测 HTTP 200；监控进程已在 7.6.5 上运行。
5. 设备事实已同步 `docs/environments/jia-li.md`（pwsh/python/.dotnet-cli/GSD_HOME 四条）。

## 未决与风险

- `PowerShell\7.6.4`（296MB）延期：唯一持锁者是承载会话的宿主终端进程，窗口关闭后重跑受管删除即可。
- **数据事件**：`clock-archive-ffda706.zip`（38MB）15:41 迁入 `D:\agents\projects\时钟倒计时\` 后 40 分钟内被不明操作删除（当时段该项目有 git 活动）；内容可由该仓库 commit `ffda706` 经 `git archive` 重建，是否重建与落点待用户决定。
- `D:\Codex\temp\附件2-blank-backup.doc`（35KB）不在授权清单内，未动，待裁决。
- `sub2api-local-deploy` 工作树 3 个 7.6.5 重指向文件未 commit（发布需单独授权）。
- 本仓库工作树 3 个修改文件（safe-tree-delete spec/policy.json/测试，policy 为 +16 行两条新条目）是**其他并发会话**的在途改动，本任务未触碰、不代为提交。
- 大额空间项（`tmp` 17.5GB、`temp` 6.2GB、`backups_state` 11.6GB 等）是保留策略问题，不在归属梳理范围，需另行授权 scope。

## 下一步

- 用户关闭旧 7.6.4 终端窗口后：重跑 7.6.4 受管删除（Plan→Apply→Purge，临时 policy 条目用后撤销）。
- 待授权候选：时钟 zip 重建；`.doc` 归位；sub2api 仓库 3 个文件的发布。
