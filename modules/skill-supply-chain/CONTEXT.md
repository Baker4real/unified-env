---
type: reference
title: Skill 供应链模块上下文
tags: [skill, 模块, 供应链]
intent: 定义 Skill 来源、安装、catalog、ledger 和发布政策的责任边界
---

# Skill 供应链模块

## 范围

本模块拥有 guarded install、跨来源 merge retirement、`SOURCE.md`/ledger 一致性、资源闭包、本机 Skill Catalog 和 GitHub default-branch overlay 政策。

## 导航

guarded installer 按职责拆成入口 `implementation/install_skill_guarded.py` 和同目录 13 个 `install_skill_guarded_<area>.py` 模块（`base`、`tree`、`activation`、`payload`、`source_record`、`bundled`、`closure`、`decision`、`ledger`、`rename`、`retirement`、`system_overlay`、`staging`），各模块 docstring 首行写明职责。入口只保留事务主体 `execute()`（成功结果与 `source_state_after` 快照在它末尾构造）、CLI、安装锁、事务 manifest 写入和默认路径。模块之间用 `import install_skill_guarded_<area> as _<area>` 引用、以 `_<area>.f()` 调用，只按名导入类、异常和常量，不导入入口且不成环；`tests/Test-SkillInstallGuardedStructure.py` 守住这些规则和部署清单。测试按同样职责拆成 `tests/Test-SkillInstallGuarded*.py`，共享 fixture 在 `tests/guarded_install_fixtures.py`（system repair 场景另见 `guarded_install_system_fixtures.py`）；patch 函数时打在 fixture 里其所属模块的 handle 上（如 `mock.patch.object(ACTIVATION, "activate_directories")`），所有调用方都经该模块查找它；从 sibling 脚本按名导入的函数（如 `system_skill_integrity`）在每个用到它的模块里各有一份绑定，要 patch 就打在调用方所在的模块上。读代码仍先按符号定位（仓库有 `.codegraph/`，用 CodeGraph 查符号名；或 `rg -n "^def |^class "` 列大纲），再只读目标函数。

## 不属于本模块

- Codex hook 注册和 remote available catalog 的目录守卫属于 `codex-host`。
- 递归目录删除能力属于 `host-safety`。

## 权威合同

- `docs/specs/2026-07-14-skill-install-guarded-wrapper.md`
- `docs/plans/2026-07-13-local-skill-catalog-implementation.md`
- `docs/specs/2026-07-13-github-default-branch-skill-policy-design.md`

最后一份 dated spec 的后半段仍承载现役 `main`-only 合同、overlay 重放门禁和验收条件，因此不能整份归档。GitHub plugin 的 2026-08-07 upstream 漂移已经闭合；未来新指纹仍按未知输入失败关闭。

## 接口与测试

对外接口是 `scripts/install-skill-guarded.cmd`、根目录 Python adapters、`scripts/Deploy-SkillInstallGuarded.ps1` 和受管 overlay/deploy 入口。安装闭包的 Python 实现与热点测试位于本模块的 `implementation/`、`tests/`；command adapter 仍由根 `scripts/install-skill-guarded.cmd` 提供，部署脚本从 module implementation 加载 Python 文件并绑定该 command adapter。`--system-provenance-repair-plan` 为精确五项 bundled `.system` 提供官方刷新 bootstrap 与保留既有 payload 的 display reconcile；两者的基线证明、schema、CAS、rollback 和部署顺序统一见 wrapper spec 的 `Bundled system provenance atomic repair` 节。跨来源职责合并通过 installer 的 `merge_retirement` decision manifest 字段完成；成功 backup 必须在独立验收后由受管安全树删除入口清理。专项测试列在 `modules/manifest.json` 的 `python` 和 `node` 清单中。根 adapter `scripts/install_skill_guarded.py` 转出的是入口模块的命名空间，拆分后各职责函数不再直接挂在它上面，要经 `_<area>` 模块访问；2026-10-14 检索时没有进程内使用者。

在共享工作树（skills 根）里只提交某次事务的确切字节，用 `implementation/commit_exact_files.py`（`--help`）：它在私有 index 里从 expected HEAD 构建提交，hook 照常运行，之后只刷新所提交路径的共享 index。live ledger 已被后续事务改动时，用 `--file-from` 提交 wrapper 成功事务的 `backups/source-state-after.json`（事务 manifest 的 `source_state_after` 记录其路径与 sha256）。skills 仓库的 pre-commit 守卫是 `implementation/skills_repo_pre_commit.py`：拦截暂存文本里的 C0 控制字符和非规范 ledger JSON；`install --repo` 把检查器副本和 shim 装进该仓库的 hooks 目录，改源后重新安装。这两个工具从源路径运行，不属于部署闭包。

