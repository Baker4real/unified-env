# Git 默认分支发布与收尾 Skill 统一策略 Implementation Plan

> **状态（2026-07-13）：** Task 1–5 已实施、验证并完成默认分支集成；临时分支与本 workflow worktree 已按顺序清理。下方复选框保留实施过程记录，不再表示当前待办。完整证据见 `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\verification-summary.json`、`VERIFICATION.md` 和 `task5-action-log.md`。

> **历史路径说明：** 下方实施命令中出现的 `D:\Codex\projects\unified-env-github-default-branch-skill-policy` 是已清理的历史 worktree；当前版本化源代码位于 `D:\Codex\projects\统一环境\scripts`，部署入口和验证证据仍以 D 盘当前路径为准。

> **退役说明（2026-07-14）：** 本计划中的 `finishing-a-development-branch`、`subagent-driven-development` 和 `writing-plans` 路径只保留为历史实施记录；obra-superpowers 指定 7 项已按用户授权无备份退役，不代表当前 active 路径，也不应从本文恢复。

> **供 agentic workers 使用：** 按任务逐项实施；每个任务先建立可观察的失败信号，再写最小实现并复验。此变更涉及插件缓存、分支生命周期与本机全局 skill，Task 3 和 Task 4 必须完成独立对抗性审查。

**目标：** 让本机收尾和 GitHub 发布 skill 默认只发布到可验证的远端默认分支，淘汰 patch-stack 分支，并让临时分支在确认后合入、推送和双端删除。

**架构：** 活跃本地 skill 直接在 D:\Codex\.codex\skills 中更新，并由 SOURCE.md 与统一账本记录本地覆盖。GitHub 插件不直接长期手改 cache：版本化源代码位于本仓库的 scripts 与 tests，部署器将其哈希校验后复制到 D:\Codex\.codex\scripts；运行时覆盖器仅接受已知上游指纹，先生成完整变更计划，再原子写入 marketplace source 与 cache，同时在 D:\Codex\.codex\run-evidence 下留可验证备份 manifest。

**技术栈：** Node.js 24（仅用内置 fs、path、crypto、assert），PowerShell 7.6.3，Git，GitHub CLI，Markdown skill 与 JSON 来源账本。

## 全局约束

- 目标 remote 不从名称猜测，而是由用户授权的仓库上下文解析；私有上游保护流程只允许已验证的 private remote。每次推送前必须证明 remote 属于用户或已获明确授权。
- 默认分支同时读取目标 remote 的 HEAD 符号引用与 GitHub defaultBranchRef；双证据必须一致，只有一个证据时才可使用，均缺失或冲突即停止。
- 不得创建、推送、追踪或保留 patch-stack 分支。已存在的本地/远端 patch-stack 引用只报告，绝不自动删除。
- 临时分支只能在 agent 说明必要性后使用；首个可发布提交必须同步远端；用户确认后必须合入并推送默认分支，再删除远端和本地临时分支。
- 收尾态只校验 workflow 管理的默认分支与临时分支；未知分支不删、不改。
- 严禁 force push、自动绕过保护、自动删除用户 worktree 或自动清理历史分支。
- 所有临时、备份和验证证据必须在 D 盘；使用 D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\ 作为本次证据根。
- 每个被改的本地 skill 必须同步 SOURCE.md 和 D:\Codex\.codex\skills\.downloaded-skills-source-state.json；最终资源闭包检查必须无硬失败。
- GitHub 插件 cache 是镜像；只能通过失败关闭的覆盖器修改，未知输入指纹不得写入任何目标。

---

### Task 1：构建版本化的 GitHub 插件覆盖器与红灯测试

**风险：** 高。覆盖器若按路径或模糊文本盲写，插件刷新后可能覆盖错误版本或破坏所有 GitHub skill。

**Files:**

- Create: scripts/Apply-GitHubDefaultBranchSkillOverlay.cjs
- Create: scripts/github-default-branch-skill-overlay-catalog.json
- Create: scripts/Deploy-GitHubDefaultBranchSkillOverlay.ps1
- Create: tests/Test-GitHubDefaultBranchSkillOverlay.cjs

**Interfaces:**

