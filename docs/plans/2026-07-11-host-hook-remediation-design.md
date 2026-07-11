# 本机 Codex 钩子收敛设计

日期：2026-07-11

## 目标

从第一性原理出发，钩子只应承载必须发生在对应生命周期、且该生命周期真正拥有的行为。当前静态配置、Projectless 路径兼容和权限持久化都不属于每个任务的 `SessionStart`，因此最终状态为：

- 用户级自定义 lifecycle hooks 数量为 0；`[features].hooks = true` 保留，供真正的项目或 skill hooks 使用。
- Serena 使用 `--project-from-cwd`，不再把所有任务固定到 QQBot 项目。
- Projectless 保留 Codex 原生的 `C:\Users\<user>\Documents\Codex` 逻辑路径；本机 `Documents` Junction 已保证实际数据落在 D 盘，不再改写应用私有全局状态。
- mobile/desktop 权限由正式的 `approval_policy`、`sandbox_mode` 和 App Server 请求参数拥有；不再扫描或改写 SQLite、heartbeat 私有状态。
- 静态配置只通过显式、可测试、可回滚的冷路径命令维护，不注册新的计划任务或启动 guard。

## 唯一公共接口

`scripts/Invoke-CodexHostHookReconciliation.ps1` 暴露两个模式：

```powershell
./scripts/Invoke-CodexHostHookReconciliation.ps1 -Mode Check -Json
./scripts/Invoke-CodexHostHookReconciliation.ps1 -Mode Repair -Json
```

该接口只拥有以下状态：

1. `config.toml` 中 Serena 的项目选择参数、正式权限默认值、`features.hooks` 与 `features.unified_exec`。
2. `config.toml` 中已失效的用户级 hook trust state。
3. `hooks.json` 中的用户级 lifecycle hook 注册。
4. 旧 hook implementation 的归档退役，以及 live hook surface 的 ACL。

它明确不拥有 `.codex-global-state.json`、`state_5.sqlite`、Store AppX、Serena 全局 YAML、IFEO、Store/OSD 计划任务或代理服务本身。

## 修复事务

`Repair` 必须遵守以下顺序：

1. 严格解析并验证输入；未知或重复关键 section/key 时拒绝写入。
2. 在 `D:\Codex\.codex\run-evidence\host-hook-remediation\<run-id>` 保存原文件、旧 implementation、哈希与 ACL。
3. 同卷临时文件写入，原子替换 `config.toml` 与 `hooks.json`，随后重新解析验证。
4. 失败时用内存快照原子恢复已修改文件。
5. 注册清空后，才退役明确 allowlist 中的旧脚本。
6. 将 `hooks.json` 和 hooks 目录收紧为仅当前用户、SYSTEM、Administrators 可写。
7. 再运行 `Check`；第二次 `Repair` 必须幂等。

## 成功标准

- `hooks.json` 可解析，`hooks` 是空对象。
- `config.toml` 中 Serena 恰好包含一个 `--project-from-cwd`，不存在固定 `--project` / `--project-file`。
- 正式权限默认值仍为 `never + danger-full-access`，`hooks` 和 `unified_exec` feature 仍开启。
- 不存在 `[hooks]` / `[hooks.state...]` 旧 trust state。
- 九个旧自定义 hook 文件已归档并从 live hooks 目录退役。
- hooks 目录与 `hooks.json` 不再允许 `Authenticated Users` 等宽泛主体写入。
- Projectless 的 C/D 别名 File ID 一致，证明逻辑 C 路径实际落盘 D。
- 最新 mobile/desktop 线程无新增权限漂移；全新 mobile canary 的首个 turn 仍为 `never + danger-full-access`。

## 回滚

每次真实修复只使用当次 evidence 目录。回滚时先恢复 `config.toml`、`hooks.json` 和旧 implementation，再恢复记录的 ACL；不得从更早的“一次性备份”猜测当前前置状态。
