# 功能钩子分层恢复实施计划

> **状态（2026-07-15）：** Task 1–8 已完成到 live registration：4 个有用 host hooks 已通过 reconciler 启用，`Check → Repair(no-op) → Check` 为 `driftCount=0`；canonical path repair 已应用安全映射，剩余歧义项为 review-only。完整重启后的 fresh lifecycle canary 仍待执行。

> **For agentic workers:** Implement this plan task-by-task. Prefer `subagent-driven-development` when available for independent tasks; otherwise use the repository's normal implementation workflow. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留实际防错和 Serena 效率能力的前提下，以无网络单一 state preflight、受控 reminder/cleanup 和显式 provider/GitHub 维护替代旧的多钩子自动写入。

**Architecture:** 热路径只自动修复受控 heartbeat JSON；projectless canonical path 与 active SQLite 在热路径只盘点/报告，分别由批准映射入口和 evidence-bound 冷维护入口显式修复。Serena reminder/cleanup 是独立行为 hook，静态 config/context/hooks 继续由冷路径 reconciler 管理，provider/GitHub 只读检查和显式修复分离。

**Tech Stack:** Windows PowerShell 7.6.3、官方 Python 3.14、SQLite、TOML/YAML 受限解析器、Codex hook JSON 协议、Serena 1.5.3。

## Global Constraints

- 生命周期热路径禁止 URL、curl、DNS、认证、PATH/proxy/User 环境写入、Serena config 写入、hooks registry 写入和 vendor binary 调用。
- `D:\Documents\Codex` 只是候选 canonical root；每条路径必须通过存在性、最终身份和 reparse 检查，不能全局替换。
- `D:\Users\WINDOWS\Documents\Codex` 不得继续作为目标，因为当前目录不存在。
- heartbeat/SQLite desired policy 必须从当前受控 policy 来源解析，不能硬编码扩大权限；只有 heartbeat 进入生命周期自动写，SQLite 写入必须有显式冷维护 evidence。
- 未知字段、未知文件、未知 hook group、未知 SQLite row 保持不变。
- 所有真实写入使用 D 盘、同目录临时文件、SHA/CAS、备份、原子发布和 postcheck。
- 任何生产注册前先完成 fixture RED/GREEN、合成 payload 和 adversarial review。
- GSD 历史材料不重新启用。

---

### Task 1: 记录 path inventory 的失败行为（已落地）

**Files:**
- Create: `tests/Test-CodexStatePathInventory.py`
- Modify: `managed/codex-hooks/hooks/codex-state-policy-guard.py`

**Interfaces:**
- Produces `build_path_inventory(state, source_root, candidate_root) -> dict`，输出每条 map entry 的 `safe`, `candidate`, `reason`, `reparse`, `sourceSha256`，并保留原始 value。

- [ ] **Step 1: Write failing tests**

测试必须覆盖：root hint 可映射到 `D:\Documents\Codex`；output path 缺失返回 `unresolved-missing`；junction 返回 `unresolved-reparse`；旧 `D:\Users\WINDOWS\Documents\Codex` 不得成为 candidate；未知 map/value 原样保留。

- [ ] **Step 2: Run the focused test**

运行：

```powershell
& 'D:\Codex\tools\python314-official\python.exe' -m unittest tests/Test-CodexStatePathInventory.py -v
```

预期：失败，提示 `build_path_inventory` 尚未定义。

- [ ] **Step 3: Implement the pure inventory function**

只实现纯计算和安全探测，不写 live state：候选路径按 `candidate_root / relative_path` 构造；祖先链遇到 junction/reparse、候选不存在或最终身份不唯一时返回 unresolved；不得把 unresolved value 改成候选值。

- [ ] **Step 4: Run the focused test**

预期：所有 path inventory fixture 通过，且测试 fixture 外没有文件写入。

- [ ] **Step 5: Commit**

```powershell
git add tests/Test-CodexStatePathInventory.py managed/codex-hooks/hooks/codex-state-policy-guard.py
git commit -m "test: define safe projectless path inventory"
```

### Task 2: 将 state policy 拆成 policy source、path inventory 和 state repair（已落地）

**Files:**
- Modify: `managed/codex-hooks/hooks/codex-state-policy-guard.py`
- Modify: `tests/Test-CodexStatePolicy.py`
- Modify: `tests/Test-CodexHookPolicy.ps1`

**Interfaces:**
- `resolve_permission_policy(codex_home) -> PermissionPolicy`：从受控 config/policy 读取 approval/sandbox，缺失或冲突时抛出 `StatePolicyError`。
- `run_policy(..., path_mode, permission_policy) -> dict`：path mode 支持 `inventory`, `repair-safe-only`, `repair-all-approved`，输出 `globalState`, `threadState`, `pathInventory`、`converged` 和 `driftCount`。

