# pip cache 迁移后验证

验证时间：2026-06-30T17:00:00+08:00

## 结论

- User scope `PIP_CACHE_DIR` 已切换到 `D:\Codex\.cache\pip`。
- 迁移后 inventory 中迁移候选数量为 0。
- 迁移后 dry-run plan 中可计划迁移项为 0。
- 旧 C 盘默认 pip cache 没有继续作为未处理低风险候选。
- 项目本地 `.venv`、`node_modules` 等人工审查项没有被迁移。

## 运行时验证限制

当前 `D:\Codex\tools\python313-official\python.exe` 没有 `pip` 模块，PATH 中也没有 `pip` 或 `pip3` 命令，因此不能用 `python -m pip cache dir` 或 `pip cache dir` 作为运行时验证信号。

验证命令结果：

```text
D:\Codex\tools\python313-official\python.exe: No module named pip
```

这表示当前机器上的默认 Python 入口无法运行 pip，并不表示缓存迁移失败。当前可验证的持久策略是 User scope 环境变量和重新生成的 inventory/plan。

## 进程刷新说明

Codex 当前长生命周期进程仍可能继承旧的 Process `PIP_CACHE_DIR` 值 `D:\Codex\.pip-cache`。本次迁移写入的是 User scope 环境变量；新 shell、刷新环境或重启相关进程后会自然读取 `D:\Codex\.cache\pip`。
