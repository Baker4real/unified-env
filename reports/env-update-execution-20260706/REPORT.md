# 环境更新执行记录

生成时间：2026-07-06 17:30 Asia/Shanghai

## 执行边界

本轮按用户指定顺序执行：先 skill 更新，再处理有明确新版本的更新，最后进入需诊断项。依据 `docs/env-governance/d-drive-layout-and-migration-policy.md`，默认不自动运行 WinGet、Rustup 等全局管理器的真实更新命令，不修改 PATH，不迁移或删除目录；但对用户已明确授权的具体项，允许在留下验证证据和回滚路径后执行。

## 1. Skill 更新

### planning-with-files

- 来源：`https://github.com/OthmanAdi/planning-with-files`
- ref：`master`
- 最新 commit：`d71b3be47b62fe49d60fb2ede800e1907ebea3d9`
- active 版本：`3.4.0`
- 已合入：`scripts/check-complete.ps1`、`scripts/check-complete.sh` 的 `PLANNING_DISABLED=1` one-shot opt-out，以及 `SKILL.md` metadata version。
- 已保留本地 overlay：中文 slash-menu description、`D:/Codex` 示例路径、`${TMPDIR:-D:/Codex/tmp}` hash cache fallback。
- 已更新：`D:\Codex\.codex\skills\planning-with-files\SOURCE.md`、`D:\Codex\.codex\skills\.downloaded-skills-source-state.json`。

### frontend-design

- 来源：`https://github.com/nexu-io/open-design`
- ref：`main`
- 最新 commit：`40d8fad21b0934a8839f27ceeed1d5f14422f237`
- 结论：active skill 不做内容替换；保留中文 description overlay。`LICENSE.txt` 已存在。
- 已更新：`D:\Codex\.codex\skills\frontend-design\SOURCE.md`、统一 ledger。

### mattpocock-skills

- 来源：`https://github.com/mattpocock/skills`
- ref：`main`
- 最新 commit：`66f92b61f5b1434a1c7422f6fbd8efc5ee0c0214`
- 结论：与 ledger 一致，无 active skill 需要更新。

### Skill 验证

- unified ledger JSON 可解析。
- active skill coverage：`missing=0`，`duplicates=0`。
- `audit-skill-menu-i18n.cjs --json`：`findingCount=0`。
- `apply-skill-menu-i18n-overlay.cjs --dry-run`：仅 remote plugin catalog 有 1 个展示 overlay 候选，不是 active skill blocker。
- `skill_similarity.py pre-install --candidate planning-with-files`：top matches 全部 `likely-distinct`。
- `check-complete.ps1` 普通模式 exit 0；`PLANNING_DISABLED=1` exit 0。
- `check-complete.sh` 的 `PLANNING_DISABLED=1` exit 0。

## 2. 有明确新版本的更新

### CMake

- 当前：`4.3.2`
- 已安装：`4.3.3`
- 当前入口：`C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin\cmake.exe`
- 本轮动作：从 Kitware GitHub release 下载 `cmake-4.3.3-windows-x86_64.zip`，解压到 `D:\Codex\tools\cmake\4.3.3`，创建 `D:\Codex\tools\cmake\current` junction，并新增 `D:\Codex\_tools\cmake.cmd` shim 指向 D 盘新版。旧 WinGet/WinLibs CMake 保留在 PATH 后面作为回退。
- 验证：当前会话和新 PowerShell 进程均返回 `cmake version 4.3.3`，`where cmake` 首位为 `D:\Codex\_tools\cmake.cmd`。
- 回滚：删除 `D:\Codex\_tools\cmake.cmd`，按 `D:\Codex\.codex\run-evidence\env-governance\update-20260706\path-before-cmake-user-change.txt` 恢复 User PATH，必要时删除 `D:\Codex\tools\cmake\current` junction 和 `D:\Codex\tools\cmake\4.3.3`。

### Rust cargo/rustc

- 当前：`rustc 1.96.0`、`cargo 1.96.0`
- 已安装：`rustc 1.96.1`、`cargo 1.96.1`
- 管理器：`rustup 1.29.0`，`RUSTUP_HOME=D:\Codex\.rustup`，`CARGO_HOME=D:\Codex\.cargo`
- 当前 toolchain：`stable-x86_64-pc-windows-msvc (default)`
- 本轮动作：运行 `rustup update stable`，再运行 `rustup default stable`，未直接修改 `.cargo/.rustup` 内部文件。
- 验证：当前会话和新 PowerShell 进程均返回 `rustc 1.96.1`、`cargo 1.96.1`、`stable-x86_64-pc-windows-msvc (default)`。
- 回滚：如需回到旧固定 toolchain，可运行 `rustup default 1.96.0-x86_64-pc-windows-msvc`，前提是旧 toolchain 仍在本机 rustup toolchain 列表中。

## 3. 需先诊断项

### .NET

