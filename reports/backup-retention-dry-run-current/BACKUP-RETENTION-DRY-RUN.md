# 备份保留清理 dry-run 报告

生成时间：2026-07-06 16:12:35 +08:00

本报告只读生成，不删除、不移动、不迁移任何文件。真实清理前必须重新生成 dry-run，并由用户确认具体 manifest、路径集合、候选数量和预计体积。

## 汇总

- 保护项：10 个
- 人工审查项：259 个，4373.92 MB
- 保留规则候选项：0 个
- 候选体积：0 MB
- 候选项内 SKILL.md 数：0 个
- 完整 JSON：D:\Codex\projects\统一环境\reports\backup-retention-dry-run-current\backup-retention-dry-run.json

## 硬边界

- 本脚本不支持 apply，deleteAllowed=false。
- 不能删除 auth.json、profile.json、install_state.json、quota_cache.json、当前 skills、当前 plugins/cache 或 account_backup 根。
- runtime shared dirs plugins、cache、sqlite 不进入保留清理候选。
- plugins、.tmp、_autosave、run-evidence、.codex-c-backups 默认只进入人工审查，不进入自动 prune。
- 保留规则必须有项目根、备份类型、严格目录名时间戳；不能用 mtime 或模糊正则兜底。
- 命中 junction、symlink 或 reparse point 的路径只能人工审查。

## 候选类别汇总

| 类别 | 项数 | 体积 MB | SKILL.md 数 |
| --- | ---: | ---: | ---: |

## 人工审查类别汇总

| 类别 | 项数 | 体积 MB | SKILL.md 数 |
| --- | ---: | ---: | ---: |
| 按组保留最近 5 个 | 249 | 5.05 | 6 |
| runtime/shared-cache | 4 | 541.85 | 638 |
| 旧 skill 备份 | 1 | 0.13 | 19 |
| 旧本地备份 | 1 | 0.89 | 35 |
| 全局备份根 | 1 | 20.34 | 230 |
| 全局临时 staging | 1 | 64.11 | 6 |
| 运行证据 | 1 | 3741.51 | 754 |
| 账号自动快照 | 1 | 0.04 | 0 |

## 保护项

- D:\Codex\.codex\skills：当前用户安装 skill 活跃层，不能按备份清理。（存在）
- D:\Codex\.codex\plugins\cache：当前插件缓存活跃层，包含官方或已安装插件 skill。（存在）
- D:\Codex\.codex\account_backup：账号备份根不能整体删除；只允许显式 allowlist 子树进入人工审查或候选。（存在）
- D:\Codex\.codex\account_backup\windows\plugins：runtime 共享 plugins 目录，不能按备份清理。（不存在）
- D:\Codex\.codex\account_backup\windows\cache：runtime 共享 cache 目录，不能按备份清理。（不存在）
- D:\Codex\.codex\account_backup\windows\sqlite：runtime 共享 sqlite 目录，不能按备份清理。（不存在）
- D:\Codex\.codex\account_backup\windows\auth.json：账号敏感文件，保护。（不存在）
- D:\Codex\.codex\account_backup\windows\profile.json：账号敏感文件，保护。（不存在）
- D:\Codex\.codex\account_backup\windows\install_state.json：账号敏感文件，保护。（存在）
- D:\Codex\.codex\account_backup\windows\quota_cache.json：账号敏感文件，保护。（存在）

## 最大人工审查项

| 风险 | 类别 | 体积 MB | SKILL.md 数 | 路径 |
| --- | --- | ---: | ---: | --- |
| 高 | 运行证据 | 3741.51 | 754 | D:\Codex\.codex\run-evidence |
| 高 | runtime/shared-cache | 403.92 | 17 | D:\Codex\.codex\account_backup\windows\refresh_runtime\plugins |
| 高 | runtime/shared-cache | 74.15 | 16 | D:\Codex\.codex\account_backup\windows\login_runtime\plugins |
| 中 | 全局临时 staging | 64.11 | 6 | D:\Codex\.codex\.tmp\bundled-marketplaces |
| 高 | runtime/shared-cache | 63.78 | 605 | D:\Codex\.codex\account_backup\windows\login_runtime\.tmp\plugins |
| 中 | 全局备份根 | 20.34 | 230 | D:\Codex\.codex\backups |
| 中 | 旧本地备份 | 0.89 | 35 | D:\Codex\.codex\.backups |
| 中 | 按组保留最近 5 个 | 0.61 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase7-fixture |
| 中 | 按组保留最近 5 个 | 0.16 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-remote-rewrite-staged-path |
| 中 | 旧 skill 备份 | 0.13 | 19 | D:\Codex\.codex\skills-backups |
| 中 | 按组保留最近 5 个 | 0.12 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-remote-tool-forward-slash |
| 中 | 按组保留最近 5 个 | 0.12 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\review-direct-fixture-classes |
| 中 | 按组保留最近 5 个 | 0.11 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\review-03-remote-tool-schema |
| 中 | 按组保留最近 5 个 | 0.11 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-remote-tool-extract-failure |
| 中 | 按组保留最近 5 个 | 0.11 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-remote-tool-unsafe-tar |
| 中 | 按组保留最近 5 个 | 0.11 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-remote-tool-hash-mismatch |
| 中 | 按组保留最近 5 个 | 0.11 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-remote-tool-corrupt-package-validation |
| 中 | 按组保留最近 5 个 | 0.11 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-remote-tool-missing-package-validation |
| 中 | 按组保留最近 5 个 | 0.1 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-remote-tool-corrupt-package-manifest |
| 中 | 按组保留最近 5 个 | 0.1 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\review-missing-remote-file |

## 最大保留规则候选项

| 风险 | 组 | 排名 | 时间戳 | 体积 MB | SKILL.md 数 | 路径 |
| --- | --- | ---: | --- | ---: | ---: | --- |

## 下一步

1. 由用户确认是否继续到 apply 设计；笼统的继续不等于删除授权。
2. 若要 apply，必须基于最新 JSON 生成显式 allowlist，并二次验证 path、size、mtime、目录计数、D 盘边界和 reparse point。
3. 人工审查项不能混入一键清理；永久删除必须作为单独显式授权。

