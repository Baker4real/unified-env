---
type: implementation-plan
title: 受管删除性能优化实施方案 v2.0（已整合对抗审查）
tags: [performance, implementation, security-hardened]
scenario: 确认小文件过多（数万+文件）
priority: P0
date: 2026-08-13
status: 待实施
---

# 受管删除性能优化实施方案 v2.0

## 前提确认

✅ **用户场景**：GB级数据，数万+小文件，删除耗时1小时
✅ **瓶颈确认**：文件数量多 + PowerShell循环开销 + 串行处理
✅ **文件系统**：假设NTFS本地磁盘（后续会验证）

## 优化目标

**主目标：** 1小时 → 10-15分钟（**4-6x提升**）

**安全前提：**
- 保持content-authenticated合同
- 保持crash safety
- 保持transaction完整性
- 经过充分测试和对抗审查

## 三阶段实施（已整合安全修正）

---

## 阶段1：哈希复用优化（安全版）

### 原理

当前每个文件读7次：
- Plan: 1次
- Apply: 3次（验证 + 重验证 + commit前确认）
- Purge: 3次（验证 + 重验证 + delete前确认）

**优化：** Apply/Purge复用Plan的hash，但必须**首次重哈希确认**后才能复用

### 安全设计（修正TOCTOU缺陷）

```csharp
// 文件Identity结构（升级到128-bit）
public struct FileIdentityV2 {
    public ulong VolumeSerialNumber;
    public byte[] FileId128;  // 升级：128-bit FILE_ID_INFO
    public long FileSize;
    public DateTime LastWriteTimeUtc;
    public DateTime CapturedAtUtc;  // Plan阶段的捕获时间
}

// 会话内Hash缓存（防止TOCTOU）
private class SessionHashCache {
    private readonly ConcurrentDictionary<string, ValidatedHash> cache = new();
    
    public class ValidatedHash {
        public byte[] Hash;
        public FileIdentityV2 Identity;
        public DateTime ValidatedAt;
        public bool RevalidatedInSession;  // 关键标志
    }
}

// 安全的Hash复用逻辑
public byte[] GetHashSafely(
    string path, 
    byte[] planHash,
    FileIdentityV2 planIdentity,
    SessionHashCache sessionCache) {
    
    SafeFileHandle handle = null;
    try {
        // 1. 以READ + DELETE sharing打开（阻止write）
        handle = OpenFileForValidation(path);
        
        // 2. 获取当前FILE_ID_INFO (128-bit)
        var currentIdentity = GetFileIdentityV2(handle);
        
        // 3. 快速检查：Identity是否匹配
        if (!IdentityMatches(currentIdentity, planIdentity)) {
            // Identity漂移，必须完整重哈希
            LogWarning($"Identity drift detected for {path}, full rehash required");
            return ComputeHashFromHandle(handle);
        }
        
        // 4. 检查是否在本会话内已验证过
        var cacheKey = GetCacheKey(path, currentIdentity);
        if (sessionCache.TryGet(cacheKey, out var cached)) {
            if (cached.RevalidatedInSession && 
                cached.Identity.Equals(currentIdentity)) {
                // 已在本会话验证，可以安全复用
                return cached.Hash;
            }
        }
        
        // 5. 【关键】首次使用时必须重哈希确认
        byte[] actualHash = ComputeHashFromHandle(handle);
        
        if (!actualHash.SequenceEqual(planHash)) {
            // Hash不匹配，内容已改变
            throw new FileModifiedException(
                $"File content changed since Plan: {path}");
        }
        
        // 6. 验证通过，加入会话缓存
        sessionCache.Set(cacheKey, new ValidatedHash {
            Hash = actualHash,
            Identity = currentIdentity,
            ValidatedAt = DateTime.UtcNow,
            RevalidatedInSession = true
        });
        
        // 7. 此后在同一Apply/Purge会话内可以复用
        return actualHash;
        
    } finally {
        handle?.Dispose();
    }
}

private bool IdentityMatches(FileIdentityV2 a, FileIdentityV2 b) {
    return a.VolumeSerialNumber == b.VolumeSerialNumber &&
           a.FileId128.SequenceEqual(b.FileId128) &&
           a.FileSize == b.FileSize &&
           // LastWriteTime只检查没有变新（允许clock skew）
           a.LastWriteTimeUtc <= b.LastWriteTimeUtc.AddSeconds(2);
}
```

