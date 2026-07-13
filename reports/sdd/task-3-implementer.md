# Task 3 实施报告

## Status

DONE

## 范围与安全边界

- 工作树：`D:\Codex\projects\unified-env-github-default-branch-skill-policy`。
- 未触碰用户原始脏工作树 `D:\Codex\projects\统一环境`。
- 六个 GitHub plugin target 均先读取 SHA-256、字节数和 UTC 修改时间，并备份到 `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\before-plugin-overlay\backups`。
- CAS 清单：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\before-plugin-overlay\cas-manifest.json`。
- runtime CLI 修复前的二次 CAS 清单：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\before-plugin-overlay\cli-fix-cas-manifest.json`。
- plugin source/cache 六个目标只由 overlay API 写入；没有手工编辑任何 `SKILL.md`。

六个输入指纹均命中版本化 catalog：`.tmp` 与 `openai-curated` 的 github/yeet 分别命中 `380D...80B9`/`9D70...0CB`，remote cache 分别命中 `81DB...2D42`/`E93C...12C`；三组 manifest 都声明 OpenAI `https://github.com/openai/plugins` 所有权。

## 版本化修改

- 新增/更新 `scripts/Apply-GitHubDefaultBranchSkillOverlay.cjs`：增加 fail-closed CLI 解析，支持 `--codex-root`、`--evidence-root`、`--catalog-path`、`--dry-run`、`--json`，保留两个位置参数兼容；未知 flag、缺值和重复参数在发现/写入前以非零退出。
- 更新 `tests/Test-GitHubDefaultBranchSkillOverlay.cjs`：覆盖 named/positional 解析、unknown flag、缺值、重复 flag 以及实际 CLI 非零阻断。
- 提交：`f17c2a9 fix: support named overlay CLI options`，已普通推送到 `origin/codex/github-default-branch-skill-policy`。

## 部署与运行证据

### WhatIf

命令：`D:\Codex\tools\PowerShell\7.6.3\pwsh.exe -NoProfile -File D:\Codex\projects\unified-env-github-default-branch-skill-policy\scripts\Deploy-GitHubDefaultBranchSkillOverlay.ps1 -SourceRoot D:\Codex\projects\unified-env-github-default-branch-skill-policy\scripts -CodexRoot D:\Codex\.codex -EvidenceRoot D:\Codex\.codex\run-evidence\github-default-branch-skill-policy -WhatIf`

结果：退出码 `0`；源文件 SHA-256 与部署目标预检为：

```json
{
  "Apply-GitHubDefaultBranchSkillOverlay.cjs": "CE6547EC5A70B965FE16072D60020CF9948DF5CC119ABE4D1889522FE4B4BD28",
  "github-default-branch-skill-overlay-catalog.json": "8A01A4675E4BAF7D93B74F26DD80EDA593BABF9D3ACC7B48CFB462B021649A21"
}
```

WhatIf evidence 输出目录：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T035441654Z-f839daf5fd3f4d4ba9d3c2f817a83ff4`。
完整 WhatIf 输出和退出码另存于 `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\task3-cli-runs\deploy-whatif.txt` 与 `deploy-whatif.exitcode`。

### 实际部署

退出码 `0`；runtime copy：

- `D:\Codex\.codex\scripts\Apply-GitHubDefaultBranchSkillOverlay.cjs`
- `D:\Codex\.codex\scripts\github-default-branch-skill-overlay-catalog.json`

部署 evidence：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T035455069Z-2accc0ea4bc249cdb4d93928dbd122ee\manifest.json`。两个 runtime SHA-256 与 repo source 完全一致。

### named-flag 全目标 dry-run（回滚后重放）

为验证 CLI 修复，先通过 overlay `rollbackManifest` 将第一次 apply manifest 恢复为已登记 upstream，再按 named flags 重放；没有直接写 plugin/cache。

```json
{
  "plan": {"changes": 6, "skipped": 0, "errors": []},
  "report": {"ok": true, "dryRun": true, "changed": 0, "planned": 6, "skipped": 0, "failed": 0, "errors": []}
}
```

退出码 `0`。

### named-flag apply

```json
{
  "plan": {"changes": 6, "skipped": 0, "errors": []},
  "report": {
    "ok": true,
    "changed": 6,
    "skipped": 0,
    "failed": 0,
    "errors": [],
    "manifestPath": "D:\\Codex\\.codex\\run-evidence\\github-default-branch-skill-policy\\run-2026-07-13T03-55-24-182Z-45448-5a912c52\\manifest.json"
  }
}
```

