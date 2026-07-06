# Codex 主机更新收尾交接

生成时间：2026-07-06 14:55 +08:00

> 状态说明：本文是 2026-07-06 14:55 的主机更新快照，仍可作为 Serena/Codex 主链路证据使用；后续环境默认入口、CMake、Rust、.NET、Python、WSL 和 CodeGraph 的最终状态以 `reports/env-update-execution-20260706/REPORT.md`、`D:\Codex\.codex\run-evidence\env-governance\update-20260706` 和 `D:\Codex\.codex\run-evidence\env-governance\fix-net-python-wsl-20260706` 为准。

## 当前结论

本轮 Codex 主机相关可安全更新项已完成到可用状态。Serena/uv 主链路保持标准入口 `D:\Codex\tools\uv\bin\serena.exe`，运行在官方 Python 3.14.6 上；Serena 仍为 `serena-agent==1.5.3`，但通过 uv override 将上游 `anthropic==0.59.0` pin 放宽为 `anthropic>=0.59.0`，当前解析为 `anthropic==0.116.0`。

Python 3.14 下的 Pydantic V1 startup warning 已通过依赖升级消除，不再依赖 `sitecustomize.py` 过滤。`sitecustomize.py` 在主 Serena venv 中已不存在。

## 已完成更新

- Codex CLI：`codex-cli 0.142.5`
- Node：`v26.4.0`
- npm / npx：`11.18.0`
- Git：`2.55.0.windows.2`
- GitHub CLI：`2.96.0`
- uv：`0.11.26`
- sqlite3：`3.53.3`
- Python latest / Serena runtime：官方 Python `3.14.6`
- Serena：`serena-agent==1.5.3`
- Serena Anthropic SDK：`anthropic==0.116.0`
- CodeGraph：`1.2.0`

未手工覆盖官方桌面包、WindowsApps、Codex 内置 vendor runtime、插件官方缓存包或系统级安装器目录；这些仍按官方更新机制处理。

## 关键验证

- `serena --version`：仅输出 `Serena 1.5.3`，无 Pydantic warning。
- 主链路 MCP smoke：`initialize`、`tools/list`、`list_dir`、`read_file` 通过。
- `codex doctor --json`：`overallStatus: ok`。
- 项目仓库：`git status --short` 干净后进入本次文档收尾。

## 已知预期项

`uv pip check --python D:\Codex\tools\uv\tools\serena-agent\Scripts\python.exe` 会报告一个预期不一致：

```text
The package `serena-agent` requires `anthropic==0.59.0`, but `0.116.0` is installed
```

这是本机用 uv override 放宽上游 pin 的结果。只有出现额外依赖冲突、Serena MCP smoke 失败、或 `anthropic.types` / `messages.count_tokens` API 形状错误时，才应回滚。

## 证据

- 主证据目录：`D:\Codex\.codex\run-evidence\codex-update-20260706-104516`
- Serena Anthropic override 证据：`D:\Codex\.codex\run-evidence\codex-update-20260706-104516\serena-anthropic-override`
- 最终版本矩阵：`D:\Codex\.codex\run-evidence\codex-update-20260706-104516\serena-anthropic-override\final-version-matrix-after-anthropic-override.txt`
- 最终 doctor：`D:\Codex\.codex\run-evidence\codex-update-20260706-104516\serena-anthropic-override\codex-doctor-after-anthropic-override.json`
- 全局主机 runbook：`D:\Codex\.codex\docs\agent-guidance\host-runbook.md`

## 回滚方式

若后续验证失败，优先执行非破坏性回滚：

1. 停止占用 `D:\Codex\tools\uv\tools\serena-agent` 或 `D:\Codex\tools\uv\bin\serena*.exe` 的 Serena/Pyright 进程。
2. 用官方 Python 3.14.6 重新安装 Serena，不传 `--overrides`。
3. 重新运行 `serena --version`、主链路 MCP smoke 和 `codex doctor --json`。

本轮替换前备份位于 `D:\Codex\.codex\run-evidence\codex-update-20260706-104516\serena-anthropic-override\backup-before-main-override`。
