---
type: reference
title: CC Switch 迁移逐记录验收
tags: [CC Switch, 更新, 验收]
intent: 用只读快照比较原模板和 MCP，并严格限制已审查的原生配置导入
---

# CC Switch 迁移逐记录验收

入口是 `scripts/daily-update/compare-cc-switch-migration.py`。在升级前建立受保护的 SQLite backup API 快照和 native 配置快照；升级后再建立独立快照。工具只接受已封存、无 `-wal`、`-shm`、`-journal` 的普通文件，拒绝 reparse 路径。它以 `mode=ro&immutable=1`、`query_only` 和单个读事务读取每份库，前后核对所有输入 hash，避免修改业务库或创建 sidecar。需要读取运行中数据库时，由既有受控备份步骤先生成一致快照；不能直接把 live 路径交给本工具。

```powershell
python scripts/daily-update/compare-cc-switch-migration.py --before D:/protected/before.db --after D:/protected/after.db --policy D:/evidence/reviewed-migration-policy.json --native-snapshot D:/protected/native-before.toml
```

stdout 只有脱敏 JSON：版本、计数、匿名 selector hash、记录 hash、固定原因码和输入 hash。exit0 为通过；exit1 为迁移差异被拒；exit2 为输入、绑定或完整性无法验证。原始配置值、URL、凭据、provider 名称和 SQLite 错误正文不输出。OAuth 文件引用只作为 TOML 数据比较，不追踪或打开凭据文件。

## 验收范围

每个原 `providers` 和 `mcp_servers` 记录按主身份逐条比较所有原字段；分别列 unchanged、changed、missing、added。JSON 列按 JSON 值语义比较，其他列按类型和值比较。所有旧 MCP enable 标志保留。旧列定义必须保持，新增列集合、定义及所有记录的该列值必须精确匹配 policy。

新增 MCP 一律拒绝。新增 provider 只允许 policy 明列的 Kimi 原生导入：必须 inactive、selector 在升级前 native snapshot 中存在、`settings_config` 等于官方 `kimi_config::get_providers` 的 provider/models 投影，且其余全部字段匹配已审查的 metadata hash。原记录删除、修改、未知新增、未声明 schema 或列变化均退出1。

本工具只验 `providers` 与 `mcp_servers`；输出 `other_tables_checked=false`。程序签名、其他数据库表、客户端文件、权限、进程、联合回滚和 host Check 仍由组件升级流程验收，不能用本工具通过代替整项完成。

## Policy

policy 必须来自目标官方版本迁移说明/源码和已审查的导入行为。不能从待验 after 库自动生成允许列表后再声称该库通过验收。首次遇到新迁移时，先只读审查并建立 policy，再重新比较；不把总行数或总集合 hash 变化直接判为旧模板损坏。

schema1 固定六个字段，额外字段拒绝：

```json
{
  "schema_version": 1,
  "before_user_version": 21,
  "after_user_version": 23,
  "added_columns": {
    "providers": {},
    "mcp_servers": {
      "enabled_kimi": {"type":"BOOLEAN","notnull":1,"default":"0","pk":0,"value":0},
      "enabled_omp": {"type":"BOOLEAN","notnull":1,"default":"0","pk":0,"value":0}
    }
  },
  "new_kimi_rows": [],
  "native_snapshot_sha256": null
}
```

上述例子只允许两列变化，不允许新增 provider。确有已审查的 Kimi 导入时，`new_kimi_rows` 每项为 `selector_sha256` 和 `metadata_sha256`，并提供 `native_snapshot_sha256` 及对应 `--native-snapshot`。所有 hash 均为小写 SHA-256：selector 是 `[id, "kimi"]` 的规范 JSON；metadata 是除 `settings_config` 外全部新行字段的规范 JSON（`meta` 先解析为 JSON）。规范 JSON 使用 UTF-8、键排序、无多余空格、保留 Unicode；禁止非有限数和重复键。声明的导入集合必须全部出现，不能用宽泛通配规则。

2026-10-26 已审查的 v4.0.20 对照基线在 `D:/agents/run-evidence/daily-codex-ecosystem-update/20261026-120001-authorized-six/cc-switch/MIGRATION-READONLY.md`；该快照不授权后续版本任意新增。

回归入口：`python -B tests/Test-CCSwitchMigration.py`。测试使用独立合成 SQLite/TOML，覆盖合法导入、原行修改/删除、MCP 标志、新列、新增记录、native hash 和敏感输出边界。
