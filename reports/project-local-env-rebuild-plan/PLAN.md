# 项目本地环境重建 DRY-RUN 计划

生成时间：2026-07-01T11:11:52.8739930+08:00

> DRY-RUN：本计划不执行命令、不删除目录、不迁移环境、不合并项目本地环境。候选命令预览只用于后续独立项目级 issue。

## 摘要

- 计划项数量：6
- 可计划重建：1
- 需 owner 决策：6
- 缺少重建来源阻塞：1
- 高风险或状态敏感：4

## 计划清单

| 项目或 app | 分类 | 标记 | 风险 | 状态 | 执行允许 | 需 owner | 说明 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D:\Codex\projects\歌单转换 | project-root-local-env | .venv | 中 | owner-decision-required | 否 | 是 | 存在部分线索，但缺少足够版本、锁文件或测试信息。 |
| D:\Codex\projects\codex-account-switch | project-root-local-env | node_modules | 中 | planned-rebuild | 否 | 是 | 存在锁文件或重建来源，但仍只能作为后续独立 issue 的候选计划。 |
| D:\Codex\projects\yangyangzi-direct-qqbot | project-root-local-env | .venv | 高 | owner-decision-required | 否 | 是 | 存在部分线索，但缺少足够版本、锁文件或测试信息。 |
| D:\Codex\.gsd\projects\hermes-agent | project-root-local-env | .venv | 高 | owner-decision-required | 否 | 是 | 存在部分线索，但缺少足够版本、锁文件或测试信息。 |
| D:\Codex\.gsd\projects\new-chat-4 | project-root-local-env | .venv | 高 | blocked-no-rebuild-source | 否 | 是 | 缺少足够重建来源，禁止自动处理。 |
| D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager | nested-app-local-env | node_modules | 高 | owner-decision-required | 否 | 是 | 存在部分线索，但缺少足够版本、锁文件或测试信息。 |

## 逐项目计划

### D:\Codex\projects\歌单转换 / .venv

- 路径：`D:\Codex\projects\歌单转换\.venv`
- 父项目：`D:\Codex\projects\歌单转换`
- 分类：`project-root-local-env`
- 计划状态：`owner-decision-required`
- 允许执行：否

#### 人工决策门
- 项目 owner 明确授权后才能进入真实重建 issue。
- owner 需要补充锁文件、Python/Node 版本和测试命令后才能生成可重建计划。

#### 前置检查
- 读取项目 README、AGENTS 或等效项目说明。
- 确认该项目环境当前未被运行中的进程、服务或恢复链路占用。
- 确认项目锁文件、解释器版本、包管理器版本和测试命令。
- 记录当前环境路径和必要环境变量，保留原环境不变。

#### 候选命令预览
- 无。当前项目缺少足够重建来源或必须先由 owner 决策。

#### 验证步骤
- 运行项目自己的最小测试或 smoke test。
- 确认新环境不会改变项目配置、绝对路径或运行账户。
- 确认解释器路径、关键依赖版本和项目入口命令。

#### 回滚前置条件
- 真实重建前必须保留原环境目录，不允许在 dry-run 阶段删除或覆盖。
- 记录恢复原环境的命令、环境变量和验证方式。

### D:\Codex\projects\codex-account-switch / node_modules

- 路径：`D:\Codex\projects\codex-account-switch\node_modules`
- 父项目：`D:\Codex\projects\codex-account-switch`
- 分类：`project-root-local-env`
- 计划状态：`planned-rebuild`
- 允许执行：否

#### 人工决策门
- 项目 owner 明确授权后才能进入真实重建 issue。

#### 前置检查
- 读取项目 README、AGENTS 或等效项目说明。
- 确认该项目环境当前未被运行中的进程、服务或恢复链路占用。
- 确认项目锁文件、解释器版本、包管理器版本和测试命令。
- 记录当前环境路径和必要环境变量，保留原环境不变。

#### 候选命令预览
- 候选命令预览：以下命令只能在独立项目级 issue、明确授权和完成前置检查后执行。
- 在项目根确认 package-lock.json 后，候选命令：npm ci
- 执行前必须确认 npm ci 会重建 node_modules，不能在本 dry-run 中运行。

