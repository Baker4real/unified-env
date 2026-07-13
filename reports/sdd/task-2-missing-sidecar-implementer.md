# Task 2 缺失 SQLite sidecar 实施报告

## Status

DONE

## 实施内容

- `run_policy` 在任何 global JSON 发布前先检查 SQLite source-set；缺失 WAL 或 SHM、或已有 sidecar 字节不可观测时，返回 `generation-unbounded`/`unsafe-partial` 或不可写错误，不产生跨域 partial。
- 对合法生产 WAL+SHM、无 rollback-journal 的 generation，新增 Windows 缺失名称 lease：`OPEN_ALWAYS` + no-share + `FILE_FLAG_DELETE_ON_CLOSE`。占位文件只用于阻止创建/替换，逻辑快照仍将 journal 视为缺失；预留后立即重新快照，覆盖捕获到占位之间的竞态。
- `SqliteTargetLease.assert_no_create()` 与两次连续 `run_return_gates()` 复用该 lease，并逐次验证句柄身份；外部普通写入、journal 创建和 junction/reparse 替换均在最后 gate 被真实阻断。
- `check_only` 也保留只读 `SqliteTargetLease` 到输出返回完成：连接使用 `query_only=on` + deferred `BEGIN`，先物化 WAL 读取页，再持有 main/journal 独占和 WAL 完整范围锁；SHM 因 SQLite 自有 reader lock 保持兼容分裂，但不跳过严格内容/hash gate，offset 120..127 的突变会被 fail-closed。整个路径不执行 `BEGIN IMMEDIATE`、不写数据库；输出前和输出后连续两次 strict snapshot gate 覆盖 row、main、WAL/SHM 变化。
- `_sqlite_generation_unbounded()` 允许仅缺失 journal 的 WAL generation；缺失 WAL/SHM 仍 fail-closed。write 与 check-only 均在缺 journal 时短暂持有 `OPEN_ALWAYS`/`DELETE_ON_CLOSE` no-share placeholder，保证最后 gate 的 lstat→create 窗口；check-only 结束后删除占位且不改变 live 状态。
- 恢复 nonzero-offset main SQLite byte-range regression，并补充真实 WAL 写入成功、check-only 输出期 row/main/WAL/SHM lock-byte 突变阻断、late journal/reparse 阻断、source-set 判定、跨域不发布和单行 fail-closed 输出测试。

## 验证

- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePolicy.py -q`：102 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePathInventory.py -q`：17 tests，全部通过；`Test-SkillCatalog.py`：16 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-SkillCatalog.py -q`：16 tests，全部通过。
- `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe -NoProfile -File tests\Test-CodexHookPolicy.ps1`：通过。
- `D:\Codex\tools\python314-official\python.exe -m py_compile managed\codex-hooks\hooks\codex-state-policy-guard.py`：通过。
- `git diff --check`（本任务文件）：通过；测试生成的临时目录、SQLite probe 和 `__pycache__` 已清理。
- live check-only：`codex-state-policy-guard.py --codex-home D:\Codex\.codex --check-only --json` 退出码 0，`ok=true`、`changed=false`、`threadState.integrityOk=true`；只读路径不创建缺失 journal 占位，仅报告现有 drift，不写 live state。

## 边界

- 未触碰 live `D:\Codex\.codex` 状态、网络、代理或生产 hook 注册；只修改受管 state guard、测试和本报告。写模式的缺失 journal lease 仅在受控 `run_policy` fixture/生产入口中建立并在 finally 删除占位。
