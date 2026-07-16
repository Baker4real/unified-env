# Git 默认分支发布与收尾 Skill 统一策略设计

> 状态：已实施并验证（2026-07-13）。默认分支发布、临时分支确认后清理和 patch-stack report-only 规则已落地；本状态不授权删除任何既有或未知分支。

> 退役说明（2026-07-16）：本文保留实施时的历史路径和设计决策。已删除来源的 skill 路径、来源和 overlay 描述不代表当前安装，也不授权恢复。

验证摘要与有序清理记录位于 `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\verification-summary.json`、`VERIFICATION.md` 和 `task5-action-log.md`。计划中的临时 worktree 路径仅是历史执行记录，不代表当前目录仍存在。

## 目标

把本机所有受本次范围控制的发布和收尾流程统一到一条可验证的规则：

1. 默认只向远端默认分支发布。通常是 main，但不得硬编码 main。
2. 不再创建、推送或保留 patch-stack 分支。
3. 仅在 agent 明确说明必要性时使用临时分支。该分支完成后经用户确认合入默认分支、推送默认分支，并删除本地和远端临时分支。
4. 收尾完成时，由本次 workflow 管理的本地与远端分支保持一致。
5. 继续禁止向不属于用户的上游仓库推送。

## 非目标

- 不删除任何已存在的 patch-stack 或其他分支；先盘点并由用户单独确认。
- 不绕过远端保护、强制推送、重写历史或自动处理合并冲突。
- 不改 gh-address-comments、gh-fix-ci 或 git-guardrails-claude-code；它们没有发布分支的执行路径，后者仍应保留为安全防线。
- 不 fork、替换或直接长期维护 OpenAI GitHub 插件的上游副本。

## 可观察事实与术语

### 目标 remote 与默认分支

普通仓库的目标 remote 是 origin；私有上游保护流程的目标 remote 是已验证的 private。任何推送前还必须确认目标 remote 属于用户或已获明确授权。对非用户上游，保持 fetch URL，禁用或拒绝 push URL。

默认分支必须按以下规则解析：

1. 读取目标 remote 的 HEAD 符号引用，并在 GitHub 可查询时读取该仓库的 defaultBranchRef；
2. 两个证据都可用时必须完全一致；
3. 只有一个证据可用时使用该证据；
4. 两者缺失或不一致时停止并报告，不猜测 main、master 或任意名称。

### 收尾态分支镜像

“本地和远端一致”只约束本次 skill 管理的分支：默认分支，以及由本次 workflow 创建的临时分支。收尾时：

- 先 fetch --prune；
- 默认分支的本地 HEAD 与远端跟踪分支一致；
- 临时分支若仍存在，必须同时存在于本地和远端；
- 临时分支完成后必须同时从本地和远端删除；
- 不认识的本地或远端分支只列为事实，不删除、不改追踪关系。

未提交工作树、尚未形成第一个提交的临时工作，不被误报为“单边残留分支”；一旦 branch 被 workflow 发布或收尾，它就必须遵守镜像规则。

## 设计

### 1. 默认发布与临时分支生命周期

默认路径不再创建 PR 或 feature branch：

1. 检查工作树、目标 remote、默认分支、分叉关系与相关验证结果。
2. 默认分支上仅提交已确认范围内的改动，先完成必要验证。
3. 用户请求发布时，快进同步并推送默认分支。
4. 重新 fetch --prune，验证默认分支镜像与干净的收尾状态。

只有风险、隔离、评审或宿主限制使默认路径不合适时，agent 才可建议临时分支，并说明理由。临时分支在首个可发布提交后必须设定远端追踪；在用户确认内容无误后：

1. 切换到默认分支并执行非破坏性合入；
2. 在合入结果通过验证后推送默认分支；
3. 删除远端临时分支；
4. 删除本地临时分支及本 workflow 自建 worktree；
5. fetch --prune 后证明没有单边临时分支。

用户明确要求保留分支、创建 PR 或等待外部评审时，才跳过删除；该例外必须在最终报告中说明。

### 2. 私有上游保护，不再使用 patch stack

现有 private-patch-stack 保留名称作为兼容入口，但行为改为“私有默认分支发布”：

- 它继续识别不属于用户的 source remote，并防止向该 remote 推送；
- 它继续检查私有目标仓库、账号、push 路由和机密范围；
- 它只把已验证的完整提交历史发布到私有仓库的远端默认分支；
- 它不再创建、推送、追踪或在报告中建议 patch-stack/NN-* 分支；
- 回滚默认使用提交历史和 git revert；需要隔离回滚时走普通临时分支生命周期，而不是保存 rollback 或 patch-stack 分支。

空私有仓库没有可解析默认分支时，workflow 停止并要求用户先初始化仓库，或明确授权初始化后重新解析。现有 patch-stack 引用只在盘点中列出；删除必须单独得到用户确认。

### 3. 收尾 skill 的单一真源

以下文件构成收尾策略的执行面：

