---
type: spec
title: 受管安全树删除性能优化
tags: [performance, safe-delete, hash-reuse, parallelization]
date: 2026-08-13
status: ready-for-agent
priority: P0
---

# 受管安全树删除性能优化

## Problem Statement

用户在使用 Codex 受管安全树删除系统删除 GB 级数据（包含数万+小文件）时，删除操作耗时超过 1 小时，严重影响工作流效率。

根本原因是当前实现的性能瓶颈：
1. **哈希读取放大**：每个文件被读取 7 次（Plan 1次 + Apply 3次 + Purge 3次）计算 SHA-256
2. **串行处理**：PowerShell 循环串行处理每个文件，无法利用多核性能
3. **PowerShell 开销**：每个文件的循环、对象创建和函数调用开销累积

用户场景是本地 NTFS 驱动器上的 GB 级目录树，包含数万个小文件（典型场景：node_modules、构建产物、.NET 缓存）。

## Solution

通过三个优化阶段将删除时间从 60 分钟降低到 10-15 分钟（4-6x 提升），同时保持所有安全保证：

**Phase 1: 安全哈希复用**（目标 3x）
- 升级 file identity 到 128-bit FILE_ID_INFO（VolumeSerialNumber + FileId + Size + LastWriteTime）
- Apply/Purge 阶段首次验证时重新计算哈希，验证通过后在会话内复用
- 将 7 次哈希读取降低到 4-5 次（Plan 1次 + Apply 1次验证 + Purge 3次复用）

**Phase 2: 批量处理优化**（累积 4x）
- Purge 阶段批量收集删除项，减少 PowerShell 循环和对象创建开销
- 批量验证和批量 journal 写入

**Phase 3: 受限并行化**（累积 6x）
- 目录级并行删除（4-8 线程），避免文件级并发的 journal 复杂度
- 每线程独立 journal 文件，立即 flush 保证 crash safety
- 文件系统检测和自动降级机制

所有优化必须保持现有安全保证：
- Content-authenticated deletion (SHA-256 验证)
- Crash safety (transaction journal)
- TOCTOU 防御（独占文件锁）
- Policy 授权边界

## User Stories