- 原问题：`where dotnet` 先命中 `C:\Program Files\dotnet\dotnet.exe`，该入口 Host `8.0.4` 且无 SDK；D 盘 `D:\Codex\tools\dotnet\dotnet.exe` 有 SDK `10.0.301`。
- 修复：用户随后授权改写 Machine PATH。管理员脚本已把 `D:\Codex\tools\dotnet` 插入到 `C:\Program Files\dotnet\` 前面，且保留 C 盘入口作为后备。由于当前 Codex 进程仍继承旧 process PATH 顺序，保留 `D:\Codex\tools\PowerShell\7.6.3\dotnet.cmd` 作为当前会话兜底；重启 Codex/新登录进程后可直接继承新的 Machine PATH。
- 验证：HKLM Machine PATH 现在顺序为 `D:\Codex\tools\dotnet` 在 `C:\Program Files\dotnet\` 前；当前会话和新 PowerShell 中 `dotnet --version` 返回 `10.0.301`。
- 回滚：管理员运行 `D:\Codex\.codex\run-evidence\env-governance\fix-net-python-wsl-20260706\rollback-machine-dotnet-path.ps1` 恢复 Machine PATH；删除 `D:\Codex\tools\PowerShell\7.6.3\dotnet.cmd` 可移除当前会话兜底。

### WSL

- `wsl.exe` 来源：`C:\WINDOWS\system32\wsl.exe`。
- `wsl --status`、`wsl --version`、`wsl -l -v` 输出乱码但均提示使用 `wsl.exe --install`，命令 exit 1。
- 需求判断：本机 host hooks、Codex/GSD 启动链路和当前 `统一环境` 项目没有发现实际依赖 WSL 的工作流；命中项主要是 inventory/readiness 把 WSL 当作盘点对象，以及源码仓库对 WSL 的跨平台支持代码。
- 判定：WSL 当前不可用，但本轮不“确实需要”。按用户条件，不安装、不启用、不初始化 WSL。

### Python 默认入口

- 原状态：`python` 默认是 `D:\Codex\tools\python313-official\python.exe`，版本 `3.13.14`；`UV_PYTHON` 也指向 3.13。
- 修复：User PATH 中默认 Python 目录切换为 `D:\Codex\tools\python314-official`；User 环境 `UV_PYTHON` 改为 `D:\Codex\tools\python314-official\python.exe`，`UV_PYTHON_PREFERENCE=system`；新增 `D:\Codex\tools\PowerShell\7.6.3\python.cmd`、`python3.cmd`、`python3.14.cmd`、`python314.cmd`，均转发到 3.14.6；`codex-provider-stability-guard.ps1` 的 Python runtime 从 3.13 切到 3.14.6，并更新 host runbook。
- 验证：当前会话和新 PowerShell 中 `python --version`、`python3.14 --version` 均返回 `Python 3.14.6`；`python -c` 显示 executable 为 `D:\Codex\tools\python314-official\python.exe`；`codex-provider-stability-guard.ps1 -Json` 返回 `ok: true`；`uv run --python D:\Codex\tools\python314-official\python.exe ...` 可运行 3.14.6。
- 注意：`uv python find 3.14` 在当前 uv 发现机制下仍未自动找到系统 3.14；需要使用显式路径或已配置的 Serena MCP 环境。这个限制已记录，不影响默认 `python`/hook/Serena 显式路径。

### CodeGraph

- 当前入口：`D:\Codex\tools\codegraph\current\bin\codegraph.cmd`
- 当前版本：`1.2.0`
- `current` 是普通目录，不是 symlink/junction。
- 本地包名：`@colbymchenry/codegraph`，版本 `1.2.0`。
- npm registry：`@colbymchenry/codegraph` dist-tag `latest` 为 `1.2.0`。
- 判定：来源与当前 latest 可对应，无需更新。
- 本轮动作：保持不动。

## 剩余建议

1. CMake 和 Rust 已按可回滚路径安装并验证。
2. .NET 默认入口已修到 D 盘 SDK；Python 默认入口已切到 3.14.6；WSL 判断为当前不确实需要，未安装；CodeGraph 已确认当前 latest，可保持不动。
3. 若要进一步整洁，下一步应是 PATH 来源 dry-run，而不是删除或迁移目录。

## 更新证据

- 证据目录：`D:\Codex\.codex\run-evidence\env-governance\update-20260706`
- CMake zip SHA-256：`935ADE9E5E8723583C07F44C5592CEA2A1C8F65C56CA7E07B34C025C880E0BD6`
- 更新前证据：`pre-update.txt`
- 更新后证据：`post-update-current-process.txt`
- 第三项诊断证据：`third-phase-diagnosis.txt`
- .NET/Python/WSL 修复证据：`fix-net-python-wsl-20260706\post-fix-validation.txt`
- Machine PATH dotnet 修复证据：`fix-net-python-wsl-20260706\admin-machine-path-before.txt`、`admin-machine-path-after.txt`、`final-machine-path-dotnet-validation.txt`
- User PATH 回滚记录：`path-before-cmake-user-change.txt`

## 外部来源

- CMake official download: `https://cmake.org/download/`
- Rust official release blog: `https://blog.rust-lang.org/releases/latest/`
- CodeGraph npm package: `https://www.npmjs.com/package/@colbymchenry/codegraph`
