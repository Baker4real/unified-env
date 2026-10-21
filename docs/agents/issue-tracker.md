---
type: reference
title: Issue tracker：GitHub Issues
tags: [agents, issue-tracker, project-docs]
intent: 说明统一环境项目使用 GitHub Issues 的 tracker 约定
---

# Issue tracker：GitHub Issues

本项目的新 issue、spec、tickets 和讨论记录使用 GitHub Issues 管理。仓库为 `Baker4real/unified-env`，在仓库根目录通过 `gh` CLI 操作。已跟踪的 `.scratch/` 内容是保留的历史记录，不作为新事项模板或清理候选。2026-08-13 受管删除性能优化系列是 GitHub #26–#43；`.scratch/safe-tree-delete-perf/` 只是拆票副本。控制面收尾 #18–#24 的状态不在本文缓存，当前事实以 GitHub live tracker 和各 issue 的最新结论评论为准；未完全满足关闭条件的票保持 OPEN。仓库快照见 `reports/safe-tree-delete-control-plane-closeout-20260814/REPORT.md`。完成状态以 GitHub Issues 为准。

## 约定

- 创建 issue：`gh issue create --title "..." --body "..."`
- 读取 issue：`gh issue view <number> --comments`
- 列出 issue：`gh issue list --state open --json 'number,title,body,labels,comments'`
- 添加评论：正文写进文件并带一个唯一的隐藏 marker，用 `scripts/Publish-GitHubIssueComment.ps1` 发（见下节）
- 管理标签：`gh issue edit <number> --add-label "..."` 或 `--remove-label "..."`
- 完成 issue：先添加必要的结论评论，再执行 `gh issue close <number>`

标签词汇以 `docs/agents/triage-labels.md` 为准。已完成事项通过关闭 GitHub issue 表示。

## gh 报 EOF 时

`gh issue …`、`gh label …`（GraphQL）和 `gh api …`（REST）都会偶发 EOF，例如 `Post "https://api.github.com/graphql": EOF` 或 `Get "https://api.github.com/repos/<owner>/<repo>/issues/89": EOF`。这时退出码非 0、stdout 为空：

- 每次 gh 调用都检查退出码；空输出不能当成"没有数据"或"不存在"。
- 读取失败就退避重试；重试用完仍失败就停下，不拿不完整的读取结果做判断。
- 发评论不能直接重试：失败的请求可能已经落地。先重新读取评论，按正文里唯一的隐藏 marker（`<!-- … -->`）判断是否已写入，确认没有才重发。加、删标签是幂等的，可以直接重试。

`scripts/Publish-GitHubIssueComment.ps1` 按这三条发评论并按需改标签（`-Number`、`-BodyPath`、`-Marker`，可选 `-AddLabels`、`-RemoveLabels`）。它全程走 REST，结束时回读核验，输出一行 JSON：带 marker 的评论恰好一条且标签符合要求时退出 0，否则退出 1 并在 `error` 里说明。

其他操作的 REST 写法如下。在仓库根目录运行时 gh 会填好 `{owner}` 和 `{repo}`；PowerShell 里整条路径加单引号。

- 读取 issue：`gh api 'repos/{owner}/{repo}/issues/<number>'`，评论在同一路径后加 `/comments`
- 列出 open issue：`gh api 'repos/{owner}/{repo}/issues?state=open&per_page=100' --paginate --jq '.[] | select(.pull_request == null) | [.number, .title] | @tsv'`（REST 结果里混着 PR，要滤掉）
- 关闭 issue：`gh api -X PATCH 'repos/{owner}/{repo}/issues/<number>' -f state=closed -f state_reason=completed`
- 管理标签：加 `gh api 'repos/{owner}/{repo}/issues/<number>/labels' -f 'labels[]=<标签>'`，删 `gh api -X DELETE 'repos/{owner}/{repo}/issues/<number>/labels/<标签>'`，列出 `gh api 'repos/{owner}/{repo}/labels' --paginate --jq '.[].name'`

关闭后用读取命令确认 `state` 是 `closed`，再报告已关闭。

## Pull requests

Pull request 不作为 triage 请求入口。处理 issue 时只查询 GitHub Issues，除非用户明确要求审查某个 pull request。

## 当技能引用 tracker

- “发布到 issue tracker”：创建 GitHub issue。
- “读取相关 ticket”：运行 `gh issue view <number> --comments`。
- 不能从当前仓库推断目标时，先检查 `git remote -v`，不要把其他仓库的 issue 作为本项目 tracker。