### 关键安全保证

1. **128-bit FILE_ID_INFO**：降低FileIndex重用概率
2. **首次必须重哈希**：闭合TOCTOU窗口
3. **会话内缓存**：验证通过后才复用
4. **Handle-bound验证**：获取identity和哈希都在同一句柄
5. **Size + Mtime双重检查**：快速过滤明显变化

### 收益预测

- **理论**：7x → 2x（Apply/Purge各复用一次，Plan+首次验证=2x）
- **实际**：7x → 3x（考虑identity漂移需要重哈希的情况）
- **提升**：约**2.3x**

---

## 阶段2：批量处理优化

### 原理

当前：PowerShell逐文件调用C#
- 每文件：PSObject创建 + Marshal + Unmarshal + 函数调用
- 10k文件 × 2ms = 20秒纯overhead

**优化：** C#批量处理，减少PowerShell往返

### 实现设计

```csharp
// 批量删除API
public class BatchPurgeRequest {
    public FileManifestEntry[] Files;  // 单次最多1000个文件
    public string DirectoryPath;
    public DirectoryGuard Guard;
    public SessionHashCache HashCache;
}

public class BatchPurgeResult {
    public bool AllSucceeded;
    public int ProcessedCount;
    public int SuccessCount;
    public string FirstFailedPath;  // 第一个失败的文件
    public Exception FirstFailureReason;
    public List<string> DeletedPaths;
    public long TotalBytesHashed;
    public long ElapsedMs;
}

public BatchPurgeResult PurgeFileBatch(BatchPurgeRequest request) {
    var result = new BatchPurgeResult {
        DeletedPaths = new List<string>()
    };
    
    var sw = Stopwatch.StartNew();
    
    foreach (var file in request.Files) {
        try {
            // 单文件处理（包含hash复用逻辑）
            byte[] hash = GetHashSafely(
                file.Path, 
                file.PlanHash, 
                file.Identity,
                request.HashCache);
            
            // 验证通过，执行删除
            DeleteFileWithPosixSemantics(file.Path, request.Guard);
            
            result.DeletedPaths.Add(file.Path);
            result.SuccessCount++;
            
        } catch (Exception ex) {
            // 【关键】第一个失败立即停止（保持原子性）
            result.AllSucceeded = false;
            result.FirstFailedPath = file.Path;
            result.FirstFailureReason = ex;
            result.ProcessedCount = result.SuccessCount;
            result.ElapsedMs = sw.ElapsedMilliseconds;
            
            // 停止处理，返回partial结果
            // 调用者必须决定：标记为purge-resumable
            return result;
        }
    }
    
    result.AllSucceeded = true;
    result.ProcessedCount = request.Files.Length;
    result.ElapsedMs = sw.ElapsedMilliseconds;
    
    return result;
}
```

### PowerShell调用方式

```powershell
# 当前方式（逐文件）
foreach ($file in $manifest.entries) {
    $hash = Get-HashSafely -Path $file.path -PlanHash $file.sha256
    Remove-FileWithValidation -Path $file.path -ExpectedHash $hash
}

# 优化方式（批量，每批1000个）
$batchSize = 1000
for ($i = 0; $i -lt $manifest.entries.Count; $i += $batchSize) {
    $batch = $manifest.entries[$i..([Math]::Min($i + $batchSize - 1, $manifest.entries.Count - 1))]
    
    $result = Invoke-CodexBatchPurge -Files $batch -Guard $guard -HashCache $sessionCache
    
    if (-not $result.AllSucceeded) {
        # 第一个失败，transaction标记为purge-resumable
        Write-TransactionStatus -Status 'purge-resumable' -FailedAt $result.FirstFailedPath
        throw $result.FirstFailureReason
    }
}
```

### 收益预测

- 减少70% PowerShell开销
- 10k文件省下约15秒
- 相对提升：约**1.3x**

---

## 阶段3：受限并行化（保持crash safety）

### 原理

单线程串行无法利用SSD并发能力

**优化：** 单目录内文件并行，目录层级串行

### 安全设计（修正crash safety缺陷）

