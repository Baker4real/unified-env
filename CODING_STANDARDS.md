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
