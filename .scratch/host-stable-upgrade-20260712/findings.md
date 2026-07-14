# 调查发现

## 当前事实

- 工作目录：`D:\Codex\projects\统一环境`。
- Active Skills 根：`D:\Codex\.codex\skills`。
- Skill 统一来源台账：`D:\Codex\.codex\skills\.downloaded-skills-source-state.json`。
- Plugin cache 视为只读镜像；必须从插件来源或官方安装机制升级。
- `mattpocock/skills` 的 `skills/in-progress/**` 不属于稳定可升级内容。

## Inventory 结论

- Active Skills 共 61 个，统一台账覆盖唯一且完整；19 个来源组均已检查。
- MCP 包括 CodeGraph、Serena、vendor `node_repl` 和远程 my-coffee；只有 CodeGraph 需要独立升级。
- 7 个启用插件均已通过官方 CLI 重装/刷新；bundled Chrome 与 Computer Use 已切到 Store 稳定包版本。
- Host 受管依赖按真实命令入口核验；vendor runtime 保持官方管理，不逐包改写。

## 已确认的插件与主机状态

- Codex Store 包 `26.707.3748.0` 与 Store catalog 最新稳定版一致，AppX 状态 `Ok`，WinHTTP 为 direct。
- 已启用插件共 7 个：documents、spreadsheets、presentations、chrome、computer-use、gmail、github；它们与当前配置的 vendor marketplace snapshot 版本一致。
- 三个 marketplace 都是 Codex/vendor 本地 snapshot，不是用户 Git marketplace；插件缓存是只读镜像，不能用 `marketplace upgrade` 强刷。
- Codex Desktop bundled workspace dependencies 版本为 `26.709.11516`，由 vendor runtime 管理，不逐包改写其 C 盘缓存。

## 已确认的 MCP 与依赖状态

- CodeGraph：1.2.0，可升级到 npm stable 1.4.1；使用自带 Node 24，不能切到系统 Node 26。
- Serena：1.5.3，已是 PyPI stable；active venv `uv pip check` 通过，保留 `anthropic>=0.59.0` 本地 override。
- uv：0.11.26，可升级到 0.11.28。
- Agent Reach：1.5.0，官方 `check-update` 判定已最新。
- node_repl 属于 Codex Desktop vendor runtime；my-coffee 是远程 HTTPS MCP，均无独立本地升级动作。
- Host-hook reconciler 的真实实现入口在本项目 `scripts/`，当前 `Check` 为 `ok=true, driftCount=0`。

## Skills 来源变化初筛

- 统一台账包含 19 个来源组；其中 GitHub 来源里 mattpocock、hyperframes、khazix、remotion、vercel-labs、planning-with-files、ui-ux-pro-max、open-design 等远端 commit 已前进，需进入 staged merge。
- mattpocock 的 `skills/in-progress/**` 继续排除，不安装、不刷新进入 active root。

## 已完成的升级与修复

- CodeGraph 已升级到 1.4.1；对 4 个曾有 interrupted references 的项目执行 `codegraph sync`，均完成。
- uv active D-root 已升级到 0.11.28；`uv self update` 的旧 C 盘 metadata 冲突通过真实 `uv tool upgrade uv` 机制修复。
- Node 26.5.0 官方 ZIP 已用官方 SHASUMS256 校验，npm 12.0.1 兼容 Node 26；D 盘命令 wrapper 已切到 26.5.0/12.0.1，保留仍在运行的旧 Vite 进程，不擅自终止。
- D 盘 npm-global 已升级：mcporter 0.12.3、opencli 1.8.6、undici 8.7.0；opencli postinstall 首次被 npm 12 安全策略拦截，随后使用 package-scoped `--allow-scripts=@jackwener/opencli` 完成并验证。
- 诊断并修复 IFEO router 漏认官方 Store `ChatGPT.exe` 的回归：只允许 `C:\Program Files\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe`，同名非官方路径仍拒绝；红绿测试与 IFEO verify 均通过，受管源/live 哈希一致。
- router live 日志已出现官方 `ChatGPT.exe` 转发成功；bundled marketplace 已从 Store 26.707.3748.0 官方资源刷新，Chrome 与 Computer Use 已安装为 26.707.31428。
- 已恢复 5 个 `.system` skill 的 `SOURCE.md` companion provenance，并同步统一台账。

## 已准备的 Skill 稳定候选

- 单独候选：my-coffee 0.8.4、a-stock-data v3.4.0、planning-with-files v3.4.1、find-skills v1.5.16、aihot 077f63b。
- Matt 稳定候选：v1.1.0，只更新 ask-matt、implement、setup-matt-pocock-skills、handoff；to-prd 和 to-issues 保留，不自动安装 promoted 但当前 inactive 的 wayfinder。
- 9 个候选均已写入 active root；旧目录与完整前置快照保存在本次 evidence 根下。

## 最终验收

- Skill strict resource closure：61 active，findings 0、missing SOURCE 0、ledger drift 0。
- 中文菜单：finding 0、warning 0、apply dry-run 0；退役菜单 finding 0。
- Planning 路径测试：3/3；D 盘 session fallback 生效。
- CodeGraph 1.4.1：全量项目 sync 通过；新进程 MCP tools/list 与真实查询通过。
- Router：source/live 哈希一致，IFEO 验证和官方/伪造路径红绿测试通过。
- 唯一加载态要求：重启 Codex Desktop，使当前任务重新建立被升级动作关闭的 CodeGraph stdio，并加载新插件/skill 快照。