```csharp
// 并行Purge设计
public class ParallelPurgeCoordinator {
    private readonly int maxParallelism;
    private readonly JournalWriter mainJournal;
    
    public ParallelPurgeCoordinator(int maxParallelism = 4) {
        this.maxParallelism = Math.Min(maxParallelism, Environment.ProcessorCount);
    }
    
    public void PurgeDirectoryTree(DirectoryManifest manifest) {
        // 从叶到根遍历目录（串行）
        foreach (var dir in manifest.GetDirectoriesBottomUp()) {
            // 单个目录的文件可以并行删除
            PurgeDirectoryFilesParallel(dir);
            
            // 删除目录本身（串行）
            DeleteDirectory(dir.Path);
            
            // 写目录级checkpoint（串行）
            mainJournal.WriteDirectoryCommit(dir.Path);
        }
    }
    
    private void PurgeDirectoryFilesParallel(DirectoryEntry dir) {
        var files = dir.GetFiles();
        
        // 线程局部journal
        var threadJournals = new ConcurrentDictionary<int, List<string>>();
        var failures = new ConcurrentQueue<(string path, Exception ex)>();
        
        // 并行删除文件
        var parallelOptions = new ParallelOptions {
            MaxDegreeOfParallelism = maxParallelism
        };
        
        Parallel.ForEach(files, parallelOptions, (file, state) => {
            var threadId = Thread.CurrentThread.ManagedThreadId;
            
            try {
                // 删除单个文件
                DeleteFileWithValidation(file);
                
                // 记录到线程局部journal
                var journal = threadJournals.GetOrAdd(threadId, _ => new List<string>());
                journal.Add(file.Path);
                
            } catch (Exception ex) {
                // 记录失败，但继续处理其他文件
                failures.Enqueue((file.Path, ex));
                
                // 如果是严重错误（非sharing violation），停止所有线程
                if (!IsRetriableError(ex)) {
                    state.Stop();
                }
            }
        });
        
        // 【关键】所有线程完成后，合并journal（串行）
        MergeThreadJournals(dir.Path, threadJournals);
        
        // 如果有失败，抛出第一个错误
        if (failures.TryDequeue(out var firstFailure)) {
            throw new PartialPurgeException(
                $"Failed to delete {firstFailure.path}",
                firstFailure.ex,
                threadJournals.Values.SelectMany(x => x).ToList());
        }
    }
    
    private void MergeThreadJournals(
        string directoryPath, 
        ConcurrentDictionary<int, List<string>> threadJournals) {
        
        // 按线程ID排序（确保可重复性）
        var sortedThreads = threadJournals.Keys.OrderBy(x => x).ToList();
        
        foreach (var threadId in sortedThreads) {
            var deletedFiles = threadJournals[threadId];
            
            // 批量写入主journal
            mainJournal.WriteBatchCommit(directoryPath, deletedFiles, threadId);
        }
        
        // 刷新到磁盘
        mainJournal.Flush();
    }
}
```

### Journal格式升级（支持并行）

```json
{
  "artifactType": "env-governance.codex-safe-tree-delete-purge-journal",
  "schemaVersion": 3,
  "commits": [
    {
      "directoryPath": "D:\\target\\subdir1",
      "threadId": 12345,
      "deletedFiles": ["file1.txt", "file2.txt", "file3.txt"],
      "timestamp": "2026-08-13T10:30:15.123Z"
    },
    {
      "directoryPath": "D:\\target\\subdir1",
      "threadId": 12346,
      "deletedFiles": ["file4.txt", "file5.txt"],
      "timestamp": "2026-08-13T10:30:15.456Z"
    },
    {
      "directoryPath": "D:\\target\\subdir1",
      "threadId": 12347,
      "deletedFiles": ["file6.txt"],
      "timestamp": "2026-08-13T10:30:15.789Z"
    }
  ],
  "directoryCheckpoints": [
    {
      "path": "D:\\target\\subdir1",
      "allFilesDeleted": true,
      "timestamp": "2026-08-13T10:30:16.000Z"
    }
  ]
}
```

### Crash Recovery逻辑

