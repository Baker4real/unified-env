# 本机 Codex 钩子收敛实施计划

> 执行方式：在 `codex/host-hook-remediation` 分支上采用测试先行和逐任务审查；不得暂存或覆盖用户已有的 `.gitignore`、`AGENTS.md` 改动。

**目标：** 把本机用户级 Codex lifecycle hooks 收敛为 0，以 Serena 原生 cwd 项目选择和一个显式冷路径修复器替代热路径补丁，并完成真实主机切换、回滚证据和 fresh canary。

**架构：** 一个 PowerShell deep module 负责检查/修复它真正拥有的两个配置文件和 live hook surface；Projectless、mobile 权限与其他 Windows guards 继续由各自 owner 管理。修复器只在人工、安装或升级后调用，不新增常驻 watcher 或计划任务。

**技术栈：** PowerShell 7.6、TOML 严格行级 section 解析、JSON、Windows ACL、原子文件替换、Git。

---

## 全局约束

- 所有新增产物和 evidence 写入 D 盘。
- 不修改 AppX/vendor 资源，不改私有 SQLite 或 `.codex-global-state.json`。
- 不清理无关脏改动，不提交 `.scratch` 审计工作区。
- 实现前测试必须先红；每个任务完成后单独审查，高风险 live cutover 前启用对抗性审查。
- 真实写入前保存哈希、内容和 ACL；任何失败都优先恢复原状态。

## 任务 1：建立冷路径修复器的红色测试

**文件：**

- 新建：`tests/Test-CodexHostHookReconciliation.ps1`
- 新建：`scripts/Invoke-CodexHostHookReconciliation.ps1`

**步骤：**

1. 用 D 盘 fixture 建立包含固定 Serena 项目、7 个 lifecycle hooks、旧 trust state 和九个 legacy 文件的输入。
2. 测试 `Check` 只读、准确报告 drift，不改变任一哈希。
3. 测试 `Repair` 清空 hooks、将固定项目替换为唯一 `--project-from-cwd`、删除旧 trust state，同时保留 custom context、无关 TOML section 和 JSON 顶层字段。
4. 测试九个 legacy 文件被复制到 evidence 后才从 live 目录退役。
5. 测试第二次 `Repair` 不再改变文件或新建无意义 evidence。
6. 测试 malformed JSON、重复 Serena section、缺失关键 key 时拒绝写入并保持原哈希。
7. 先运行测试确认因实现缺失或行为缺失而失败。

## 任务 2：实现最小修复器并通过测试

**文件：**

- 修改：`scripts/Invoke-CodexHostHookReconciliation.ps1`
- 修改：`tests/Test-CodexHostHookReconciliation.ps1`

**步骤：**

1. 实现严格 section/key 定位与 Serena args token 变换，拒绝模糊输入。
2. 实现 hooks JSON 保留未知顶层字段、只把 `hooks` 设为空对象。
3. 实现同卷临时文件、原子替换、内存回滚和 D 盘 evidence manifest。
4. 实现明确 legacy allowlist，不做目录级递归删除。
5. 实现 ACL 收敛与 read-only `Check`，仅允许当前用户、SYSTEM、Administrators 写入。
6. 运行新测试，再运行仓库全部 `tests/Test-*.ps1`。

## 任务 3：任务级评审与对抗性审查

**文件：**

- 新建：`.scratch/host-hook-remediation/review-task-2.md`

**步骤：**

1. 独立 reviewer 检查 spec 符合性、幂等性、失败回滚、路径边界和用户脏改动隔离。
2. 对抗性 reviewer 攻击 malformed TOML、ACL 漏洞、TOCTOU、旧脚本残留、配置半提交和错误回滚 evidence。
3. 只修复经复现或明确证明的问题，并重跑相关测试。

## 任务 4：真实主机 cutover

**文件：**

- 修改：`D:\Codex\.codex\config.toml`
- 修改：`D:\Codex\.codex\hooks.json`
- 退役：`D:\Codex\.codex\hooks\` 下九个明确 legacy 文件
- 新建：`D:\Codex\.codex\run-evidence\host-hook-remediation\<run-id>\`

**步骤：**

1. 运行 live `Check` 并保存只读基线。
2. 运行 live `Repair`；不得手工并行编辑同一文件。
3. 运行第二次 `Check` 和第二次 `Repair`，证明终态与幂等性。
4. 运行 `codex features list` 验证配置仍被当前 CLI 接受。
5. 从当前项目启动新的 Serena 进程/子代理，确认参数包含 `--project-from-cwd` 且不再固定 QQBot。
6. 验证 C/D Projectless 路径 File ID 一致，且 `Documents` Junction 仍指向 D。
7. 只读检查最新权限记录；不修改历史错误行。

## 任务 5：文档与最终验证

**文件：**

- 修改：`D:\Codex\.codex\docs\agent-guidance\host-runbook.md`
- 修改：`.scratch/host-hook-architecture-audit/report.md`
- 新建：`.scratch/host-hook-remediation/final-verification.md`

**步骤：**

1. 将 host runbook 从“四个 SessionStart guard”更新为“全局 custom lifecycle hooks 为 0 + 冷路径 reconciler”。
2. 记录 Projectless Junction 事实、mobile canary 边界和明确回滚入口。
3. 从手机新建一个任务完成 canary：首个 turn 为 `never + danger-full-access`，且测试窗口内 guard 已退役。
4. 再做一次固定基点 code review 和 live-state 对抗性检查。
5. 仅提交本任务拥有的 repo 文件；确认用户原有脏改动仍未被覆盖或暂存。