- [ ] **Step 1: Add RED tests**

新增测试要求：heartbeat/SQLite 使用解析到的 policy；policy 缺失 fail closed；热路径只修 heartbeat，path inventory 与 active SQLite drift 只报告且不改原 bytes；安全 path 映射只在显式 approved map 中写入，SQLite 只在 evidence-bound 冷维护中写入。

- [ ] **Step 2: Run state tests and record failures**

运行：

```powershell
& 'D:\Codex\tools\python314-official\python.exe' -m unittest tests/Test-CodexStatePolicy.py -v
```

- [ ] **Step 3: Implement policy source and split commit order**

保持现有命名锁和 JSON/SQLite 安全核心。生命周期 preflight 只对 heartbeat JSON 做 CAS/原子发布；path unresolved 和 active SQLite drift 只写 evidence。显式 SQLite 冷维护使用源代绑定备份、`BEGIN IMMEDIATE`、目标 row 过滤、提交后并发重验和返回租约。

- [ ] **Step 4: Run state tests and adversarial cases**

验证 malformed JSON、duplicate key、NaN、WAL、rollback journal、busy mutex、竞争 replacement、third-party row、reparse 和 policy ambiguity 全部 fail closed。

- [ ] **Step 5: Commit**

```powershell
git add managed/codex-hooks/hooks/codex-state-policy-guard.py tests/Test-CodexStatePolicy.py tests/Test-CodexHookPolicy.ps1
git commit -m "feat: split state policy from canonical path repair"
```

### Task 3: 新增 local-only state preflight wrapper（已完成）

**Files:**
- Create: `managed/codex-hooks/hooks/codex-state-preflight.py`
- Create: `managed/codex-hooks/hooks/codex-state-preflight.cmd`
- Create: `tests/Test-CodexStatePreflight.py`
- Modify: `managed/codex-hooks/manifest.json`

**Interfaces:**
- `.cmd` 固定调用官方 Python 和 `codex-state-preflight.py`，不继承任意 cwd。
- `--check-only --json` 返回 `ok`, `converged`, `driftCount`, `domains`, `repairRequired`。
- 无参数生命周期调用保持 stdout 安静；失败只写脱敏 health/evidence 和受控 stderr。

- [x] **Step 1: Write RED wrapper and no-network tests**

测试传入任意 cwd 时仍使用 `D:\Codex\.codex`；环境中设置恶意 proxy/URL 不会产生子进程网络调用；正常收敛不输出 hook protocol 以外内容。

- [x] **Step 2: Run focused tests**

预期：入口、no-network 和 schema 测试失败，直到 wrapper 和 result contract 存在。

- [x] **Step 3: Implement wrapper**

wrapper 只调用 state core，显式拒绝 `--check-network`、`--check-auth`、URL 参数和非授权 Codex home；每域保留独立锁和 evidence。

- [x] **Step 4: Run focused tests**

预期：fixture 和 no-network tests 全部通过。

- [x] **Step 5: Commit**

```powershell
git add managed/codex-hooks/hooks/codex-state-preflight.py managed/codex-hooks/hooks/codex-state-preflight.cmd tests/Test-CodexStatePreflight.py managed/codex-hooks/manifest.json
git commit -m "feat: add local-only state preflight entrypoint"
```

### Task 4: 恢复 Serena reminder、cleanup 和静态 activation reminder（已完成）

**Files:**
- Create: `managed/codex-hooks/hooks/serena-reminder-guarded.cmd`
- Create: `managed/codex-hooks/hooks/serena-cleanup-guarded.cmd`
- Create: `managed/codex-hooks/hooks/serena-activation-reminder.cmd`
- Create: `tests/Test-CodexSerenaBehaviorHooks.ps1`
- Modify: `managed/codex-hooks/manifest.json`

**Interfaces:**
- 每个 wrapper 在启动 vendor 前设置 `SERENA_HOME=D:\Codex\.serena`，固定官方 `serena-hooks.exe`，拒绝外部 executable override。
- reminder 只绑定 `Bash` matcher；cleanup 只绑定 `Stop`；activation reminder 只产生静态 SessionStart additionalContext，不根据 cwd 自动激活。

- [x] **Step 1: Write RED synthetic payload tests**

覆盖 no-op、连续三次 grep/read 后 deny/reminder、Serena 工具调用重置计数、不同 session 目录隔离、空/错误 payload、cleanup 不删除其他 session，以及 activation prompt 包含绝对 workspace 激活要求。

- [x] **Step 2: Run focused behavior tests**

