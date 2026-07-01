# 失效 PATH 入口清理 DRY-RUN

生成时间：2026-07-01T13:18:05.5945344+08:00

> DRY-RUN：本计划只读取 readiness 报告并生成 PATH 清理候选，不修改用户 PATH、不写系统配置、不删除或重建任何 `.venv`、`node_modules`。

## 摘要

- readiness：`D:\Codex\projects\统一环境\reports\env-update-readiness\readiness.json`
- 候选数量：1
- 可进入真实授权候选：1
- 阻塞候选：0
- 执行允许：否

## 候选清单

| candidateId | PATH 序号 | 路径 | 当前存在 | 状态 | 建议动作 |
| --- | --- | --- | --- | --- | --- |
| stale-path-23-97cda33deb43 | 23 | D:\hermes-agent\.venv\Scripts | 否 | cleanup-candidate | 真实授权后只从用户 PATH 中移除该失效入口；不删除、不重建对应环境目录。 |

## 逐项说明

### stale-path-23-97cda33deb43

- 路径：`D:\hermes-agent\.venv\Scripts`
- 当前存在：否
- 状态：`cleanup-candidate`

#### 前置检查
- 重新生成 env-update-readiness 报告，确认该 PATH 入口仍缺失。
- 读取当前 User scope 和 Process scope PATH，确认该入口来自用户 PATH 还是当前进程继承。
- 确认没有项目、服务或快捷方式仍依赖该失效入口。
- 确认真实清理范围只包含列出的 PATH 字符串，不触碰 .venv、node_modules 或项目文件。

#### 验证步骤
- 真实清理后打开新 shell，确认 PATH 中不再包含该入口。
- 确认相关项目和常用工具命令仍能按现有入口启动。
- 重新运行 env-update-readiness 报告，确认该失效项目本地环境 PATH 入口数量下降。

#### 回滚步骤
- 保留清理前的完整 User scope PATH 字符串。
- 如发现依赖缺失，将该 PATH 入口按原顺序加回 User scope PATH。
- 打开新 shell 重新验证 PATH 和相关命令。

#### 人工授权门
- 用户逐项确认 candidateId、路径数量和具体 PATH 字符串后，才能进入真实清理。
- 真实清理必须作为独立执行步骤，不得和依赖重建、目录删除或环境迁移合并。

## 策略

- 本计划只生成 PATH 清理 dry-run，不修改用户 PATH、机器 PATH 或当前进程环境。
- 本计划不删除、不移动、不重建任何 .venv、node_modules 或项目目录。
- 真实清理前必须重新生成 readiness 和本 dry-run，并逐项确认 candidateId、路径数量和 PATH 字符串。
- 真实清理必须保留清理前完整 PATH 字符串作为回滚依据。
- 输出只能位于 D 盘允许报告目录。
