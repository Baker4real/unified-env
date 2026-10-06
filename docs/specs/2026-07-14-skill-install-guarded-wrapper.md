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
| 候选治理 | 来源、采用度、重叠、`writing-for-agents` 和 install/update 决策 | `D:\agents\skills-manager\skills\skill-install-guard\SKILL.md` |
| 事务执行 | 暂存、备份、激活、台账写入、回滚和后置校验 | `D:\Codex\.codex\scripts\install-skill-guarded.cmd` |
| 派生目录 | 从 active root、`SOURCE.md` 和 ledger 重新扫描生成 catalog | `modules\skill-supply-chain\implementation\generate_skill_catalog.py`（根 adapter：`scripts\generate_skill_catalog.py`） |
| 上游下载 | 只提供候选下载/复制能力 | `.system\skill-installer` |

不把回写逻辑放进被安装的 skill，也不修改 bundled `.system` 安装器。skill 是提示词规则，不是可靠的安装后回调；原始安装器只复制目录，无法保证台账和 catalog 同步。

## 事务流程

1. `skill-install-guard` 产生 decision manifest，必须包含 `install` 或 `update`、`source-pass/source-review` 和 `writing-for-agents` 通过证据。
2. wrapper 将远端候选下载到 D 盘 staging；本地 `--candidate` 必须先用 decision manifest 绑定 `SKILL.md` 和安装载荷 SHA-256，再复制已审查内容。安装载荷排除任何层级的 `.git`、`__pycache__` 和 `.pyc`，这些来源仓库/解释器元数据不进入 active skill。所有 D 盘输入和写入路径都检查目标及全部既有祖先，任何父级 symlink、junction 或其他 reparse point 都在读取、暂存、备份或激活前失败闭锁；canonical identity 读取还必须先完成 candidate 与 predecessor 整树 reparse 审计。顶层和 manifest 声明的 bundled skill 若包含 `agents/openai.yaml`，wrapper 必须结构化解析并要求 `interface.display_name` 是只含可打印 ASCII 的非空英文身份；只有 `short_description` 和 `default_prompt` 等解释字段可中文化。YAML 非法、字段类型错误或非 ASCII 身份都必须在 active/state 备份之前失败闭锁。
3. wrapper 在事务身份建立后把已验证的 decision manifest 原子快照到持久 transaction evidence，并写入/保留 `SOURCE.md` 和 staging ledger。受管追加记录用 transaction evidence 与快照替代本地 candidate 和原始 decision manifest 输入路径；repo/ref/upstream、active path 等持久来源字段继续保留。候选已有记录仍包含当前输入路径或本机临时根时在激活前失败闭锁。父 skill 内会被运行时发现的 bundled skill 必须由 `bundled_skills` 逐项绑定安全相对路径和 frontmatter 名称，并各自保留可验证的 `SOURCE.md`；wrapper 把其 active-root 相对目录写入同一事务 ledger。随后运行严格资源闭包检查。
4. wrapper 在 active root 下重新创建候选内容，不移动 staging 目录，也不复制 staging 的 owner、DACL 或 SACL；目标目录和文件必须继承本机 active root 的权限。
5. wrapper 备份旧 active skill，再原子换入候选；Windows 备份移动前清除旧树只读位，该属性规范化本身也必须位于同一恢复边界内。若属性规范化或复制式移动在清理阶段失败，则合并源树与事务备份、恢复原只读属性，并按旧树内容 seal 证明恢复。回滚已有 active skill 时，删除当前 active 前必须先证明事务备份存在且匹配旧树 seal；删除已换入目录前还必须证明当前路径同时匹配本事务换入前捕获的目录 identity（volume/file index）与 payload seal。缺失、不匹配或路径消失时保留现状并标记 `rollback-failed`。无法证明恢复时状态必须为 `rollback-failed`。canonical rename 在 preflight、旧名退场后和真正换入前持续断言 successor 不存在，并使用 Windows 原子 no-replace rename；竞争产生的意外 successor 原样保留，既不备份成普通 update，也不覆盖或删除。换入后立即在独立子进程中枚举并读取全部文件，同时验证目标树不存在受保护 ACL。任一项失败都回滚，事务不得标记成功。
6. wrapper 更新 `D:\agents\skills-manager\skills\.downloaded-skills-source-state.json`；只有 decision manifest 明确提供且通过白名单校验的来源元数据才可覆盖既有字段。
7. wrapper 调用 `generate_skill_catalog.py --write`，再运行闭包、catalog 条目、ledger coverage 和 `SKILL.md` SHA-256 复核。
8. 事务身份建立后的任一步失败都恢复 active 目录和状态文件，并把失败/回滚结果写入 `D:\agents\run-evidence\skill-install-guarded\`。事务 manifest 记录 decision 快照的持久路径和 SHA-256，成功、dry-run 与事务内失败结果使用同一证据身份。decision 输入在事务身份建立前消失、不可读或变化时返回受管错误，但不声称已生成事务 evidence。

`activation_readability` 只证明安装后的文件系统权限、枚举和读取健康；Skill Catalog 的 `runtime_verification=unverified` 仍表示尚未验证 skill 行为本身，两者不能互相替代。

## Decision manifest 最小格式

```json
{
  "decision": "install",
  "source_status": "source-review",
  "writing_for_agents": { "status": "no-change" },
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

`writing_for_agents` 是现役 decision manifest 的唯一机器字段名；`writing_great_skills` 已退役，只允许作为历史 evidence 原样保留。新 manifest 使用旧字段或同时提供新旧字段时必须失败闭锁。

`candidate_integrity` 对本地 `--candidate` 是硬门槛。wrapper 的 `--candidate-integrity-only` 只读入口生成该对象；决策生产方必须把其原样写入 manifest，普通事务缺少 decision manifest 时在创建锁、temp 或 evidence 目录前失败闭锁。指纹同时绑定目录拓扑与文件哈希。wrapper 在复制前按上述固定排除规则重算输入指纹，复制后再次验证同一指纹；候选新增、删除或修改任何会进入 active 的文件或目录都会在备份和激活前失败。事务 manifest 同时记录输入绑定、decision manifest 快照路径及其 SHA-256、被排除文件的数量/总字节和写入 `SOURCE.md` 后的 staging seal；activation 在复制前、复制后、原子换入前和换入后都必须对照同一 seal，并在每次 seal 计算中拒绝 symlink、junction 或其他 reparse point。`.git` 或 `__pycache__` 无论是目录还是普通文件都不进入安装载荷；`.pyc` 只在它是文件时排除，同名普通目录属于受绑定载荷。被排除元数据若原先存在于 active skill，只保留在该次 update 的事务回滚备份中，不复制进新 active payload。候选已有 `SOURCE.md` 时，最后一个独立 `---` 分段必须无歧义地包含与目标目录一致的 `Skill`；仅未知字段、空值或冲突均在写入前拒绝。候选没有 `SOURCE.md` 时，wrapper 才生成新的受管记录。候选 `SOURCE.md` 在追加受管记录后仍命中本机临时根、当前 candidate 或原始 decision manifest 路径时拒绝事务；只有 wrapper 生成且值精确匹配的 `Local path`、`Active root`、`Guarded transaction evidence` 和 `Decision manifest` 字段可在自定义测试根下豁免临时根检查，不能用共同祖先遮蔽其他路径。

菜单身份预检是 `candidate_integrity` 之后、`SOURCE.md` 受管追加和 active/state 备份之前的独立硬门槛。它不把展示名强制改写成目录 slug，也不翻译任何字段；只接受由可打印 ASCII 组成的 `interface.display_name`，从而保留上游英文名称和品牌写法。缺少 `agents/openai.yaml` 或 `interface.display_name` 不由该门槛补造字段，仍由候选治理和其他 schema 校验决定是否可接受。

`bundled_skills` 只允许用于单个本地 `--candidate`。每一项只能包含 `path` 和 `name`：`path` 必须是 candidate 内不含绝对路径、反斜杠、空段、`.`、`..`、`.git` 或 `__pycache__` 的 POSIX 相对目录，`name` 必须与该目录 `SKILL.md` 的 frontmatter 完全一致，且不能与顶层目标或其他 bundled skill 仅大小写不同。目录必须包含安全普通文件 `SKILL.md` 与 `SOURCE.md`；当前 provenance 记录必须有一致的 `Skill`，以及不含用户信息、query 或 fragment 且带 hostname/path 的 HTTPS `Source repository`、`Upstream path`、`Ref` 和 `Commit or revision`。暂存态与 live 态都按 `<top-level-name>/<bundled-path>` 校验唯一 ledger coverage、catalog 相对路径和两个 provenance 文件的 SHA-256。`manifest.skills` 仍只声明顶层安装目标，不能把 bundled 路径伪装成额外顶层安装目录。

`source.upstream_path` 只用于已审查的 `--candidate`：它把本地暂存候选映射回真实仓库子路径，确保新写入的 `SOURCE.md` 可精确追溯。仓库根使用精确值 `.`；其他值必须是仓库内的 POSIX 相对路径，不接受绝对路径、反斜杠、反引号、不可打印字符、空段、`.` 或 `..` 路径段。省略时为兼容旧调用仍回退到候选目录名。它与 `source.ledger_updates.path` 不同，后者是统一来源台账已有的本地路径字段。

`decision=update` 才允许替换已有 active skill。直接调用 `.system\skill-installer`、手工复制到 active root 或跳过 decision manifest，都不算完成的安装流程。

本机允许重放的官方 `.system` local overlay 使用同一事务入口，并在 manifest 中显式绑定 `target_scope: "system"`。该分支只接受经过 `candidate_integrity` 绑定的本地 candidate；frontmatter 与 `manifest.skills` 仍使用 canonical basename，目录换入、`SOURCE.md` identity、ledger key 和 catalog postcheck 使用 `.system/<name>`。catalog 生成与 strict resource closure 始终以顶层 active root 为输入，禁止把 `.system` 子目录伪装成新的 active root。该分支当前不承载 canonical rename、merge retirement 或 bundled skill。

`skill-creator` 的 quick_validate 兼容更新须分别绑定 ledger 中的 official baseline 与当前 effective baseline：decision manifest 的 `official_integrity` 等于既有 official 记录，active payload 及其 `SOURCE.md` 必须匹配 ledger 当前有效态。已有 `display-only`（底层为 `none`）时，兼容层的 `base_overlay` 完整保留该展示投影及 `baseline_file_sha256`，`baseline_integrity` 保留此次更新前的有效指纹；不把中文化内容重新认定为官方原文。`SOURCE.md` 保留旧记录字节并追加新的 current record，当前记录继续使用原官方指纹并注明展示层及更新前有效基线。候选差异仍严格限定为 `SKILL.md`、`scripts/quick_validate.py`、`scripts/test_quick_validate.py` 三个文件；其他未知底层 overlay、active/SOURCE 漂移或 postcheck 不一致均失败闭锁或回滚。

`source.ledger_updates` 可选且只允许更新 `action`、`installed_version`、`path`、`repo_stars`、`repo_stars_checked_at`、`resource_paths`、`status`、`tag`。`action`、`installed_version`、`path`、`status`、`tag` 和 `resource_paths` 各项必须是非空、可打印且无首尾空白的规范字符串。`repo_stars` 必须是非负整数，`repo_stars_checked_at` 必须是规范 ISO 日期，且两者必须成对提供，使采用度数值始终带观测日期。未知字段、错误类型、非规范字符串或缺少配对字段会在 activation 前拒绝事务，避免 decision manifest 静默改写任意台账内容。

本地 overlay 变更在目标 source 的 `local_changes` 中按 skill 独立记账，每条记录必须包含 `skill`、`date` 和 `summary`，并以 `(skill, summary)` 去重。兼容旧账本时，同摘要且缺少 `skill` 的 legacy 记录只允许依次归属给本次事务中的一个 skill；其余 skill 必须追加完整记录，不能因共享摘要而丢失归因。

### Bundled system provenance atomic repair

`--system-provenance-repair-plan <json>` 是独立的 bootstrap/repair 模式，不进入普通 candidate install/update 分支，也不改变其 full-root closure。它只接受固定顺序的 `imagegen`、`openai-docs`、`review-agent`、`skill-creator`、`skill-installer` 五项（2026-10-07 起五项化：`plugin-creator` 已被 Codex Desktop 26.928+ 官方刷新从 `.system` 移除，其 stale ledger 条目按上游移除摘除），并要求 `codex-bundled-system-skills` 在 unified ledger 中唯一覆盖该精确集合。`atomic-six-skill-*` 模式名是历史 schema 标识，按 `schema_version` 兼容保留。

Repair plan 必须精确绑定 schema/mode、受管 `system_package_identity.py` 的 SHA-256、当前 `OpenAI.Codex` Store package full name/family/version/publisher、`SignatureKind=Store`、签名 `Valid`、AppX `Ok`、install location、`AppxManifest.xml` 与 `AppxSignature.p7x` 路径和 SHA-256、`.codex-system-skills.marker` 路径和 SHA-256、ledger/catalog 原始 SHA-256，以及五项各自排除 sibling `SOURCE.md` 后的 official/effective tree 与 `SKILL.md` hash。按漂移来源选择 mode：

- `atomic-six-skill-bootstrap`：官方刷新后重建来源。`review-agent` 绑定 `agents/openai.yaml` hash 与 `allow_implicit_invocation: false`，payload 只插入 `disable-model-invocation: true`；其余四项 official/effective integrity 相同。
- `atomic-six-skill-display-reconcile`：已有来源记录且只发生展示中文化后对账。每项 `overlay` 包含 `kind: "display-only"`、`baseline_files`（旧有效态 `SKILL.md` 和存在时的 `agents/openai.yaml` 完整 UTF-8 文本）及 `base_overlay`。将这些旧文本覆盖到当前树后，整树必须精确命中旧 ledger 的 effective integrity；official integrity、SOURCE 前哈希、critical file 键集合和底层 overlay 必须继承旧记录。旧记录已是 display-only 时继承其 `base_overlay`，不嵌套 display overlay。

Display 对账只接受 `SKILL.md` frontmatter `description` 和 `agents/openai.yaml` 的 `interface.short_description/default_prompt` 字符串值变化。YAML 解析拒绝重复键、非字符串键和字段存在性/类型变化；屏蔽展示 scalar 后还比较原文，正文、调用策略、注释及其他资源必须保持。ledger 保存 baseline 文件哈希投影而非原文，分别记录保留的 official baseline、本次 effective tree 和底层 overlay。缺少可验证的旧有效态时保留 pending，不把翻译后的树重新归因为官方原始树。

事务在写前两次核验 repair plan/provider 的 identity+bytes、Store package 路径 identity+hash、marker identity+hash、五目录 identity+tree、critical payload、SOURCE baseline、ledger 和 catalog。Bootstrap 联合备份五个 SOURCE、`review-agent/SKILL.md`、ledger、catalog；display reconcile 只备份和写入五个 SOURCE、ledger、catalog 共七个 metadata 文件，payload 不 stage、不替换。随后运行 catalog `--write`、strict closure、catalog/ledger/SOURCE/hash/parity postcondition，并按 plan 执行至少两次稳定性观测。默认 live active root 的观测间隔不得低于 10 秒；该门槛只证明 bounded stability，不把 Codex runtime 进程停掉或改造成受管对象。菜单工具后续再次改写展示字段时，需以新现场事实重复对账。

任一 schema、package、marker、tree、critical payload、CAS、catalog、closure、postcondition 或稳定性检查失败时，按每个目标的 original/current/written bytes 做 CAS 联合回滚。目标已回到 original bytes 视为已恢复；目标既非 original 也非本事务 written bytes 时保留现场、标记 `rollback-failed` 并写入 evidence。Repair 生成的 SOURCE 只记录已观察的 Store package/marker/hash 与 ledger source-group 事实，不声明未知的 public upstream repo/commit；review-agent 的 SOURCE 与 ledger 同时区分 official baseline 和本机 invocation parity overlay。

普通 `target_scope: "system"` 的 candidate update 不得用 `local_changes` 代替
system provenance。当前唯一受管的 candidate payload overlay 是
`system_provenance_overlay.kind = "skill-creator-quick-validate-compatibility"`，
并且必须绑定 `.system/skill-creator`、Store identity provider SHA-256、
SOURCE-excluding official/effective tree integrity、恰好三份 critical files
(`SKILL.md`、`scripts/quick_validate.py`、`scripts/test_quick_validate.py`) 及固定
契约（`argument-hint` 为 string、`disable-model-invocation` 为 boolean、非字符串
key 和未知 frontmatter 字段拒绝）。wrapper 在换入前后用目录 identity、payload
inventory、marker/provider CAS 和 catalog/ledger postcondition 复核；任一检查失败
按目录与 state CAS 回滚，外部并发字节不被覆盖。ledger 只保存 overlay 的 hash
projection，不保存候选临时路径或 payload 字节。

受管发布顺序是：源码定向/模块测试通过；`Deploy-SkillInstallGuarded.ps1 -WhatIf` 证明六文件部署闭包；独立 review 通过后才实际部署六文件并核验 deployment manifest/hash；再从当时 live facts 生成新的 repair plan，先 dry-run 后 apply；最后复核稳定性、strict closure、catalog、ledger、五个 SOURCE 与 review parity。只有这些 live 验收通过后，后续任务才可激活依赖该能力的 `subagent-orchestration`；源码存在、WhatIf 或 fixture green 都不等于已部署/已激活。

## Canonical rename

canonical rename 是单候选 `decision=update` 的原子 identity 迁移，不是“安装新名后手工删除旧名”。manifest 必须额外包含：

```json
{
  "decision": "update",
  "skills": ["new-skill"],
  "canonical_rename": {
    "old_name": "old-skill",
    "new_name": "new-skill",
    "source_id": "owner-repo-source",
    "predecessor_source": {
      "upstream_path": "skills/old-skill",
      "ref": "main",
      "commit": "<predecessor-commit>"
    },
    "successor_source": {
      "upstream_path": "skills/new-skill",
      "ref": "main",
      "commit": "<reviewed-commit>"
    }
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

`canonical_rename.new_name` 必须等于唯一 candidate 目标和 manifest `skills` 中显式声明的唯一名称，`old_name` 必须是当前唯一 active predecessor，`source_id` 必须与 `source.id` 及覆盖旧名的唯一 ledger source entry 完全一致，并且该 id 在 live `sources` 中只能出现一次。`predecessor_source` 和 `successor_source` 都必须精确包含 `upstream_path`、`ref`、`commit`；successor 必须与顶层 `source` 的对应字段一致。direct-entry coverage 的 `name`/`skill` 若同时存在必须指向同一名称，否则在任何 ledger mutation 前失败闭锁。candidate `SOURCE.md` 只把最后一个独立 `---` 分段作为当前追加记录：历史段不参与当前 identity 校验，当前段同一字段出现不同值或空值即为冲突并失败闭锁。当前记录必须无歧义地记录 `Skill`、`Canonical predecessor`、`Source identity`、`Source repository`、`Upstream path`、`Ref` 和 `Commit or revision`；candidate 对照 successor identity，旧 active 的最新 `SOURCE.md` 记录对照 predecessor identity。ledger 继续校验唯一 coverage、source id、repo 和 predecessor ref；组级 ledger commit 可以比单个 predecessor 更新，不能替代两端 `SOURCE.md` 的精确身份绑定。历史追加记录可以保留旧 ref/commit/path，但当前记录字段缺失或冲突、同 repo 错误 identity、错误 predecessor 或版本漂移都在 staging/activation 前失败闭锁。

事务先把旧 active 目录移动到同一 evidence backup，再以 no-replace 语义激活 successor。成功后 ledger 只给新名保留一个 live source coverage，并把旧名记录为 `deleted/status=moved/reason=canonical rename/new_name=<successor>`；catalog 和严格 closure 必须同时通过。activation、ledger、catalog、closure 或后置 hash 任一步失败时，按逆序移除本事务创建的新目录、恢复旧目录及其只读属性，并原样恢复 ledger/catalog；由竞争者创建的 successor 不属于本事务，必须保留。

## Cross-source merge retirement

当一个 active skill 的职责已经分别并入不同来源的 survivor 时，使用单候选 `decision=update` 的 `merge_retirement`，不能伪装成同源 canonical rename，也不能先安装后手工删除：

```json
{
  "decision": "update",
  "skills": ["leader"],
  "merge_retirement": {
    "retired": {
      "name": "decision-to-brief",
      "source_id": "local-candidate-decision-to-brief",
      "skill_md_sha256": "<64-hex-sha256>",
      "tree_seal": {
        "directory_count": 1,
        "file_count": 3,
        "tree_sha256": "<64-hex-sha256>"
      }
    },
    "survivors": [
      {
        "name": "goal-first",
        "skill_md_sha256": "<64-hex-sha256>"
      },
      {
        "name": "leader",
        "skill_md_sha256": "<64-hex-sha256>"
      }
    ],
    "reason": "merged into goal-first and leader"
  }
}
```

`merge_retirement` 只允许单个本地 candidate update，且不能与 `canonical_rename` 同时出现。退役对象必须与 update 目标属于不同 source id，名称按 Windows 大小写折叠后也不能相同；所有 direct-entry 和 `skills` ledger coverage 同样按大小写折叠比较，大小写别名属于同一 live identity，不能绕过唯一覆盖门禁。`retired` 精确绑定 active frontmatter name、唯一 live ledger source coverage、`SKILL.md` SHA-256 和整树 seal。update 目标必须由 manifest 中 survivor source id 的唯一 live `sources` 条目覆盖，同仓库的其他 source id 不能替代。survivors 至少包含本次 update 目标，名称不得重复或等于退役对象；目标 survivor 绑定 candidate `SKILL.md`，其他 survivor 绑定当前 active `SKILL.md`。

事务在 active/state 备份前和真正写入前各复验一次所有绑定。写入阶段先把退役 active 移到同一事务 backup，再激活 update candidate；随后 ledger 移除退役 live coverage，在原 source entry 和顶层 `deleted` 各记录 `deleted-by-user`、reason、survivors、source id、旧 `SKILL.md` 哈希和旧整树 seal。catalog 重建和 strict closure 通过后，还必须证明：

- 退役 active 路径不存在；
- 重新读取的磁盘 ledger 与本事务写入结果精确一致；
- `sources` 与 `unresolved` 不再覆盖退役名称，且顶层 `deleted` 与 retired source 的 `deleted_skills` 记录都唯一完整；direct-entry source 在移除退役名称后规范化为显式空 `skills` 数组；
- catalog 不再包含退役 active artifact；
- 每个 survivor 的 active `SKILL.md`、catalog hash 和 ledger coverage 与 manifest 一致。

任一 activation、ledger、catalog、closure 或 postcondition 失败都恢复退役 skill、update 目标、ledger 和 catalog。成功事务保留一次可恢复 backup，并在结果中标记 `backup_cleanup=required-after-transaction-success`；调用方完成独立 active/hash/ledger/catalog/closure 验收后，必须只用 `D:\Codex\.codex\scripts\invoke-safe-tree-delete.cmd` 的 Plan/Apply/Purge 删除该精确 backup。最终退役证据只保留旧内容 seal、哈希、ledger 动作与安全删除 transaction，不保留 payload 副本。

## 可维护性

部署入口必须以隔离模式验证目标受管 Python 可以导入 PyYAML，并确认 `yaml.safe_load` 可调用；真实 `install-skill-guarded.cmd` 也必须用 `python -X utf8 -I` 启动 wrapper，使部署探针与运行态保持相同的导入隔离，并避免非 UTF-8 Windows runner 在输出中文帮助时触发编码失败。缺失、同名模块劫持或 API 不兼容时不得报告部署成功。

项目源部署闭包的 Python 实现位于 `modules\skill-supply-chain\implementation\`，由 `skill_source_record.py`、`generate_skill_catalog.py`、`system_skill_provenance_repair.py`、`system_package_identity.py`、`install_skill_guarded.py` 组成，command adapter 仍位于根 `scripts\install-skill-guarded.cmd`；根目录 `scripts\` 同时保留稳定 Python adapters，部署脚本从 module implementation 复制 Python runtime 并绑定 command adapter。部署后 installer、catalog 与 system repair 从同目录加载各自受管依赖，不依赖项目源仓库路径。通过 `scripts\Deploy-SkillInstallGuarded.ps1` 部署到本机 D 盘入口。`D:\Codex\.codex\scripts\` 中的同名文件是部署产物，不可单独热修；紧急修复必须先回迁 module implementation、通过相关测试，再由部署脚本替换并留下 deployment manifest。catalog 仍是派生快照，ledger 与各 skill 的 `SOURCE.md` 仍是来源事实。