预期：当前 live registry 为空时测试先验证 fixture behavior，不要求生产注册。

- [x] **Step 3: Implement fixed-environment wrappers**

wrapper 必须显式传 `--client=codex`，将 stdout 保留为 vendor 协议，health/evidence 只写 D 盘；不恢复 auto-approve。

- [x] **Step 4: Run focused behavior tests and fresh canary fixture**

验证 User `SERENA_HOME` 为 Hermes 时，wrapper 仍只使用 D 盘 hook state。

- [x] **Step 5: Commit**

```powershell
git add managed/codex-hooks/hooks/serena-reminder-guarded.cmd managed/codex-hooks/hooks/serena-cleanup-guarded.cmd managed/codex-hooks/hooks/serena-activation-reminder.cmd tests/Test-CodexSerenaBehaviorHooks.ps1 managed/codex-hooks/manifest.json
git commit -m "feat: restore Serena reminder and cleanup safely"
```

### Task 5: 分离 provider/GitHub 的本地检查与显式修复（已完成）

**Files:**
- Modify: `managed/codex-hooks/hooks/codex-provider-stability-guard.ps1`
- Modify: `D:\Codex\.codex\hooks\codex-github-cli-guard.ps1` only through its managed source path
- Create: `tests/Test-CodexLocalHealthGuards.ps1`

**Interfaces:**
- `-CheckOnly -Json` 只读 TOML、环境、签名、hardlink 和版本，不写 User/Process 环境、不运行 curl/认证。
- `-Repair -Json` 显式修复；`-CheckNetwork`/`-CheckAuth` 只允许显式 acceptance 命令。

- [x] **Step 1: Write RED tests for no-write/no-network**

测试冻结 User/Process 环境快照，运行 quick check 后 hash 不变；用 stub process list 确认没有 curl、`gh auth` 或 URL 子进程。

- [x] **Step 2: Implement provider scalar result and hard no-network guard**

统一 `@($repairs).Count`，把 `CheckOnly` 与 `Repair` 的 result schema 固定；拒绝从 lifecycle payload 传入 network/auth 开关。

- [x] **Step 3: Run local guard tests**

预期：quick check 只输出脱敏 JSON，显式 repair 才能报告 changed。

- [x] **Step 4: Commit**

```powershell
git add managed/codex-hooks/hooks/codex-provider-stability-guard.ps1 tests/Test-CodexLocalHealthGuards.ps1
git commit -m "fix: separate local health checks from provider repairs"
```

### Task 6: 拆分 legacy fixture manifest 与生产 preflight manifest（已完成）

**Files:**
- Create: `managed/codex-hooks/legacy-fixture-manifest.json`
- Create: `managed/codex-hooks/host-preflight-manifest.json`
- Modify: `scripts/lib/CodexHookPolicy.ps1`
- Modify: `scripts/Get-CodexHookInventory.ps1`
- Modify: `scripts/Invoke-CodexHostHookReconciliation.ps1`
- Modify: `tests/Test-CodexHookPolicy.ps1`
- Modify: `tests/Test-CodexHookInventory.ps1`

**Interfaces:**
- production inventory/reconciler 默认只读取 `host-preflight-manifest.json`；历史部署 fixture 显式传 `-LegacyFixtureManifest`。
- `RequireNoRetiredRegistrations` 必须同时检查 production manifest 不含旧 identity，未知 live registration 仍 preserve/report。

- [x] **Step 1: Write RED manifest separation tests**

测试旧 manifest 不能作为 production apply identity；new production manifest 只包含 state preflight、reminder、cleanup、activation reminder 和静态冷路径 ownership；auto-approve 与旧双写 wrapper 不得出现。

- [x] **Step 2: Implement explicit manifest routing**

保留历史 fixture 测试所需字段，但所有 live entrypoint 使用新的 production manifest，并让旧 ProductionFull façade 继续拒绝生产 profile。

- [x] **Step 3: Run policy/inventory/deployment tests**

运行现有 29 个 PowerShell suite 中所有 hook policy、inventory、deployment、reconciliation tests。

- [x] **Step 4: Commit**

```powershell
git add managed/codex-hooks/legacy-fixture-manifest.json managed/codex-hooks/host-preflight-manifest.json scripts/lib/CodexHookPolicy.ps1 scripts/Get-CodexHookInventory.ps1 scripts/Invoke-CodexHostHookReconciliation.ps1 tests/Test-CodexHookPolicy.ps1 tests/Test-CodexHookInventory.ps1
git commit -m "refactor: separate production preflight manifest from fixtures"
```

### Task 7: 生成 canonical path repair plan 并执行获授权的 state 修复（已完成）

