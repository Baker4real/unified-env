# Task 2 缺失 SQLite sidecar 实施报告

## Status

DONE（生命周期热路径已安全收口）

## 实施内容

- `run_policy` 在任何 global JSON 发布前先检查 SQLite source-set；缺失 WAL 或 SHM、或已有 sidecar 字节不可观测时，返回 `generation-unbounded`/`unsafe-partial` 或不可写错误，不产生跨域 partial。
- 生命周期 `run_policy` 的默认热路径对任何已存在的 `state_5.sqlite-shm` 返回 `generation-unbounded` + `cold-maintenance-required`，write/repair 追加 `unsafe-partial`，check-only 追加 `repair-required`；全部在 global JSON 发布前返回，不创建 journal 占位、不写任何 state。
- 新增显式冷维护契约：只有传入 `cold_maintenance=True` 和匹配 `codex-state-cold-maintenance-v1` 的 `maintenance_evidence`（绑定 `codexHome`、`sqliteStopped=true`、`backupVerified=true`）才允许继续 WAL/SHM 写入；直接调用 `update_thread_state` 的默认热路径同样拒绝 WAL/SHM，不能绕过生命周期门。旧的 missing-journal placeholder/return-lease 逻辑不再由热路径调用，避免 SQLite connection 到 SHM 120..127 完整锁之间的不可原子交接。
- 只读观察仍保留严格身份/元数据/内容门：活动连接无法直接 `ReadFile` 时仅允许只读 mmap 读取 SHM payload；mmap 不可建立则 fail-closed，不能退回仅比较 size/mtime/identity。严格 gate 传入 SHM index 2 做完整 payload 比较。
- 补充 RED/GREEN：offset 120/122/127 原位写入后恢复 mtime 的 lifecycle 攻击不会得到成功；strict snapshot gate 在同一 identity/metadata 下拒绝 122/127 payload 变化；不可观测 SHM 明确返回 unsafe-partial；缺少冷维护 evidence 或默认 check-only 时保持 global 不变，合法 evidence 的 cold WAL+SHM 写入可正常收敛。

## 验证

- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePolicy.py -q`：107 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-CodexStatePathInventory.py -q`：17 tests，全部通过；`Test-SkillCatalog.py`：16 tests，全部通过。
- `D:\Codex\tools\python314-official\python.exe -W error::ResourceWarning -m unittest tests/Test-SkillCatalog.py -q`：16 tests，全部通过。
- `D:\Codex\tools\PowerShell\7.6.3\pwsh.exe -NoProfile -File tests\Test-CodexHookPolicy.ps1`：通过。
- `D:\Codex\tools\python314-official\python.exe -m py_compile managed\codex-hooks\hooks\codex-state-policy-guard.py tests\Test-CodexStatePolicy.py`：通过。
- `git diff --check`（本任务文件）：通过；测试生成的临时目录、SQLite probe 和 `__pycache__` 已清理。
- live check-only：`codex-state-policy-guard.py --codex-home D:\Codex\.codex --check-only --json` 退出码 1（预期 fail-closed），`ok=false`、`changed=false`、`converged=false`，错误含 `generation-unbounded`/`cold-maintenance-required`/`repair-required`；global、SQLite 主库/WAL/SHM、config 哈希前后一致，`D:\Codex\.codex\tmp\codex-state-policy-check` 前后均不存在。

- 新增回归：`test_run_policy_rejects_shm_lock_byte_mutation_during_output` 覆盖 SHM 偏移 120、122、127 的 metadata-restore 攻击并确认 lifecycle 预检先 fail-closed；`test_sqlite_strict_gate_rejects_shm_metadata_restore` 覆盖同 identity/metadata 下 122/127 payload 变化；`test_run_policy_write_requires_observable_shm_lock_window` 覆盖 mmap 不可观测的维护前置。

## 边界

- 未触碰 live `D:\Codex\.codex` 状态、网络、代理或生产 hook 注册；live check-only 仅读检查并返回 `repair-required`，global/config/SQLite 指纹未变且临时 snapshot root 不存在。默认热路径不会写 WAL/SHM；冷维护入口必须由停止 SQLite、完成备份和可观测 SHM 的维护步骤生成 evidence 后显式调用；`serena-auto-approve` 等非 state hook 未在本任务中恢复。