- Consumes: JSON catalog entries with role, accepted upstream SHA-256, expected patched SHA-256 and canonical patched document.
- Produces: discoverTargets(codexRoot), buildChangePlan(targets, catalog), applyChangePlan(plan, options), rollbackManifest(manifestPath, options) and a JSON report with changed, skipped, failed and evidence paths.
- Deployment consumes the repository source files and produces byte-identical runtime copies at D:\Codex\.codex\scripts\Apply-GitHubDefaultBranchSkillOverlay.cjs and D:\Codex\.codex\scripts\github-default-branch-skill-overlay-catalog.json.

- [ ] **Step 1：写覆盖器红灯测试**

创建 tests/Test-GitHubDefaultBranchSkillOverlay.cjs。测试在 D:\Codex\.codex\run-evidence 下创建独立 fixture root，模拟下面三类已发现的 GitHub 插件 surface：

~~~javascript
const surfaces = [
  '.tmp/plugins/plugins/github/skills/yeet/SKILL.md',
  'plugins/cache/openai-curated/github/27126220/skills/yeet/SKILL.md',
  'plugins/cache/openai-curated-remote/github/0.1.8-2841cf9749ae/skills/yeet/SKILL.md',
];

// fixtureCatalogPath points to a D: evidence file written before this plan.
// Production runs use the script-local file-backed catalog and never enable
// allowTestCatalog; the explicit test-only options below keep the fixture
// provenance visible and prevent an inline object from becoming production input.
const plan = overlay.buildChangePlan(
  overlay.discoverTargets(fixtureCodexRoot),
  fixtureCatalogPath,
);
const fixtureApplyOptions = {
  evidenceRoot,
  allowTestCatalog: true,
  testOnlyCatalogPath: fixtureCatalogPath,
};
assert.equal(plan.errors.length, 0);
assert.equal(plan.changes.length, 6);
assert.equal(overlay.applyChangePlan(plan, { ...fixtureApplyOptions, dryRun: true }).changed, 0);
assert.equal(overlay.applyChangePlan(plan, { ...fixtureApplyOptions, dryRun: false }).changed, 6);
assert.equal(overlay.applyChangePlan(
  overlay.buildChangePlan(overlay.discoverTargets(fixtureCodexRoot), fixtureCatalogPath),
  { ...fixtureApplyOptions, dryRun: false },
).changed, 0);
~~~

另加三个失败用例：把一个 fixture 的内容改成未知哈希；把未知内容伪造为含稳定标记；删除一个配对的 github 路由 skill。三个用例都断言 buildChangePlan 返回错误且 applyChangePlan 未写入任何文件。

- [ ] **Step 2：运行红灯**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitHubDefaultBranchSkillOverlay.cjs'
~~~

预期：失败，错误明确说明 Apply-GitHubDefaultBranchSkillOverlay.cjs 和 catalog 尚不存在。

- [ ] **Step 3：实现 catalog 与覆盖器**

catalog 必须为每个 role 记录当前已知的 upstream 指纹、预期 patched 指纹和完整 patchedDocument。当前 upstream 基线包括：

- yeet：9D70C68282ACBC7FBEE678F142ADBF84B4F1091890D6CB93B3106E5E629FC0CB 与 E93C6EA769BA673D30749A981CD8AD75B687F454E3C8E2E45E7CFCBD412DF12C；
- github：380D663305EB74B44858F58D76BDB21173A4D4C63D5885299AD6005D6FFC80B9 与 81DBDD90934FE86A79DDC4790FD211E5FCA866302A74090AD153395F56F2BD42。

覆盖器使用以下确定性接口；先收集所有目标和预期变更，任何一个目标未知或缺失时不调用写入函数：

~~~javascript
function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex').toUpperCase();
}

function buildChangePlan(targets, catalog) {
  const failures = [];
  const changes = [];
  for (const target of targets) {
    const original = fs.readFileSync(target.path, 'utf8');
    const currentSha256 = sha256(original);
    const entry = catalog[target.role]?.find((item) =>
      item.upstreamSha256 === currentSha256 || item.patchedSha256 === currentSha256,
    );
    if (!entry) {
      failures.push({ path: target.path, reason: 'unknown-input-fingerprint' });
      continue;
    }
    if (entry.patchedSha256 === currentSha256) continue;
    changes.push({ ...target, original, replacement: entry.patchedDocument });
  }
  return { changes, errors: failures };
}
~~~

