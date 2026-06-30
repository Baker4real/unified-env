# 环境迁移 dry-run 计划

生成时间：2026-06-30T16:53:02.8721139+08:00

> DRY-RUN：本计划为只读迁移计划。生成过程没有移动文件、没有修改环境变量、没有执行更新。

## 来源

- inventory：D:\Codex\projects\统一环境\reports\env-inventory\inventory.json
- inventory 生成时间：2026-06-30T16:52:45.7495004+08:00

## 摘要

- 可计划迁移项：0
- 排除的人工审查项：5
- 排除的根目录规则：5

## 迁移计划

当前没有可生成 dry-run 计划的迁移候选。
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
