# Task 2 缺失 SQLite sidecar 实施报告

## Status

DONE

## 实施内容

- `run_policy` 在任何 global JSON 发布前先检查 SQLite source-set；缺失 WAL 或 SHM、或已有 sidecar 字节不可观测时，返回 `generation-unbounded`/`unsafe-partial` 或不可写错误，不产生跨域 partial。
- 对合法生产 WAL+SHM、无 rollback-journal 的 write generation，新增 Windows 缺失名称 lease：`CREATE_NEW` + no-share + `FILE_FLAG_DELETE_ON_CLOSE`。占位文件只用于阻止创建/替换，逻辑快照仍将 journal 视为缺失；若 journal 在存在性检查后出现，`CREATE_NEW` 直接失败，不会获取或删除竞争文件。
- `SqliteTargetLease.assert_no_create()` 与两次连续 `run_return_gates()` 复用该 lease，并逐次验证句柄身份；外部普通写入、journal 创建和 junction/reparse 替换均在最后 gate 被真实阻断。
- write-mode WAL 提交后的 return lease 先关闭 no-op SQLite writer transaction，再把同一 SHM handle 的 120..127 lock-byte window 升级为独占 `LockFileEx`，重新捕获完整 WAL/SHM generation，并以 detached lease 对全部 sidecar 做严格内容 gate；因此 offset 120、122、127 的输出期写入均被系统阻断。升级或交接失败时 fail-closed，不发布假成功。
- `check_only` 保留只读 `SqliteTargetLease` 到输出返回完成：连接使用 `query_only=on` + deferred `BEGIN`，先物化 WAL 读取页，再持有 main/journal 独占和 WAL 完整范围锁；SHM 因 SQLite 自有 reader lock 保持兼容分裂，但不跳过严格内容/hash gate，未知 SHM 内容直接 fail-closed。整个路径不执行 `BEGIN IMMEDIATE`、不写数据库；输出前和输出后连续 strict snapshot gate 覆盖 row、main、WAL/SHM 变化。
- `_sqlite_generation_unbounded()` 允许仅缺失 journal 的 WAL write generation；缺失 WAL/SHM 仍 fail-closed。check-only 不创建物理占位文件：遇到 WAL+SHM/无 journal 时，在任何 global 发布前返回 `generation-unbounded` + `repair-required`，并保持 `changed=false`、`converged=false`。
- 恢复 nonzero-offset main SQLite byte-range regression，并补充真实 WAL 写入成功、write-mode SHM lock-byte 120/122/127 输出阻断、check-only 主库/行写入阻断、未知 SHM 内容拒绝、竞争 journal 不删除、check-only 无占位 fail-closed、late journal/reparse 阻断、source-set 判定、跨域不发布和单行 fail-closed 输出测试。

## 验证

- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePolicy.py -q`：102 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePathInventory.py -q`：17 tests，全部通过；`Test-SkillCatalog.py`：16 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-SkillCatalog.py -q`：16 tests，全部通过。
- `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe -NoProfile -File tests\Test-CodexHookPolicy.ps1`：通过。
- `D:\Codex\tools\python314-official\python.exe -m py_compile managed\codex-hooks\hooks\codex-state-policy-guard.py tests\Test-CodexStatePolicy.py`：通过。
- `git diff --check`（本任务文件）：通过；测试生成的临时目录、SQLite probe 和 `__pycache__` 已清理。
- live check-only：`codex-state-policy-guard.py --codex-home D:\Codex\.codex --check-only --json` 退出码 1（预期 fail-closed），`ok=false`、`changed=false`、`converged=false`，错误含 `generation-unbounded`/`repair-required`；global、SQLite 主库/WAL/SHM、config 哈希前后一致，`D:\Codex\.codex\tmp\codex-state-policy-check` 前后均不存在。

## 边界

- 未触碰 live `D:\Codex\.codex` 状态、网络、代理或生产 hook 注册；只修改受管 state guard、测试和本报告。写模式的缺失 journal lease 仅在受控 `run_policy` fixture/生产入口中建立并在 finally 删除占位；check-only 从不创建该占位。
