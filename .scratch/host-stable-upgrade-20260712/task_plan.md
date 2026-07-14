# 本机 Codex 扩展与依赖稳定版升级计划

## 目标

把本机当前已安装、可追溯且在授权范围内的 Codex 插件、Skills、MCP 服务及其运行依赖升级到各自最新稳定版本，同时保留本地 overlay、D 盘布局、官方产物边界和可回滚性。`mattpocock/skills` 的 `skills/in-progress/**` 明确不升级、不安装。

## 阶段

- [x] 建立真实 inventory，识别来源、当前版本、最新稳定版和排除项。
- [x] 形成逐类升级与回滚方案，备份关键配置和版本清单。
- [x] 升级插件与可安全自动升级的运行依赖。
- [x] 按来源逐个升级 eligible Skills，重放本地 overlay，并跳过 in-progress 库。
- [x] 升级 MCP 服务及其依赖，保持现有 D 盘 wiring。
- [x] 运行闭包、依赖、MCP、插件和主机健康验证。
- [x] 启用多子代理进行对抗性审查，修复兼容性、遗漏和状态漂移。
- [x] 汇总版本、跳过项、残余风险和回滚证据。

## 硬边界

- 只采用最新稳定版，不采用 alpha、beta、rc、nightly 或 upstream in-progress 草稿。
- 不恢复 GSD workflow、skills、agents 或 runtime routing。
- 不用本地自构建产物替换官方/vendor runtime。
- 所有新产物、备份、缓存和证据写入 D 盘。
- Skills 更新必须保留 `SOURCE.md`、统一来源台账、本地中文菜单 overlay 和资源闭包。
- 未确认来源或无法安全重放本地 overlay 的组件保持不变，并记录为 blocked/source-unresolved。

## 错误记录

| 错误 | 尝试 | 处理 |
|---|---:|---|
| PowerShell inventory 命令在 `foreach` 后直接接管道导致 `empty pipe element` 解析错误 | 1 | 改为先收集到数组，再统一格式化输出。 |
| 将 host-hook reconciler 误从 live `hooks` 目录调用，入口不存在 | 1 | 依据项目/主机边界定位到 `D:\Codex\projects\统一环境\scripts\Invoke-CodexHostHookReconciliation.ps1`；真实 Check 为 `ok=true, driftCount=0`，不是环境损坏。 |
| 查询 ChatGPT.exe CIM 信息时再次在 `if/else` 后直接接管道，触发 PowerShell `empty pipe element` | 1 | 停止复用该写法，改为先赋值 `$result` 再 `Format-List`。 |
| 第一次 Skill 目录交换命令在 `foreach` 后直接接管道，再次触发 `empty pipe element` | 1 | 改为 `$results` 数组后成功完成 9 个 active skill 的原子交换。 |
| 升级 CodeGraph 后当前任务持有的旧 MCP stdio 连接关闭 | 1 | 用新进程完成 MCP initialize、tools/list 和真实查询；当前 Codex 任务需重启应用后重新建立内置连接。 |
