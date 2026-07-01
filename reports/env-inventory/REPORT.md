# 本机环境资产盘点报告

生成时间：2026-07-01T15:12:39.8280663+08:00

> 本报告由只读盘点脚本生成。脚本未移动文件、未修改环境变量、未执行软件更新。

## 摘要

- 工具探测数量：33
- 已存在目录数量：9
- 项目级审查环境数量：6
- 本地环境相关发现数量：11
- 迁移候选数量：0
- 人工审查项数量：11

## 绝不自动迁移

| 路径 | 原因 |
| --- | --- |
| C:\Windows | 系统目录，绝不自动迁移 |
| C:\Program Files | MSI/系统级安装目录，绝不直接搬迁 |
| C:\Program Files (x86) | MSI/系统级安装目录，绝不直接搬迁 |
| C:\ProgramData | 服务和机器级状态常驻位置，仅按官方迁移流程处理 |
| C:\Users | 不批量迁移用户目录或 AppData |

## 工具探测

| 工具 | 是否存在 | 探测成功 | 路径 | 版本输出 | 错误 |
| --- | --- | --- | --- | --- | --- |
| python | True | True | D:\Codex\tools\python313-official\python.exe | Python 3.13.14 |  |
| py | False | False |  |  |  |
| uv | True | True | C:\Users\14224\.local\bin\uv.exe | uv 0.11.7 (9d177269e 2026-04-15 x86_64-pc-windows-msvc) |  |
| pipx | False | False |  |  |  |
| poetry | False | False |  |  |  |
| conda | False | False |  |  |  |
| mamba | False | False |  |  |  |
| node | True | True | C:\Program Files\nodejs\node.exe | v24.15.0 |  |
| npm | True | True | C:\Program Files\nodejs\npm.ps1 | 11.12.1 |  |
| pnpm | False | False |  |  |  |
| yarn | False | False |  |  |  |
| nvm | False | False |  |  |  |
| fnm | False | False |  |  |  |
| mise | False | False |  |  |  |
| scoop | False | False |  |  |  |
| winget | False | False |  |  |  |
| choco | False | False |  |  |  |
| git | True | True | d:\Program Files\Git\cmd\git.exe | git version 2.54.0.windows.1 |  |
| cargo | True | True | D:\Codex\.cargo\bin\cargo.exe | cargo 1.96.0 (30a34c682 2026-05-25) |  |
| rustc | True | True | D:\Codex\.cargo\bin\rustc.exe | rustc 1.96.0 (ac68faa20 2026-05-25) |  |
| go | False | False |  |  |  |
| dotnet | True | False | C:\Program Files\dotnet\dotnet.exe |  | Version probe exited with code -2147450735 |
| java | False | False |  |  |  |
| javac | False | False |  |  |  |
| mvn | False | False |  |  |  |
| gradle | False | False |  |  |  |
| cmake | True | True | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin\cmake.exe | cmake version 4.3.2  CMake suite maintained and supported by Kitware (kitware.com/cmake). |  |
| ninja | True | True | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin\ninja.exe | 1.13.2 |  |
| docker | False | False |  |  |  |
| wsl | True | False | C:\WINDOWS\system32\wsl.exe |  | Version probe exited with code 1 |
| code | False | False |  |  |  |
| pwsh | True | True | D:\Codex\tools\PowerShell\7.6.3\pwsh.exe | PowerShell 7.6.3 |  |
| powershell | True | True |  | 7.6.3 |  |

## PATH 入口

