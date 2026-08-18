# CLOSEABLE.md — GitHub #36 Phase 1 集成测试和生产验证

这不是 GitHub 关单授权。本文只记录实现关口是否可交给根 Agent 汇总。

## 关口结论

`DONE_WITH_CONCERNS`

功能 AC 已用 live 测试证明：10k×160KiB（每树 1,638,400,000 字节，约 1.526 GiB）两棵兄弟树走完整 Plan→Apply→Purge；baseline 用同一工作树、同一库的 `-DisableApplyHashReuseForTest` / `-DisablePurgeHashReuseForTest`，没有 `git checkout` 旧实现。安全路径 IdentityMismatch 拒绝；成功路径 quarantine/purge 与 plan 一致；夹具树测完已删。3x 未达到：Phase1/baseline = **0.98**（speedup **1.02x**）。FAT32 / 网络盘实卷 e2e 未验证。未改 lib / guard / policy / hooks。未 commit / comment / close #36。

## 逐条 AC

1. **通过。** 性能测试套件 `tests/Test-CodexSafeTreeDeletePhase1Integration.ps1`：10000 文件，每文件 163840 字节，总大小 1638400000（1–2 GiB）。跑前 D: `availableFreeBytes=417905205248`，`requiredBytes=5424283648`。
2. **通过。** Baseline 完整 Plan→Apply→Purge，无复用。`baselineElapsedMs=527846`（plan 86283 / apply 254708 / purge 186855）。
3. **通过。** Phase 1 哈希复用完整 Plan→Apply→Purge。`phase1ElapsedMs=517444`（plan 82685 / apply 246872 / purge 187887）。
4. **未达 3x（如实记录）。** ratio=0.98，speedup=1.02，`metTarget=false`。原始 JSON：`reports/safe-tree-delete-issue36-20260817/scale-phase1.json`。方法见该文件 `method` 字段。
5. **通过。** 小夹具成功路径：quarantine 文件数=2，Purge `deleted=2`，`streamSetSource=plan.leafStreamSetV1`。Apply/Purge 过程中改文件记录 IdentityMismatch 并保留目标/quarantine。
6. **通过。** TOCTOU：`BeforeQuarantineMutexForTest` / `BeforePurgeMutexForTest` 改文件必须拒绝；未削弱 #32/#33 切片。`Test-CodexSafeTreeDeleteHashSafely` exit 0。
7. **通过。** Crash safety 复跑既有套件，未另造生产杀进程协议。`Test-CodexSafeTreeDeleteCrashSafety` exit 0（13 scenarios）；`Test-CodexSafeTreeDeleteUncertainRecovery` exit 0。
8. **本机 NTFS 已跑；FAT32 / 网络未验证。** `filesystem-probe.json`：DriveFormat=NTFS，DriveType=Fixed，FILE_ID_INFO=true，DeletionAllowed=true。无就绪 FAT32/exFAT 或 Network 卷；#35 waiver，未提权 diskpart/格式化。
9. **通过。** 端到端 Plan→Apply→Purge：小夹具与 10k 两棵树 Purge 后目标与 quarantine 均不存在；baseline/phase1 `leafDispositions.summary.deleted=10000`。测完 `scale-phase1/` 与 fixtures 已清理，未留 1–2 GiB 树。
10. **通过（本阶段相关套件，非全仓、非 ProductionSmoke）。** HashSafely 0；UncertainRecovery 0；CrashSafety 0；LeafStreamSet 0。未重跑 #32/#33 的 10k×4KB 基准。
11. **通过。** `scale-phase1.json` + `filesystem-probe.json` + 各套件 stdout/stderr + `suite-meta.json`。

## 两轴审查（相对进入本关口的工作树）

固定点：进入本关口时的工作树（不是独立 commit）。审查范围仅本票写入。

### Standards

- 无硬违反仓库编码标准。`git diff --check` 对本票文件通过。
- 未改 `scripts/lib/CodexSafeTreeDelete.ps1`、policy、hooks、ProductionSmoke。现有 disable 开关与 `metrics.elapsedMs` 足够，没有为刷 3x 放宽 `FileShare.None` 或跳过 identity。
- 判断：`invoke-issue36.ps1` 初版把 `Write-Output` 进度行和返回对象混进同一输出流，StrictMode 在收尾 `Where-Object exitCode` 处失败；套件本身已全部 exit 0。已改成写 stderr，并扁平化 `suite-meta.json`（同一轮墙钟，不是重跑）。
- 判断：scale 树与 #32/#33 同形（100 目录 × 100 文件），只把每文件从 4KB 换成 160KiB，以满足 1–2 GiB 合同。

### Spec

- 票面要求的 10k+/1–2GB 对跑、同一库 disable 开关 baseline、安全/TOCTOU、复跑 crash/uncertain、NTFS 探测、夹具清理、报告字段都在。
- 没有伪造 3x，没有用 #32/#33 的 4KB 数字冒充本票结果，没有 checkout 旧实现，没有碰生产 leftover，没有扩到 #37 Phase 2 / 并行 / Status 冷启动。
- 性能 spec 的 ≥3x 是本票对照门槛；实测 1.02x，按票面写 `metTarget=false`。大文件上哈希占比仍远低于 per-file open / PowerShell / journal 成本：Apply/Purge 各约 4.9GB `bytesHashed`（含 cache hit 按长度记账），墙钟几乎重合。

**Standards 0 硬违反 / 2 判断味道；Spec 0 缺失要求，最差是 3x 未达到。**

## 未解决问题

- 10k×160KiB 完整流水线未达 3x（1.02x）。snapshot 仍 dispose lease 再 `GetHashSafely` `FileShare.None` 二次打开；这是已知味道，本票未改协议。
- `bytesHashed` 在 cache hit 时仍按文件长度记账，不能当物理读字节。
- FAT32 / 网络盘实卷 e2e 未验证（无就绪卷；#35 waiver）。
- 未改 lib / guard / policy / hooks。未 commit / comment / close #36。
- #37 Phase 2 批量、#38+ 并行、#49 Status 冷启动不在本票。
