# 项目本地环境审查包

生成时间：2026-07-09T16:07:23.5933337+08:00

> 只读报告：项目本地环境默认不自动迁移；本报告不移动、不删除、不合并任何 `.venv`、`node_modules`、`.conda` 或其他项目本地环境。

## 摘要

- 审查项数量：5
- 长期服务或状态敏感项目：0
- 可重建线索项：5
- 需项目 owner 决策项：0
- 嵌套 app 环境项：5

## 审查清单

| 项目或 app | 父项目 | 分类 | 标记 | 路径 | 风险 | 建议动作 | 重建判断 | 长期服务 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D:\Codex\projects\minmin-calendar\cloudfunctions\createRoom | D:\Codex\projects\minmin-calendar | nested-app-local-env | node_modules | D:\Codex\projects\minmin-calendar\cloudfunctions\createRoom\node_modules | 中 | 默认保留；可单独开重建 issue，但不得在本项目中自动迁移或合并。 | 可重建：发现 package-lock.json；可在独立 issue 中用 npm ci 重建并运行项目测试。 | 否 |
| D:\Codex\projects\minmin-calendar\cloudfunctions\dataOp | D:\Codex\projects\minmin-calendar | nested-app-local-env | node_modules | D:\Codex\projects\minmin-calendar\cloudfunctions\dataOp\node_modules | 中 | 默认保留；可单独开重建 issue，但不得在本项目中自动迁移或合并。 | 可重建：发现 package-lock.json；可在独立 issue 中用 npm ci 重建并运行项目测试。 | 否 |
| D:\Codex\projects\minmin-calendar\cloudfunctions\getMyRoom | D:\Codex\projects\minmin-calendar | nested-app-local-env | node_modules | D:\Codex\projects\minmin-calendar\cloudfunctions\getMyRoom\node_modules | 中 | 默认保留；可单独开重建 issue，但不得在本项目中自动迁移或合并。 | 可重建：发现 package-lock.json；可在独立 issue 中用 npm ci 重建并运行项目测试。 | 否 |
| D:\Codex\projects\minmin-calendar\cloudfunctions\joinRoom | D:\Codex\projects\minmin-calendar | nested-app-local-env | node_modules | D:\Codex\projects\minmin-calendar\cloudfunctions\joinRoom\node_modules | 中 | 默认保留；可单独开重建 issue，但不得在本项目中自动迁移或合并。 | 可重建：发现 package-lock.json；可在独立 issue 中用 npm ci 重建并运行项目测试。 | 否 |
| D:\Codex\projects\minmin-calendar\cloudfunctions\login | D:\Codex\projects\minmin-calendar | nested-app-local-env | node_modules | D:\Codex\projects\minmin-calendar\cloudfunctions\login\node_modules | 中 | 默认保留；可单独开重建 issue，但不得在本项目中自动迁移或合并。 | 可重建：发现 package-lock.json；可在独立 issue 中用 npm ci 重建并运行项目测试。 | 否 |

## 验证前置条件

### D:\Codex\projects\minmin-calendar\cloudfunctions\createRoom / node_modules
- 读取项目 README/AGENTS 或等效项目说明。
- 确认项目自己的依赖安装命令、锁文件和测试命令。
- 确认当前环境不是正在运行的服务或恢复链路的一部分。
- 先在项目内生成独立 dry-run 或重建计划，不跨项目复用该目录。
- 确认 package manager 与锁文件一致，例如 npm/package-lock、pnpm/pnpm-lock 或 yarn/yarn.lock。

### D:\Codex\projects\minmin-calendar\cloudfunctions\dataOp / node_modules
- 读取项目 README/AGENTS 或等效项目说明。
- 确认项目自己的依赖安装命令、锁文件和测试命令。
- 确认当前环境不是正在运行的服务或恢复链路的一部分。
- 先在项目内生成独立 dry-run 或重建计划，不跨项目复用该目录。
- 确认 package manager 与锁文件一致，例如 npm/package-lock、pnpm/pnpm-lock 或 yarn/yarn.lock。

### D:\Codex\projects\minmin-calendar\cloudfunctions\getMyRoom / node_modules
- 读取项目 README/AGENTS 或等效项目说明。
- 确认项目自己的依赖安装命令、锁文件和测试命令。
- 确认当前环境不是正在运行的服务或恢复链路的一部分。
- 先在项目内生成独立 dry-run 或重建计划，不跨项目复用该目录。
- 确认 package manager 与锁文件一致，例如 npm/package-lock、pnpm/pnpm-lock 或 yarn/yarn.lock。

### D:\Codex\projects\minmin-calendar\cloudfunctions\joinRoom / node_modules
- 读取项目 README/AGENTS 或等效项目说明。
- 确认项目自己的依赖安装命令、锁文件和测试命令。
- 确认当前环境不是正在运行的服务或恢复链路的一部分。
- 先在项目内生成独立 dry-run 或重建计划，不跨项目复用该目录。
- 确认 package manager 与锁文件一致，例如 npm/package-lock、pnpm/pnpm-lock 或 yarn/yarn.lock。

### D:\Codex\projects\minmin-calendar\cloudfunctions\login / node_modules
- 读取项目 README/AGENTS 或等效项目说明。
- 确认项目自己的依赖安装命令、锁文件和测试命令。
- 确认当前环境不是正在运行的服务或恢复链路的一部分。
- 先在项目内生成独立 dry-run 或重建计划，不跨项目复用该目录。
- 确认 package manager 与锁文件一致，例如 npm/package-lock、pnpm/pnpm-lock 或 yarn/yarn.lock。

## 策略
- 项目本地环境默认不自动迁移。
- 本审查包不移动、不删除、不合并任何项目本地环境。
- 嵌套 app 的本地环境只能按所在 app 的项目级流程审查，不能并入父项目或共享环境。
- 插件 runtime/cache 和 repair backup 缓存不属于本审查包的可重建项目依赖。
- 长期服务或状态敏感项目必须先有项目 owner 决策和项目级验证。
- 可重建只表示存在锁文件或配置线索，不等于允许自动重建。
- 任何重建都必须作为独立项目级 issue 执行。