patchedDocument 必须保留各自 YAML name，加入稳定标记，并实现下列行为：默认 remote 分支双证据解析、用户/授权 remote 检查、默认不建 PR、临时分支远端同步、确认后合入/推送/双端删除、未知或历史 patch-stack 只报告。不得含 main/master 猜测、git push 到 patch-stack、默认 draft PR 或强推。覆盖器还要在加载 catalog 时自行计算 patchedDocument 的 SHA-256，和 patchedSha256 不同即拒绝运行。

applyChangePlan 先为每个目标写入 evidence backup 和原始 SHA-256，再使用同目录临时文件与 rename 完成替换。单个写入失败时，它必须用 manifest 中的原始哈希执行已写目标的比较后恢复；恢复失败时报告 unsafe-partial，绝不把部分写入称为成功。

- [ ] **Step 4：实现部署器**

Deploy-GitHubDefaultBranchSkillOverlay.ps1 使用 CmdletBinding(SupportsShouldProcess)，接受 SourceRoot、CodexRoot 和 EvidenceRoot，验证两个源文件存在且其 SHA-256 在复制后完全一致，再用 D 盘同卷临时文件原子替换 runtime copy。它输出 JSON：

~~~powershell
[pscustomobject]@{
  ok = $true
  sourceRoot = $SourceRoot
  deployed = @(
    @{ relative = 'Apply-GitHubDefaultBranchSkillOverlay.cjs'; sha256 = $scriptHash }
    @{ relative = 'github-default-branch-skill-overlay-catalog.json'; sha256 = $catalogHash }
  )
  evidenceDir = $EvidenceRoot
} | ConvertTo-Json -Depth 6
~~~

- [ ] **Step 5：运行绿灯与部署 dry-run**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitHubDefaultBranchSkillOverlay.cjs'
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\scripts\Deploy-GitHubDefaultBranchSkillOverlay.ps1' -SourceRoot 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\scripts' -CodexRoot 'D:\Codex\.codex' -EvidenceRoot 'D:\Codex\.codex\run-evidence\github-default-branch-skill-policy' -WhatIf
~~~

预期：fixture 测试通过；部署器报告两个可部署文件和零个 D 盘外目标。

- [ ] **Step 6：提交版本化工具**

~~~powershell
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' add -- scripts/Apply-GitHubDefaultBranchSkillOverlay.cjs scripts/github-default-branch-skill-overlay-catalog.json scripts/Deploy-GitHubDefaultBranchSkillOverlay.ps1 tests/Test-GitHubDefaultBranchSkillOverlay.cjs
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' commit -m 'feat: add GitHub default branch skill overlay'
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' push
~~~

---

### Task 2：先验证再更新本地收尾 skill 与来源记录

**风险：** 高。错误的文案会让 agent 推错 remote、无提示保留临时分支，或把历史 branch 当成可安全删除的对象。

**Files:**

- Create: tests/Test-GitDefaultBranchSkillPolicy.cjs
- Modify: D:\Codex\.codex\skills\finishing-a-development-branch\SKILL.md
- Modify: D:\Codex\.codex\skills\private-patch-stack\SKILL.md
- Modify: D:\Codex\.codex\skills\neat-freak\SKILL.md
- Modify: D:\Codex\.codex\skills\neat-freak\references\repo-clean-closeout.md
- Modify: D:\Codex\.codex\skills\repo-clean-closeout\SKILL.md
- Modify: D:\Codex\.codex\skills\clean-git-worktree\SKILL.md
- Modify: D:\Codex\.codex\skills\handoff\SKILL.md
- Modify: D:\Codex\.codex\skills\finishing-a-development-branch\SOURCE.md
- Modify: D:\Codex\.codex\skills\private-patch-stack\SOURCE.md
- Modify: D:\Codex\.codex\skills\neat-freak\SOURCE.md
- Modify: D:\Codex\.codex\skills\repo-clean-closeout\SOURCE.md
- Modify: D:\Codex\.codex\skills\clean-git-worktree\SOURCE.md
- Modify: D:\Codex\.codex\skills\handoff\SOURCE.md
- Modify: D:\Codex\.codex\skills\.downloaded-skills-source-state.json

