# 本机环境更新与整洁审计报告

生成时间：2026-07-06

本报告从第一性原理出发，只读梳理本机 Codex/GSD/项目环境中 skills、工具链、依赖、缓存、PATH、备份和更新候选。审计过程中未安装、未更新、未删除、未迁移、未修改 PATH 或系统配置。

## 第一性原理边界

目标不是“全部升级到最新”，而是保持环境可用、可追溯、可回滚、可持续维护。

核心约束：

- 活跃工具、skills、插件缓存、账号状态、项目本地环境和运行证据不能混作普通垃圾清理。
- 更新必须能说明来源、入口、影响范围、验证方式和回滚路径。
- 项目本地 `.venv`、`node_modules`、服务状态和 GSD 项目环境默认保持隔离。
- 真实迁移、更新入口切换、PATH 修改、删除或重建前，必须重新生成最新 inventory/dry-run，并取得逐项显式授权。

## 总体结论

当前没有适合直接自动执行的全局更新或清理项。主机核心链路总体可用，Codex/Serena/CodeGraph/uv/Node/npm/Git/gh/sqlite3 等主链路已验证。

明确可作为后续独立候选的项：

- `CMake`：本机 `4.3.2`，官方 GitHub latest 为 `4.3.3`；当前入口在 WinGet/WinLibs 包目录，必须通过官方/包管理器路径规划，不能手搬目录。
- `cargo/rustc`：本机 `1.96.0`，上游 latest 为 `1.96.1`；只能通过 `rustup` 官方机制评估，不能直接改 `D:\Codex\.cargo` 或 `D:\Codex\.rustup`。
- skills source group staged refresh：`mattpocock-skills`、`nexu-open-design-frontend-design`、`planning-with-files` 远端 HEAD 已变化；需要按 `skill-install-guard` + `writing-great-skills` staged diff、重放本地 overlay 后再决定是否更新。

必须先诊断、不建议直接更新：

- `.NET`：`C:\Program Files\dotnet\dotnet.exe` 存在但 inventory 版本探测失败；子审查显示 Host `8.0.4`、runtime `6.0.16/8.0.4`、未列出 SDK。它是系统安装器目录，先确认项目需求和 SDK/runtime 状态。
- `wsl`：系统组件，当前版本/status 输出不正常或提示安装；只建议诊断启用状态，不由本项目直接更新。
- `Python` 默认入口：全局 `python` 是 `3.13.14`，本机也有 `3.14.6`，Serena 使用 `3.14.6`。这是默认解释器策略问题，不是直接升级问题。
- `CodeGraph`：本机 `1.2.0` 可用，但公开权威 latest 源未稳定确认；暂不建议更新。

保持不动：

- `codex-cli 0.142.5`、`node v26.4.0`、`npm 11.18.0`、`uv 0.11.26`、`PowerShell 7.6.3`、`Git 2.55.0.windows.2`、`gh 2.96.0`、`sqlite3 3.53.3`、`Serena 1.5.3`、`anthropic 0.116.0`、`Ninja 1.13.2` 均与权威源核对为当前或无需动。

## Skills 审计

active skills 治理总体健康：

- `D:\Codex\.codex\skills` 下 active skill 含 `.system/*` 共 136 个，全部有同目录 `SOURCE.md`。
- `D:\Codex\.codex\skills\.downloaded-skills-source-state.json` 覆盖 active skills：missing `0`，duplicate `0`，extra active 引用 `0`。
- 8 个 retained-local/unresolved skills 有 ledger 记录，当前保留合理。
- 菜单中文化审计健康：`audit-skill-menu-i18n.cjs --json` 返回 `findingCount: 0`。

可建议但需授权：

- 对 3 个远端 HEAD 已变化的 source group 做 staged refresh：先下载/暂存远端版本，比较具体 skill diff，重放中文菜单、第一性原理、对抗审查、D 盘路径、SOURCE.md、ledger 等本地 overlay。
- `apply-skill-menu-i18n-overlay.cjs --dry-run` 显示 remote plugin catalog 有 1 个展示 overlay 可重放。它不是 active skill root，但可作为展示一致性维护项。
- `check-codex-iq`、`frontend-design`、`my-coffee`、`repo-clean-closeout` 的 `SOURCE.md` 未显式提到统一 ledger 路径；ledger 覆盖正常，所以只是元数据一致性改进，不是阻断项。

必须阻止：

- 不能把远端 HEAD 变化直接等同于可覆盖 active skills。
- 不能恢复 ledger 中 `deleted-by-user` 的 source group，例如 `hyperframes`、`remotion-skills`，除非用户重新授权。
- 不能绕过 `writing-great-skills` 和 `skill-install-guard` 做批量 skill 更新。

## 工具链与依赖