```csharp
public RecoveryState AnalyzeCrashJournal(string journalPath) {
    var journal = LoadJournal(journalPath);
    
    // 按目录分组
    var byDirectory = journal.commits.GroupBy(c => c.directoryPath);
    
    foreach (var dirGroup in byDirectory) {
        var dirPath = dirGroup.Key;
        
        // 检查目录是否有checkpoint
        var checkpoint = journal.directoryCheckpoints
            .FirstOrDefault(c => c.path == dirPath);
        
        if (checkpoint != null && checkpoint.allFilesDeleted) {
            // 该目录已完整处理
            continue;
        }
        
        // 该目录部分处理，收集已删除的文件
        var deletedFiles = dirGroup.SelectMany(c => c.deletedFiles).ToHashSet();
        
        // 从manifest中找出未删除的文件
        var remainingFiles = manifest.GetFilesInDirectory(dirPath)
            .Where(f => !deletedFiles.Contains(f.Path))
            .ToList();
        
        if (remainingFiles.Count > 0) {
            // 标记为purge-resumable
            return new RecoveryState {
                Status = "purge-resumable",
                RemainingFiles = remainingFiles
            };
        }
    }
    
    return new RecoveryState { Status = "completed" };
}
```

### 并行约束

- ✅ **单目录内文件可并行**（独立文件，无共享状态）
- ❌ **目录层级必须串行**（父子依赖，保持顺序）
- ✅ **Journal合并串行**（保持crash recovery能力）
- ✅ **最大并发度：4**（避免MFT锁争用和资源耗尽）

### 收益预测

- 4核并行，理论4x
- 考虑MFT锁争用和journal串行开销
- 实际：约**2x**

---

## 综合收益预测

| 阶段 | 优化内容 | 单项提升 | 累计提升 |
|------|---------|---------|---------|
| 基线 | 当前实现 | 1x | 1x |
| 阶段1 | 哈希复用（安全版） | 2.3x | 2.3x |
| 阶段2 | 批量处理 | 1.3x | 3.0x |
| 阶段3 | 受限并行 | 2.0x | **6.0x** |

**用户场景预期：**
- 当前：60分钟
- 优化后：**10分钟**
- 提升：**6倍**

## 实施时间表（现实版）

### Week 1: 基础架构（5天）

**Day 1-2: FILE_ID_INFO升级**
- 实现128-bit FILE_ID_INFO获取
- FileIdentityV2结构定义
- 单元测试：identity获取正确性

**Day 3-4: 安全哈希复用**
- SessionHashCache实现
- GetHashSafely完整逻辑
- 单元测试：
  - Identity匹配/不匹配
  - 首次必须重哈希
  - 会话内复用
  - TOCTOU场景模拟

**Day 5: 集成测试**
- Apply/Purge集成哈希复用
- Benchmark对比（预期2.3x）
- Crash safety测试（kill -9中断）

### Week 2: 批量处理（5天）

**Day 6-7: 批量API实现**
- BatchPurgeRequest/Result定义
- PurgeFileBatch核心逻辑
- 错误处理和原子性保证

**Day 8: PowerShell集成**
- 修改Invoke-CodexSafeTreeDeletePurge
- 批量调用wrapper
- 进度回调

**Day 9-10: 测试和验证**
- 单元测试：批量处理各种场景
- 集成测试：与阶段1组合
- Benchmark对比（预期累计3x）

### Week 3: 并行化（5天）

**Day 11-12: 并行架构**
- ParallelPurgeCoordinator实现
- 线程局部journal
- Journal合并逻辑

**Day 13: Journal升级**
- Schema v3定义
- 序列化/反序列化
- Crash recovery逻辑更新

**Day 14-15: 完整测试**
- 并发stress测试
- Crash safety with并发
- 完整回归测试（所有现有test suite）
- Benchmark验证（预期累计6x）

### Week 4: 生产验收（可选）

**Day 16-17: 用户真实场景测试**
- 在用户提供的真实目录上测试
- 性能profiling
- 稳定性验证

**Day 18-19: Bug修复和调优**
- 修复测试中发现的问题
- 性能微调

**Day 20: 文档和发布**
- 更新CHANGELOG
- 更新规格文档
- 准备rollout

**总计：3-4周**

## 风险缓解

### 1. Identity验证失败率高

**风险：** 如果经常遇到identity漂移，需要频繁重哈希，收益降低

**缓解：**
- 监控identity漂移率
- 如果>10%，调查原因（是否有后台进程频繁修改文件）
- 考虑缩短Plan到Apply的间隔