退出码 `0`；六份 backup 与 manifest 均在同一 evidence 根下。

### named-flag 幂等 dry-run

```json
{
  "plan": {"changes": 0, "skipped": 6, "errors": []},
  "report": {"ok": true, "changed": 0, "skipped": 6, "failed": 0, "errors": []}
}
```

退出码 `0`。

上述三次 named-flag 的完整 stdout JSON 与退出码文件已保存在：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\task3-cli-runs\named-dry-run.json`、`named-apply.json`、`named-idempotent-dry-run.json` 及同名 `.exitcode` 文件。

## 内容与回归测试

- `D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe --check D:\Codex\projects\unified-env-github-default-branch-skill-policy\scripts\Apply-GitHubDefaultBranchSkillOverlay.cjs`：通过。
- `D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe --check D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitHubDefaultBranchSkillOverlay.cjs`：通过。
- `D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitHubDefaultBranchSkillOverlay.cjs`：通过，`changed=6`、`idempotent=6`；包含未知指纹、伪造 marker、缺配对、CAS/回滚、catalog provenance、CLI named flag 和 unknown flag 阻断。
- `D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe D:\Codex\projects\unified-env-github-default-branch-skill-policy\tests\Test-GitDefaultBranchSkillPolicy.cjs --codex-root D:\Codex\.codex`：通过，退出码 `0`，输出 `Git default-branch skill policy: PASS`；source、两组 cache 和本地收尾 skill 内容策略一致。完整输出及退出码在 `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\task3-cli-runs\content-policy-test.txt` 与 `.exitcode`。

## 运行说明

已创建：`D:\Codex\.codex\docs\agent-guidance\github-default-branch-skill-policy.md`，包含六 surface/输入指纹、版本化源/部署器/runtime 路径、固定 refresh 顺序、CAS、失败关闭、manifest/evidence 和禁止手改边界。

已在 `D:\Codex\.codex\docs\agent-guidance\skill-operations.md` 增加一条指针，明确 GitHub 行为覆盖必须通过上述 overlay，不能混入菜单中文化脚本。

## 审查补强（f673343）

- 固定三种 exact surface relative：`.tmp/plugins/plugins/github`、`plugins/cache/openai-curated/github/27126220`、`plugins/cache/openai-curated-remote/github/0.1.8-2841cf9749ae`；发现 extra version/surface、缺失 expected surface、重复角色、surface/target 数量变化时，discover/build/apply 均 fail-closed。`supportedPluginSurface` 和 apply boundary 也拒绝未登记版本，手工 plan 无法绕过。
- manifest 和 change plan 增加原始/替换 mtime fingerprint（按文件系统稳定的毫秒粒度取整）；dry-run 在任何写入前执行 mtime CAS，apply 备份阶段和写入阶段再次校验，mtime 漂移返回 `original-mtime-cas-conflict`。回滚恢复原始字节并恢复原始 mtime，替换 mtime 漂移也会阻断回滚。
- fixture 增加 `27126220-extra`、`github-extra` 和缺失 expected surface 场景，断言 discover/build 报错、dry-run/apply blocked 且六个登记 target 不被写入；增加窄 mtime drift 测试。
- 普通提交：`f673343 fix: lock overlay surfaces and mtime CAS`，已推送到 `origin/codex/github-default-branch-skill-policy`。
- runtime 重新 WhatIf/部署：源与 runtime overlay SHA-256 为 `0982041C7A99066E9932FB25862464FDC77E184F7C4F0CB31A5A3B5740963DE8`（脚本）和 `8A01A4675E4BAF7D93B74F26DD80EDA593BABF9D3ACC7B48CFB462B021649A21`（catalog），部署 evidence 为 `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T041205904Z-1c514f9252e04fb4a735a1cb2fbb6f5a\manifest.json`。
- 重新运行 named flags：当前六目标已是 patched，dry-run/apply/idempotent 三次均退出码 `0`，`changed=0`、`skipped=6`、无错误；完整 JSON/退出码在 `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\task3-cli-runs-v2`，WhatIf 证据在 `deploy-20260713T041241499Z-c59f12ae05684370907580ab3c4908ff`。
- `Test-GitHubDefaultBranchSkillOverlay.cjs`（含两次连续运行）、`Test-GitDefaultBranchSkillPolicy.cjs`、PowerShell parser syntax 和部署器 `-WhatIf` 全部通过。

## 回滚 mtime CAS 补强（5e86890）

- `rollbackManifest` 现在在 current bytes 已等于 `originalSha256` 时仍会比较 `originalMtimeMs`；若字节被并发者恢复但 mtime 漂移，记录 `rollback-mtime-cas-conflict` 并返回 `unsafe-partial`，不覆盖、不标记 restored。
- fixture 新增该并发场景：原始字节 + 偏移 mtime 的 entry 被拒绝；替换 mtime 漂移检查与恢复原始 mtime 验证仍保留。
- 普通提交：`5e86890 fix: reject rollback original mtime drift`，已推送到 `origin/codex/github-default-branch-skill-policy`。
- 由于文件系统 timestamp 读取/`utimes` 存在亚毫秒舍入差异，mtime fingerprint 使用稳定的 10ms bucket；真实秒级触碰仍 fail-closed，避免合法 byte-identical 文件的伪冲突。
- runtime 重部署 WhatIf/实际部署均通过；runtime 脚本 SHA-256：`6FC7DE794D0E729663A6A05D3B98DCE06FB365A5EA3EC72C8F8F2F87F85C3290`，实际部署 manifest：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T042103256Z-79ab0f69a37d4368b8e73153fb395ef1\manifest.json`。
- 最终 named-flag 幂等 dry-run：退出码 `0`，发现 6 个 exact target，`changed=0`、`skipped=6`、无错误；随后两套 Node 测试、PowerShell syntax 和 `-WhatIf` 均通过（WhatIf manifest：`deploy-20260713T042121989Z-3e9e36cb2bf54402ab983253c95715c5`）。

