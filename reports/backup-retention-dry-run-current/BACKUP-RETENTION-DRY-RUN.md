---
generationId: 8e4738a0-d0cf-4dbf-9a7c-a19123d1b944
sourceJsonSha256: b3d4e13476cb27e33ac80c1df3f41e3d09e1d539e74cfe1facaf26981b5ec4b0
---
# 备份保留清理 dry-run 报告

生成时间：2026-07-11T08:07:24.3621258+08:00

产物模式：production；覆盖完整：False；源 JSON SHA-256：b3d4e13476cb27e33ac80c1df3f41e3d09e1d539e74cfe1facaf26981b5ec4b0

本报告只读生成，不删除、不移动、不迁移任何文件。deleteAllowed=false。

## 覆盖结论

- coverageAccounted：True
- coverageComplete：False
- 显式 allowlist 扫描根：5 个
- 账本项：29 个；未分类 gap：5 个
- 覆盖证明仅适用于显式 declaredScanRoots，不声称扫描全盘。
- 每个成功枚举的直接子项恰好分类一次。

## 分类汇总

- 保留 retained：2 个
- 候选 candidate：0 个
- 保护 protected：21 个
- 人工审查：16 个

## 声明扫描根

| 根 | 枚举 started/completed | 直接子项/分类 | 错误 | 快照 SHA-256 |
| --- | --- | ---: | ---: | --- |
| D:\Codex\.codex\backups_state | True / True | 5 / 5 | 0 | 361089cab3ab724f02b7b25784e3fd1a4036a865264ff6c88f616d207f8dbbe1 |
| D:\Codex\.codex\backups_state\provider-sync | True / True | 2 / 2 | 0 | 3fd89fde529a76bba40b3dceba8f6d1ce13963e3cf5ba056849b5d630f1fb961 |
| D:\Codex\.gsd\backups\replicator | True / True | 0 / 0 | 0 | 4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945 |
| D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator | True / True | 1 / 1 | 0 | 0bf25aab14bba4c5cc3fa03831de1dfffe47ef608ffe913fd076698a125983c3 |
| D:\Codex\apps\codex_switch\backups | True / True | 0 / 0 | 0 | 4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945 |

## 候选项

| 组 | 排名 | 严格目录名时间戳 | 路径 |
| --- | ---: | --- | --- |

## 硬边界

- 本脚本不支持 apply；任何真实删除都需要显式授权。
- auth.json、profile.json、install_state.json、quota_cache.json、plugins、cache、sqlite 均受保护。
- 命中 junction、symlink 或 reparse point 的根/子项失败关闭。
- 保留规则只使用严格目录名时间戳，不使用 mtime 兜底。
