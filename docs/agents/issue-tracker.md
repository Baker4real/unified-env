# Issue tracker：本地 Markdown

本项目的 issue 和 PRD 以 markdown 文件形式保存在 `.scratch/`。

## 约定

- 每个功能一个目录：`.scratch/<feature-slug>/`
- PRD 文件：`.scratch/<feature-slug>/PRD.md`
- 实施 issue：`.scratch/<feature-slug>/issues/<NN>-<slug>.md`，从 `01` 开始编号
- triage 状态写在每个 issue 文件靠前位置的 `Status:` 行
- 评论和对话历史追加到文件底部的 `## Comments`

## 当技能说“发布到 issue tracker”

在 `.scratch/<feature-slug>/` 下创建新文件，必要时先创建目录。

## 当技能说“读取相关 ticket”

读取用户给出的路径或 issue 文件。