## 完整 inventory 与 mixed state 补强（259aaf9）

- `discoverTargets` 现在产出 canonical six-target inventory 和 digest；`buildChangePlan` 原样绑定该 inventory，缺失/改写 inventory 的 plan 在构建或 apply 前失败关闭。
- apply 每次重新 discover inventory.codexRoot，要求 exact 三 surface、六路径/角色/codexRoot/surfaceDirectory 完全一致且无当前发现错误；要求 `changes + skipped === 6`，不再错误地要求 `changes === 6`。
- skipped entry 重新校验当前文件必须命中 canonical patched SHA、plan 中的 patched SHA/current SHA 与 mtime fingerprint 必须一致；全 patched 也经过这些边界检查后才允许幂等返回。
- fixture 现覆盖合法 `changes=1/skipped=5` mixed apply（`changed=1`）、伪造 skipped fingerprint 阻断、以及缺 inventory partial plan 阻断；原 extra/missing surface 与 rollback mtime CAS 场景继续通过。
- 普通提交：`259aaf9 fix: bind overlay apply to complete inventory`，已推送到 `origin/codex/github-default-branch-skill-policy`。
- runtime 先 CAS 备份/WhatIf，再实际部署：脚本 SHA-256 `320229AB0A02AA5A02404B04D8109DF5F15ACDFFD3D87BBB66DF07BB9C8FA1AC`；实际部署 manifest `D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T043040459Z-42112e16e4234e389164e2fabb0cae86\manifest.json`。
- 最终 named CLI idempotent dry-run exit `0`，exact six targets，`changed=0`、`skipped=6`、无错误；两套 Node 测试、PowerShell syntax 和部署器 WhatIf 通过（WhatIf evidence `deploy-20260713T043057115Z-d140475292bf458eae71af30d1d6a9b9`）。

## 中文 catalog、证据闭包与计划硬标准