| 位置 | 角色 | 改动 |
| --- | --- | --- |
| D:\Codex\.codex\skills\neat-freak\references\repo-clean-closeout.md | clean closeout 真源 | `neat-freak` 对发生改动的 Git 仓库默认提交本次授权范围、显式推送到用户拥有远端的 `main`，并验证 clean worktree 与远端 parity；只审计、只整理或不发布的显式阶段要求优先。 |
| D:\Codex\.codex\skills\repo-clean-closeout\SKILL.md | 直接入口 | 保持薄包装，只明确委托真源，不复制规则。 |
| D:\Codex\.codex\skills\private-patch-stack\SKILL.md | 遗留兼容入口 | 仅处理用户明确要求的历史 patch-stack 审计、只读保留、精确清理或迁移；普通发布不进入此 skill。 |
| D:\Codex\.codex\skills\handoff\SKILL.md | 收尾交接路由 | 只在存在非用户上游和未发布补丁时建议兼容入口，且说明默认分支发布规则。 |

neat-freak 的 reference 是 Git clean closeout 的唯一行为真源；`repo-clean-closeout` 薄包装不重复维护分支规则。默认发布不意味着吸收、删除或丢弃既有无关脏改动：无法合法归属的路径必须保留，并使 closeout 明确处于 incomplete。每个变更过的本地 skill 会同步更新 SOURCE.md 与统一来源账本。

### 4. GitHub 发布插件的可重放本地覆盖

GitHub 的 yeet 与 github skill 来自插件 source/cache，不属于活跃本地 skill 根。直接手改 cache 会在插件更新时丢失，因此采用独立、失败关闭的覆盖器：

1. 在 D:\Codex\.codex\scripts 下增加一个专用覆盖器和声明式补丁清单。
2. 覆盖器只发现 GitHub 插件的 marketplace source、已安装 cache 与当前可见 remote cache 中的 github 和 yeet SKILL.md。
3. 对已知上游内容指纹执行受限替换；发现未知指纹、缺失目标或意外结构时不写入并退出失败。
4. 已打补丁的内容带稳定标记，重复运行必须是 no-op。
5. 每次 plugin refresh 后先运行 dry-run，再应用覆盖；重放规则和当前指纹记录在 D:\Codex\.codex\docs\agent-guidance\ 中，不把插件 cache 当成来源真相。

yeet 将改为默认分支发布流程：先解析默认分支、默认不建 PR、仅在明确建议临时分支时创建和同步该分支；用户确认后合入、推送默认分支并删除两端临时分支。github 仅修改路由说明，使 publish changes 明确进入此规则。gh-address-comments 与 gh-fix-ci 只做 review/CI 工作，不纳入行为补丁。

### 5. 来源与更新边界

- neat-freak、handoff 和其他 source-backed skill 保留上游身份，只在 SOURCE.md 与账本中追加本地策略覆盖。
- private-patch-stack 和 repo-clean-closeout 保留其本地来源记录。
- 插件行为覆盖不伪装成上游改动；其来源、输入指纹、应用时间和回滚证据由覆盖器文档和 run-evidence 记录。

## 失败处理

| 触发条件 | 第一处理 | 仍无法恢复时 |
| --- | --- | --- |
| 无法解析默认分支 | 停止并列出目标 remote 的 HEAD 与 GitHub 查询结果 | 要求用户指定或修复 remote 配置。 |
| 目标 remote 非用户所有 | 禁止向该 remote 推送，检查私有目标 | 只报告，不发布。 |
| 默认分支有非快进分叉、保护或合并冲突 | 停止并展示差异/保护错误 | 由用户选择临时分支、PR 或手工处理。 |
| 检测到既有 patch-stack 引用 | 列出本地和远端引用 | 未获单独确认前不删、不改。 |
| 插件内容指纹未知 | 覆盖器 dry-run 失败，不写 cache | 先审查新上游版本并更新补丁清单。 |
| 无法删除临时分支的一端 | 保留另一端并报告不一致 | 不宣称收尾完成。 |

## 验证与验收

实施完成前必须同时满足：

1. 本地 skill 内容测试证明没有创建、推送或追踪 patch-stack 分支的指令。
2. 普通收尾目标固定为用户拥有远端的 `main`；remote 名称不能代替所有权证据，remote ahead/diverged、目标歧义或非 `main` 时停止。
3. `neat-freak` delivery mode 覆盖：全仓库集合预检、脏路径分类、窄验证、精确 staging、显式 `HEAD:main` push、远端 SHA parity 和空 porcelain；任一步失败都不能宣称 clean closeout 完成。
4. 插件覆盖器对 fixture、marketplace source 和两个 cache 变体的已知指纹均可应用；重复运行 no-op；未知指纹失败且不写入。
5. 所有被改本地 skill 的 SOURCE.md 与 D:\Codex\.codex\skills\.downloaded-skills-source-state.json 一致，且资源闭包严格检查为零问题。
6. git diff --check、覆盖器专项测试和最窄的相关测试全部通过。
7. 独立对抗性审查覆盖：错误默认分支、非用户 remote、单边临时分支、历史 patch-stack、插件升级漂移和回滚。

## 回滚

变更前把所有会被覆盖的本地 skill、插件 source/cache 目标、账本和覆盖清单复制到带时间戳的 D:\Codex\.codex\run-evidence\ 目录，并生成哈希 manifest。覆盖器支持基于该 manifest 的精确还原；若验证失败，先恢复本次备份，再重新运行闭包和行为测试。任何 Git 分支删除都不属于本次 skill 配置变更的自动回滚范围。
