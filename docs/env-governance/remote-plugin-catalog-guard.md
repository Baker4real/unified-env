---
type: reference
title: Codex 远端插件 catalog guard
tags: [环境治理, Codex, plugin-catalog]
intent: 说明远端插件 catalog guard 的治理范围、入口和安全边界
---

# Codex 远端插件 catalog guard

该 guard 只治理 `D:\Codex\.codex\cache\remote_plugin_catalog` 下文件名为 16 位小写十六进制的普通 JSON catalog。它精确移除 policy 中四组固定 `name` / `id`，不扫描、不删除插件或 skill 安装目录，也不会恢复或复制已退役的 Superpowers skill。

治理入口固定为 `scripts\Invoke-CodexRemotePluginCatalogGuard.ps1`，目标身份的唯一配置来源是 `managed\remote-plugin-catalog-guard\policy.json`。本机调用只使用 `D:\Codex\tools\PowerShell\7.6.5\pwsh.exe`：

```powershell
& 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -NoLogo -NoProfile -NonInteractive -File 'D:\Codex\projects\统一环境\scripts\Invoke-CodexRemotePluginCatalogGuard.ps1' -Mode Check -Json
& 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -NoLogo -NoProfile -NonInteractive -File 'D:\Codex\projects\统一环境\scripts\Invoke-CodexRemotePluginCatalogGuard.ps1' -Mode Repair -Json
& 'D:\Codex\tools\PowerShell\7.6.5\pwsh.exe' -NoLogo -NoProfile -NonInteractive -File 'D:\Codex\projects\统一环境\scripts\Invoke-CodexRemotePluginCatalogGuard.ps1' -Mode Remove -Json
```

- `-Mode Check -Json`：只读检查受管文件、当前用户登录任务、隐藏进程链、跨会话单实例 mutex、watcher state 与 live catalog。catalog/policy 解析直接复用 runtime 的 `Audit` validator；watcher state 使用严格 JSON parser，重复属性、类型转换、属性集合漂移和非精确 UTC `Z` 时间均被拒绝。`retrying`、非零 `pendingRetryCount`、失败或超过 45 秒的 `lastSweep`、陈旧 heartbeat、异常 state schema 都会使 Check 非零退出，即使当前目标计数已经为 0。
- `-Mode Repair -Json`：按 source hash 原子部署到 `D:\Codex\.codex\catalog-guard`，注册并启动当前用户登录任务 `Codex Remote Plugin Catalog Guard`；第二次健康 Repair 应返回 `changed=false`、`evidencePath=null`。
- `-Mode Remove -Json`：停止并注销 guard 自有任务，删除 guard 自有部署文件和 state；不恢复四条 vendor catalog 记录，也不触碰运行日志和历史 evidence。

catalog schema v1 的可选 `fetched_at` 只接受严格 UTC `YYYY-MM-DDTHH:mm:ss[.1-9 位小数]Z`。时区偏移、尾随空白或换行、非法日期均以 `catalog-schema-drift` 失败闭锁，拒绝时保留 catalog 原始字节；合法值在过滤目标条目时逐字保留，不按 .NET 的七位小数精度重写。

计划任务由 D 盘 `pythonw.exe` 与受管 hidden launcher 启动固定 PowerShell，任务和子进程均不得出现可见窗口。

