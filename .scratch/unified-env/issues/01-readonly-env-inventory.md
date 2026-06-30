# Issue 01：实现只读环境资产盘点器

Status: done

## 目标

实现一个只读 PowerShell 脚本，建立本机开发环境资产基线，为后续 D 盘迁移和统一更新策略提供事实依据。

## 范围

- 新增 `scripts/Invoke-EnvInventory.ps1`
- 输出 `reports/env-inventory/inventory.json`
- 输出 `reports/env-inventory/REPORT.md`
- 不修改系统状态

## 验收

- [x] 脚本能在当前项目根运行。
- [x] JSON 文件能被 `ConvertFrom-Json` 正常解析。
- [x] 报告中包含迁移候选和“不自动迁移”说明。
- [x] 默认不做昂贵的目录大小统计；需要时通过参数开启。

## Comments

本 issue 来自统一环境项目初始 MVP。

## Completion notes

- 已实现 `scripts/Invoke-EnvInventory.ps1`。
- 已生成 `reports/env-inventory/inventory.json` 和 `reports/env-inventory/REPORT.md`。
- 当前报告明确标注只读、不自动迁移、迁移候选和项目本地环境标记。
- 验证通过：`tests/Test-EnvInventory.ps1`。