#### 验证步骤
- 运行项目自己的最小测试或 smoke test。
- 确认新环境不会改变项目配置、绝对路径或运行账户。
- 运行 package.json 中的 lint/test/build 中至少一个项目级验证命令。

#### 回滚前置条件
- 真实重建前必须保留原环境目录，不允许在 dry-run 阶段删除或覆盖。
- 记录恢复原环境的命令、环境变量和验证方式。

### D:\Codex\projects\yangyangzi-direct-qqbot / .venv

- 路径：`D:\Codex\projects\yangyangzi-direct-qqbot\.venv`
- 父项目：`D:\Codex\projects\yangyangzi-direct-qqbot`
- 分类：`project-root-local-env`
- 计划状态：`owner-decision-required`
- 允许执行：否

#### 人工决策门
- 项目 owner 明确授权后才能进入真实重建 issue。
- owner 需要补充锁文件、Python/Node 版本和测试命令后才能生成可重建计划。
- 必须由 owner 确认停机窗口。
- 必须确认服务启动命令、健康检查、状态恢复和回滚负责人。

#### 前置检查
- 读取项目 README、AGENTS 或等效项目说明。
- 确认该项目环境当前未被运行中的进程、服务或恢复链路占用。
- 确认项目锁文件、解释器版本、包管理器版本和测试命令。
- 记录当前环境路径和必要环境变量，保留原环境不变。
- 高风险项目必须先确认 owner、停机窗口、启动命令、健康检查和回滚步骤。

#### 候选命令预览
- 无。当前项目缺少足够重建来源或必须先由 owner 决策。

#### 验证步骤
- 运行项目自己的最小测试或 smoke test。
- 确认新环境不会改变项目配置、绝对路径或运行账户。
- 确认解释器路径、关键依赖版本和项目入口命令。
- 完成服务级健康检查，并确认状态文件、账号、队列或会话数据未丢失。

#### 回滚前置条件
- 真实重建前必须保留原环境目录，不允许在 dry-run 阶段删除或覆盖。
- 记录恢复原环境的命令、环境变量和验证方式。
- 高风险项目必须预先写明停止新实例、恢复旧环境、重新启动和健康检查的回滚顺序。

### D:\Codex\.gsd\projects\hermes-agent / .venv

- 路径：`D:\Codex\.gsd\projects\hermes-agent\.venv`
- 父项目：`D:\Codex\.gsd\projects\hermes-agent`
- 分类：`project-root-local-env`
- 计划状态：`owner-decision-required`
- 允许执行：否

#### 人工决策门
- 项目 owner 明确授权后才能进入真实重建 issue。
- owner 需要补充锁文件、Python/Node 版本和测试命令后才能生成可重建计划。
- 必须由 owner 确认停机窗口。
- 必须确认服务启动命令、健康检查、状态恢复和回滚负责人。

#### 前置检查
- 读取项目 README、AGENTS 或等效项目说明。
- 确认该项目环境当前未被运行中的进程、服务或恢复链路占用。
- 确认项目锁文件、解释器版本、包管理器版本和测试命令。
- 记录当前环境路径和必要环境变量，保留原环境不变。
- 高风险项目必须先确认 owner、停机窗口、启动命令、健康检查和回滚步骤。

#### 候选命令预览
- 无。当前项目缺少足够重建来源或必须先由 owner 决策。

#### 验证步骤
- 运行项目自己的最小测试或 smoke test。
- 确认新环境不会改变项目配置、绝对路径或运行账户。
- 确认解释器路径、关键依赖版本和项目入口命令。
- 完成服务级健康检查，并确认状态文件、账号、队列或会话数据未丢失。

#### 回滚前置条件
- 真实重建前必须保留原环境目录，不允许在 dry-run 阶段删除或覆盖。
- 记录恢复原环境的命令、环境变量和验证方式。
- 高风险项目必须预先写明停止新实例、恢复旧环境、重新启动和健康检查的回滚顺序。