1. As a Codex user, I want to delete large temporary directories (node_modules, build outputs) in under 15 minutes, so that I can quickly clean up disk space without waiting an hour
2. As a Codex user, I want the deletion to remain safe and verifiable, so that I never accidentally delete the wrong files even with performance optimizations
3. As a Codex user, I want crash recovery to still work after optimization, so that interrupted deletions don't leave my system in an inconsistent state
4. As a system administrator, I want file identity verification to use Windows FILE_ID_INFO, so that identity checks are reliable across file moves and modifications
5. As a developer, I want hash reuse to only happen after identity verification passes, so that TOCTOU vulnerabilities are prevented
6. As a developer, I want hash reuse to be session-scoped, so that different Apply/Purge sessions don't incorrectly reuse stale hashes
7. As a Codex user, I want the system to detect my file system type (NTFS/ReFS/FAT32/Network), so that optimizations are only enabled when safe
8. As a Codex user on a network drive, I want the system to automatically disable hash reuse and parallelization, so that I don't encounter file system compatibility issues
9. As a Codex user, I want parallel deletion to respect directory boundaries, so that journal integrity is maintained
10. As a Codex user, I want each parallel thread to have its own journal file, so that concurrent writes don't corrupt the transaction log
11. As a Codex user, I want journal writes to flush immediately to disk, so that crash recovery can reconstruct the exact deletion state
12. As a Codex user, I want the optimization to benchmark my specific hardware, so that parallelism degree is tuned to my CPU core count
13. As a developer, I want crash recovery to handle "uncertain" files (pending but no longer exist), so that manual verification is required rather than assuming completion
14. As a developer, I want file handles to use FileShare.None during validation, so that no other process can modify the file during the verification window
15. As a developer, I want the Delete/Journal sequence to be atomic (pending → delete → commit), so that crash recovery knows exactly which files were successfully deleted
16. As a Codex user, I want journal flush performance to be monitored, so that if journal overhead exceeds 10% of total time, I'm warned about potential disk bottlenecks
17. As a developer, I want FILE_ID_INFO P/Invoke structures to use embedded value types, so that memory layout is correct and GetFileInformationByHandleEx works reliably
18. As a developer, I want GetFileIdentityV2 to use GetFileInformationByHandle for size/mtime, so that the code compiles and runs correctly
19. As a developer, I want ComputeHashFromHandle to document its stream position contract, so that callers know the handle position is reset to 0 after use
20. As a developer, I want FileIdentityV2 to implement IEquatable correctly, so that session cache lookups work with byte array content comparison
21. As a developer, I want ThreadJournalWriter lifecycle to use ThreadLocal with proper cleanup, so that no journal handles are leaked even on exceptions
22. As a Codex user, I want the performance gain to be measured and reported, so that I know if the optimization delivered the expected 4-6x improvement
23. As a system administrator, I want policy entries to specify minimum quarantine age, so that accidental deletions have a recovery window
24. As a system administrator, I want producer fence modes (manual-only vs os-handle-required), so that batch purge only works when producers are cooperating
25. As a Codex user, I want legacy Plan artifacts (v1/v2/v3) to be automatically rejected, so that I must re-plan with the new identity system
26. As a developer, I want the implementation to fail fast on unsupported file systems, so that users get clear error messages rather than silent data loss
27. As a Codex user, I want Apply phase to detect cloud sync placeholders (OneDrive/Dropbox), so that I'm warned about potential sync conflicts
28. As a developer, I want parallelism tests to benchmark 1/2/4/8/16 thread configurations, so that the optimal degree is empirically determined
29. As a Codex user, I want the first deployment to be conservative (hash reuse only), so that risk is minimized before enabling parallelization
30. As a Codex user, I want comprehensive testing on real-world scenarios (10k+ files), so that performance gains are validated before production rollout

## Implementation Decisions

### Module Modifications

**`scripts/lib/CodexSafeTreeDelete.ps1`**
- Add `FileIdentityV2` structure with 128-bit FILE_ID_INFO fields
- Add `SessionHashCache` for in-memory hash reuse within Apply/Purge sessions
- Add `GetHashSafely` function implementing the safe hash reuse protocol
- Add `FileSystemCapabilities` detection and automatic degradation
- Add `ParallelPurgeCoordinator` for directory-level parallel deletion
- Add `ThreadJournalWriter` with ThreadLocal lifecycle management
- Modify `Invoke-CodexSafeTreeDeletePlan` to capture FileIdentityV2
- Modify `Invoke-CodexSafeTreeDeleteApply` to use GetHashSafely and optional parallelization
- Modify `Invoke-CodexSafeTreeDeletePurge` to use GetHashSafely, batch processing, and optional parallelization

**`scripts/Invoke-CodexSafeTreeDelete.ps1`**
- Add file system detection call before Plan phase
- Add warnings for non-optimal file systems (network drives, FAT32, non-FILE_ID_INFO)
- Add performance monitoring and reporting

**`managed/safe-tree-delete/policy.json`**
- Upgrade schema version to v5 (if not already)
- Ensure all entries have `minimumQuarantineAgeMinutes` and `producerFenceMode`

**Evidence directory structure**
- Thread journals: `transaction-{id}.thread-{tid}.dir-{name}.json`
- Main journal checkpoint: `transaction-{id}.checkpoint.json`
- Performance metrics: `transaction-{id}.perf.json`

### Technical Clarifications

**FILE_ID_INFO Interop**
- Use embedded `FILE_ID_128` struct with 16 individual byte fields (B0-B15), not `byte[]` managed array
- P/Invoke must use `GetFileInformationByHandleEx` with `FILE_INFO_BY_HANDLE_CLASS.FileIdInfo = 18`
- Size and mtime must come from `GetFileInformationByHandle` returning `BY_HANDLE_FILE_INFORMATION`
- FILETIME conversion: `((long)dwHighDateTime << 32) | dwLowDateTime` then `DateTime.FromFileTimeUtc`

