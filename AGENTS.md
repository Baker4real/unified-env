# 统一环境 Agent 入口

本仓库治理本机开发环境。先证明当前事实，再规划；只有取得具体授权并具备验证与回滚路径后，才改变宿主状态。

## 启动顺序

1. 跨模块、治理、文件归属或测试 profile 任务读取 `CONTEXT.md`、`modules/README.md` 和当前模块上下文；单模块任务直接读取 `modules/manifest.json`、目标模块上下文和将修改的文件，不为无关模块加载整套根上下文。
2. 只加载当前分支需要的政策：
   - **迁移、PATH、全局运行时或包管理器更新**：真实迁移前读 `docs/env-governance/d-drive-layout-and-migration-policy.md`，重新生成现场 inventory 与 dry-run。
   - **宿主递归目录删除或 terminal evidence 归档**：执行前读 `docs/specs/2026-07-24-safe-tree-delete-capability.md`；只通过受管控制面处理（canonical 入口为 gate shim `D:\Codex\.codex\scripts\invoke-safe-tree-delete.ps1`，POSIX shell 经托管 pwsh 直调；cmd 语境用同名 `.cmd` 兼容启动器），具体 mode 与确认合同以该 spec 为准。
   - **Sub2API 稳定版升级**：执行前读 `docs/env-governance/sub2api-update-policy.md`，逐项证明官方稳定版、联合回滚点和健康验收条件；活跃连接不再单独构成延期条件。
   - **领域建模或架构边界**：读 `docs/agents/domain.md`，再按其中顺序加载相关模块上下文和现役合同。
   - **Issue、PRD 或 triage**：读 `docs/agents/issue-tracker.md` 与 `docs/agents/triage-labels.md`。
   - **知识整理或提交收尾**：读 `docs/agents/knowledge-scope.md`，把项目知识、模块知识、设备事实、本机状态和一次性证据放到各自真源。
3. 在所属模块内做最小改动；从 `modules/manifest.json` 和现有脚本接口选择相关验证，不在本文件缓存命令清单或易变版本。

## 不变量

- `reports/` 和历史 evidence 是带时间戳的快照，不是当前事实或执行授权。真实迁移、配置写入、更新、删除或恢复前必须重新核验 live 状态。
- 所有生成物、迁移目标和运行证据位于获准的 `D:\` 路径。项目本地环境、服务状态、数据库、凭据、浏览器 profile 和受官方安装器管理的目录保持隔离，除非当前任务明确授权并满足对应政策。
- 对异常 schema、未知路径、reparse point、identity/hash 不一致、覆盖不完整或回滚条件无法证明的输入失败闭锁；保留原始事实并报告阻断原因。
- 项目规则、模块 CONTEXT、权威合同和机器可校验 manifest 各自只保留一份真源；设备版本、活动数量、哈希和运行状态从现场环境读取。

## 完成标准

只有以下结果全部可证明时才报告完成：任务范围和授权未扩大；相关模块 ownership 与边界校验通过；目标成功路径及适用的失败路径已验证；写操作有前后状态和回滚证据；`git diff --check` 通过。未执行的 live 验收必须明确列为未验证，不得用 fixture、历史报告或进程存活代替。