**Files:**
- Modify: `scripts/lib/CodexHookHandleBoundIO.cs`
- Modify: `scripts/lib/CodexHookPolicy.ps1`
- Create: `scripts/Get-CodexStatePathInventory.ps1`
- Create: `scripts/lib/CodexRepairTransaction.ps1`
- Create: `tests/Test-CodexStatePathRepair.ps1`
- Create: `tests/Test-CodexStatePathRepairHardening.ps1`
- Evidence: `D:\Codex\.codex\run-evidence\env-governance\codex-state-preflight\`

**Interfaces:**
- inventory 输出每个 source path、candidate、final identity、reparse state、disposition 和 reason；不得直接改 state。
- repair 只接受 inventory generation id 和 approved mapping hash；缺失/reparse/ambiguous entries 保留并报告。

- [x] **Step 1: Write RED inventory/approval tests**

合成规模门覆盖 171 个 safe、5 个 missing、junction target、ambiguous、竞争创建和 generation/hash 不一致；hardening 必须覆盖批准闭包、文件身份、固定认证消费账本、no-op、apply/restore/automatic rollback 的真实 FailFast 崩溃恢复；这些数量只属于 fixture，真实执行前必须以 fresh live inventory 为唯一事实来源。

- [x] **Step 2: Implement D:\Documents\Codex candidate inventory**

使用绝对路径、D 盘边界、祖先 reparse 检查和最终 regular-file/directory identity；不遍历或搬移 C 盘目录，不删除任何源。

- [x] **Step 3: Run inventory and inspect report**

预期报告明确列出 safe、reparse、missing、ambiguous 四类，不允许只返回一个总数。

- [x] **Step 4: Implement approved repair**

对 fresh live inventory 中已明确批准且最终身份稳定的条目执行 state JSON 原子 CAS；所有 missing、reparse、ambiguous 或未批准条目保持原值并逐项报告，不预设生产数量。

- [x] **Step 5: Run live repair and immediate check**

保存证据，验证批准的 canonical path drift 降为 0 或只剩明确 unresolved；heartbeat 由热路径专项测试收敛；SQLite 修复能力由 evidence-bound 冷维护专项测试证明，不在本次 canonical path repair 中隐式执行。失败进入 unsafe-partial，不覆盖竞争版本。

- [x] **Step 6: Commit code and reports**

```powershell
git add scripts/Get-CodexStatePathInventory.ps1 scripts/lib/CodexRepairTransaction.ps1 scripts/lib/CodexHookHandleBoundIO.cs scripts/lib/CodexHookPolicy.ps1 tests/Test-CodexStatePathRepair.ps1 tests/Test-CodexStatePathRepairHardening.ps1 docs/plans/2026-07-13-functional-hook-preflight.md
git commit -m "feat: repair projectless state with approved canonical mappings"
```

### Task 8: 注册新功能 hook 并做 fresh lifecycle 验收（live registration 已完成，fresh restart canary 待执行）

**Files:**
- Modify live: `D:\Codex\.codex\hooks.json` only through the approved reconciler/registration transaction
- Modify: `D:\Codex\.codex\config.toml` only for explicit static policy fields
- Create: `tests/Test-CodexFunctionalHookRegistration.ps1`

**Interfaces:**
- production registry 只注册经测试的 state preflight、activation reminder、reminder、cleanup；不注册 auto-approve、旧双写、provider network repair 或 GitHub auth repair。
- registration result 必须包含 per-hook identity、timeout、matcher、source hash、wrapper/runtime hash、trust/restart requirement。

- [x] **Step 1: Write RED registration tests**

验证顺序、matcher、timeout、未知 group preserve、auto-approve absence、no-network argument allowlist 和 wrapper environment pinning。

- [x] **Step 2: Implement registration projection**

使用现有 handle-bound/CAS registration transaction，registry 最后发布；任何 source/live drift 停止并保留现状。

- [x] **Step 3: Run synthetic lifecycle tests**

逐个验证 SessionStart、PreToolUse Bash、Stop 的 stdout、stderr、退出码、超时和 session isolation。

- [ ] **Step 4: Perform explicit user-trust/restart canary**

完整重启 Codex；确认 state preflight 只做本地 state 工作，Serena 初始中性，显式激活后符号查询成功，reminder/cleanup 只读写 D 盘 hook state。

- [x] **Step 5: Run complete verification**

运行全部 PowerShell tests、13 个 hardening cases、Python suite、live Check/Repair/Check、firewall/runtime/dashboard 独立只读 inventory 和 `git diff --check`。

- [x] **Step 6: Commit and report**

```powershell
git add tests/Test-CodexFunctionalHookRegistration.ps1
git commit -m "feat: enable verified functional Codex hooks"
```
