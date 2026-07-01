# 统一更新准备报告

生成时间：2026-07-01T15:12:40.0109602+08:00

> 只读报告：本报告不会执行 winget、Scoop、uv、npm、Cargo、Rustup 或任何其他更新命令。

## 摘要

- 工具项数量：13
- 高风险对象：2
- PATH 总入口：31
- PATH C 盘入口：17
- PATH D 盘入口：13
- PATH 缺失入口：1
- 失效项目本地环境 PATH 入口：0

## 工具更新准备

| 工具 | 位置类型 | 当前入口 | 推荐更新入口 | 建议动作 | 风险 | 不自动更新 |
| --- | --- | --- | --- | --- | --- | --- |
| python | D 盘 | D:\Codex\tools\python313-official\python.exe | 官方 Python 安装器、uv python 或 D 盘工具根策略 | 当前已在 D 盘；后续优先统一 Python 管理策略。 | 低 | 是 |
| uv | 用户目录 | C:\Users\14224\.local\bin\uv.exe | uv self update 或重装到 D 盘工具根 | 先确认当前入口是否应迁到 D 盘；本项目只生成建议，不执行 uv 更新。 | 中 | 是 |
| node | 系统安装目录 | C:\Program Files\nodejs\node.exe | 官方 Node 安装器、mise/fnm/nvm-windows 迁移方案或 winget | 不要直接搬 C 盘安装目录；后续用独立 issue 选择 Node 管理器。 | 中 | 是 |
| npm | 系统安装目录 | C:\Program Files\nodejs\npm.ps1 | 随 Node 一起管理 | 跟随 Node 管理策略；不要单独改 npm 入口。 | 中 | 是 |
| git | D 盘 | d:\Program Files\Git\cmd\git.exe | Git for Windows 安装器或现有 D 盘安装策略 | 当前已在 D 盘；后续可单独确认 Git 更新入口。 | 低 | 是 |
| cargo | D 盘 | D:\Codex\.cargo\bin\cargo.exe | rustup 或官方 Rust 安装方式 | 当前入口在系统安装目录；不要直接搬目录。 | 中 | 是 |
| rustc | D 盘 | D:\Codex\.cargo\bin\rustc.exe | rustup 或官方 Rust 安装方式 | 当前入口在系统安装目录；不要直接搬目录。 | 中 | 是 |
| dotnet | 系统安装目录 | C:\Program Files\dotnet\dotnet.exe | .NET 官方安装器、winget 或已存在 D 盘 dotnet 策略 | 当前探测失败或入口位于系统安装目录；先诊断再更新。 | 高 | 是 |
| cmake | WinGet 包目录 | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin\cmake.exe | WinGet package 或 D 盘工具根重装 | 当前来自 WinGet 包目录；不要直接搬目录。 | 中 | 是 |
| ninja | WinGet 包目录 | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin\ninja.exe | WinGet package 或 D 盘工具根重装 | 当前来自 WinGet 包目录；不要直接搬目录。 | 中 | 是 |
| wsl | Windows 系统目录 | C:\WINDOWS\system32\wsl.exe | Windows 功能 / WSL 官方机制 | 系统组件，不由本项目自动更新。 | 高 | 是 |
| pwsh | D 盘 | D:\Codex\tools\PowerShell\7.6.3\pwsh.exe | D 盘 PowerShell 工具根策略 | 当前已在 D 盘；保持现有 host 策略，不自动更新。 | 低 | 是 |
| powershell | 未解析 | 未解析（inventory 未返回路径） | 当前 PowerShell 解析入口 | 仅记录入口，不自动更新。 | 低 | 是 |

## PATH 整理建议

- 保留系统目录和官方安装器目录，不直接搬迁。
- 对重复 PATH 入口单独建立清理 issue。
- 对 C 盘工具入口先生成更新/重装方案，再决定是否切到 D 盘。
- 对 D 盘 PATH 入口优先保留已验证工具根；如同一工具有多个 D 盘入口，再单独去重。
- 对失效 `.venv`、`venv` 或 `node_modules` PATH 入口先确认项目归属，再单独清理 PATH，不重建依赖目录。
- 对缺失 PATH 入口先确认是否仍有工具依赖，再决定删除。

### 重复 PATH 入口

| 路径 | 次数 |
| --- | --- |
| D:\Codex\.cargo\bin | 2 |

### 缺失 PATH 入口

| 序号 | 路径 | 项目本地环境入口 | 建议动作 |
| --- | --- | --- | --- |
| 30 | D:\Codex\tools\dotnet-home\.dotnet\tools | 否 | 先确认工具是否仍需要该入口；不得作为迁移副作用直接删除。 |

## 高风险对象

| 工具 | 路径 | 原因 |
| --- | --- | --- |
| dotnet | C:\Program Files\dotnet\dotnet.exe | 当前探测失败或入口位于系统安装目录；先诊断再更新。 |
| wsl | C:\WINDOWS\system32\wsl.exe | 系统组件，不由本项目自动更新。 |

## 策略

- 本项目只生成更新准备报告，不执行任何更新命令。
- 系统组件、MSI/官方安装器、WinGet 包目录和 Windows 功能不直接搬迁。
- D 盘工具入口优先保持现有策略，更新前需单独确认。
- 失效项目本地环境 PATH 入口只生成清理建议，不代表可以删除或重建对应 `.venv`、`node_modules`。
- 高风险对象必须进入人工审查，不能进入自动更新候选。