policy schema v2 使用无 `Local\` 前缀的命名 mutex/event，并显式设置 `CurrentUserOnly=true`、`CurrentSessionOnly=false`。因此同一 Windows 用户在不同交互或 RDP session 中共享同一 watcher 锁与 stop event，其他用户不能借该对象取得控制权；任务计划器的 `IgnoreNew` 只是第二层保护，不能代替 runtime 锁。

catalog 发布采用同目录、句柄绑定的 crash-safe transaction。`.txn`、`.publish` 和 `.vendor-abort` 先写入唯一 staging；写入期间，同一个拒绝 write/delete/rename 的句柄设置可清除的 delete disposition。完整写入并 `Flush(true)` 后，guard 通过同一句柄写入固定名称的 NTFS Extended Attribute 完整性锚点；锚点包含 magic、版本、artifact kind 和默认数据流 SHA-256，再经 `FlushFileBuffers` 持久化并同句柄回读验证。普通的默认数据流原地覆写会保留 File ID，但不会同步改变该 EA，因此重启时不能由当前 artifact 内容重新建立 SHA 信任。锚点完成后仍由原句柄清除 disposition、执行 no-replace rename，并核对最终路径、identity 和 SHA-256。

NTFS EA 由名称作为键；同一文件上再次通过 `NtSetEaFile` 写入同名 `CodexCatalogGuardV1` 会替换该名称的 value，而不是形成第二个同名 entry。Hardening 通过真实 API 连续写入两个值、回读第二个值并枚举唯一同名 entry 验证该行为，不构造 NTFS 不支持的“重复同名 EA”伪场景。测试还对三类可信 artifact 分别覆盖 EA 缺失、截断、额外长度、错误 magic/version/kind/SHA，并在默认流和 File ID 不变的前提下要求恢复失败闭锁。

create、写入中或数据 flush 后但尚未清除 disposition 时退出，由内核删除 staging；该阶段的 EA 尚未创建或尚未成为可恢复对象。清除 disposition 后退出可能留下完整 staging 或最终 artifact，启动 reconcile 只接受 EA magic/version/kind、锚定 SHA、当前默认流 SHA 和 handle-bound identity 全部匹配的对象；缺少锚点、锚点异常或默认流被同 identity 原地改写时，artifact 会被保留并以 `catalog-transaction-conflict` 失败闭锁，陌生 staging 不会被删除或采用。catalog root 必须位于支持 NTFS EA 的卷；seal 在清除 disposition 前失败时不会发布半锚定 artifact。

Hardening 的 fixture-only seal fault 会在 `NtSetEaFile` 调用点或 EA 写入后的 `FlushFileBuffers` 调用点确定性失败；该注入只在受控 fixture scope 内传给 runtime。两处失败都发生在清除 delete-on-close 之前，测试要求进程退出后 staging 为 0、失败 kind 的最终 artifact 不存在、canonical 未被覆盖，并由无注入的下一次 sweep 收敛。

`.txn` schema v2 在首次 staging identity 已知时固化自身 `txnIdentity`，并同时绑定 `.publish` 的 `publishIdentity`；`.vendor-abort` schema v2 同样固化自身 `vendorAbortIdentity`。重启同时要求这些持久 binding、当前 handle-bound identity 和独立 EA 锚点完全一致，不采纳当前 marker 自述的 SHA 作为可信基线；publish 也必须逐字节满足首次锚定的 SHA。即使替换对象字节相同，只要 file identity 不同或 EA 不存在，也会保留替换对象并失败闭锁。后续任何 marker 删除都只使用首次完整发布时保存的 binding。

guard 在隔离前持久化 `.txn` 与 `.publish`，再用同一旧对象句柄复核 identity/hash，并以 no-replace rename 将旧对象隔离为确定名称的 `.quarantine` sibling；旧 canonical 不会被预先永久删除。新内容只以 no-replace rename 发布，发布成功并复核 SHA-256 后才删除 quarantine，最后按原始 binding 删除 marker。

publish 失败且 canonical 仍为空时，guard 用 quarantine 的原 identity/hash 做 no-replace 恢复，再按原始 binding 清理 publish/marker 并进入 retry。若受支持的新 vendor catalog 已抢占 canonical，guard 绝不覆盖 vendor；它先原子发布并 flush `.vendor-abort` 阶段标记，绑定 vendor canonical、旧 quarantine、publish、原始 `.txn` 和自身的 identity/SHA-256，然后按 quarantine、publish、txn、vendor-abort 的顺序幂等清理。若进程在 durable abort 标记完成前退出，reconcile 仅在 v2 txn、quarantine、publish 与受支持的新 vendor canonical 的内容和持久 identity binding 全部匹配时重建该阶段；已有 abort 被同字节不同 identity 对象替换时不会重建信任。阶段标记最后删除；每次重启都会先复核同一 vendor identity/hash，vendor 已改变时不删除任何剩余事务对象。

从 canonical 验证开始，到最后一个可恢复副本被不可逆清理完成，guard 始终持有拒绝 write/delete/rename 的 handle-bound lease，并在每次清理前从同一句柄复核 identity/SHA-256。正常发布沿用原始 publish 句柄；重启发布和回滚使用 no-replace move 返回的 leased 句柄；vendor-abort 使用已验证 vendor canonical 的 read lease。并发 writer 不能在这段窗口替换或删除 canonical；任何恢复、验证或清理竞争都会保留可审计 transaction 并失败闭锁，不用路径存在性猜测覆盖对象。

恢复时获取 transaction artifact 的独占句柄可能被文件系统 filter 或短时读取者以 Win32 `ERROR_SHARING_VIOLATION (32)` / `ERROR_LOCK_VIOLATION (33)` 暂时阻塞。guard 只在这个句柄获取操作上按 `25/50/100/200/400 ms` 有限退避，总等待上限 775 ms；每次成功获取后仍从该句柄重新校验默认流 SHA-256 与首次 identity binding，路径消失、内容/identity 漂移及其他 native error 不重试。每次退避记录 `transaction-sharing-retry` 及 basename、native code、attempt 和 delay；这不是无归因的整轮 Sweep 重试。

每次启动和周期 sweep 都会在处理 canonical `*.json` 前 reconcile `.txn/.publish/.quarantine/.vendor-abort` 与可识别 staging。inventory 枚举全部 filesystem entries；artifact 合法名称保持严格小写，但 Windows stem 冲突映射不区分大小写，因此受管前缀下的大小写变体、目录、junction/reparse、非普通文件和未知 staging 一律作为 `catalog-transaction-unknown-artifact` 报红，并阻止对应 stem canonical 被处理。canonical 为空时可继续已验证 publish 或恢复旧 quarantine；已成功发布、合法完整 staging 或 vendor-abort 清理中断时可幂等收敛；marker 非法、artifact 无 marker、内容/identity 漂移或 canonical 冲突时一律不删除、不恢复、不覆盖。runtime `Audit` 和治理 `Check` 对任何未解决 transaction/quarantine/staging 都报红，不能因剩余 canonical 看似干净而假健康。处理后的 fingerprint 只有在路径对象 identity 与内容 SHA-256 仍等于实际处理对象时才缓存；后置替换会清除旧缓存并重试。

Repair/Remove 的变更证据位于 `D:\Codex\.codex\run-evidence\remote-plugin-catalog-guard\<run-id>\evidence.json`。运行日志只记录 catalog 文件 basename、SHA-256、计数和脱敏错误码，位于 `D:\Codex\.codex\logs\remote-plugin-catalog-guard.jsonl`。

`tests\Test-CodexRemotePluginCatalogGuardVendorAbortStress.ps1` 是独立的 `vendor-abort:after-clear` 定向 stress，不运行完整 hardening。它每轮使用两个公开 Sweep 子进程和真实 NTFS fixture，首个失败立即停止；逐操作 evidence 位于同一 guard evidence 根下的 `stress-events.jsonl`，只记录 stderr、异常/栈、API/native code、进程阶段及 artifact leaf/type/identity/hash/attributes，不记录 catalog payload。连续零失败只证明该次运行未复现，不能表述为历史间歇 I/O 根因已经修复，也不能据此加入整轮重试。Hardening 另用真实共享句柄确定性制造第一次 `AcquirePreparedTempFile` 的 native code 32，并要求同一 Sweep 内收敛及日志证据存在。

回滚只执行 `Remove`。由于 catalog 是 vendor 可重新刷新的缓存，Remove 不主动回填已过滤记录；后续官方刷新可自然重建它们。guard 的对抗边界是官方刷新进程只创建、替换或原地写入 canonical catalog；它不把拥有同一 Windows 用户权限、能够同时改写受管 runtime/policy 和 NTFS EA 的主动攻击者视为可隔离对象。guard 能保证该边界内磁盘 catalog 自动最终收敛，但不能承诺 Codex 已加载到内存或 UI 的菜单在一次 vendor 刷新与守护处理之间绝对不短暂出现。

确定性回归使用 `reports\catalog-guard-tests-<guid>\.codex` fixture，并通过受管安全树删除入口清理。跨会话测试会验证底层等待句柄的 `CurrentUserOnly=true` / `CurrentSessionOnly=false` 属性、跨进程互斥和 session-local 命名空间不可见性；若主机没有第二个同时在线的交互/RDP session，不把该测试表述为真实双 session 登录实测。
