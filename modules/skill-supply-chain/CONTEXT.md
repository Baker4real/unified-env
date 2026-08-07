---
type: reference
title: Skill 供应链模块上下文
tags: [skill, 模块, 供应链]
intent: 定义 Skill 来源、安装、catalog、ledger 和发布政策的责任边界
---

# Skill 供应链模块

## 范围

本模块拥有 guarded install、跨来源 merge retirement、`SOURCE.md`/ledger 一致性、资源闭包、本机 Skill Catalog 和 GitHub default-branch overlay 政策。

## 不属于本模块

- Codex hook 注册和 remote available catalog 的目录守卫属于 `codex-host`。
- 递归目录删除能力属于 `host-safety`。

## 权威合同

- `docs/specs/2026-07-14-skill-install-guarded-wrapper.md`
- `docs/plans/2026-07-13-local-skill-catalog-implementation.md`
- `docs/specs/2026-07-13-github-default-branch-skill-policy-design.md`

最后一份 dated spec 的后半段仍承载现役 `main`-only 合同、overlay 重放门禁和验收条件，因此不能整份归档。GitHub plugin 的 2026-08-07 upstream 漂移已经闭合；未来新指纹仍按未知输入失败关闭。

## 接口与测试

对外接口是 `scripts/install-skill-guarded.cmd`、根目录 Python adapters、`scripts/Deploy-SkillInstallGuarded.ps1` 和受管 overlay/deploy 入口。四文件安装闭包的 Python 实现与热点测试位于本模块的 `implementation/`、`tests/`；command adapter 仍由根 `scripts/install-skill-guarded.cmd` 提供，部署脚本从 module implementation 加载 Python 文件并绑定该 command adapter。跨来源职责合并通过 installer 的 `merge_retirement` decision manifest 字段完成；成功 backup 必须在独立验收后由受管安全树删除入口清理。专项测试列在 `modules/manifest.json` 的 `python` 和 `node` 清单中。

旧 `SOURCE.md` 末尾记录的 schema 迁移只允许使用
`scripts/reconcile_skill_source_records.py`：它在隔离镜像达到 strict
zero-conflict 后，仅追加规范 current record，并为整批 SOURCE、统一 ledger、
catalog 和四文件 runtime 建立受 ACL 保护的联合回滚点。迁移不得改写历史
记录、`SKILL.md` 或 plugin cache；任一身份/标量歧义必须整批失败关闭。

## 已知漂移

仓库源中的四文件部署闭包由 `skill_source_record.py`、catalog generator、installer 与 command wrapper 组成；installer 与 catalog 从同目录加载共享 parser，不依赖项目源仓库路径。现役 `D:\Codex\.codex\scripts\` 是否已包含该闭包只以受管部署 manifest 与现场 hash 为准，不能由仓库源存在推断。后续源文件变更、移动或拆分仓库前必须重新执行受管部署并核验 hash。当前仍依赖 active `skill-install-guard` 的 closure 脚本和官方 system installer，且事务内部还有待迁移的递归删除。在这些依赖、独立 fixture 和受管删除全部收敛前，本模块不拆出独立 Git 仓库。