### 2. 并行度不理想

**风险：** MFT锁争用导致并行效果不佳

**缓解：**
- 实测1/2/4/8线程的实际吞吐
- 选择最优并发度（可能不是CPU核心数）
- 提供配置项让用户调整

### 3. Journal合并成为瓶颈

**风险：** 高并发时journal写入成为瓶颈

**缓解：**
- 批量flush journal（积累N条再写入）
- 监控journal写入耗时占比
- 考虑异步journal写入（需要更复杂的crash safety保证）

### 4. 特殊文件系统不兼容

**风险：** ReFS/SMB/OneDrive行为不同

**缓解：**
- 检测文件系统类型
- 非NTFS给出警告
- 提供降级模式（禁用哈希复用或并行）

## 验收标准

### 功能正确性

- ✅ 所有现有test suite通过
- ✅ 新增单元测试覆盖率>90%
- ✅ Crash safety测试通过（kill -9 at各个阶段）
- ✅ Transaction完整性测试通过

### 性能目标

- ✅ 1GB/10k小文件场景：60分钟 → 10分钟（6x）
- ✅ 有效吞吐：从17MB/s提升到100MB/s
- ✅ Hash复用率：>80%（identity不经常漂移）
- ✅ 并行利用率：4核达到3-3.5x吞吐（考虑开销）

### 安全保证

- ✅ 无identity验证绕过
- ✅ 无partial purge泄漏
- ✅ Crash后可正确恢复或resume
- ✅ Transaction状态机正确

### 用户体验

- ✅ 进度反馈及时（每1000个文件或每5秒）
- ✅ 错误消息清晰（identity漂移、sharing violation等）
- ✅ 降级优雅（非NTFS给出警告但仍可工作）

## 回滚计划

### 阶段性rollout

1. **Week 1结束**：如果哈希复用测试通过，部署到staging
2. **Week 2结束**：如果批量处理测试通过，扩大到beta用户
3. **Week 3结束**：如果并行化测试通过，逐步rollout

### Fallback机制

```powershell
# 提供配置项禁用优化
$config = @{
    EnableHashReuse = $true      # 可禁用哈希复用
    EnableBatchProcessing = $true # 可禁用批量处理
    EnableParallelPurge = $true   # 可禁用并行化
    MaxParallelism = 4            # 可调整并发度
}

# 如果发现问题，一键回退到保守模式
$config.EnableHashReuse = $false
$config.EnableParallelPurge = $false
```

### 监控指标

```json
{
  "metrics": {
    "hashReuseRate": 0.85,
    "identityDriftRate": 0.05,
    "averageParallelism": 3.2,
    "journalMergeDurationMs": 120,
    "effectiveThroughputMBps": 95,
    "crashRecoverySuccessRate": 1.0
  }
}
```

## 不做的事（明确边界）

❌ **不降级安全保证**
- 不引入metadata-only轻量模式
- 不跳过首次重哈希确认
- 不假设FileId永不重用

❌ **不破坏现有契约**
- 不改变transaction状态机
- 不改变quarantine语义
- 不改变journal格式（只扩展，保持兼容）

❌ **不超出NTFS边界**
- 不假设所有文件系统都支持FILE_ID_INFO
- 不假设网络驱动器行为与本地一致
- 不假设ReFS行为与NTFS完全相同

❌ **不引入新的外部依赖**
- 不使用第三方哈希库
- 不使用第三方并行库（只用TPL）
- 不引入新的运行时要求

## 成功指标

### 短期（Week 3结束）

- ✅ Benchmark达到6x提升
- ✅ 所有测试通过
- ✅ 代码审查通过
- ✅ 文档完整

### 中期（Month 1）

- ✅ 真实用户场景验证（10个用户）
- ✅ 零P0 bug报告
- ✅ 性能提升达到预期（4-6x）

### 长期（Month 3）

- ✅ 广泛rollout无问题
- ✅ Crash recovery测试通过（生产环境）
- ✅ 用户满意度提升

---

## 下一步

1. **获得批准**：确认方案可实施
2. **Week 1**：开始FILE_ID_INFO和哈希复用实现
3. **持续沟通**：每周进度更新
4. **灵活调整**：根据测试结果调整并发度等参数

需要我现在开始实施Week 1的代码吗？