**Interfaces:**

- Consumes: an explicit codex root argument and the active local skill files.
- Produces: one zero-exit content-policy report or a list of path, rule and matched text.

- [ ] **Step 1：写本地 skill 内容红灯**

创建 tests/Test-GitDefaultBranchSkillPolicy.cjs，以绝对 codex root 为默认输入。至少断言：

~~~javascript
assert.doesNotMatch(finishing, /merge-base HEAD main|merge-base HEAD master/i);
assert.doesNotMatch(privateSkill, /refs\/heads\/patch-stack|git push .*patch-stack/i);
assert.match(finishing, /ls-remote --symref .* HEAD/i);
assert.match(finishing, /defaultBranchRef/i);
assert.match(finishing, /push .*--delete/i);
assert.match(repoCloseout, /repo-clean-closeout\.md/);
assert.match(cleanWorktree, /Repository Clean Gate/);
assert.match(handoff, /D:\\Codex\\\.codex\\handoffs\\projectless/i);
assert.doesNotMatch(handoff, /temporary directory of the user's OS/i);
~~~

再断言 private-patch-stack 的报告和回滚说明不再要求 patch-stack/NN-*，而是使用提交历史、git revert 或受控临时分支；neat-freak 真源必须把既有 patch-stack 引用列为“报告并等待单独删除授权”。

- [ ] **Step 2：运行红灯**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitDefaultBranchSkillPolicy.cjs' --codex-root 'D:\Codex\.codex'
~~~

预期：失败并精确指出当前 main/master 猜测、patch-stack 推送、旧 PR 默认和 handoff 临时目录漂移。

- [ ] **Step 3：制作 CAS 备份 manifest**

在修改前，针对本任务列出的全部活跃本地 skill、SOURCE.md、统一账本和 handoff 文件生成路径、SHA-256、长度、最后写入时间的 JSON manifest，并把原件复制到：

~~~text
D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\before-local-skill-policy\
~~~

写入前再次计算 SHA-256；任何目标在盘点和写入之间变动时停止，更新 manifest 后重新审查，而不是覆盖并发变更。

- [ ] **Step 4：重写执行真源与薄包装**

finishing-a-development-branch 改为固定流程：验证 → 解析目标 remote/default branch 双证据 → 选择直接默认分支或已说明的临时分支 → 用户确认 → 合入/推送默认分支 → 远端与本地删除临时分支 → fetch --prune 验证。保留 discard 的精确确认，但不再提供“默认创建 PR”或“保持 branch as-is”的普通选项。

private-patch-stack 保留兼容名称，description 改为私有上游保护和 private 默认分支发布。它必须保留 source remote push 禁用、私有仓库和机密扫描；把当前完整提交历史发往 private 的已解析默认分支；移除 baseline/full patch branch 与所有 patch-stack checkpoint 指令；空 private repo、未知默认分支、历史 patch-stack 引用均失败关闭或报告。

neat-freak 的 SKILL.md 只保留一条指向 repo-clean-closeout reference 的路由说明；reference 增加统一分支门：解析目标 remote 默认分支、只提交确认范围、发布时镜像并验证、历史 patch-stack 只报告。repo-clean-closeout 和 clean-git-worktree 只增加对这一真源的明确委托，不能复制第二套 Git 分支逻辑。

handoff 当前内容与 SOURCE.md 记录的 D-hosted overlay 不一致。先恢复已记录的项目/项目外 handoff 位置和 point-in-time 规则，再把 private-patch-stack 建议改成“非用户上游且需要私有默认分支发布”这一事实门；handoff 绝不执行 remote、push、删除或 cleanup。

- [ ] **Step 5：同步来源记录与账本**

对每个已改本地 skill 在 SOURCE.md 写入日期、本地覆盖意图、具体 policy 和恢复/迁移原因。统一账本中：

- 把 finishing-a-development-branch 从 retained-local 的错误回填对象中删除；
- 将它加入 obra-superpowers source group，并记录 source-backed local overlay；
- 更新 khazix-skills、mattpocock-skills 和 retained-local 项中受影响 skill 的 local_changes；
- 保证每个 active local skill 仅被账本覆盖一次。

- [ ] **Step 6：运行绿灯与资源闭包**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitDefaultBranchSkillPolicy.cjs' --codex-root 'D:\Codex\.codex'
& 'D:\Codex\tools\python314-official\python.exe' 'D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py' --root 'D:\Codex\.codex\skills' --strict --format markdown
~~~

预期：内容策略测试通过，闭包检查没有 Missing resources、Missing SOURCE.md、Missing ledger coverage、Duplicate ledger coverage 或 Stale live ledger coverage。

- [ ] **Step 7：提交可审计测试来源**

~~~powershell
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' add -- tests/Test-GitDefaultBranchSkillPolicy.cjs
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' commit -m 'test: cover default branch skill policy'
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' push
~~~


---

### Task 3：部署并应用 GitHub 插件覆盖，记录重放与回滚证据

**风险：** 高。这里会触及 marketplace source 和插件 cache；必须先 dry-run、一次性预检所有文件，并且让未知版本安全失败。

**Files:**

- Create: D:\Codex\.codex\scripts\Apply-GitHubDefaultBranchSkillOverlay.cjs
- Create: D:\Codex\.codex\scripts\github-default-branch-skill-overlay-catalog.json
- Create: D:\Codex\.codex\docs\agent-guidance\github-default-branch-skill-policy.md
- Modify: D:\Codex\.codex\docs\agent-guidance\skill-operations.md
- Modify through overlay only: D:\Codex\.codex\.tmp\plugins\plugins\github\skills\github\SKILL.md
- Modify through overlay only: D:\Codex\.codex\.tmp\plugins\plugins\github\skills\yeet\SKILL.md
- Modify through overlay only: D:\Codex\.codex\plugins\cache\openai-curated\github\27126220\skills\github\SKILL.md
- Modify through overlay only: D:\Codex\.codex\plugins\cache\openai-curated\github\27126220\skills\yeet\SKILL.md
- Modify through overlay only: D:\Codex\.codex\plugins\cache\openai-curated-remote\github\0.1.8-2841cf9749ae\skills\github\SKILL.md
- Modify through overlay only: D:\Codex\.codex\plugins\cache\openai-curated-remote\github\0.1.8-2841cf9749ae\skills\yeet\SKILL.md

**Interfaces:**

- Consumes: the deployed runtime overlay, catalog, all currently discovered GitHub plugin targets and an evidence directory.
- Produces: a JSON apply manifest with source and patched SHA-256, target role/surface, backup path and changed status.

- [ ] **Step 1：部署版本化覆盖器并验证哈希**

运行：

~~~powershell
& 'D:\Codex\tools\PowerShell\7.6.3\pwsh.exe' -NoProfile -File 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\scripts\Deploy-GitHubDefaultBranchSkillOverlay.ps1' -SourceRoot 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\scripts' -CodexRoot 'D:\Codex\.codex' -EvidenceRoot 'D:\Codex\.codex\run-evidence\github-default-branch-skill-policy'
~~~

预期：JSON 的两个 deployed SHA-256 与 repository source 相同；任何不同立即停止。

- [ ] **Step 2：运行全目标 dry-run**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\.codex\scripts\Apply-GitHubDefaultBranchSkillOverlay.cjs' --codex-root 'D:\Codex\.codex' --evidence-root 'D:\Codex\.codex\run-evidence\github-default-branch-skill-policy' --dry-run --json
~~~

预期：当前六个 github/yeet target 全部被识别，全部属于 catalog 已知指纹；输出 changedCount=6、errorCount=0，且不修改文件。

- [ ] **Step 3：应用覆盖并复验幂等性**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\.codex\scripts\Apply-GitHubDefaultBranchSkillOverlay.cjs' --codex-root 'D:\Codex\.codex' --evidence-root 'D:\Codex\.codex\run-evidence\github-default-branch-skill-policy' --json
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\.codex\scripts\Apply-GitHubDefaultBranchSkillOverlay.cjs' --codex-root 'D:\Codex\.codex' --evidence-root 'D:\Codex\.codex\run-evidence\github-default-branch-skill-policy' --dry-run --json
~~~

预期：首次输出 changedCount=6 并生成 backup/manifest；第二次输出 changedCount=0、errorCount=0。

- [ ] **Step 4：写运行维护说明**

github-default-branch-skill-policy.md 记录：

- 六个当前 surface 及其输入指纹；
- 版本化源代码、部署器与 runtime copy 的绝对路径；
- refresh 后固定顺序：部署 → overlay dry-run → overlay apply → 幂等 dry-run → 内容测试；
- 未知指纹、缺失 target、哈希不一致和 rollback 的失败关闭行为；
- manifest 的证据根与禁止手改 plugin cache 的边界。

skill-operations.md 只添加一条简短指针：GitHub 插件刷新后，必须使用上述覆盖器重放默认分支发布策略；不要把行为覆盖混入菜单中文化脚本。

- [ ] **Step 5：运行内容策略测试**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitDefaultBranchSkillPolicy.cjs' --codex-root 'D:\Codex\.codex'
~~~

预期：它同时验证本地收尾 skill、marketplace source 与两份 GitHub plugin cache 都没有默认 PR、patch-stack 或 main/master 猜测，并包含临时分支双端收尾规则。

---

### Task 4：全链路验证与独立对抗性审查

**风险：** 最高。这个任务验证的不是“文本已改”，而是最坏情况下不会把非用户 remote、错误默认分支或单边临时分支当成正常完成。

**Files:**

- Create: D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\verification-summary.json
- Create: D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\VERIFICATION.md
- Create: D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\writing-great-skills-acceptance.md
- Review: 本计划、设计文档、覆盖器 manifest、所有受影响 active skill、plugin source/cache 目标和来源账本。

**Interfaces:**

- Consumes: Task 1 至 Task 3 的测试输出、哈希 manifest、严格资源闭包报告与 Git 状态。
- Produces: 一份不含凭据的验证摘要，逐项标出通过、失败或未验证，以及可用于回滚的 manifest 路径。

- [ ] **Step 1：运行全部自动验证**

运行：

~~~powershell
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitHubDefaultBranchSkillOverlay.cjs'
& 'D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' 'D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitDefaultBranchSkillPolicy.cjs' --codex-root 'D:\Codex\.codex'
& 'D:\Codex\tools\python314-official\python.exe' 'D:\Codex\.codex\skills\skill-install-guard\scripts\skill_resource_closure.py' --root 'D:\Codex\.codex\skills' --strict --format markdown
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' diff --check
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' status --short --branch
~~~

预期：所有 Node 测试零失败、资源闭包零硬失败、Git 格式检查无输出，临时分支已追踪远端同名分支。

自动验证使用已解析的 Codex primary runtime；不得改用 PATH 中无法证明来源的 Node 入口。
在生成最终证据前，必须完整读取 `D:\Codex\.codex\skills\writing-great-skills\SKILL.md`，
并把 acceptance gate 的逐项结果写入本 Task 的 evidence 根。

- [ ] **Step 2：执行对抗性审查**

使用独立 agent 对以下攻击面做只读审查：

1. origin/HEAD 与 GitHub defaultBranchRef 不一致；
2. target remote 不是用户所有但 local config 仍可能路由到它；
3. 临时分支只删除了本地或只删除了远端；
4. 已有 patch-stack 引用被误删；
5. 插件更新改变 SKILL.md 后覆盖器是否会误写；
6. rollback manifest 遇到文件已被其他进程修改时是否会覆盖新内容；
7. handoff 内容与 SOURCE.md 再次漂移时验证器是否能发现。

审查必须给出文件、路径和可复现命令。任何高优先级发现都回到对应任务修复并重跑本任务。

- [ ] **Step 3：生成验证证据**

先完成 writing-great-skills acceptance gate：记录已完整读取
`D:\Codex\.codex\skills\writing-great-skills\SKILL.md`，并逐项审查本次改动的单一职责、
清晰描述与 leading vocabulary、最小范围与剪枝、单一真源/渐进披露、可检查完成标准、
测试与资源闭包、正向行为与失败关闭；只有结论 `approved` 且无未决项时才可继续。

生成 `writing-great-skills-acceptance.md`，并在 `verification-summary.json` 中记录 gate
路径、源 skill SHA-256、审查项目和状态。`verification-summary.json` 还包含：时间、active
skill/插件 target 哈希、测试命令及退出码、资源闭包摘要、overlay manifest 路径、对抗性审查
结论和已知未验证项。`VERIFICATION.md` 用简体中文解释结果，不复制敏感远端 URL、token 或
credential 输出。

- [ ] **Step 4：提交并同步所有版本化实现**

~~~powershell
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' add -- scripts tests docs
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' commit -m 'feat: enforce default branch skill publishing'
git -C 'D:\Codex\projects\unified-env-github-default-branch-skill-policy' push
~~~

---

### Task 5：用户确认后的默认分支集成与临时分支清理

**风险：** 高。此任务只能在用户看到验证结果并明确确认无误后执行。

**Files:**

- Modify through Git only: `<TARGET_REMOTE>/<RESOLVED_DEFAULT_BRANCH>`（两个变量必须由目标仓库授权上下文和双证据解析得到）
- Delete through Git only after the resolved default branch push succeeds: `<TARGET_REMOTE>/<TEMPORARY_BRANCH>` 和本地 `<TEMPORARY_BRANCH>`
- Remove only this workflow 创建的 worktree: D:\Codex\projects\unified-env-github-default-branch-skill-policy

**Interfaces:**

- Consumes: 用户明确确认、Task 4 全通过、`<TARGET_REMOTE>/<RESOLVED_DEFAULT_BRANCH>` 的最新状态，以及已记录的默认分支双证据。
- Produces: 已推送的 `<TARGET_REMOTE>/<RESOLVED_DEFAULT_BRANCH>`、删除完成的双端临时分支和 worktree、最终 fetch --prune 镜像证明。

- [ ] **Step 1：创建干净的默认分支集成 worktree**

不触碰 D:\Codex\projects\统一环境 的用户脏 worktree。先把 `<TARGET_REMOTE>` 和 `<RESOLVED_DEFAULT_BRANCH>` 固定为已验证变量，再执行 `git fetch <TARGET_REMOTE> --prune`，从 `<TARGET_REMOTE>/<RESOLVED_DEFAULT_BRANCH>` 创建唯一的新 worktree，验证其中没有未提交改动。

- [ ] **Step 2：合入并验证**

在新的默认分支 worktree 中执行普通非强制 merge；发生冲突、非快进或测试失败立即停止，不删除临时分支。合入成功后重跑 Task 4 的全部自动验证。

- [ ] **Step 3：推送已解析默认分支**

只在验证通过后执行 `git push <TARGET_REMOTE> <RESOLVED_DEFAULT_BRANCH>`。推送后执行 `git fetch <TARGET_REMOTE> --prune`，确认本地默认分支 HEAD 与 `<TARGET_REMOTE>/<RESOLVED_DEFAULT_BRANCH>` 相同。

- [ ] **Step 4：删除临时分支与 worktree**

仅在默认分支推送成功后，严格按“远端删除成功 → worktree 删除 → 本地分支删除 → fetch/prune”顺序执行：先执行 `git push --delete <TARGET_REMOTE> <TEMPORARY_BRANCH>`；只有远端删除成功，才对 `ownedByThisWorkflow=true` 的 worktree 执行 `git worktree remove <TEMPORARY_WORKTREE>`，再执行 `git branch --delete <TEMPORARY_BRANCH>`，最后执行 `git fetch --prune <TARGET_REMOTE>`。每一步都检查上一步成功；远端删除失败时必须停止并保留本地临时分支及其 worktree，不能继续任何本地清理；后续任一步失败也保留尚未删除的现场并如实报告不一致。用户明确要求保留临时分支或创建 PR 时不得执行删除例外。

- [ ] **Step 5：最终证明**

运行 `git branch -vv`、`git ls-remote --heads <TARGET_REMOTE>`、`git worktree list --porcelain` 和 `git status --short --branch`，证明已解析默认分支推送成功、workflow 临时分支没有单边残留、原用户 worktree 未被修改。
