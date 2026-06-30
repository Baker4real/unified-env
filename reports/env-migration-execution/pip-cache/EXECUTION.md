# pip cache 迁移执行记录

执行时间：2026-06-30T16:52:15.5475142+08:00

> 本次只执行 `migration-01-python-cache`。旧源目录默认保留；本脚本不删除 C 盘目录，不处理项目本地 `.venv` 或其他人工审查项。

## 范围

- 来源：C:\Users\14224\AppData\Local\pip\Cache
- 目标：D:\Codex\.cache\pip
- 环境变量：PIP_CACHE_DIR
- 环境变量作用域：User
- 执行前 dry-run 计划项数量：1
- 执行前 dry-run 计划项：migration-01-python-cache
- 执行前 root policy：targeted-cache-under-excluded-user-root
- 执行前计划要求显式授权：是

## 结果

- 复制文件数：266
- 已存在而跳过的文件数：9
- 创建目录数：458
- 旧源目录保留：是
- 回滚状态文件：D:\Codex\projects\统一环境\reports\env-migration-execution\pip-cache\rollback-state.json

## 回滚

如需回滚环境变量策略，执行：

```powershell
& 'D:\Codex\projects\统一环境\scripts\Invoke-PipCacheMigration.ps1' -Mode Rollback -StatePath 'D:\Codex\projects\统一环境\reports\env-migration-execution\pip-cache\rollback-state.json' -EnvironmentScope User -EnvironmentVariableName 'PIP_CACHE_DIR'
```
