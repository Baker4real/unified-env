---
generationId: 1be1d55f-1660-4e05-96eb-fb85d627246a
sourceJsonSha256: 3f289ab67823f04af1d9c213943da5c695d6ef490aac985bf6068e76b63c38b4
---
# 备份保留清理 dry-run 报告

生成时间：2026-07-16T19:42:41.6695902+08:00

产物模式：production；覆盖完整：False；源 JSON SHA-256：3f289ab67823f04af1d9c213943da5c695d6ef490aac985bf6068e76b63c38b4

本报告只读生成，不删除、不移动、不迁移任何文件。deleteAllowed=false。

## 覆盖结论

- coverageAccounted：True
- coverageComplete：False
- 显式 allowlist 扫描根：3 个
- 账本项：33 个；未分类 gap：8 个
- 覆盖证明仅适用于显式 declaredScanRoots，不声称扫描全盘。
- 每个成功枚举的直接子项恰好分类一次。

## 分类汇总

- 保留 retained：3 个
- 候选 candidate：0 个
- 保护 protected：21 个
- 人工审查：19 个

## 声明扫描根

| 根 | 枚举 started/completed | 直接子项/分类 | 错误 | 快照 SHA-256 |
| --- | --- | ---: | ---: | --- |
| D:\Codex\.codex\backups_state | True / True | 9 / 9 | 0 | 54cd7bcb60a158431a2741e8ee04a99c5477b9242c13b3b5eb5c67bb356e1c4e |
| D:\Codex\.codex\backups_state\provider-sync | True / True | 3 / 3 | 0 | ed445c7600990bec79c8bb8d6f2d61748aef44b00787bd6040060dc437cf6930 |
| D:\Codex\apps\codex_switch\backups | True / True | 0 / 0 | 0 | 4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945 |

## 候选项

| 组 | 排名 | 严格目录名时间戳 | 路径 |
| --- | ---: | --- | --- |

## 硬边界

- 本脚本不支持 apply；任何真实删除都需要显式授权。
- auth.json、profile.json、install_state.json、quota_cache.json、plugins、cache、sqlite 均受保护。
- 命中 junction、symlink 或 reparse point 的根/子项失败关闭。
- 保留规则只使用严格目录名时间戳，不使用 mtime 兜底。
