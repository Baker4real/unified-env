# 环境迁移 dry-run 计划

生成时间：2026-06-30T15:20:32.0885651+08:00

> DRY-RUN：本计划为只读迁移计划。生成过程没有移动文件、没有修改环境变量、没有执行更新。

## 来源

- inventory：D:\Codex\projects\统一环境\reports\env-inventory\inventory.json
- inventory 生成时间：2026-06-30T15:20:24.2556931+08:00

## 摘要

- 可计划迁移项：1
- 排除的人工审查项：5
- 排除的根目录规则：5

## 迁移计划

### migration-01-python-cache

| 字段 | 值 |
| --- | --- |
| 来源 | C:\Users\14224\AppData\Local\pip\Cache |
| 目标 | D:\Codex\.cache\pip |
| 类型 | cache |
| 所属生态 | python |
| 风险 | low |
| 原因 | pip 默认用户缓存候选 |
| 允许执行 | False |
| 需要显式授权 | True |
| Root policy | targeted-cache-under-excluded-user-root |
| Root policy 说明 | 来源位于不批量迁移的用户根目录下；仅允许生成具体缓存子目录 dry-run 计划，真实执行必须另行显式授权。 |

#### 前置检查

- 确认 inventory 是最新生成的基线。
- 确认来源路径存在且不是 reparse point、junction 或 symlink。
- 确认目标路径位于 D 盘，并且不会覆盖已有非空目录。
- 确认没有正在运行的进程写入来源路径。
- 确认 root policy 允许继续；若命中不批量迁移根，必须取得显式授权。

#### 执行步骤

- 创建目标目录：D:\Codex\.cache\pip。
- 复制来源内容到目标目录，保留原来源目录不删除。
- 按工具官方方式切换配置或环境变量，指向目标目录。
- 重新运行只读 inventory，确认新配置生效。

#### 验证步骤

- 验证工具命令仍可运行。
- 验证 inventory 不再把来源路径列为待处理迁移候选。
- 验证报告中没有新增人工审查风险。
- 保留迁移证据和前后对比。

#### 回滚步骤

- 撤销新增配置或环境变量，恢复到迁移前值。
- 重新运行只读 inventory，确认工具回到迁移前策略。
- 确认目标目录不再被工具使用后，再人工决定是否删除目标副本。
- 保留回滚证据。

## 排除项

### 被人工审查项阻止的候选

无。

### 人工审查项

| 来源 | 类型 | 风险 | 原因 |
| --- | --- | --- | --- |
| D:\Codex\projects\歌单转换\.venv | project-local-env | high | 项目本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\projects\codex-account-switch\node_modules | project-local-env | high | 项目本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\projects\yangyangzi-direct-qqbot\.venv | project-local-env | high | 项目本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\.gsd\projects\hermes-agent\.venv | project-local-env | high | 项目本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\.gsd\projects\new-chat-4\.venv | project-local-env | high | 项目本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |

### 绝不自动迁移根

| 路径 | 原因 |
| --- | --- |
| C:\Windows | 系统目录，绝不自动迁移 |
| C:\Program Files | MSI/系统级安装目录，绝不直接搬迁 |
| C:\Program Files (x86) | MSI/系统级安装目录，绝不直接搬迁 |
| C:\ProgramData | 服务和机器级状态常驻位置，仅按官方迁移流程处理 |
| C:\Users | 不批量迁移用户目录或 AppData |

### 被根策略阻止的候选

无。

## 下一步

1. 人工审查本计划。
2. 只对通过审查的低风险项执行真实迁移 issue。
3. 执行前再次运行 inventory，避免基线过期。
