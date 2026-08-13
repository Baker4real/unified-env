---
type: implementation-plan
title: 受管删除性能优化实施方案 v2.1（修正P0缺陷）
tags: [performance, implementation, security-hardened]
scenario: 确认小文件过多（数万+文件）
priority: P0
date: 2026-08-13
status: 待实施
revision: v2.1 - 修正第二轮审查发现的4个P0致命缺陷
---

# 受管删除性能优化实施方案 v2.1

## 版本修订历史

- **v2.0**: 整合第一轮对抗审查的P0修正
- **v2.1**: 修正第二轮审查发现的4个P0致命缺陷
  - P0-1: 移除LastWriteTime容忍窗口，改为严格验证
  - P0-2: Identity漂移改为抛异常拒绝删除
  - P0-3: 明确OpenFileForValidation的完整实现
  - P0-4: 改为每线程独立journal文件+立即flush

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

// 安全的Hash复用逻辑（v2.1修正版）
public byte[] GetHashSafely(
    string path, 
    byte[] planHash,
    FileIdentityV2 planIdentity,
    SessionHashCache sessionCache) {
    
    SafeFileHandle handle = null;
    try {
        // 1. 以READ + DELETE sharing打开（明确禁止write）
        handle = OpenFileForValidation(path);
        
        // 2. 获取当前FILE_ID_INFO (128-bit)
        var currentIdentity = GetFileIdentityV2(handle);
        
        // 3. 【P0-2修正】严格检查：Identity必须完全匹配
        if (!IdentityMatches(currentIdentity, planIdentity)) {
            // Identity漂移视为验证失败，拒绝删除
            throw new FileModifiedException(
                $"File identity changed since Plan: {path}. " +
                $"Expected: Vol={planIdentity.VolumeSerialNumber:X}, " +
                $"FileId={BitConverter.ToString(planIdentity.FileId128)}, " +
                $"Size={planIdentity.FileSize}, " +
                $"Mtime={planIdentity.LastWriteTimeUtc:O}. " +
                $"Current: Vol={currentIdentity.VolumeSerialNumber:X}, " +
                $"FileId={BitConverter.ToString(currentIdentity.FileId128)}, " +
                $"Size={currentIdentity.FileSize}, " +
                $"Mtime={currentIdentity.LastWriteTimeUtc:O}. " +
                $"This indicates the file was modified, replaced, or recreated.");
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
                $"File content changed since Plan: {path}. " +
                $"Expected hash: {BitConverter.ToString(planHash)}, " +
                $"Actual hash: {BitConverter.ToString(actualHash)}");
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

// 【P0-3修正】明确OpenFileForValidation的完整实现
private SafeFileHandle OpenFileForValidation(string path) {
    // 明确sharing模式：只允许Read和Delete，禁止Write
    // 这样可以阻止其他进程在验证过程中修改文件
    return File.OpenHandle(
        path,
        FileMode.Open,
        FileAccess.Read,
        FileShare.Read | FileShare.Delete,  // 只share读和删，明确禁止写
        FileOptions.SequentialScan
    );
}

// 【P0-1修正】严格的Identity验证，移除容忍窗口
private bool IdentityMatches(FileIdentityV2 a, FileIdentityV2 b) {
    return a.VolumeSerialNumber == b.VolumeSerialNumber &&
           a.FileId128.SequenceEqual(b.FileId128) &&
           a.FileSize == b.FileSize &&
           // 【P0-1修正】严格验证：mtime必须完全相等
           // 不允许任何容忍窗口，避免TOCTOU漏洞
           a.LastWriteTimeUtc == b.LastWriteTimeUtc;
}

// 【P1-1修正】明确CacheKey实现，确保全局唯一
private string GetCacheKey(string path, FileIdentityV2 identity) {
    // 使用完整路径 + FileId，确保不同目录的同名文件不会冲突
    return $"{path.ToLowerInvariant()}|{identity.VolumeSerialNumber:X16}|{BitConverter.ToString(identity.FileId128)}";
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
            
            // 【P1-2修正】立即写journal，保证crash safety
            request.Journal.WriteCommit(file.Path, hash);
            
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
// 【P0-4修正】并行Purge设计 - 每线程独立journal
public class ParallelPurgeCoordinator {
    private readonly int maxParallelism;
    private readonly string journalBaseDir;
    private readonly string transactionId;
    
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
            WriteMainJournalCheckpoint(dir.Path);
        }
    }
    
    private void PurgeDirectoryFilesParallel(DirectoryEntry dir) {
        var files = dir.GetFiles();
        var failures = new ConcurrentQueue<(string path, Exception ex)>();
        var threadJournalPaths = new ConcurrentBag<string>();
        
        // 并行删除文件
        var parallelOptions = new ParallelOptions {
            MaxDegreeOfParallelism = maxParallelism
        };
        
        Parallel.ForEach(files, parallelOptions, (file, state) => {
            var threadId = Thread.CurrentThread.ManagedThreadId;
            
            // 【P0-4关键修正】每个线程有独立的journal文件
            var threadJournal = GetOrCreateThreadJournal(dir.Path, threadId);
            threadJournalPaths.Add(threadJournal.FilePath);
            
            try {
                // 删除单个文件
                DeleteFileWithValidation(file);
                
                // 【P0-4关键修正】立即写入线程journal并flush
                // 确保crash时已删除的文件有journal记录
                threadJournal.WriteCommit(file.Path, file.Hash);
                threadJournal.Flush();  // 立即持久化到磁盘
                
            } catch (Exception ex) {
                // 【P1-3修正】任何失败都立即停止所有线程
                failures.Enqueue((file.Path, ex));
                state.Stop();  // 停止所有线程
            }
        });
        
        // 所有线程完成后，写入目录级checkpoint到主journal
        WriteMainJournalCheckpoint(dir.Path, threadJournalPaths.ToList());
        
        // 如果有失败，抛出第一个错误
        if (failures.TryDequeue(out var firstFailure)) {
            throw new PartialPurgeException(
                $"Failed to delete {firstFailure.path}",
                firstFailure.ex);
        }
    }
    
    // 获取或创建线程局部journal文件
    private ThreadJournalWriter GetOrCreateThreadJournal(string directoryPath, int threadId) {
        // 命名模式：transaction-{guid}.thread-{tid}.json
        var journalPath = Path.Combine(
            journalBaseDir,
            $"transaction-{transactionId}.thread-{threadId}.json");
        
        return new ThreadJournalWriter(journalPath, directoryPath, threadId);
    }
    
    // 写主journal的目录checkpoint
    private void WriteMainJournalCheckpoint(string directoryPath, List<string> threadJournalPaths = null) {
        var mainJournalPath = Path.Combine(
            journalBaseDir,
            $"transaction-{transactionId}.main.json");
        
        using (var writer = new StreamWriter(mainJournalPath, append: true)) {
            var checkpoint = new {
                directoryPath = directoryPath,
                allFilesDeleted = true,
                threadJournals = threadJournalPaths ?? new List<string>(),
                timestamp = DateTime.UtcNow
            };
            writer.WriteLine(JsonSerializer.Serialize(checkpoint));
        }
    }
}

// 线程局部journal writer
public class ThreadJournalWriter : IDisposable {
    private readonly StreamWriter writer;
    private readonly string directoryPath;
    private readonly int threadId;
    public string FilePath { get; }
    
    public ThreadJournalWriter(string filePath, string directoryPath, int threadId) {
        this.FilePath = filePath;
        this.directoryPath = directoryPath;
        this.threadId = threadId;
        
        // 创建journal文件并写入header
        this.writer = new StreamWriter(filePath, append: false);
        WriteHeader();
    }
    
    private void WriteHeader() {
        var header = new {
            artifactType = "env-governance.codex-safe-tree-delete-thread-journal",
            schemaVersion = 3,
            threadId = threadId,
            directoryPath = directoryPath,
            createdAt = DateTime.UtcNow
        };
        writer.WriteLine(JsonSerializer.Serialize(header));
    }
    
    public void WriteCommit(string filePath, byte[] hash) {
        var commit = new {
            filePath = filePath,
            sha256 = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant(),
            deletedAt = DateTime.UtcNow
        };
        writer.WriteLine(JsonSerializer.Serialize(commit));
    }
    
    public void Flush() {
        writer.Flush();
        // 确保OS也flush到磁盘
        ((FileStream)writer.BaseStream).Flush(flushToDisk: true);
    }
    
    public void Dispose() {
        writer?.Dispose();
    }
}
```

### Journal格式升级（支持并行 + 线程独立journal）

**主Journal格式（transaction-{guid}.main.json）：**
```json
{
  "artifactType": "env-governance.codex-safe-tree-delete-main-journal",
  "schemaVersion": 3,
  "transactionId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "createdAt": "2026-08-13T10:30:00.000Z",
  "directoryCheckpoints": [
    {
      "path": "D:\\target\\subdir1",
      "allFilesDeleted": true,
      "threadJournals": [
        "transaction-a1b2c3d4.thread-12345.json",
        "transaction-a1b2c3d4.thread-12346.json"
      ],
      "timestamp": "2026-08-13T10:30:16.000Z"
    }
  ]
}
```

**线程Journal格式（transaction-{guid}.thread-{tid}.json）：**
```json
{
  "artifactType": "env-governance.codex-safe-tree-delete-thread-journal",
  "schemaVersion": 3,
  "threadId": 12345,
  "directoryPath": "D:\\target\\subdir1",
  "createdAt": "2026-08-13T10:30:10.000Z",
  "commits": [
    {
      "filePath": "D:\\target\\subdir1\\file1.txt",
      "sha256": "abc123...",
      "deletedAt": "2026-08-13T10:30:11.123Z"
    },
    {
      "filePath": "D:\\target\\subdir1\\file2.txt",
      "sha256": "def456...",
      "deletedAt": "2026-08-13T10:30:11.456Z"
    }
  ]
}
```

**关键改进（v2.1）：**
- ✅ 每个线程独立journal文件（立即flush，保证crash safety）
- ✅ 主journal只记录目录checkpoint和线程journal引用
- ✅ Crash recovery读取所有线程journal重建已删除文件集合

### Crash Recovery逻辑（v2.1修正版）

```csharp
public RecoveryState AnalyzeCrashJournal(string transactionId, string journalBaseDir) {
    // 1. 读取主journal
    var mainJournalPath = Path.Combine(journalBaseDir, $"transaction-{transactionId}.main.json");
    if (!File.Exists(mainJournalPath)) {
        return new RecoveryState { Status = "no-journal-found" };
    }
    
    var mainJournal = LoadMainJournal(mainJournalPath);
    
    // 2. 【P0-4修正】读取所有线程journal
    var threadJournalPattern = $"transaction-{transactionId}.thread-*.json";
    var threadJournalPaths = Directory.GetFiles(journalBaseDir, threadJournalPattern);
    
    var allDeletedFiles = new HashSet<string>();
    
    foreach (var threadJournalPath in threadJournalPaths) {
        var threadJournal = LoadThreadJournal(threadJournalPath);
        foreach (var commit in threadJournal.commits) {
            allDeletedFiles.Add(commit.filePath);
        }
    }
    
    // 3. 检查哪些目录已完成
    var completedDirectories = new HashSet<string>(
        mainJournal.directoryCheckpoints
            .Where(c => c.allFilesDeleted)
            .Select(c => c.path)
    );
    
    // 4. 从manifest中找出未删除的文件
    var remainingFiles = new List<string>();
    
    foreach (var dir in manifest.GetAllDirectories()) {
        if (completedDirectories.Contains(dir.Path)) {
            // 该目录已完整处理，跳过
            continue;
        }
        
        // 该目录部分处理或未处理
        var filesInDir = manifest.GetFilesInDirectory(dir.Path);
        var notDeleted = filesInDir
            .Where(f => !allDeletedFiles.Contains(f.Path))
            .ToList();
        
        if (notDeleted.Count > 0) {
            remainingFiles.AddRange(notDeleted.Select(f => f.Path));
        }
    }
    
    if (remainingFiles.Count > 0) {
        // 有未删除的文件，标记为purge-resumable
        return new RecoveryState {
            Status = "purge-resumable",
            RemainingFiles = remainingFiles,
            CompletedFiles = allDeletedFiles.ToList()
        };
    }
    
    return new RecoveryState { 
        Status = "completed",
        CompletedFiles = allDeletedFiles.ToList()
    };
}

// 清理已完成transaction的journal文件
public void CleanupCompletedJournals(string transactionId, string journalBaseDir) {
    // 删除主journal
    var mainJournalPath = Path.Combine(journalBaseDir, $"transaction-{transactionId}.main.json");
    if (File.Exists(mainJournalPath)) {
        File.Delete(mainJournalPath);
    }
    
    // 删除所有线程journal
    var threadJournalPattern = $"transaction-{transactionId}.thread-*.json";
    var threadJournalPaths = Directory.GetFiles(journalBaseDir, threadJournalPattern);
    foreach (var path in threadJournalPaths) {
        File.Delete(path);
    }
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
- 【P0-4验证】Crash safety with并发（kill -9在各个线程journal写入阶段）
- 【P0-1/P0-2验证】Identity严格验证测试（mtime修改、文件替换）
- 【P1-4验证】文件系统检测和降级测试
- 完整回归测试（所有现有test suite）
- Benchmark验证（预期累计6x）

### Week 4: 生产验收和文档（5天）

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
- 【v2.1注】严格mtime验证可能增加漂移检测率，但保证了安全性

### 2. 并行度不理想

**风险：** MFT锁争用导致并行效果不佳

**缓解：**
- 实测1/2/4/8线程的实际吞吐
- 选择最优并发度（可能不是CPU核心数）
- 提供配置项让用户调整

### 3. Journal文件数量增多

**风险：** 【v2.1新增】每个线程独立journal，高并发时journal文件数量多

**缓解：**
- Transaction完成后立即清理journal文件
- 监控journal目录的文件数
- 限制最大并发度（默认4，避免过多journal文件）

### 4. 特殊文件系统不兼容

**风险：** ReFS/SMB/OneDrive行为不同

**缓解：**
- 【P1-4】实现文件系统类型检测
- 非NTFS给出警告并自动降级
- 提供手动降级模式（禁用哈希复用或并行）

## 验收标准

### 功能正确性

- ✅ 所有现有test suite通过
- ✅ 新增单元测试覆盖率>90%
- ✅ Crash safety测试通过（kill -9 at各个阶段，包括线程journal写入时）
- ✅ Transaction完整性测试通过
- ✅ 【v2.1新增】Identity严格验证测试（mtime修改、文件替换、FileId重用模拟）
- ✅ 【v2.1新增】多线程journal独立性测试（并发写入、crash恢复）

### 性能目标

- ✅ 1GB/10k小文件场景：60分钟 → 10分钟（6x）
- ✅ 有效吞吐：从17MB/s提升到100MB/s
- ✅ Hash复用率：>80%（identity不经常漂移）
- ✅ 并行利用率：4核达到3-3.5x吞吐（考虑开销）

### 安全保证

- ✅ 无identity验证绕过（strict mtime check）
- ✅ 无partial purge泄漏
- ✅ Crash后可正确恢复或resume（多线程journal完整性）
- ✅ Transaction状态机正确
- ✅ 【v2.1新增】Content-authenticated保证不被破坏（Identity漂移拒绝删除）
- ✅ 【v2.1新增】Crash safety在并发场景下保持（每线程独立journal+立即flush）

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
    StrictIdentityCheck = $true   # 【v2.1新增】严格identity验证（默认启用）
}

# 如果发现问题，一键回退到保守模式
$config.EnableHashReuse = $false
$config.EnableParallelPurge = $false
```

### 监控指标（v2.1扩展）

```json
{
  "metrics": {
    "hashReuseRate": 0.85,
    "identityDriftRate": 0.05,
    "identityDriftReasons": {
      "mtimeChanged": 0.03,
      "sizeChanged": 0.01,
      "fileIdChanged": 0.01
    },
    "averageParallelism": 3.2,
    "threadJournalCount": 4,
    "threadJournalFlushDurationMs": 15,
    "effectiveThroughputMBps": 95,
    "crashRecoverySuccessRate": 1.0,
    "strictIdentityCheckEnabled": true
  }
}
```

### 【v2.1新增】Schema兼容性策略

```json
{
  "schemaVersion": 3,
  "schemaCompatibility": {
    "description": "v3引入多线程journal，主journal只记录checkpoint",
    "canReadV1": false,
    "canReadV2": false,
    "v2CanReadV3": false,
    "note": "v3是破坏性升级，需要完整的v3代码才能读取线程journal"
  }
}
```

**向后兼容策略：**
- v2.1生成的journal（schema v3）只能由v2.1代码读取
- 如果需要回滚到v2.0，必须完成当前transaction或手动清理journal
- 不支持跨版本的crash recovery

## 不做的事（明确边界）

❌ **不降级安全保证**
- 不引入metadata-only轻量模式
- 不跳过首次重哈希确认
- 不假设FileId永不重用
- 【v2.1强调】不允许LastWriteTime容忍窗口（严格相等）
- 【v2.1强调】Identity漂移必须拒绝删除，不能"重哈希后继续"

❌ **不破坏现有契约**
- 不改变transaction状态机
- 不改变quarantine语义
- 不改变journal格式向后兼容性（v3是破坏性升级，明确声明）

❌ **不超出NTFS边界**
- 不假设所有文件系统都支持FILE_ID_INFO
- 不假设网络驱动器行为与本地一致
- 不假设ReFS行为与NTFS完全相同

❌ **不引入新的外部依赖**
- 不使用第三方哈希库
- 不使用第三方并行库（只用TPL）
- 不引入新的运行时要求

❌ **不妥协crash safety**
- 【v2.1强调】不允许内存journal延迟flush
- 【v2.1强调】每个文件删除后必须立即持久化journal
- 不允许"性能优先、安全次之"的权衡

## v2.1关键修正总结

### P0-1: 移除LastWriteTime容忍窗口
- **修正前**：允许2秒mtime差异
- **修正后**：严格相等验证（`a.LastWriteTimeUtc == b.LastWriteTimeUtc`）
- **影响**：闭合TOCTOU窗口，但可能增加identity漂移检测率

### P0-2: Identity漂移改为拒绝删除
- **修正前**：漂移时重哈希并继续
- **修正后**：`throw FileModifiedException`，拒绝删除
- **影响**：保证content-authenticated语义

### P0-3: 明确OpenFileForValidation实现
- **修正前**：实现不明
- **修正后**：明确`FileShare.Read | FileShare.Delete`，禁止write
- **影响**：阻止验证过程中的并发修改

### P0-4: 每线程独立journal+立即flush
- **修正前**：内存journal，批量合并
- **修正后**：每线程独立文件，删除后立即flush
- **影响**：保证并发场景下的crash safety，代价是journal文件数增加

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

1. **获得批准**：确认v2.1方案可实施
2. **第三轮对抗审查**：验证P0修正是否充分
3. **Week 1**：开始FILE_ID_INFO和哈希复用实现
4. **持续沟通**：每周进度更新
5. **灵活调整**：根据测试结果调整并发度等参数

---

## 附录：P1级待办事项（实施时处理）

### P1-1: GetCacheKey实现
已在v2.1明确实现（第136-139行）

### P1-2: 批量journal写入时机
已在v2.1修正（第199行，立即写journal）

### P1-3: 并行失败处理统一
已在v2.1修正（第324行，任何失败都立即停止）

### P1-4: 文件系统检测
需要在Week 1-2实现：

```csharp
public FileSystemCapabilities DetectFileSystem(string path) {
    var root = Path.GetPathRoot(path);
    var driveInfo = new DriveInfo(root);
    
    var isRemote = driveInfo.DriveType == DriveType.Network;
    var fsType = driveInfo.DriveFormat;
    
    // 测试FILE_ID_INFO支持
    var supportsFileId128 = TestFileIdSupport(path);
    
    return new FileSystemCapabilities {
        FileSystem = fsType,
        IsRemote = isRemote,
        SupportsFileId128 = supportsFileId128,
        RecommendHashReuse = fsType == "NTFS" && !isRemote && supportsFileId128,
        RecommendParallel = fsType == "NTFS" && !isRemote,
        Warning = GetFileSystemWarning(fsType, isRemote, supportsFileId128)
    };
}

private string GetFileSystemWarning(string fsType, bool isRemote, bool supportsFileId) {
    if (isRemote) {
        return "警告：网络驱动器，优化效果可能有限（<2x），建议本地处理";
    }
    if (fsType != "NTFS") {
        return $"警告：文件系统 {fsType} 未经充分测试，建议禁用哈希复用和并行";
    }
    if (!supportsFileId) {
        return "警告：FILE_ID_INFO不可用，将禁用哈希复用";
    }
    return null;
}
```

### P1-5: Journal性能监控
在Week 3 Day 14添加测试：

```csharp
[Test]
public void TestJournalPerformanceNotBottleneck() {
    // 测量journal写入占总时间的百分比
    var sw = Stopwatch.StartNew();
    var journalTime = 0L;
    
    foreach (var file in testFiles) {
        DeleteFile(file);
        
        var journalSw = Stopwatch.StartNew();
        journal.WriteCommit(file.Path);
        journal.Flush();
        journalSw.Stop();
        
        journalTime += journalSw.ElapsedMilliseconds;
    }
    
    sw.Stop();
    var journalPercent = (double)journalTime / sw.ElapsedMilliseconds;
    
    Assert.That(journalPercent, Is.LessThan(0.1), 
        "Journal写入不应超过总时间的10%");
}
```

### P1-6: 时间表调整
已在Week 4扩展为生产验收（不再是"可选"）

### P1-7: Schema兼容性
已在v2.1明确声明为破坏性升级
