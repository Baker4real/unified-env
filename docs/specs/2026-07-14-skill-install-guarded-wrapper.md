---
type: reference
title: Skill 安装事务 Wrapper 设计
tags: [设计, skill-install, transaction]
intent: 说明 Skill 安装事务 Wrapper 的目标和一致性保证
---

# Skill 安装事务 Wrapper 设计

状态：已实施并通过本机验证。

## 目标

把 skill 安装/更新的“完成”定义为一个可验证的后置状态：active skill、`SOURCE.md`、统一来源台账、资源闭包和本机 Skill Catalog 必须同时一致。

## 单一职责

| 层 | 唯一职责 | 入口 |
| --- | --- | --- |
| 候选治理 | 来源、采用度、重叠、`writing-great-skills` 和 install/update 决策 | `D:\Codex\.codex\skills\skill-install-guard\SKILL.md` |
| 事务执行 | 暂存、备份、激活、台账写入、回滚和后置校验 | `D:\Codex\.codex\scripts\install-skill-guarded.cmd` |
| 派生目录 | 从 active root、`SOURCE.md` 和 ledger 重新扫描生成 catalog | `scripts\generate_skill_catalog.py` |
| 上游下载 | 只提供候选下载/复制能力 | `.system\skill-installer` |

不把回写逻辑放进被安装的 skill，也不修改 bundled `.system` 安装器。skill 是提示词规则，不是可靠的安装后回调；原始安装器只复制目录，无法保证台账和 catalog 同步。

## 事务流程