| 项 | 当前状态 | 判断 | 下一步 |
| --- | --- | --- | --- |
| Codex CLI | `0.142.5` | 当前 latest | 保持 |
| Node | `v26.4.0` | 当前 current latest | 保持 |
| npm | `11.18.0` | 当前 latest | 保持 |
| uv | `0.11.26` | 当前 latest | 保持 |
| PowerShell | `7.6.3` | 当前 latest | 保持 |
| Git | `2.55.0.windows.2` | 当前 latest | 保持 |
| gh | `2.96.0` | 当前 latest | 保持 |
| sqlite3 | `3.53.3` | 当前 latest | 保持 |
| Serena | `1.5.3` | 当前 latest | 保持 |
| anthropic | `0.116.0` | 当前 latest | 保持，保留 Serena override 说明 |
| CMake | `4.3.2` | 落后于 `4.3.3` | 单独授权后通过官方/WinGet 路线处理 |
| Ninja | `1.13.2` | 当前 latest | 保持 |
| cargo/rustc | `1.96.0` | 落后于 `1.96.1` | 单独授权后用 `rustup` 评估 |
| .NET | Host/runtime 存在但 inventory 探测失败 | 需诊断 | 先确认项目需求和 SDK/runtime |
| WSL | 系统组件，状态不明确 | 需诊断 | 只诊断，不直接更新 |
| Python | `python` 默认 3.13.14，Serena 使用 3.14.6 | 策略问题 | 不直接切默认入口 |
| CodeGraph | `1.2.0` 可用 | 官方 latest 不确定 | 暂不更新 |

## PATH 与入口整洁

当前 readiness 报告显示：

- PATH 总入口：35。
- C 盘入口：19。
- D 盘入口：15。
- 缺失入口：1，`D:\Codex\tools\dotnet-home\.dotnet\tools`。
- 重复入口：1 类，`D:\Codex\tools\PowerShell\7.6.3` 出现 3 次。
- 失效项目本地环境 PATH 入口：0。

建议：

- 重复 PowerShell 入口可单独开 PATH 整理 dry-run；真实修改前必须确认 User/Machine/Process scope 来源和回滚字符串。
- 缺失 `.dotnet\tools` 入口先确认是否还有工具依赖；不能作为迁移副作用直接删除。
- C 盘系统目录、WinGet 包目录、WindowsApps 和官方安装器目录不直接搬迁。

## 项目本地环境

项目本地环境审查项 6 个，其中长期服务或状态敏感项目 4 个。全部默认保留，不跨项目合并，不进入共享环境。

可重建线索只表示存在锁文件或配置线索，不等于授权重建。任何重建都必须进入对应项目自己的 issue，并先确认停启、状态恢复、锁文件、测试和回滚。

## 备份、缓存与整洁

当前备份保留 dry-run：

- 保留规则候选：0。
- 人工审查项：259 个，约 4373.92 MB。
- 最大人工审查项是 `D:\Codex\.codex\run-evidence`，约 3741.51 MB。

判断：

- 当前没有可按严格规则直接清理的备份候选。
- `run-evidence` 体积大，但包含跨项目证据、回滚、审计材料，不能按体积直接删除。
- runtime/shared-cache、account backup、旧 skill 备份、全局临时 staging 都必须单独 allowlist 审查。

## 推荐执行顺序

1. 不做任何自动全局更新或清理。
2. 若要继续更新，优先开两个小候选：`CMake 4.3.3` 更新方案、`rustup 1.96.1` 更新方案。
3. 若要继续 skill 维护，先对 3 个变更 source group 做 staged diff 报告，不直接覆盖 active root。
4. 若要继续整洁，优先做 PATH 重复入口 dry-run，然后再考虑 `run-evidence` 保留策略设计；不要直接删除。
5. `.NET`、WSL、Python 默认入口先诊断，不进入更新。

## 已执行验证

- 刷新 `reports/env-inventory/`。
- 刷新 `reports/env-update-readiness/`。
- 刷新 `reports/project-local-env-review/`。
- 刷新 `reports/stale-path-entry-cleanup-dry-run/`。
- 生成 `reports/backup-retention-dry-run-current/`。
- `codex doctor --json` 返回 `overallStatus: ok`。
- 子代理三路只读审查完成：环境治理、skill ledger、工具版本。

## 授权门槛

以下任一动作都需要新的明确授权：

- 安装、更新、删除、迁移任何工具或依赖。
- 修改 PATH、环境变量、hook 或 Codex/Serena/CodeGraph 配置。
- 刷新 active skills 或重放 plugin catalog overlay。
- 删除或压缩 `run-evidence`、备份、缓存、plugin cache、account backup。
- 重建任何项目本地 `.venv` 或 `node_modules`。