| 序号 | 是否存在 | 路径 | Reparse Point |
| --- | --- | --- | --- |
| 0 | True | C:\WINDOWS\system32 | False |
| 1 | True | C:\WINDOWS | False |
| 2 | True | C:\WINDOWS\System32\Wbem | False |
| 3 | True | C:\WINDOWS\System32\WindowsPowerShell\v1.0\ | False |
| 4 | True | C:\WINDOWS\System32\OpenSSH\ | False |
| 5 | True | C:\Program Files\dotnet\ | False |
| 6 | True | C:\Program Files\nodejs\ | False |
| 7 | True | d:\Program Files\Git\cmd | False |
| 8 | True | C:\Program Files (x86)\ZeroTier\One\ | False |
| 9 | True | C:\Program Files\Tailscale\ | False |
| 10 | True | D:\Codex\.cargo\bin | False |
| 11 | True | D:\Codex\.cargo\bin | False |
| 12 | True | D:\Codex\tools\codegraph\current\bin | False |
| 13 | True | D:\Codex\tools\PowerShell\7.6.3 | False |
| 14 | True | D:\Codex\tools\python313-official | False |
| 15 | True | D:\Codex\tools\python313-shims | False |
| 16 | True | D:\Codex\tools\dotnet | False |
| 17 | True | D:\Codex\tools\uv\bin | False |
| 18 | True | D:\Codex\_tools | False |
| 19 | True | D:\hermes-data\bin | False |
| 20 | True | C:\Users\14224\.local\bin | False |
| 21 | True | C:\Users\14224\AppData\Roaming\Programs\Zero Install | False |
| 22 | True | C:\Users\14224\AppData\Roaming\npm | False |
| 23 | True | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\voidtools.Everything.Cli_Microsoft.Winget.Source_8wekyb3d8bbwe | False |
| 24 | True | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin | False |
| 25 | True | D:\Program Files\Git\bin | False |
| 26 | True | D:\Program Files\Git\usr\bin | False |
| 27 | True | C:\Users\14224\AppData\Local\.luckin\bin | False |
| 28 | True | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\jqlang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe | False |
| 29 | True | C:\Users\14224\AppData\Local\Microsoft\WinGet\Packages\GitHub.cli_Microsoft.Winget.Source_8wekyb3d8bbwe\bin | False |
| 30 | False | D:\Codex\tools\dotnet-home\.dotnet\tools | False |

## 目录探测

| 名称 | 类别 | 是否存在 | 路径 | 说明 |
| --- | --- | --- | --- | --- |
| Codex tools root | d-target | True | D:\Codex\tools | 推荐工具根目录 |
| Codex envs root | d-target | False | D:\Codex\envs | 推荐共享环境根目录 |
| Codex cache root | d-target | True | D:\Codex\.cache | 推荐共享缓存根目录 |
| uv cache env | cache | True | D:\uv\cache | 显式 UV_CACHE_DIR |
| uv tools env | tool-env | True | D:\Codex\tools\uv\tools | 显式 UV_TOOL_DIR |
| pip cache env | cache | True | D:\Codex\.cache\pip | 显式 PIP_CACHE_DIR |
| pip cache default | cache | True | C:\Users\14224\AppData\Local\pip\Cache | pip 默认用户缓存候选 |
| pipx default home | tool-env | False | C:\Users\14224\.local\pipx | pipx 常见默认位置 |
| poetry cache default | cache | False | C:\Users\14224\AppData\Local\pypoetry\Cache | Poetry 常见缓存位置 |
| conda user root | tool-env | False | C:\Users\14224\.conda | Conda 用户目录 |
| npm cache env | cache | True | D:\Codex\tools\npm-cache | 显式 NPM_CONFIG_CACHE |
| npm cache default | cache | False | C:\Users\14224\AppData\Local\npm-cache | npm 常见缓存位置 |
| pnpm store default | cache | False | C:\Users\14224\AppData\Local\pnpm\store | pnpm 常见 store 位置 |
| cargo home | tool-env | True | D:\Codex\.cargo | Cargo 工具和缓存根 |
| rustup home | tool-env | True | D:\Codex\.rustup | Rustup 工具链根 |
| go path | tool-env | False | C:\Users\14224\go | Go GOPATH |
| scoop user | tool-env | False | C:\Users\14224\scoop | Scoop 用户安装根 |
| scoop global | tool-env | False | C:\ProgramData\scoop | Scoop 全局安装根 |
| nuget packages | cache | False | C:\Users\14224\.nuget\packages | NuGet 包缓存 |
| maven repository | cache | False | C:\Users\14224\.m2\repository | Maven 本地仓库常见位置 |
| gradle user home | cache | False | C:\Users\14224\.gradle | Gradle 用户缓存和 wrapper 根 |
| docker user config | manual-only | False | C:\Users\14224\.docker | Docker 用户配置，可能包含上下文和凭据引用 |
| vscode extensions | tool-env | False | C:\Users\14224\.vscode\extensions | VS Code 用户扩展目录 |

