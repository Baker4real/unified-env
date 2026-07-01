# 备份清理 apply manifest 设计

生成时间：2026-07-01 15:52:00 +08:00

本文件是删除前 manifest 设计和二次校验结果，不删除、不移动、不迁移任何文件。即使所有路径验证通过，真实删除仍需要用户再次明确确认 manifest id、路径数量和预计释放体积。

## 汇总

- manifest id：backup-retention-apply-20260701-155200-57ae1622
- source dry-run：D:\Codex\.codex\run-evidence\env-governance\backup-retention-20260701-154928\backup-retention-dry-run.json
- dry-run 年龄：0 小时
- 选择模式：all-dry-run-candidates
- 选中路径：36 个，234.11 MB
- 通过二次校验：36 个，234.11 MB
- 阻塞路径：0 个
- deleteAllowed=false
- executionReady=false

## 硬边界

- 本脚本只生成 manifest，不包含删除实现。
- 人工审查项和保护路径不会进入可删除集合。
- 每个路径都必须仍存在、仍在 D 盘、未命中 reparse point，且当前 bytes/files/dirs/SKILL.md/newestUtc/oldestUtc 与 dry-run 快照一致。
- 下一阶段如果实现真实 apply，必须要求用户逐字确认 manifest id、路径数量和预计释放体积。

## 最终授权短语

```text
我确认删除 manifest backup-retention-apply-20260701-155200-57ae1622 中的 36 个已验证路径，预计释放 234.11 MB
```

## 已验证路径

| id | 风险 | 组 | 排名 | 体积 MB | 路径 |
| --- | --- | --- | ---: | ---: | --- |
| db8fbca3138accb5 | 中 | apps/codex_switch/backups::codex-switch-installed-binary | 9 | 33.51 | D:\Codex\apps\codex_switch\backups\20260629-102645 |
| 7aeb76e698e8c88d | 中 | apps/codex_switch/backups::codex-switch-installed-binary | 8 | 33.51 | D:\Codex\apps\codex_switch\backups\20260629-162215 |
| 0fe03263c435fcc3 | 中 | apps/codex_switch/backups::codex-switch-installed-binary | 10 | 33.48 | D:\Codex\apps\codex_switch\backups\20260629-100650 |
| 32169df8d9acedc7 | 中 | apps/codex_switch/backups::codex-switch-installed-binary | 7 | 33.48 | D:\Codex\apps\codex_switch\backups\before-quota-provenance-20260629-184908 |
| ec99d6f82e68ef07 | 中 | apps/codex_switch/backups::codex-switch-installed-binary | 11 | 33.47 | D:\Codex\apps\codex_switch\backups\pre-runtime-autodetect-20260626-155927 |
| 04ec99e851eded1a | 中 | apps/codex_switch/backups::codex-switch-installed-binary | 6 | 33.45 | D:\Codex\apps\codex_switch\backups\before-msvc-replacement-20260629-202144 |
| f375721b16e8357a | 低 | .codex/backups_state/provider-sync::provider-sync | 6 | 32.59 | D:\Codex\.codex\backups_state\provider-sync\20260630T015140652Z |
| ef161706e9334128 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 16 | 0.1 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-core-sync-fixed-20260623T152032Z |
| 077fc685bf29d423 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 15 | 0.1 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-core-sync-fixed2-20260623T152452Z |
| cc38ee05e05d44df | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase3 | 6 | 0.05 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-live-uat-20260619164423 |
| b5cc2860961c5263 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase3 | 7 | 0.05 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-live-uat-20260619163908 |
| 4a3c89bc06abae26 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase3 | 8 | 0.04 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase3-live-uat-20260619163346 |
| 1141e7804d4908ee | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 13 | 0.03 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-machine-temp-repair-20260623T170734 |
| 5ac2d69839435469 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 14 | 0.02 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-ssh-l2r-20260623T170433 |
| 8cc7f175118bce6e | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 12 | 0.02 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-ssh-l2r-postrepair-20260623T171608 |
| 32d7a8aa0298f69b | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 7 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260623T090046Z |
| dfaa884dbe10e2f7 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 6 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260623T091127Z |
| e5a6af1aebf93f01 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 18 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T064431Z |
| 9e9a908019615bf8 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 17 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T064450Z |
| ecf54f0aabd68397 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 16 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T064522Z |
| eeaf73e3b92ca59e | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 15 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T064529Z |
| c6ccd7d30996caa5 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 14 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T070623Z |
| eba803bae1bd4b04 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 13 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T074749Z |
| c78d29f939a30bb6 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 12 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260622T025554Z |
| de38f896ce0fb05e | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 11 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260623T013325Z |
| 7d47afe3fbff3666 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 10 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260623T013650Z |
| 409e84dc6e34bc12 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 9 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260623T014449Z |
| 1dc06b7afec15def | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 8 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260623T021442Z |
| 94ea4895fba5c97b | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 20 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T053338Z |
| 200cd8c8fe52acd1 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase4 | 19 | 0.01 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase4-live-uat-20260621T064006Z |
| c1c4d0eaae61fbdc | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 10 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-remote-junction-report-20260623T172005 |
| 899a6f1d198e2484 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 11 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-remote-core-verify-20260623T171734 |
| 4c410b6cdbf26952 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 7 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-ssh-r2l-origin-keyonly-20260623T172650 |
| 766b6ac47a82cda3 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 8 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-ssh-r2l-origin-20260623T172514 |
| f9eaaf80788782d1 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 6 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-local-sshd-probe-20260623T173330 |
| 06a713e1ebeda915 | 中 | projects/codex-gsd-codex-c-skill/docs/gsd-archive/tmp/replicator::phase5 | 9 | 0 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase5-live-ssh-r2l-origin-20260623T172220 |

## 阻塞路径

| id | 状态 | 原因 | 路径 |
| --- | --- | --- | --- |

## 下一步

1. 人工审查本 manifest 的路径集合、数量和体积。
2. 如需真实删除，先实现单独的 apply 执行脚本，并要求用户使用上面的最终授权短语确认。
3. 真实删除前再次重新生成 dry-run 和 manifest；本 manifest 过期后不能直接执行。

