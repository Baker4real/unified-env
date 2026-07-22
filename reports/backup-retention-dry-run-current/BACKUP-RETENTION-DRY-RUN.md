---
generationId: 57ad464b-e777-4e6b-ab87-15221bbecda8
sourceJsonSha256: 611199eab9a6907f6e4ed03a527e2d4e33fd4d4cd16b3f35176610e5db0fa167
---
# 备份保留清理 dry-run 报告

生成时间：2026-07-22T19:28:10.7056587+08:00

产物模式：production；覆盖完整：True；源 JSON SHA-256：611199eab9a6907f6e4ed03a527e2d4e33fd4d4cd16b3f35176610e5db0fa167

本报告只读生成，不删除、不移动、不迁移任何文件。deleteAllowed=false。

## 覆盖结论

- coverageAccounted：True
- coverageComplete：True
- 显式 allowlist 扫描根：3 个
- 账本项：34 个；未分类 gap：0 个
- 覆盖证明仅适用于显式 declaredScanRoots，不声称扫描全盘。
- 每个成功枚举的直接子项恰好分类一次。
- policy-guardrail 路径只记录根路径元数据，不递归统计。

## 分类汇总

- 保留 retained：3 个
- 候选 candidate：0 个
- 保护 protected：30 个
- 人工审查：20 个
- 人工审查存在性：存在 14 个；缺失 6 个；未知 0 个
- 人工审查大小：已统计 0/14 个存在路径；14 个存在路径或存在性未知项未递归统计，总大小未知

## 声明扫描根

| 根 | 枚举 started/completed | 直接子项/分类 | 错误 | 快照 SHA-256 |
| --- | --- | ---: | ---: | --- |
| D:\Codex\.codex\backups_state | True / True | 10 / 10 | 0 | 7954b445fa11a095dfc6dd142e9d5ed18999d42edcb0b4379b9cc59202804259 |
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