## 项目本地环境

| 项目或 app | 父项目 | 分类 | 标记 | 路径 | 建议 |
| --- | --- | --- | --- | --- | --- |
| D:\Codex\projects\歌单转换 | D:\Codex\projects\歌单转换 | project-root-local-env | .venv | D:\Codex\projects\歌单转换\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| D:\Codex\projects\codex-account-switch | D:\Codex\projects\codex-account-switch | project-root-local-env | node_modules | D:\Codex\projects\codex-account-switch\node_modules | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| D:\Codex\projects\yangyangzi-direct-qqbot | D:\Codex\projects\yangyangzi-direct-qqbot | project-root-local-env | .venv | D:\Codex\projects\yangyangzi-direct-qqbot\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| D:\Codex\.gsd\projects\hermes-agent | D:\Codex\.gsd\projects\hermes-agent | project-root-local-env | .venv | D:\Codex\.gsd\projects\hermes-agent\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| D:\Codex\.gsd\projects\new-chat-4 | D:\Codex\.gsd\projects\new-chat-4 | project-root-local-env | .venv | D:\Codex\.gsd\projects\new-chat-4\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager | D:\Codex\.gsd\projects\codex-plus-plus | nested-app-local-env | node_modules | D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager\node_modules | 不自动迁移；纳入项目级审查，但不得跨项目复用。 |

## 本地环境分类发现

| 分类 | 纳入项目级审查 | 所属项目或容器 | 标记 | 路径 | 建议 |
| --- | --- | --- | --- | --- | --- |
| project-root-local-env | 是 | D:\Codex\projects\歌单转换 | .venv | D:\Codex\projects\歌单转换\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| project-root-local-env | 是 | D:\Codex\projects\codex-account-switch | node_modules | D:\Codex\projects\codex-account-switch\node_modules | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| project-root-local-env | 是 | D:\Codex\projects\yangyangzi-direct-qqbot | .venv | D:\Codex\projects\yangyangzi-direct-qqbot\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| archived-project-cache | 否 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase6-skills\source-skills\shared-skill | node_modules | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase6-skills\source-skills\shared-skill\node_modules | 不按当前项目依赖重建；如需处理，进入归档或产物清理 dry-run。 |
| plugin-cache-backup | 否 | D:\Codex\projects\yangyangzi-direct-qqbot\data\repair_backups\plugin-cache-20260610-123718\openai-bundled\chrome\26.602.71036\scripts | node_modules | D:\Codex\projects\yangyangzi-direct-qqbot\data\repair_backups\plugin-cache-20260610-123718\openai-bundled\chrome\26.602.71036\scripts\node_modules | 不按项目依赖重建；如需处理，进入备份治理 dry-run。 |
| archived-project-cache | 否 | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase6-skills\source-codex\skills\shared-skill | node_modules | D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase6-skills\source-codex\skills\shared-skill\node_modules | 不按当前项目依赖重建；如需处理，进入归档或产物清理 dry-run。 |
| plugin-runtime-cache | 否 | D:\Codex\projects\yangyangzi-direct-qqbot\data\codex_home_yangyangzi\plugins\cache\openai-bundled\browser\26.616.51431\scripts | node_modules | D:\Codex\projects\yangyangzi-direct-qqbot\data\codex_home_yangyangzi\plugins\cache\openai-bundled\browser\26.616.51431\scripts\node_modules | 不按项目依赖重建；如需处理，进入插件 runtime/cache 治理。 |
| plugin-runtime-cache | 否 | D:\Codex\projects\yangyangzi-direct-qqbot\data\codex_home_yangyangzi\plugins\cache\openai-bundled\chrome\26.616.51431\scripts | node_modules | D:\Codex\projects\yangyangzi-direct-qqbot\data\codex_home_yangyangzi\plugins\cache\openai-bundled\chrome\26.616.51431\scripts\node_modules | 不按项目依赖重建；如需处理，进入插件 runtime/cache 治理。 |
| project-root-local-env | 是 | D:\Codex\.gsd\projects\hermes-agent | .venv | D:\Codex\.gsd\projects\hermes-agent\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| project-root-local-env | 是 | D:\Codex\.gsd\projects\new-chat-4 | .venv | D:\Codex\.gsd\projects\new-chat-4\.venv | 不自动迁移；这是项目本地依赖环境，需逐项目评估。 |
| nested-app-local-env | 是 | D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager | node_modules | D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager\node_modules | 不自动迁移；纳入项目级审查，但不得跨项目复用。 |