**Hash Reuse Protocol**
1. Open file with `FileShare.None` exclusive lock
2. Get current `FileIdentityV2` from handle
3. Check session cache with identity as key
4. If cache hit AND identity matches: return cached hash (no re-hash)
5. If cache miss OR identity mismatch: recompute hash from handle, verify against Plan hash, cache on success

**ComputeHashFromHandle Contract**
- Input: handle at any position
- Output: SHA-256 hash as byte[]
- Side effect: handle position reset to 0
- Thread safety: unsafe for concurrent calls on same handle

**FileIdentityV2 Equality**
- Implement `IEquatable<FileIdentityV2>`
- `Equals`: compare VolumeSerialNumber, FileSize, LastWriteTimeUtc, and FileId128.SequenceEqual()
- `GetHashCode`: combine VolumeSerialNumber, FileSize, LastWriteTimeUtc, and first 8 bytes of FileId128
- CapturedAtUtc does NOT participate in equality

**ThreadJournalWriter Lifecycle**
- Use `ThreadLocal<ThreadJournalWriter>(trackAllValues: true)` to store per-thread instances
- Each directory creates a fresh journal writer (no cross-directory reuse)
- `finally` block disposes all thread values after `Parallel.ForEach`
- Coordinator implements `IDisposable` and calls `threadJournals.Dispose()`

**Delete/Journal Atomicity**
- Sequence: `WritePending() → Flush() → File.Delete() → WriteCommit() → Flush()`
- Pending entry must hit disk before OS delete syscall
- Commit entry must hit disk before function returns
- Crash between pending and commit: recovery finds pending entry, file existence determines resumability

**Crash Recovery Uncertain State**
- If pending entry exists but file does not exist: mark as "uncertain"
- Cannot assume "we deleted it" — could be another process
- Recovery returns `UncertainFiles` list requiring manual verification
- Only committed entries or pending entries with existing file (after hash re-verification) count as known state

**File System Detection and Degradation**
- Detect: `DriveInfo.DriveFormat` (NTFS/ReFS/FAT32), `DriveType` (Local/Network), test FILE_ID_INFO support
- Local NTFS with FILE_ID_INFO: enable hash reuse + parallelization
- Network drive: disable hash reuse, disable parallelization, warn user
- Non-NTFS or no FILE_ID_INFO: disable hash reuse, allow parallelization with warning
- Removable media: conservative mode (no optimizations)

**Parallelism Configuration**
- Directory-level parallelism only (files within a directory still serial)
- `MaxDegreeOfParallelism = min(4, Environment.ProcessorCount - 2)` as starting point
- Week 3 benchmarks will tune this based on 1/2/4/8/16 thread tests
- Each thread gets its own journal file with immediate flush

**Journal Performance Monitoring**
- Track total flush time and flush count per thread
- Compute `journalOverheadPercent = totalFlushTime / totalElapsedTime`
- Fail acceptance test if overhead > 10%
- Log slow flushes (>100ms) for diagnosis

**Schema Compatibility**
- Plan v4 (current) → v5 (optimized): breaking change, must re-plan
- Policy v4 → v5: add required fields, validate in activation
- Evidence v1 unchanged (metrics and journal schemas extend independently)

### Architectural Decisions

**Why 128-bit FILE_ID_INFO instead of 64-bit?**
- 64-bit FileIndex can be reused after delete/recreate on NTFS
- 128-bit FILE_ID_INFO is globally unique and stable across volume lifetime
- Eliminates risk of false identity match leading to wrong file deletion

**Why session-scoped cache instead of persistent?**
- Persistent cache would need invalidation on file modification (complex)
- Session scope is simple: cache lives only during one Apply or Purge run
- Re-verification on first use in each session provides safety

