---
generationId: b5ef5bc7-2492-421c-a883-fd259cabe9d9
sourceJsonSha256: c613f2a0d703d78d6517c8a5bdfda1239ef6944d8063326af6131e12f52f67ca
---
# 统一更新准备报告

生成时间：2026-07-18T17:35:14.2821773+08:00

> 只读报告：本报告不会执行 winget、uv、npm、Cargo、Rustup 或其他更新命令。

## 摘要

- Inventory schema：3
- PATH 来源作用域：process
- PATH 作用域完整：True
- 工具项数量：15
- 高风险对象：4
- PATH 总入口：37
- PATH C 盘入口：25
- PATH D 盘入口：8
- PATH 缺失事实：4

## 工具更新准备

| 工具 | 位置类型 | 事实归属 | 当前入口 | 官方更新入口 | 条件策略建议 | 风险 | 人工审查 | 不自动更新 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| python | D 盘 | shared-tool | D:\Codex\tools\PowerShell\7.6.3\python.cmd | Python 官方安装器或 uv python | 位于明确的 D 盘共享工具根；保持现有位置策略，后续按工具生态单独审查更新。 | 低 | 否 | 是 |
| py | D 盘 | shared-tool | D:\hermes-data\.npm-global\py.exe | Python 官方安装器 | 位于明确的 D 盘共享工具根；保持现有位置策略，后续按工具生态单独审查更新。 | 低 | 否 | 是 |
| uv | D 盘 | shared-tool | D:\hermes-data\.local\bin\uv.exe | uv self update 或 uv 官方安装方式 | 位于明确的 D 盘共享工具根；保持现有位置策略，后续按工具生态单独审查更新。 | 低 | 否 | 是 |
| node | 系统安装目录 | system-installer | C:\Program Files\nodejs\node.exe | Node.js 官方安装器或已批准的版本管理器 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 | 中 | 是 | 是 |
| pnpm | 用户目录 | user-profile | C:\Users\WINDOWS\.cache\codex-runtimes\codex-primary-runtime\dependencies\bin\fallback\pnpm.cmd | 该工具的官方更新机制 | 工具归属用户目录；先确认包管理器和 owner，再选择官方更新机制。 | 高 | 是 | 是 |
| winget | 用户目录 | windows-system | C:\Users\WINDOWS\AppData\Local\Microsoft\WindowsApps\winget.exe | 该工具的官方更新机制 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 存在 reparse 证据；必须确认祖先、目标与 owner。 | 高 | 是 | 是 |
| git | 系统安装目录 | system-installer | C:\Program Files\Git\cmd\git.exe | Git for Windows 官方安装器 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 | 中 | 是 | 是 |
| cargo | D 盘 | unknown | D:\Dev\.cargo\bin\cargo.exe | rustup 或 Rust 官方安装器 | 工具归属未知；先确认真实 launcher、runtime 与管理机制。 | 高 | 是 | 是 |
| rustc | D 盘 | unknown | D:\Dev\.cargo\bin\rustc.exe | rustup 或 Rust 官方安装器 | 工具归属未知；先确认真实 launcher、runtime 与管理机制。 | 高 | 是 | 是 |
| go | 系统安装目录 | system-installer | C:\Program Files\Go\bin\go.exe | 该工具的官方更新机制 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 | 中 | 是 | 是 |
| dotnet | 系统安装目录 | system-installer | C:\Program Files\dotnet\dotnet.exe | .NET 官方安装器或官方包管理入口 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 | 中 | 是 | 是 |
| docker | 系统安装目录 | system-installer | C:\Program Files\Docker\Docker\resources\bin\docker.exe | 该工具的官方更新机制 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 | 中 | 是 | 是 |
| wsl | Windows 系统目录 | windows-system | C:\WINDOWS\system32\wsl.exe | Windows 功能和 WSL 官方机制 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 | 中 | 是 | 是 |
| pwsh | D 盘 | shared-tool | D:\Codex\tools\PowerShell\7.6.3\pwsh.exe | PowerShell 官方发布或已批准的包管理器 | 位于明确的 D 盘共享工具根；保持现有位置策略，后续按工具生态单独审查更新。 | 低 | 否 | 是 |
| powershell | Windows 系统目录 | windows-system | C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe | Windows 系统维护机制 | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 | 中 | 是 | 是 |

## PATH 整理建议

- 仅基于完整的 Process PATH scope 生成清理建议。
- 保留系统目录和官方安装器目录，不直接搬迁。
- 对重复或缺失 PATH 入口单独建立清理 issue，不作为迁移副作用删除。

### 缺失 PATH 入口

| 序号 | 路径 | 项目本地环境入口 | 建议动作 |
| --- | --- | --- | --- |
| 30 | C:\Users\WINDOWS\.dotnet\tools | 否 | 先确认工具是否仍需要该入口；不得作为迁移副作用直接删除。 |
| 31 | D:\Codex\.codex\tmp\dotnet-home\.dotnet\tools | 否 | 先确认工具是否仍需要该入口；不得作为迁移副作用直接删除。 |
| 32 | C:\Users\WINDOWS\AppData\Roaming\npm | 否 | 先确认工具是否仍需要该入口；不得作为迁移副作用直接删除。 |
| 33 | D:\Codex\.dotnet\.dotnet\tools | 否 | 先确认工具是否仍需要该入口；不得作为迁移副作用直接删除。 |

## 高风险对象

| 工具 | 路径 | 原因 |
| --- | --- | --- |
| pnpm | C:\Users\WINDOWS\.cache\codex-runtimes\codex-primary-runtime\dependencies\bin\fallback\pnpm.cmd | 工具归属用户目录；先确认包管理器和 owner，再选择官方更新机制。 |
| winget | C:\Users\WINDOWS\AppData\Local\Microsoft\WindowsApps\winget.exe | 位于 Windows 系统或安装器管理范围；只使用官方机制，不直接搬目录。 存在 reparse 证据；必须确认祖先、目标与 owner。 |
| cargo | D:\Dev\.cargo\bin\cargo.exe | 工具归属未知；先确认真实 launcher、runtime 与管理机制。 |
| rustc | D:\Dev\.cargo\bin\rustc.exe | 工具归属未知；先确认真实 launcher、runtime 与管理机制。 |

## 策略

- 本项目只生成更新准备报告，不执行任何更新命令。
- 位置、归属与探测结论只由共享条件策略生成；工具专属层只命名官方更新入口。
- 系统组件、安装器管理目录和 WinGet 包只通过官方机制更新，不直接搬迁。
- 项目本地环境、vendor runtime、未知归属或探测失败必须人工审查。
- 只有完整的 Process PATH scope 才能生成缺失、重复或失效入口清理建议。