## 迁移候选

当前未发现明确迁移候选。

## 人工审查项

| 来源 | 类型 | 风险 | 建议动作 | 原因 |
| --- | --- | --- | --- | --- |
| D:\Codex\projects\歌单转换\.venv | project-root-local-env | high | 不自动迁移 | 项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\projects\codex-account-switch\node_modules | project-root-local-env | high | 不自动迁移 | 项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\projects\yangyangzi-direct-qqbot\.venv | project-root-local-env | high | 不自动迁移 | 项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase6-skills\source-skills\shared-skill\node_modules | archived-project-cache | high | 不自动迁移 | 项目文档或历史归档中的依赖缓存副本，不属于当前项目依赖重建。 |
| D:\Codex\projects\yangyangzi-direct-qqbot\data\repair_backups\plugin-cache-20260610-123718\openai-bundled\chrome\26.602.71036\scripts\node_modules | plugin-cache-backup | high | 不自动迁移 | repair backup 内的插件缓存副本，不属于项目依赖重建；只能走备份保留或清理治理。 |
| D:\Codex\projects\codex-gsd-codex-c-skill\docs\gsd-archive\tmp\replicator\phase6-skills\source-codex\skills\shared-skill\node_modules | archived-project-cache | high | 不自动迁移 | 项目文档或历史归档中的依赖缓存副本，不属于当前项目依赖重建。 |
| D:\Codex\projects\yangyangzi-direct-qqbot\data\codex_home_yangyangzi\plugins\cache\openai-bundled\browser\26.616.51431\scripts\node_modules | plugin-runtime-cache | high | 不自动迁移 | 插件 runtime/cache 内的依赖目录，不属于项目本地依赖重建；可能由插件安装或运行时管理。 |
| D:\Codex\projects\yangyangzi-direct-qqbot\data\codex_home_yangyangzi\plugins\cache\openai-bundled\chrome\26.616.51431\scripts\node_modules | plugin-runtime-cache | high | 不自动迁移 | 插件 runtime/cache 内的依赖目录，不属于项目本地依赖重建；可能由插件安装或运行时管理。 |
| D:\Codex\.gsd\projects\hermes-agent\.venv | project-root-local-env | high | 不自动迁移 | 项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\.gsd\projects\new-chat-4\.venv | project-root-local-env | high | 不自动迁移 | 项目根本地依赖环境可能绑定解释器、绝对路径、构建产物或服务运行状态。 |
| D:\Codex\.gsd\projects\codex-plus-plus\apps\codex-plus-manager\node_modules | nested-app-local-env | high | 不自动迁移 | 嵌套 app 的项目本地依赖环境，需按所在 app 的锁文件、验证命令和 owner 决策单独处理。 |

## 下一步

1. 人工审查 risk=medium 和 risk=high 的候选项。
2. 为低风险缓存迁移单独建立迁移 issue。
3. 对任何工具根目录迁移，优先使用工具官方配置或重装方式，不直接搬目录。