**Why directory-level parallelism instead of file-level?**
- File-level would require complex journal coordination (lock-free queue or mutex)
- Directory-level is simpler: each thread owns its files, independent journal
- Still achieves most of the speedup (directories naturally partition the work)

**Why not use C# for the hot path?**
- PowerShell module boundary is already established
- C# would require native module, deployment complexity
- Optimization focus is reducing I/O (7x → 4x hashing), not execution speed
- If PowerShell overhead remains after Phase 1-2, Phase 3+ can consider C#

**Why immediate journal flush instead of batching?**
- Crash safety requires pending entry on disk before delete syscall
- Batching would introduce correctness risk (delete happens before journal written)
- Modern SSDs handle small sequential writes efficiently
- Performance monitoring (Week 3) will confirm <10% overhead

**Why three-phase rollout (hash reuse → batch → parallel)?**
- Risk management: each phase independently testable
- If Phase 1 delivers 3x, user pain is already reduced
- Phase 2 and 3 can be delayed if risk/complexity too high
- Allows early production validation before full optimization

## Testing Decisions

### What Makes a Good Test

Tests should verify **external observable behavior**, not implementation details:
- ✅ "After Purge, target directory does not exist"
- ✅ "After crash during Apply, recovery correctly resumes"
- ✅ "Hash reuse only happens when identity matches"
- ❌ "SessionHashCache internal dictionary has correct key"
- ❌ "ThreadJournalWriter calls Flush exactly twice per file"

Tests should use **realistic data volumes** for performance tests:
- Unit tests: 10-100 files
- Integration tests: 1,000 files
- Performance tests: 10,000+ files (actual user scenario)

Tests should verify **safety properties** hold under optimization:
- Content-authenticated: wrong file never deleted
- Crash safety: recovery never produces inconsistent state
- TOCTOU: file modified between identity check and delete → fails safely

### Modules to Test

**Core hash reuse logic** (`GetHashSafely`, `SessionHashCache`)
- Identity match → hash reuse works
- Identity mismatch → hash recomputed
- Hash mismatch → exception thrown
- Cache isolation between sessions

**Parallel coordination** (`ParallelPurgeCoordinator`, `ThreadJournalWriter`)
- Correct parallelism degree
- No journal corruption under concurrency
- Exception in one thread → other threads clean up
- All journal handles disposed on exit

**Crash recovery with uncertain state**
- Pending file exists → resumable
- Pending file missing → uncertain (not assumed deleted)
- Committed file missing → counted as deleted
- Recovery returns correct classification

**FILE_ID_INFO interop**
- GetFileIdentityV2 returns correct 128-bit FileId
- Identity equality uses content comparison (not reference)
- Works on NTFS, ReFS
- Fails gracefully on FAT32 or network drives without FILE_ID_INFO

**File system detection**
- Detects NTFS/ReFS/FAT32/Network correctly
- Recommends correct optimization level
- Warns on non-optimal file systems

**Performance benchmarks**
- Baseline (current): measure on 10k file tree
- Phase 1 (hash reuse): verify 3x improvement
- Phase 2 (batch): verify cumulative 4x improvement
- Phase 3 (parallel): verify cumulative 6x improvement
- Journal overhead: verify <10% of total time

### Prior Art for Tests

Existing test files provide patterns:
- `tests/Test-CodexSafeTreeDelete.ps1`: Plan/Apply/Purge integration tests
- `tests/Invoke-CodexSafeTreeDeleteCrashFixture.ps1`: Crash recovery scenarios
- `tests/Test-CodexSafeTreeDeleteBenchmark.ps1`: Performance measurement harness

New tests should follow these patterns:
- Use fixture functions to create test directory trees
- Use `Measure-Command` for performance measurements
- Use evidence directory inspection to verify journal correctness
- Use `try/finally` to ensure test cleanup even on failure

Specific test additions:
- `Test-CodexSafeTreeDeleteHashReuse.ps1`: Verify hash reuse protocol
- `Test-CodexSafeTreeDeleteParallel.ps1`: Verify parallel correctness and performance
- `Test-CodexSafeTreeDeleteFileSystemDetection.ps1`: Verify detection and degradation
- `Test-CodexSafeTreeDeleteIdentityV2.ps1`: Verify FILE_ID_INFO interop