### D:\Codex\.gsd\projects\new-chat-4 / .venv

- 路径：`D:\Codex\.gsd\projects\new-chat-4\.venv`
- 父项目：`D:\Codex\.gsd\projects\new-chat-4`
- 分类：`project-root-local-env`
- 计划状态：`blocked-no-rebuild-source`
- 允许执行：否

#### 人工决策门
- 项目 owner 明确授权后才能进入真实重建 issue。
- 缺少足够重建来源，禁止自动处理，需 owner 决策是否保留或补充说明。
- 必须由 owner 确认停机窗口。
- 必须确认服务启动命令、健康检查、状态恢复和回滚负责人。

#### 前置检查
- 读取项目 README、AGENTS 或等效项目说明。
- 确认该项目环境当前未被运行中的进程、服务或恢复链路占用。
- 确认项目锁文件、解释器版本、包管理器版本和测试命令。
- 记录当前环境路径和必要环境变量，保留原环境不变。
- 高风险项目必须先确认 owner、停机窗口、启动命令、健康检查和回滚步骤。

#### 候选命令预览
- 无。当前项目缺少足够重建来源或必须先由 owner 决策。

#### 验证步骤
- 运行项目自己的最小测试或 smoke test。
- 确认新环境不会改变项目配置、绝对路径或运行账户。
- 确认解释器路径、关键依赖版本和项目入口命令。
- 完成服务级健康检查，并确认状态文件、账号、队列或会话数据未丢失。

#### 回滚前置条件
- 真实重建前必须保留原环境目录，不允许在 dry-run 阶段删除或覆盖。
- 记录恢复原环境的命令、环境变量和验证方式。
- 高风险项目必须预先写明停止新实例、恢复旧环境、重新启动和健康检查的回滚顺序。

### D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager / node_modules

- 路径：`D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager\node_modules`
- 父项目：`D:\Codex\.gsd\projects\codex-plus-plus`
- 分类：`nested-app-local-env`
- 计划状态：`owner-decision-required`
- 允许执行：否

#### 人工决策门
- 项目 owner 明确授权后才能进入真实重建 issue。
- owner 需要补充锁文件、Python/Node 版本和测试命令后才能生成可重建计划。
- 必须由 owner 确认停机窗口。
- 必须确认服务启动命令、健康检查、状态恢复和回滚负责人。

#### 前置检查
- 读取项目 README、AGENTS 或等效项目说明。
- 确认该项目环境当前未被运行中的进程、服务或恢复链路占用。
- 确认项目锁文件、解释器版本、包管理器版本和测试命令。
- 记录当前环境路径和必要环境变量，保留原环境不变。
- 高风险项目必须先确认 owner、停机窗口、启动命令、健康检查和回滚步骤。

#### 候选命令预览
- 无。当前项目缺少足够重建来源或必须先由 owner 决策。

#### 验证步骤
- 运行项目自己的最小测试或 smoke test。
- 确认新环境不会改变项目配置、绝对路径或运行账户。
- 运行 package.json 中的 lint/test/build 中至少一个项目级验证命令。
- 完成服务级健康检查，并确认状态文件、账号、队列或会话数据未丢失。

#### 回滚前置条件
- 真实重建前必须保留原环境目录，不允许在 dry-run 阶段删除或覆盖。
- 记录恢复原环境的命令、环境变量和验证方式。
- 高风险项目必须预先写明停止新实例、恢复旧环境、重新启动和健康检查的回滚顺序。

## 策略
- 本计划是 dry-run，只生成说明和候选命令预览。
- 本计划不执行、不删除、不迁移、不合并任何项目本地环境。
- 嵌套 app 环境必须按所在 app 单独审查，不能并入父项目统一重建。
- 插件 runtime/cache 和 repair backup 缓存不进入项目依赖重建计划。
- 候选命令必须在独立项目级 issue、明确授权和项目验证计划下执行。
- 高风险、长期服务或状态敏感项目必须先通过人工决策门。
- 缺少锁文件或重建说明的项目不得输出可直接执行的重建命令。