- catalog 的 `github`/`yeet` 四个 `patchedDocument` 已统一改为简体中文；命令、路径、skill/API 标识符保留原文。临时分支流程明确包含 `git push --set-upstream <targetRemote> <temporaryBranch>`、用户确认后的默认分支合入/推送、`git push --delete <targetRemote> <temporaryBranch>`、仅删除 `ownedByThisWorkflow` worktree、本地删除和 `git fetch --prune`；用户明确保留临时分支或创建 PR 时走例外。新的 patched SHA 为 yeet `A448F0938D78CE38D1EB0E46B0D498A4529F03061FDD348E9D764A21C931868F`、github `DB6A7E97B49C998E9C1D342EC05A0F2B4E88865FA71ECE4B433105A424ECB23E`。
- 变更前使用既有成功 apply manifest 通过 overlay API 回滚 6 个插件目标，结果 `rolled-back/restored=6`；没有直接手改 plugin/cache。随后部署新 source/catalog 并重新应用六个目标。
- apply manifest 现在复制并记录 canonical catalog：`catalogPath`、`catalogSha256`、evidence 内 `catalogBackupPath`，并记录完整 `inventory` digest 与 `sourceInputs`（catalog、六个 targets、changes、skipped）；fixture 测试断言 catalog 备份 SHA 和 mixed state 的 sourceInputs 闭包。
- 最新 runtime WhatIf：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T051600591Z-414eb812764a4e50990080dfc1d6112b`；实际部署 manifest：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T051606236Z-026caae11f924e9794cd0eb46f3be9f5\manifest.json`。runtime source SHA 为脚本 `4C98C1D585B04642A4F67C49A0EBC2F4B00DA0272E99A4C519570D3A03598618`、catalog `EC1DB117B84F9B6F95CE32BC0249F00ECFDE11B23EF78A3C626D8C703BA3CB65`。
- 最新 named CLI apply manifest：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\run-2026-07-13T05-16-18-863Z-53216-97effd32\manifest.json`；`changed=6`、`skipped=0`，catalog 备份 SHA 与 `catalogSha256` 相同，inventory digest `AAD78C4550AAF1D6B495973ACDF9D863BF96DDCDE2E0ABB64AC437A152E81477`，sourceInputs targets=6/changes=6/skipped=0。随后幂等 dry-run `changed=0`、`skipped=6`、无错误。
- 实施计划 Task 5 已改用 `<TARGET_REMOTE>/<RESOLVED_DEFAULT_BRANCH>` 与 `<TEMPORARY_BRANCH>` 变量，不再把 `origin/main` 或 `git push origin main` 当作默认路径；计划中的 Node 命令统一使用 `D:\Codex\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe`。
- 维护说明新增 catalog/inventory/sourceInputs 证据闭包、计划/报告/运行证据链接，并如实记录 `gh.ps1` wrapper 与原生 `gh.exe` 入口差异为不阻塞本任务的环境债务。

## Spec 复核：默认发布 tracking 证明

- 在再次修改 catalog 前，通过 runtime overlay 回滚上一份成功 apply manifest：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\run-2026-07-13T05-16-18-863Z-53216-97effd32\manifest.json`，结果 `rolled-back/restored=6`。
- yeet 的默认发布第 2 步现在明确要求推送后执行 `git fetch --prune <targetRemote>`，并证明本地 `HEAD` 与 `<targetRemote>/<resolvedDefaultBranch>` tracking 一致。新的 yeet patched SHA 为 `CD52990C227295A752E1563526ACBB5D7AAF1571CF2DC85FA81C3A1D1C508089`；github patched SHA 保持 `DB6A7E97B49C998E9C1D342EC05A0F2B4E88865FA71ECE4B433105A424ECB23E`。
- catalog runtime WhatIf evidence：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T053327572Z-16d7830d0e934f989bbc497c50f25bd3`；实际部署 manifest：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\deploy-20260713T053327976Z-9a2da2e8ec9d434dadb15743d6786b0f\manifest.json`。runtime catalog SHA 为 `FD96D3E1483E2B42CA65CC48125A0363694AE815187C303D79A899A5EBBC11C5`，overlay 脚本保持 `4C98C1D585B04642A4F67C49A0EBC2F4B00DA0272E99A4C519570D3A03598618`。
- runtime named dry-run/apply/idempotent 重新执行成功：`changes=6/skipped=0`、`changed=6`、随后 `changed=0/skipped=6`，无错误。最新 apply manifest：`D:\Codex\.codex\run-evidence\github-default-branch-skill-policy\run-2026-07-13T05-33-38-392Z-60172-c3c54222\manifest.json`；catalog backup、inventory digest 和 sourceInputs 闭包继续通过。
- 本轮 `Test-GitHubDefaultBranchSkillOverlay.cjs`、PowerShell parser syntax 和部署器 `-WhatIf` 均通过。`Test-GitDefaultBranchSkillPolicy.cjs` 当时因并行全局 finishing skill 修改导致临时 worktree 生命周期顺序检查失败（`git fetch --prune` out of order）；该失败属于全局收尾文档的并行变更，需修复后复跑，不把它误报为本次 plugin overlay 通过。