## Out of Scope

**Not included in this optimization:**
- Optimizing Plan phase (still 1x hash read per file) — Plan is run once, Apply/Purge are run repeatedly
- Cross-session persistent hash cache — too complex, invalidation unclear
- File-level parallelization — journal coordination complexity too high
- C# rewrite of hot path — PowerShell boundary already established, I/O is the bottleneck
- Optimizing other phases (Status, BatchPurge) — not on critical path for user pain
- Supporting file systems other than NTFS/ReFS — FAT32 and network drives get conservative fallback
- Windows 7 support — FILE_ID_INFO requires Windows 8+, older systems fall back to no optimization
- Symlink or external junction optimization — complexity not justified by user scenarios
- Producer lease optimization — separate concern, not blocking this performance work

**Explicitly deferred to future work:**
- Policy v6 schema (if needed) — v5 is sufficient for this optimization
- Metrics dashboard or visualization — evidence JSON is sufficient for now
- Automatic parallelism tuning based on disk type (SSD vs HDD) — manual configuration acceptable
- Integration with Codex Desktop progress UI — CLI evidence output is sufficient

**Will not do:**
- Remove crash safety or content authentication — these are non-negotiable security properties
- Skip identity verification to save time — would violate TOCTOU defense
- Use approximate hashes (CRC32, xxHash) — SHA-256 is the security contract
- Allow file-level parallelism — correctness risk too high

## Further Notes

**Risk Management**
- Phase 1 (hash reuse) is lowest risk: purely additive, no concurrency
- Phase 2 (batch) is medium risk: changes PowerShell control flow but still single-threaded
- Phase 3 (parallel) is highest risk: concurrency requires careful journal design
- Rollout plan: Phase 1 → 2 weeks production validation → Phase 2 → 2 weeks validation → Phase 3

**Performance Expectations**
- Best case (local NTFS SSD, many small files): 6x improvement
- Typical case (local NTFS HDD, mixed file sizes): 4x improvement
- Worst case (network drive, large files): 1.5x improvement (batch only, no hash reuse or parallel)

**Compatibility Matrix**
| File System | Hash Reuse | Parallel | Expected Gain |
|-------------|------------|----------|---------------|
| Local NTFS  | ✅         | ✅       | 6x            |
| Local ReFS  | ✅         | ✅       | 6x            |
| Local FAT32 | ❌         | ⚠️       | 2x            |
| Network     | ❌         | ❌       | 1.5x          |
| Removable   | ❌         | ❌       | 1.5x          |

**Acceptance Criteria for Production**
- All P0/P1 defects from adversarial review fixed
- Performance benchmark shows ≥4x improvement on 10k file test case
- Crash recovery tests pass with uncertain state handling
- Journal overhead <10% of total time
- File system detection works correctly on NTFS/ReFS/FAT32/Network
- Zero regressions in existing safety tests
- Documentation updated (user guide, troubleshooting)

**Timeline**
- Week 1 (Day 1-5): FILE_ID_INFO + hash reuse implementation
- Week 2 (Day 6-10): Batch processing optimization
- Week 3 (Day 11-15): Parallelization + complete testing
- Week 4 (Day 16-20): Production validation + documentation
- Total: 4 weeks from kickoff to production-ready

**Dependencies**
- Policy v5 activation (if not already done) — minimal, schema already defined
- Windows 8+ for FILE_ID_INFO — acceptable, Windows 7 users get conservative fallback
- PowerShell 7+ — already required by Codex environment
- No external library dependencies — pure .NET Framework/PowerShell

**Success Metrics**
- Primary: User-reported deletion time reduced from 60min to <15min
- Secondary: Hash read amplification reduced from 7x to 4-5x
- Tertiary: Journal overhead measured at <10% of total time
- Qualitative: Zero P0 bugs reported in first month of production use