1. `skill-install-guard` 产生 decision manifest，必须包含 `install` 或 `update`、`source-pass/source-review` 和 `writing-great-skills` 通过证据。
2. wrapper 将远端候选下载到 D 盘 staging；本地 `--candidate` 必须先用 decision manifest 绑定 `SKILL.md` 和安装载荷 SHA-256，再复制已审查内容。安装载荷排除任何层级的 `.git`、`__pycache__` 和 `.pyc`，这些来源仓库/解释器元数据不进入 active skill。所有 D 盘输入和写入路径都检查目标及全部既有祖先，任何父级 symlink、junction 或其他 reparse point 都在读取、暂存、备份或激活前失败闭锁；canonical identity 读取还必须先完成 candidate 与 predecessor 整树 reparse 审计。
3. wrapper 在事务身份建立后把已验证的 decision manifest 原子快照到持久 transaction evidence，并写入/保留 `SOURCE.md` 和 staging ledger。受管追加记录用 transaction evidence 与快照替代本地 candidate 和原始 decision manifest 输入路径；repo/ref/upstream、active path 等持久来源字段继续保留。候选已有记录仍包含当前输入路径或本机临时根时在激活前失败闭锁。父 skill 内会被运行时发现的 bundled skill 必须由 `bundled_skills` 逐项绑定安全相对路径和 frontmatter 名称，并各自保留可验证的 `SOURCE.md`；wrapper 把其 active-root 相对目录写入同一事务 ledger。随后运行严格资源闭包检查。
4. wrapper 在 active root 下重新创建候选内容，不移动 staging 目录，也不复制 staging 的 owner、DACL 或 SACL；目标目录和文件必须继承本机 active root 的权限。
5. wrapper 备份旧 active skill，再原子换入候选；Windows 备份移动前清除旧树只读位，该属性规范化本身也必须位于同一恢复边界内。若属性规范化或复制式移动在清理阶段失败，则合并源树与事务备份、恢复原只读属性，并按旧树内容 seal 证明恢复。回滚已有 active skill 时，删除当前 active 前必须先证明事务备份存在且匹配旧树 seal；删除已换入目录前还必须证明当前路径同时匹配本事务换入前捕获的目录 identity（volume/file index）与 payload seal。缺失、不匹配或路径消失时保留现状并标记 `rollback-failed`。无法证明恢复时状态必须为 `rollback-failed`。canonical rename 在 preflight、旧名退场后和真正换入前持续断言 successor 不存在，并使用 Windows 原子 no-replace rename；竞争产生的意外 successor 原样保留，既不备份成普通 update，也不覆盖或删除。换入后立即在独立子进程中枚举并读取全部文件，同时验证目标树不存在受保护 ACL。任一项失败都回滚，事务不得标记成功。
6. wrapper 更新 `D:\Codex\.codex\skills\.downloaded-skills-source-state.json`；只有 decision manifest 明确提供且通过白名单校验的来源元数据才可覆盖既有字段。
7. wrapper 调用 `generate_skill_catalog.py --write`，再运行闭包、catalog 条目、ledger coverage 和 `SKILL.md` SHA-256 复核。
8. 事务身份建立后的任一步失败都恢复 active 目录和状态文件，并把失败/回滚结果写入 `D:\Codex\.codex\run-evidence\skill-install-guarded\`。事务 manifest 记录 decision 快照的持久路径和 SHA-256，成功、dry-run 与事务内失败结果使用同一证据身份。decision 输入在事务身份建立前消失、不可读或变化时返回受管错误，但不声称已生成事务 evidence。

`activation_readability` 只证明安装后的文件系统权限、枚举和读取健康；Skill Catalog 的 `runtime_verification=unverified` 仍表示尚未验证 skill 行为本身，两者不能互相替代。

## Decision manifest 最小格式

```json
{
  "decision": "install",
  "source_status": "source-review",
  "writing_great_skills": { "status": "no-change" },
  "skills": ["example-skill"],
  "bundled_skills": [
    {
      "path": "node_modules/example-runtime/lib/tools/trace",
      "name": "example-trace"
    }
  ],
  "candidate_integrity": {
    "algorithm": "sha256(utf8(concat(sorted_unicode_codepoint(D + tab + relative_posix_directory + lf, or F + tab + relative_posix_file + tab + file_sha256 + lf)))); excludes any path segment named .git or __pycache__, and files ending in .pyc",
    "excluded": ["**/.git", "**/.git/**", "**/__pycache__", "**/__pycache__/**", "**/*.pyc"],
    "directory_count": 2,
    "file_count": 3,
    "tree_sha256": "<64-hex-sha256>",
    "skill_md_sha256": "<64-hex-sha256>"
  },
  "source": {
    "id": "owner-repo",
    "repo": "owner/repo",
    "ref": "main",
    "upstream_path": "plugins/example/skills/example-skill",
    "ledger_updates": {
      "installed_version": "1.2.3",
      "status": "updated-with-local-overlay"
    }
  }
}
```

`candidate_integrity` 对本地 `--candidate` 是硬门槛。wrapper 的 `--candidate-integrity-only` 只读入口生成该对象；决策生产方必须把其原样写入 manifest，普通事务缺少 decision manifest 时在创建锁、temp 或 evidence 目录前失败闭锁。指纹同时绑定目录拓扑与文件哈希。wrapper 在复制前按上述固定排除规则重算输入指纹，复制后再次验证同一指纹；候选新增、删除或修改任何会进入 active 的文件或目录都会在备份和激活前失败。事务 manifest 同时记录输入绑定、decision manifest 快照路径及其 SHA-256、被排除文件的数量/总字节和写入 `SOURCE.md` 后的 staging seal；activation 在复制前、复制后、原子换入前和换入后都必须对照同一 seal，并在每次 seal 计算中拒绝 symlink、junction 或其他 reparse point。`.git` 或 `__pycache__` 无论是目录还是普通文件都不进入安装载荷；`.pyc` 只在它是文件时排除，同名普通目录属于受绑定载荷。被排除元数据若原先存在于 active skill，只保留在该次 update 的事务回滚备份中，不复制进新 active payload。候选已有 `SOURCE.md` 时，最后一个独立 `---` 分段必须无歧义地包含与目标目录一致的 `Skill`；仅未知字段、空值或冲突均在写入前拒绝。候选没有 `SOURCE.md` 时，wrapper 才生成新的受管记录。候选 `SOURCE.md` 在追加受管记录后仍命中本机临时根、当前 candidate 或原始 decision manifest 路径时拒绝事务；只有 wrapper 生成且值精确匹配的 `Local path`、`Active root`、`Guarded transaction evidence` 和 `Decision manifest` 字段可在自定义测试根下豁免临时根检查，不能用共同祖先遮蔽其他路径。

`bundled_skills` 只允许用于单个本地 `--candidate`。每一项只能包含 `path` 和 `name`：`path` 必须是 candidate 内不含绝对路径、反斜杠、空段、`.`、`..`、`.git` 或 `__pycache__` 的 POSIX 相对目录，`name` 必须与该目录 `SKILL.md` 的 frontmatter 完全一致，且不能与顶层目标或其他 bundled skill 仅大小写不同。目录必须包含安全普通文件 `SKILL.md` 与 `SOURCE.md`；当前 provenance 记录必须有一致的 `Skill`，以及不含用户信息、query 或 fragment 且带 hostname/path 的 HTTPS `Source repository`、`Upstream path`、`Ref` 和 `Commit or revision`。暂存态与 live 态都按 `<top-level-name>/<bundled-path>` 校验唯一 ledger coverage、catalog 相对路径和两个 provenance 文件的 SHA-256。`manifest.skills` 仍只声明顶层安装目标，不能把 bundled 路径伪装成额外顶层安装目录。

`source.upstream_path` 只用于已审查的 `--candidate`：它把本地暂存候选映射回真实仓库子路径，确保新写入的 `SOURCE.md` 可精确追溯。仓库根使用精确值 `.`；其他值必须是仓库内的 POSIX 相对路径，不接受绝对路径、反斜杠、反引号、不可打印字符、空段、`.` 或 `..` 路径段。省略时为兼容旧调用仍回退到候选目录名。它与 `source.ledger_updates.path` 不同，后者是统一来源台账已有的本地路径字段。

`decision=update` 才允许替换已有 active skill。直接调用 `.system\skill-installer`、手工复制到 active root 或跳过 decision manifest，都不算完成的安装流程。

`source.ledger_updates` 可选且只允许更新 `action`、`installed_version`、`path`、`resource_paths`、`status` 五个字段；`action`、`installed_version`、`path` 与 `status` 必须是非空字符串，`resource_paths` 必须是非空字符串数组。未知字段或错误类型会在 activation 前拒绝事务，避免 decision manifest 静默改写任意台账内容。

## Canonical rename

canonical rename 是单候选 `decision=update` 的原子 identity 迁移，不是“安装新名后手工删除旧名”。manifest 必须额外包含：

```json
{
  "decision": "update",
  "skills": ["new-skill"],
  "canonical_rename": {
    "old_name": "old-skill",
    "new_name": "new-skill",
    "source_id": "owner-repo-source"
  },
  "source": {
    "id": "owner-repo-source",
    "repo": "owner/repo",
    "ref": "main",
    "commit": "<reviewed-commit>",
    "upstream_path": "skills/new-skill"
  }
}
```

`canonical_rename.new_name` 必须等于唯一 candidate 目标和 manifest `skills` 中显式声明的唯一名称，`old_name` 必须是当前唯一 active predecessor，`source_id` 必须与 `source.id` 及覆盖旧名的唯一 ledger source entry 完全一致，并且该 id 在 live `sources` 中只能出现一次。direct-entry coverage 的 `name`/`skill` 若同时存在必须指向同一名称，否则在任何 ledger mutation 前失败闭锁。candidate `SOURCE.md` 只把最后一个独立 `---` 分段作为当前追加记录：历史段不参与当前 identity 校验，当前段同一字段出现不同值或空值即为冲突并失败闭锁。当前记录必须无歧义地记录 `Skill`、`Canonical predecessor`、`Source identity`、`Source repository`、`Upstream path`、`Ref` 和 `Commit or revision`；wrapper 将其与旧 active `SOURCE.md` 的最新追加记录、manifest 及 ledger 的 id/repo/ref/commit 结构化交叉核对。历史追加记录可以保留旧 ref/commit/path，但当前记录字段缺失或冲突、同 repo 错误 identity、错误 predecessor 或版本漂移都在 staging/activation 前失败闭锁。

事务先把旧 active 目录移动到同一 evidence backup，再以 no-replace 语义激活 successor。成功后 ledger 只给新名保留一个 live source coverage，并把旧名记录为 `deleted/status=moved/reason=canonical rename/new_name=<successor>`；catalog 和严格 closure 必须同时通过。activation、ledger、catalog、closure 或后置 hash 任一步失败时，按逆序移除本事务创建的新目录、恢复旧目录及其只读属性，并原样恢复 ledger/catalog；由竞争者创建的 successor 不属于本事务，必须保留。

## 可维护性

项目源部署闭包由 `scripts\skill_source_record.py`、`scripts\generate_skill_catalog.py`、`scripts\install_skill_guarded.py` 和 `scripts\install-skill-guarded.cmd` 组成；部署后 installer 与 catalog 从同目录加载共享 `SOURCE.md` parser，不依赖项目源仓库路径。通过 `scripts\Deploy-SkillInstallGuarded.ps1` 部署到本机 D 盘入口。`D:\Codex\.codex\scripts\` 中的同名文件是部署产物，不可单独热修；紧急修复必须先回迁项目源、通过相关测试，再由部署脚本替换并留下 deployment manifest。catalog 仍是派生快照，ledger 与各 skill 的 `SOURCE.md` 仍是来源事实。
