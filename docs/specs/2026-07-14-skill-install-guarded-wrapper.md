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
2. wrapper 将远端候选下载到 D 盘 staging，或复制已审查的本地候选。
3. wrapper 写入/保留 `SOURCE.md` 和 staging ledger，运行严格资源闭包检查。
4. wrapper 在 active root 下重新创建候选内容，不移动 staging 目录，也不复制 staging 的 owner、DACL 或 SACL；目标目录和文件必须继承本机 active root 的权限。
5. wrapper 备份旧 active skill，再原子换入候选；立即在独立子进程中枚举并读取全部文件，同时验证目标树不存在受保护 ACL。任一项失败都回滚，事务不得标记成功。
6. wrapper 更新 `D:\Codex\.codex\skills\.downloaded-skills-source-state.json`。
7. wrapper 调用 `generate_skill_catalog.py --write`，再运行闭包、catalog 条目、ledger coverage 和 `SKILL.md` SHA-256 复核。
8. 任一步失败都恢复 active 目录和状态文件，并把失败/回滚结果写入 `D:\Codex\.codex\run-evidence\skill-install-guarded\`。

`activation_readability` 只证明安装后的文件系统权限、枚举和读取健康；Skill Catalog 的 `runtime_verification=unverified` 仍表示尚未验证 skill 行为本身，两者不能互相替代。

## Decision manifest 最小格式

```json
{
  "decision": "install",
  "source_status": "source-review",
  "writing_great_skills": { "status": "no-change" },
  "skills": ["example-skill"],
  "source": {
    "id": "owner-repo",
    "repo": "owner/repo",
    "ref": "main"
  }
}
```

`decision=update` 才允许替换已有 active skill。直接调用 `.system\skill-installer`、手工复制到 active root 或跳过 decision manifest，都不算完成的安装流程。

## 可维护性

项目源文件是 `scripts\install_skill_guarded.py` 和 `scripts\install-skill-guarded.cmd`；通过 `scripts\Deploy-SkillInstallGuarded.ps1` 部署到本机 D 盘入口。catalog 仍是派生快照，ledger 与各 skill 的 `SOURCE.md` 仍是来源事实。