退休清理的两个运行时脚本以仓库为源：`scripts/retired-skill-menu-surface.cjs` 审计并清理退休 skill/plugin 的菜单、插件容器与 catalog 表面，`scripts/purge-retired-skill-backups.cjs` 处理 ledger 里失效的 cleanup manifest 和精确 payload target。两者由 `scripts/Deploy-RetiredSkillCleanup.ps1` 逐字节部署到 `D:\Codex\.codex\scripts\`，evidence 与部署前副本在 `D:\agents\run-evidence\retired-skill-cleanup\`；现役副本是否与源码一致，以 host-live 测试 `tests/Test-SuperpowersSkillRetirement.cjs` 的逐字节比对为准。账本和 active skills 的边界是统一实体根 `D:\agents\skills-manager\skills`；menu 脚本还要求 `D:\Codex\.codex\skills` 是解析到该根的 junction，否则以 `skills-alias-mismatch` 失败关闭。menu 默认审计只覆盖已安装面：active skills 和每个 `plugins\cache\<marketplace>` 容器（含 `account_backup` 里的两份运行时）；`.tmp` 下由应用同步的本地 marketplace 副本和远端 catalog 只列出可安装项，分别用 `--include-local-marketplace`、`--include-remote-catalog` 显式审计和清理，host-live 测试也只断言 Superpowers 未安装、未启用、不在 active root。它的 handle-bound 快照、删除和原子写来自 host-safety 的 `scripts/lib/CodexHostSafety.ps1`，部署副本运行时从本仓库工作树加载该文件。

旧 `SOURCE.md` 末尾记录的 schema 迁移只允许使用
`scripts/reconcile_skill_source_records.py`：它在隔离镜像达到 strict
zero-conflict 后，仅追加规范 current record，并为整批 SOURCE、统一 ledger、
catalog 和 `RUNTIME_FILES` 列出的 runtime 部署闭包建立受 ACL 保护的联合回滚点。迁移不得改写历史
记录、`SKILL.md` 或 plugin cache；任一身份/标量歧义必须整批失败关闭。

`RUNTIME_FILES` 与部署脚本的 `$sourceFiles` 是同一份清单。清单增加文件后，此前建立的回滚点缺少新增的闭包文件，在当前 `verify_backup` 下失败关闭，`--reharden-legacy-backup` 也无法再通过；2026-10-14 installer 按职责拆分之前建立的回滚点都是如此。schema 2 回滚点仍可运行 manifest 内嵌的 `restore_command`：它调用随回滚点保存的旧版迁移工具，把 runtime 中回滚点所含的文件还原成建立回滚点时的版本，恢复后必须重新部署。

## 已知漂移

仓库源中的部署闭包由 shared SOURCE parser、catalog generator、system provenance repair、Store identity provider、installer 入口及其 13 个模块与 command wrapper 组成，完整清单以 `scripts/Deploy-SkillInstallGuarded.ps1` 的 `$sourceFiles` 为准；这些实现从部署目录加载受管依赖，不依赖项目源仓库路径。现役 `D:\Codex\.codex\scripts\` 是否已包含该闭包只以受管部署 manifest 与现场 hash 为准，不能由仓库源存在推断。后续源文件变更、移动或拆分仓库前必须重新执行受管部署并核验 hash。当前仍依赖 active `skill-install-guard` 的 closure 脚本和官方 system installer，且事务内部还有待迁移的递归删除。在这些依赖、独立 fixture 和受管删除全部收敛前，本模块不拆出独立 Git 仓库。

部署目录曾有一份不在部署闭包内、`MODULE_PATH` 指向部署副本的 `test_install_skill_guarded.py`，该漂移已于 2026-10-13 闭合：按行为对照后，本模块尚未覆盖的行为迁入 `Test-SkillInstallGuarded.py`（`ScopedClosureGateTests`，以及 canonical rename 的旧 active SOURCE 身份、英文开头 description 两个用例；2026-10-14 测试按职责拆分后依次位于 `Test-SkillInstallGuardedClosure.py`、`Test-SkillInstallGuardedCanonicalRename.py` 与 `Test-SkillInstallGuardedPayload.py`）和 `Test-SkillCatalog.py`（四个 closure gate 用例），其余用例已有等价覆盖或价值低；部署副本及其 `__pycache__` 字节码经受管回收移入回收站，证据在 `D:\agents\run-evidence\managed-recycle\20261013T114802Z-082266b5\` 和 `20261013T114830Z-ba618232\`。
