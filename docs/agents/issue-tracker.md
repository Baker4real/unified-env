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
- 列出 issue：`gh issue list --state open --json number,title,body,labels,comments`
- 添加评论：`gh issue comment <number> --body "..."`
- 管理标签：`gh issue edit <number> --add-label "..."` 或 `--remove-label "..."`
- 完成 issue：先添加必要的结论评论，再执行 `gh issue close <number>`

标签词汇以 `docs/agents/triage-labels.md` 为准。已完成事项通过关闭 GitHub issue 表示。

## Pull requests

Pull request 不作为 triage 请求入口。处理 issue 时只查询 GitHub Issues，除非用户明确要求审查某个 pull request。

## 当技能引用 tracker

- “发布到 issue tracker”：创建 GitHub issue。
- “读取相关 ticket”：运行 `gh issue view <number> --comments`。
- 不能从当前仓库推断目标时，先检查 `git remote -v`，不要把其他仓库的 issue 作为本项目 tracker。
