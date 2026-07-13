# Task 2 缺失 SQLite sidecar 实施报告

## Status

DONE

## 实施内容

- 写入/修复 `run_policy` 在任何 global JSON 发布前预检 SQLite 的 WAL/SHM/journal source-set；任一 sidecar 缺失即返回 `generation-unbounded` + `unsafe-partial`，不产生跨域 partial。
- `SqliteTargetLease.assert_no_create()` 与 `run_return_gates()` 仍保留对完整 source-set 的晚到 journal/reparse 防线；缺失 source-set 不再依赖不可靠的 no-create primitive。
- `_sqlite_generation_unbounded()` 对初始缺失的 WAL、SHM、journal 一律 fail-closed；check-only/inventory 路径仍可读取和报告合法 cold-start。
- 新增真实 WAL fixture、late journal、journal reparse、WAL/SHM/journal source-set 判定、跨域不发布和单行 fail-closed 输出测试；WAL 写入 cold-start 明确验证为拒绝，不声称修复成功。

## 验证

- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePolicy.py -q`：95 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePathInventory.py -q`：17 tests，全部通过；`Test-SkillCatalog.py`：16 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-SkillCatalog.py -q`：16 tests，全部通过。
- `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe -NoProfile -File tests\Test-CodexHookPolicy.ps1`：通过。
- `D:\Codex\tools\python314-official\python.exe -m py_compile managed\codex-hooks\hooks\codex-state-policy-guard.py`：通过。
- `git diff --check`（本任务文件）：通过；测试生成的临时目录、SQLite probe 和 `__pycache__` 已清理。
- live check-only：`codex-state-policy-guard.py --codex-home D:\Codex\.codex --check-only --json` 退出码 0，`ok=true`、`changed=false`、`threadState.integrityOk=true`；仅报告现有 drift，不写 live state。

## 边界

- 未触碰 live `D:\Codex\.codex` 状态、网络、代理或生产 hook 注册；只修改受管 state guard、测试和本报告。
