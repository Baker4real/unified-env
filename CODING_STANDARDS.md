---
type: reference
title: 编码标准
tags: [代码评审, 测试]
intent: 评审改动时逐条检查、需要判断的编码规则
---

# 编码标准

评审本仓库的改动时逐条检查下面的规则。能机械判定的规则做成 lint 或测试（例如 `scripts/Invoke-PowerShellArrayUnwrapLint.ps1`、`scripts/Invoke-PowerShellParameterCaseLint.ps1`），不写在这里。

## 测试 seam 不能替代生产默认路径

脚本给测试留了替换生产默认值的参数时（本仓库惯例命名为 `*ForTest`，例如替身命令、零等待重试、夹具根目录），只走 seam 的测试覆盖不到生产分支。

- 新增或改动这样的 seam，至少要有一条测试不传它，只在外边界替身：PATH 最前面放转发到替身的可执行文件、改环境变量或指向夹具目录，并先断言替身确实被解析到，免得测试打到真实服务。
- 评审时列出 diff 里新增或改动的每个 seam 参数，逐个找到不传它的那条测试；找不到就记为缺陷。

反例：`scripts/Publish-GitHubIssueComment.ps1` 的测试一直传 `-GhCommandForTest`。生产分支把 `@('gh')` 包在 `$(...)` 里，只有一个元素时被展开成 `'gh'`，`[0]` 只剩 `'g'`，每次生产调用都失败，到 272fd4c 才修好。修复时加的「不带 seam、按 PATH 解析 gh」场景（`tests/Test-PublishGitHubIssueComment.ps1`）是这条规则的写法范例。

## 命令串白名单校验先验原始整串与控制字符

涉及宿主钩子注册、命令白名单或受管启动器匹配时，先对原始命令整串拒绝换行与控制字符（如 `\r`、`\n`）并完成规范串边界比对，再对词法切分结果做结构化解析。

- 仅校验分词后的 token 会被包裹引号的分隔符（如 `';'`）、带引号的可执行路径、多语句拼接或嵌入换行绕过，或把篡改命令静默降级为「未知第三方命令」放行。
- 评审此类改动时，核对是否对原始命令串做了控制字符拒绝与规范串比对，并确认测试覆盖引号/分隔符/换行对抗用例。

反例：PRD #97 `#107` 初版 `scripts/lib/CodexHookPolicy.ps1` 仅按分词后的 token 识别 `direct-managed-launcher`，在独立对抗审查中被引号包裹分号、引号包裹 `python.exe` 与嵌入换行绕过；补充 `Split-CodexHookCommandLine` 拒绝 `[\r\n]` 与 `-RawCommand` 逐字 `Ordinal` 比对后才闭环（`ecd46de`）。
