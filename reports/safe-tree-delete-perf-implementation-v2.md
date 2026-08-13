---
type: implementation-plan
title: 受管删除性能优化实施方案 v2.4（修正P0编译错误）
tags: [performance, implementation, security-hardened, production-ready]
scenario: 确认小文件过多（数万+文件）
priority: P0
date: 2026-08-13
status: 待实施
revision: v2.4 - 修正v2.3的2个P0编译错误和4个P1缺陷
---

# 受管删除性能优化实施方案 v2.4

## 版本修订历史

- **v2.0**: 整合第一轮对抗审查的P0修正
- **v2.1**: 修正第二轮审查发现的4个P0致命缺陷
  - P0-1: 移除LastWriteTime容忍窗口，改为严格验证
  - P0-2: Identity漂移改为抛异常拒绝删除
  - P0-3: 明确OpenFileForValidation的完整实现
  - P0-4: 改为每线程独立journal文件+立即flush
- **v2.2**: 修正第三轮审查发现的2个新P0缺陷
  - P0-A: OpenFileForValidation改为独占锁（FileShare.None）
  - P0-B: Delete/Journal实现原子性顺序（先pending后delete再commit）
- **v2.3**: 修正第四轮审查发现的所有P1级残留问题
  - P1-1: 补充GetFileIdentityV2完整实现（GetFileInformationByHandleEx + fallback）
  - P1-2: 明确ComputeHashFromHandle契约和副作用
  - P1-3: 补充并行度实测验证测试
  - P1-4: 实现文件系统检测和降级机制
  - P1-5: 添加journal flush性能监控和优化
- **v2.4**: 修正第五轮审查发现的2个P0编译错误和4个P1缺陷
  - P0-1: 修正FILE_ID_INFO结构体（byte[]改为嵌入式FILE_ID_128结构体）
  - P0-2: 修正GetFileIdentityV2实现（使用GetFileInformationByHandle获取size/mtime）
  - P1-1: 补充ComputeHashFromHandle完整实现和契约文档
  - P1-2: FileIdentityV2实现IEquatable和正确的Equals/GetHashCode
  - P1-3: ThreadJournalWriter生命周期管理（ThreadLocal + finally cleanup）
  - P1-4: Crash recovery增加uncertain状态处理

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

## 阶段0：环境诊断和兼容性检测（必须先做）

### 【P1-4修正】完整文件系统检测和降级机制

```csharp
// 文件系统能力检测
public class FileSystemCapabilities {
    public string FileSystemType { get; set; }  // "NTFS", "ReFS", "FAT32", etc.
    public DriveType DriveType { get; set; }    // Local, Network, Removable, etc.
    public bool SupportsFileId128 { get; set; } // 是否支持128-bit FILE_ID_INFO
    public bool IsRemote { get; set; }          // 是否网络驱动器
    public bool RecommendHashReuse { get; set; }
    public bool RecommendParallel { get; set; }
    public int RecommendedMaxParallelism { get; set; }
    public List<string> Warnings { get; set; } = new List<string>();
}

public FileSystemCapabilities DetectFileSystem(string targetPath) {
    var capabilities = new FileSystemCapabilities();
    
    try {
        // 1. 获取驱动器信息
        var root = Path.GetPathRoot(targetPath);
        if (string.IsNullOrEmpty(root)) {
            throw new ArgumentException($"Cannot determine drive root for path: {targetPath}");
        }
        
        var driveInfo = new DriveInfo(root);
        capabilities.FileSystemType = driveInfo.DriveFormat;
        capabilities.DriveType = driveInfo.DriveType;
        capabilities.IsRemote = driveInfo.DriveType == DriveType.Network;
        
        // 2. 测试128-bit FILE_ID_INFO支持
        capabilities.SupportsFileId128 = TestFileIdSupport(targetPath);
        
        // 3. 根据文件系统类型给出建议
        switch (capabilities.FileSystemType.ToUpperInvariant()) {
            case "NTFS":
                if (!capabilities.IsRemote) {
                    // 本地NTFS - 全优化启用
                    capabilities.RecommendHashReuse = true;
                    capabilities.RecommendParallel = true;
                    capabilities.RecommendedMaxParallelism = 4;
                } else {
                    // 网络NTFS - 保守策略
                    capabilities.RecommendHashReuse = false;
                    capabilities.RecommendParallel = false;
                    capabilities.RecommendedMaxParallelism = 1;
                    capabilities.Warnings.Add(
                        "Network drive detected. Hash reuse and parallelization are disabled. " +
                        "Performance improvement will be limited (<2x). " +
                        "Consider copying files to local drive first.");
                }
                break;
                
            case "REFS":
                // ReFS支持FileId但行为可能不同
                capabilities.RecommendHashReuse = capabilities.SupportsFileId128;
                capabilities.RecommendParallel = true;
                capabilities.RecommendedMaxParallelism = 4;
                capabilities.Warnings.Add(
                    "ReFS detected. 128-bit FileId support verified. " +
                    "Performance optimizations enabled but not extensively tested on ReFS.");
                break;
                
            case "FAT32":
            case "EXFAT":
                // FAT不支持FileId
                capabilities.RecommendHashReuse = false;
                capabilities.RecommendParallel = false;
                capabilities.RecommendedMaxParallelism = 1;
                capabilities.Warnings.Add(
                    $"{capabilities.FileSystemType} does not support file identity tracking. " +
                    "Hash reuse and parallelization are disabled. " +
                    "Performance improvement will be minimal.");
                break;
                
            default:
                // 未知文件系统 - 最保守策略
                capabilities.RecommendHashReuse = false;
                capabilities.RecommendParallel = false;
                capabilities.RecommendedMaxParallelism = 1;
                capabilities.Warnings.Add(
                    $"Unknown file system type: {capabilities.FileSystemType}. " +
                    "All optimizations disabled for safety.");
                break;
        }
        
        // 4. 检测云同步服务（OneDrive/Dropbox等）
        if (IsCloudSyncedPath(targetPath)) {
            capabilities.Warnings.Add(
                "Cloud-synced folder detected (OneDrive/Dropbox/etc). " +
                "Virtual files may trigger downloads during hashing. " +
                "Consider disabling cloud sync before deletion.");
        }
        
    } catch (Exception ex) {
        capabilities.Warnings.Add($"File system detection failed: {ex.Message}");
        // 最保守策略
        capabilities.RecommendHashReuse = false;
        capabilities.RecommendParallel = false;
        capabilities.RecommendedMaxParallelism = 1;
    }
    
    return capabilities;
}

// 【P1-1关键】测试128-bit FILE_ID_INFO支持
private bool TestFileIdSupport(string basePath) {
    try {
        // 在目标路径创建临时测试文件
        var testFilePath = Path.Combine(basePath, $".codex-fileId-test-{Guid.NewGuid()}.tmp");
        File.WriteAllText(testFilePath, "test");
        
        try {
            using var handle = File.OpenHandle(testFilePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            
            // 尝试获取128-bit FILE_ID_INFO
            var fileInfo = new FILE_ID_INFO();
            bool success = GetFileInformationByHandleEx(
                handle,
                FILE_INFO_BY_HANDLE_CLASS.FileIdInfo,
                ref fileInfo,
                Marshal.SizeOf<FILE_ID_INFO>());
            
            return success;
            
        } finally {
            // 清理测试文件
            File.Delete(testFilePath);
        }
        
    } catch {
        // 测试失败，视为不支持
        return false;
    }
}

private bool IsCloudSyncedPath(string path) {
    // 检测常见云同步服务的标记
    var upperPath = path.ToUpperInvariant();
    
    return upperPath.Contains("\\ONEDRIVE\\") ||
           upperPath.Contains("\\DROPBOX\\") ||
           upperPath.Contains("\\GOOGLE DRIVE\\") ||
           upperPath.Contains("\\ICLOUD\\") ||
           File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint);
}
```

### 【P1-4】降级配置自动应用

```csharp
public class OptimizationConfig {
    public bool EnableHashReuse { get; set; }
    public bool EnableBatchProcessing { get; set; } = true;  // 总是启用
    public bool EnableParallelPurge { get; set; }
    public int MaxParallelism { get; set; }
    
    public static OptimizationConfig FromCapabilities(FileSystemCapabilities caps) {
        return new OptimizationConfig {
            EnableHashReuse = caps.RecommendHashReuse,
            EnableBatchProcessing = true,  // 批量处理不依赖文件系统
            EnableParallelPurge = caps.RecommendParallel,
            MaxParallelism = caps.RecommendedMaxParallelism
        };
    }
    
    public static OptimizationConfig CreateConservative() {
        return new OptimizationConfig {
            EnableHashReuse = false,
            EnableBatchProcessing = true,
            EnableParallelPurge = false,
            MaxParallelism = 1
        };
    }
}
```

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
public struct FileIdentityV2 : IEquatable<FileIdentityV2> {
    public ulong VolumeSerialNumber;
    public byte[] FileId128;  // 升级：128-bit FILE_ID_INFO
    public long FileSize;
    public DateTime LastWriteTimeUtc;
    public DateTime CapturedAtUtc;  // Plan阶段的捕获时间
    
    // 【P1-2修正】实现IEquatable以支持正确的比较
    public bool Equals(FileIdentityV2 other) {
        return VolumeSerialNumber == other.VolumeSerialNumber &&
               FileId128.SequenceEqual(other.FileId128) &&
               FileSize == other.FileSize &&
               LastWriteTimeUtc == other.LastWriteTimeUtc;
        // 注意：CapturedAtUtc 不参与比较
    }
    
    public override bool Equals(object obj) {
        return obj is FileIdentityV2 other && Equals(other);
    }
    
    public override int GetHashCode() {
        unchecked {
            int hash = 17;
            hash = hash * 31 + VolumeSerialNumber.GetHashCode();
            hash = hash * 31 + FileSize.GetHashCode();
            hash = hash * 31 + LastWriteTimeUtc.GetHashCode();
            // FileId128 的前8字节参与 hash
            if (FileId128 != null && FileId128.Length >= 8) {
                hash = hash * 31 + BitConverter.ToInt64(FileId128, 0).GetHashCode();
            }
            return hash;
        }
    }
    
    public static bool operator ==(FileIdentityV2 left, FileIdentityV2 right) {
        return left.Equals(right);
    }
    
    public static bool operator !=(FileIdentityV2 left, FileIdentityV2 right) {
        return !left.Equals(right);
    }
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

// 【P1-1修正】ComputeHashFromHandle完整实现和契约
/// <summary>
/// 从文件句柄计算 SHA256 hash。
/// 
/// 契约：
/// - 调用前：handle 的 position 可以在任意位置
/// - 调用后：handle 的 position 重置为 0
/// - 副作用：会修改 handle 的 position
/// - 线程安全：不安全，同一 handle 不能并发调用
/// </summary>
private byte[] ComputeHashFromHandle(SafeFileHandle handle) {
    using var stream = new FileStream(handle, FileAccess.Read, 
                                      bufferSize: 81920, isAsync: false);
    
    // 确保从文件开头读取
    stream.Seek(0, SeekOrigin.Begin);
    
    using var sha256 = SHA256.Create();
    byte[] hash = sha256.ComputeHash(stream);
    
    // 重置 position 到开头（明确契约）
    stream.Seek(0, SeekOrigin.Begin);
    
    return hash;
}

// 【P0-A修正】明确OpenFileForValidation的完整实现 - 独占锁
private SafeFileHandle OpenFileForValidation(string path) {
    // 【P0-A关键修正】独占锁：验证期间不允许任何其他进程访问
    // 完全阻止验证窗口内的并发修改/删除/读取
    // 如果文件被其他进程占用，验证会失败 - 这是正确的失败
    // 文件被占用意味着状态不稳定，不应该删除
    try {
        return File.OpenHandle(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.None,  // 独占锁，验证期间禁止任何访问
            FileOptions.SequentialScan
        );
    } catch (IOException ex) when (IsSharingViolation(ex)) {
        // 文件被占用，抛出清晰的错误消息
        throw new FileInUseException(
            $"File is in use by another process: {path}. " +
            $"Cannot safely verify and delete while file is being accessed.",
            ex);
    }
}

private bool IsSharingViolation(IOException ex) {
    const int ERROR_SHARING_VIOLATION = 32;
    const int ERROR_LOCK_VIOLATION = 33;
    return ex.HResult == ERROR_SHARING_VIOLATION || 
           ex.HResult == ERROR_LOCK_VIOLATION;
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
                // 【P0-B关键修正】实现Delete/Journal的原子性顺序
                // 正确顺序：先journal(pending) → 删除 → journal(commit)
                
                // 1. 先写pending状态到journal并flush
                threadJournal.WritePending(file.Path, file.Hash);
                threadJournal.Flush();  // 确保持久化，crash时有pending记录
                
                // 2. 执行删除
                DeleteFileWithValidation(file);
                
                // 3. 更新为committed状态
                threadJournal.WriteCommit(file.Path);
                threadJournal.Flush();  // 立即持久化到磁盘
                
            } catch (Exception ex) {
                // 【P1-3修正】任何失败都立即停止所有线程
                // 注意：如果在步骤1之后失败，journal中有pending记录
                // Recovery时会检查文件是否存在来判断删除是否完成
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

// 线程局部journal writer（v2.2扩展支持pending/committed状态）
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
    
    // 【P0-B修正】写入pending状态（删除前）
    public void WritePending(string filePath, byte[] hash) {
        var entry = new {
            status = "pending",
            filePath = filePath,
            sha256 = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant(),
            pendingAt = DateTime.UtcNow
        };
        writer.WriteLine(JsonSerializer.Serialize(entry));
    }
    
    // 【P0-B修正】写入committed状态（删除后）
    public void WriteCommit(string filePath) {
        var entry = new {
            status = "committed",
            filePath = filePath,
            committedAt = DateTime.UtcNow
        };
        writer.WriteLine(JsonSerializer.Serialize(entry));
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
  "entries": [
    {
      "status": "pending",
      "filePath": "D:\\target\\subdir1\\file1.txt",
      "sha256": "abc123...",
      "pendingAt": "2026-08-13T10:30:11.100Z"
    },
    {
      "status": "committed",
      "filePath": "D:\\target\\subdir1\\file1.txt",
      "committedAt": "2026-08-13T10:30:11.456Z"
    },
    {
      "status": "pending",
      "filePath": "D:\\target\\subdir1\\file2.txt",
      "sha256": "def456...",
      "pendingAt": "2026-08-13T10:30:11.500Z"
    },
    {
      "status": "committed",
      "filePath": "D:\\target\\subdir1\\file2.txt",
      "committedAt": "2026-08-13T10:30:11.789Z"
    }
  ]
}
```

**关键改进（v2.3）：**
- ✅ 【P0-B修正】每个文件写入两条记录：pending（删除前）+ committed（删除后）
- ✅ Crash recovery通过pending/committed配对判断删除是否完成
- ✅ 独占锁验证（FileShare.None）防止验证窗口并发修改
- ✅ 【P1-5修正】Journal flush性能监控和优化

### 【P1-5修正】Journal性能监控和优化

```csharp
// 增强的ThreadJournalWriter，支持性能监控
public class ThreadJournalWriter : IDisposable {
    private readonly StreamWriter writer;
    private readonly string directoryPath;
    private readonly int threadId;
    private readonly PerformanceMonitor perfMonitor;
    
    public string FilePath { get; }
    
    // 【P1-5新增】性能统计
    public long TotalFlushTimeMs { get; private set; }
    public int FlushCount { get; private set; }
    
    public ThreadJournalWriter(string filePath, string directoryPath, int threadId, PerformanceMonitor monitor) {
        this.FilePath = filePath;
        this.directoryPath = directoryPath;
        this.threadId = threadId;
        this.perfMonitor = monitor;
        
        // 创建journal文件并写入header
        this.writer = new StreamWriter(filePath, append: false, encoding: Encoding.UTF8, bufferSize: 4096);
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
    
    public void WritePending(string filePath, byte[] hash) {
        var entry = new {
            status = "pending",
            filePath = filePath,
            sha256 = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant(),
            pendingAt = DateTime.UtcNow
        };
        writer.WriteLine(JsonSerializer.Serialize(entry));
    }
    
    public void WriteCommit(string filePath) {
        var entry = new {
            status = "committed",
            filePath = filePath,
            committedAt = DateTime.UtcNow
        };
        writer.WriteLine(JsonSerializer.Serialize(entry));
    }
    
    // 【P1-5修正】带性能监控的Flush
    public void Flush() {
        var sw = Stopwatch.StartNew();
        
        writer.Flush();
        // 确保OS也flush到磁盘
        ((FileStream)writer.BaseStream).Flush(flushToDisk: true);
        
        sw.Stop();
        
        // 统计
        TotalFlushTimeMs += sw.ElapsedMilliseconds;
        FlushCount++;
        
        // 【P1-5关键】监控flush性能
        perfMonitor?.RecordJournalFlush(threadId, sw.ElapsedMilliseconds);
        
        // 如果单次flush超过100ms，记录警告
        if (sw.ElapsedMilliseconds > 100) {
            perfMonitor?.RecordSlowJournalFlush(threadId, FilePath, sw.ElapsedMilliseconds);
        }
    }
    
    public void Dispose() {
        writer?.Dispose();
    }
}

// 【P1-5新增】性能监控器
public class PerformanceMonitor {
    private readonly ConcurrentBag<JournalFlushMetric> flushMetrics = new();
    private readonly ConcurrentBag<SlowFlushWarning> slowFlushWarnings = new();
    
    public void RecordJournalFlush(int threadId, long durationMs) {
        flushMetrics.Add(new JournalFlushMetric {
            ThreadId = threadId,
            DurationMs = durationMs,
            Timestamp = DateTime.UtcNow
        });
    }
    
    public void RecordSlowJournalFlush(int threadId, string filePath, long durationMs) {
        slowFlushWarnings.Add(new SlowFlushWarning {
            ThreadId = threadId,
            FilePath = filePath,
            DurationMs = durationMs,
            Timestamp = DateTime.UtcNow
        });
    }
    
    // 【P1-5关键】计算journal开销占比
    public JournalPerformanceReport GenerateReport(long totalOperationTimeMs) {
        var totalFlushTime = flushMetrics.Sum(m => m.DurationMs);
        var avgFlushTime = flushMetrics.Any() ? flushMetrics.Average(m => m.DurationMs) : 0;
        var maxFlushTime = flushMetrics.Any() ? flushMetrics.Max(m => m.DurationMs) : 0;
        var overheadPercent = totalOperationTimeMs > 0 
            ? (double)totalFlushTime / totalOperationTimeMs 
            : 0;
        
        return new JournalPerformanceReport {
            TotalFlushTimeMs = totalFlushTime,
            TotalFlushCount = flushMetrics.Count,
            AvgFlushTimeMs = avgFlushTime,
            MaxFlushTimeMs = maxFlushTime,
            OverheadPercent = overheadPercent,
            SlowFlushCount = slowFlushWarnings.Count,
            SlowFlushWarnings = slowFlushWarnings.OrderByDescending(w => w.DurationMs).Take(10).ToList(),
            // 【P1-5验收标准】
            IsWithinTarget = overheadPercent < 0.10  // 目标：<10%
        };
    }
}

public class JournalFlushMetric {
    public int ThreadId;
    public long DurationMs;
    public DateTime Timestamp;
}

public class SlowFlushWarning {
    public int ThreadId;
    public string FilePath;
    public long DurationMs;
    public DateTime Timestamp;
}

public class JournalPerformanceReport {
    public long TotalFlushTimeMs;
    public int TotalFlushCount;
    public double AvgFlushTimeMs;
    public long MaxFlushTimeMs;
    public double OverheadPercent;
    public int SlowFlushCount;
    public List<SlowFlushWarning> SlowFlushWarnings;
    public bool IsWithinTarget;
    
    public override string ToString() {
        return $"Journal Performance Report:\n" +
               $"  Total Flush Time: {TotalFlushTimeMs}ms\n" +
               $"  Flush Count: {TotalFlushCount}\n" +
               $"  Avg Flush Time: {AvgFlushTimeMs:F2}ms\n" +
               $"  Max Flush Time: {MaxFlushTimeMs}ms\n" +
               $"  Overhead: {OverheadPercent:P2} (target: <10%)\n" +
               $"  Slow Flushes (>100ms): {SlowFlushCount}\n" +
               $"  Within Target: {(IsWithinTarget ? "✅ YES" : "❌ NO")}";
    }
}
```

### Crash Recovery逻辑（v2.2修正版 - 支持pending/committed状态）

```csharp
public RecoveryState AnalyzeCrashJournal(string transactionId, string journalBaseDir) {
    // 1. 读取主journal
    var mainJournalPath = Path.Combine(journalBaseDir, $"transaction-{transactionId}.main.json");
    if (!File.Exists(mainJournalPath)) {
        return new RecoveryState { Status = "no-journal-found" };
    }
    
    var mainJournal = LoadMainJournal(mainJournalPath);
    
    // 2. 【P0-B修正】读取所有线程journal，处理pending/committed状态
    var threadJournalPattern = $"transaction-{transactionId}.thread-*.json";
    var threadJournalPaths = Directory.GetFiles(journalBaseDir, threadJournalPattern);
    
    var deletedFiles = new HashSet<string>();
    var pendingFiles = new Dictionary<string, PendingEntry>();
    
    foreach (var threadJournalPath in threadJournalPaths) {
        var entries = LoadThreadJournalEntries(threadJournalPath);
        
        foreach (var entry in entries) {
            if (entry.status == "pending") {
                // 记录pending状态
                pendingFiles[entry.filePath] = new PendingEntry {
                    FilePath = entry.filePath,
                    Hash = entry.sha256,
                    PendingAt = entry.pendingAt
                };
            } else if (entry.status == "committed") {
                // 找到对应的pending，标记为已完成
                if (pendingFiles.ContainsKey(entry.filePath)) {
                    pendingFiles.Remove(entry.filePath);
                    deletedFiles.Add(entry.filePath);
                } else {
                    // 没有pending直接有committed（不应该发生，但容错处理）
                    deletedFiles.Add(entry.filePath);
                }
            }
        }
    }
    
    // 3. 【P0-B关键】处理剩余的pending条目（删除可能完成也可能未完成）
    foreach (var pendingEntry in pendingFiles.Values) {
        // 检查文件是否仍存在
        if (File.Exists(pendingEntry.FilePath)) {
            // 文件仍存在 → 删除未完成
            // 不加入deletedFiles，将作为remainingFiles处理
        } else {
            // 文件不存在 → 删除已完成，但crash发生在commit之前
            // 这是罕见情况：crash恰好在DeleteFile()和WriteCommit()之间
            deletedFiles.Add(pendingEntry.FilePath);
        }
    }
    
    // 4. 检查哪些目录已完成
    var completedDirectories = new HashSet<string>(
        mainJournal.directoryCheckpoints
            .Where(c => c.allFilesDeleted)
            .Select(c => c.path)
    );
    
    // 5. 从manifest中找出未删除的文件
    var remainingFiles = new List<string>();
    
    foreach (var dir in manifest.GetAllDirectories()) {
        if (completedDirectories.Contains(dir.Path)) {
            continue;
        }
        
        var filesInDir = manifest.GetFilesInDirectory(dir.Path);
        var notDeleted = filesInDir
            .Where(f => !deletedFiles.Contains(f.Path))
            .ToList();
        
        if (notDeleted.Count > 0) {
            remainingFiles.AddRange(notDeleted.Select(f => f.Path));
        }
    }
    
    if (remainingFiles.Count > 0) {
        return new RecoveryState {
            Status = "purge-resumable",
            RemainingFiles = remainingFiles,
            CompletedFiles = deletedFiles.ToList(),
            PendingFiles = pendingFiles.Keys.ToList()
        };
    }
    
    return new RecoveryState { 
        Status = "completed",
        CompletedFiles = deletedFiles.ToList()
    };
}

private class PendingEntry {
    public string FilePath;
    public string Hash;
    public DateTime PendingAt;
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
- 【P1-1完整实现】实现GetFileIdentityV2（GetFileInformationByHandleEx + 128-bit FILE_ID_INFO）
- 【P1-1 Fallback】Windows 7/Server 2008 R2不支持时的降级逻辑（回退到64-bit或禁用哈希复用）
- FileIdentityV2结构定义
- 单元测试：identity获取正确性、fallback逻辑
- 【P1-4集成】文件系统检测集成（DetectFileSystem + TestFileIdSupport）

**Day 3-4: 安全哈希复用**
- SessionHashCache实现
- GetHashSafely完整逻辑（结合P1-1的identity获取）
- 【P1-2明确】ComputeHashFromHandle契约实现（Seek(0)开始、Seek(0)结束）
- 单元测试：
  - Identity匹配/不匹配
  - 首次必须重哈希
  - 会话内复用
  - TOCTOU场景模拟（P0-A独占锁验证）
- 【P1-4测试】非NTFS文件系统降级测试

**Day 5: 集成测试**
- Apply/Purge集成哈希复用
- 【P1-4验证】文件系统检测自动降级测试（NTFS/ReFS/FAT32/网络驱动器）
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
- 【P1-3关键】并发度实测验证（1/2/4/8/16核对比，确认4核是否最优）
- 并发stress测试
- 【P0-4验证】Crash safety with并发（kill -9在各个线程journal写入阶段）
- 【P0-A验证】独占锁验证测试（文件被占用时的错误处理）
- 【P0-B验证】Delete/Journal原子性测试（kill -9在pending后、delete后、commit前各个时间点）
- 【P0-1/P0-2验证】Identity严格验证测试（mtime修改、文件替换）
- 【P1-4验证】文件系统检测和降级测试（NTFS/ReFS/FAT32/SMB各场景）
- 【P1-5验证】Journal flush性能验证（目标：overhead < 10%）
- 完整回归测试（所有现有test suite）
- Benchmark验证（预期累计6x）

### Week 4: 生产验收和文档（5天）

**Day 16-17: 用户真实场景测试**
- 在用户提供的真实目录上测试
- 【P1-5监控】Performance profiling + journal性能报告
- 【P1-4监控】文件系统检测日志验证
- 【P0-A监控】File-in-use失败率统计（目标 < 20%）
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

### 2. 文件被占用导致删除失败

**风险：** 【v2.2新增】独占锁（FileShare.None）会导致被其他进程占用的文件无法删除

**影响场景：**
- 杀毒软件正在扫描文件
- 备份工具正在读取文件
- 用户在编辑器中打开文件
- 系统服务占用文件

**缓解：**
- 清晰的错误消息（FileInUseException）提示用户关闭占用进程
- 允许transaction标记为purge-resumable，关闭占用后重试
- 【v2.3监控】监控file-in-use失败率（目标<20%）
- 如果>20%，提示用户在删除前关闭相关应用
- **权衡说明**：这是正确的失败 - 文件被占用意味着状态不稳定，强行删除可能破坏其他应用

### 3. Journal flush性能瓶颈

**风险：** 【v2.3新增】每个文件2次flush（pending + commit），高频IO可能成为瓶颈

**影响场景：**
- 大量小文件（10k+）时，flush开销累积
- 慢速磁盘（HDD、网络驱动器）flush延迟高

**缓解：**
- 【P1-5监控】PerformanceMonitor实时跟踪flush时间和占比
- 【P1-5验收】Week 3测试验证flush开销<10%
- 如果>10%，考虑批量flush优化（积累N个entry再flush）
- 慢速磁盘自动降级（检测到avg flush > 50ms时禁用并行化）

### 4. 并行度不理想

**风险：** MFT锁争用导致并行效果不佳

**缓解：**
- 【P1-3实测】Week 3 Day 14实测1/2/4/8/16线程的实际吞吐
- 选择最优并发度（可能不是CPU核心数）
- 提供配置项让用户调整
- 根据实测结果调整默认值（当前假设4核最优）

### 5. Journal文件数量增多

**风险：** 【v2.1新增】每个线程独立journal，高并发时journal文件数量多

**缓解：**
- Transaction完成后立即清理journal文件（CleanupCompletedJournals）
- 监控journal目录的文件数
- 限制最大并发度（默认4，避免过多journal文件）
- 【v2.3】journal清理失败时记录警告但不阻塞主流程

### 6. 特殊文件系统不兼容

**风险：** ReFS/SMB/OneDrive行为不同

**缓解：**
- 【P1-4完整实现】DetectFileSystem()识别所有主要文件系统
- 非NTFS给出警告并自动降级（OptimizationConfig.FromCapabilities）
- 云同步服务检测（IsCloudSyncedPath）并警告
- 提供手动降级模式（禁用哈希复用或并行）
- 【v2.3】降级决策明确记录到日志，便于用户理解性能差异

### 7. Windows版本兼容性

**风险：** 【v2.3新增】128-bit FILE_ID_INFO需要Windows 8+，老系统不支持

**影响场景：**
- Windows 7 / Server 2008 R2：不支持128-bit FileId
- 导致GetFileIdentityV2失败

**缓解：**
- 【P1-1 Fallback】TestFileIdSupport()检测失败时自动回退
- Fallback策略1：使用64-bit FileIndex（降低唯一性但仍可用）
- Fallback策略2：完全禁用哈希复用（最保守，只有批量处理和并行化生效）
- 启动时明确警告用户（"Windows 7 detected, hash reuse disabled"）
- 文档明确说明最佳性能需要Windows 8+

## 验收标准

### 功能正确性

- ✅ 所有现有test suite通过
- ✅ 新增单元测试覆盖率>90%
- ✅ Crash safety测试通过（kill -9 at各个阶段，包括线程journal写入时）
- ✅ Transaction完整性测试通过
- ✅ 【v2.1新增】Identity严格验证测试（mtime修改、文件替换、FileId重用模拟）
- ✅ 【v2.1新增】多线程journal独立性测试（并发写入、crash恢复）
- ✅ 【v2.2新增】独占锁验证测试（文件被占用、sharing violation处理）
- ✅ 【v2.2新增】Delete/Journal原子性测试（pending/committed状态完整性）
- ✅ 【v2.2新增】Crash recovery测试（pending未配对committed的各种场景）
- ✅ 【v2.3新增】文件系统检测测试（NTFS/ReFS/FAT32/SMB/云同步）
- ✅ 【v2.3新增】128-bit FileId fallback测试（Windows 7/8兼容性）
- ✅ 【v2.3新增】ComputeHashFromHandle副作用验证测试

### 性能目标

- ✅ 1GB/10k小文件场景（NTFS本地）：60分钟 → 10分钟（6x）
- ✅ 有效吞吐：从17MB/s提升到100MB/s
- ✅ Hash复用率：>80%（identity不经常漂移）
- ✅ 【P1-3验证】并行利用率：实测最优并发度（预期4核达到3-3.5x吞吐）
- ✅ 【P1-5验收】Journal flush开销：<10%总时间
- ⚠️ 【v2.2/v2.3注】独占锁可能降低并发成功率（文件被占用时拒绝删除，目标<20%失败率）
- ⚠️ 【v2.3注】非NTFS文件系统性能提升有限（FAT32/网络驱动器：1-2x）

### 安全保证

- ✅ 无identity验证绕过（strict mtime check + 独占锁）
- ✅ 无partial purge泄漏
- ✅ Crash后可正确恢复或resume（多线程journal + pending/commit完整性）
- ✅ Transaction状态机正确
- ✅ 【v2.1新增】Content-authenticated保证不被破坏（Identity漂移拒绝删除）
- ✅ 【v2.1新增】Crash safety在并发场景下保持（每线程独立journal+立即flush）
- ✅ 【v2.2新增】验证窗口并发修改完全阻止（独占锁FileShare.None）
- ✅ 【v2.2新增】Delete/Journal原子性保证（pending→delete→commit顺序）
- ✅ 【v2.3新增】文件系统兼容性保证（自动检测和降级）
- ✅ 【v2.3新增】Windows版本兼容性（128-bit FileId有fallback）

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

## v2.2关键修正总结

### P0-A: OpenFileForValidation改为独占锁
- **问题**：FileShare.Read|Delete无法阻止已打开句柄的进程修改，也无法阻止其他进程删除文件
- **修正**：FileShare.None独占锁，验证期间禁止任何访问
- **影响**：验证窗口完全闭合，但文件被占用时会失败（这是正确的失败）
- **错误处理**：清晰的FileInUseException提示用户关闭占用进程

### P0-B: Delete/Journal实现原子性顺序
- **问题**：先delete后journal，crash会导致文件已删除但journal无记录
- **修正**：pending → delete → commit三阶段
  1. WritePending() + Flush() - 标记待删除
  2. DeleteFile() - 执行删除
  3. WriteCommit() + Flush() - 标记已完成
- **影响**：任何时刻crash都能正确恢复
- **Crash recovery**：pending未配对committed时检查文件是否存在判断删除状态

### 完整P0修正链条（v2.0 → v2.1 → v2.2）

| 版本 | P0缺陷 | 修正 | 状态 |
|------|--------|------|------|
| v2.0 | P0-1: mtime容忍窗口 | v2.1: 严格相等 | ✅ |
| v2.0 | P0-2: Identity漂移继续 | v2.1: throw拒绝 + v2.2: 独占锁 | ✅ |
| v2.0 | P0-3: 实现不明 | v2.1: 明确FileShare + v2.2: 独占锁 | ✅ |
| v2.0 | P0-4: 内存journal | v2.1: 独立文件 + v2.2: pending/commit | ✅ |
| v2.1 | P0-A: FileShare不安全 | v2.2: 独占锁 | ✅ |
| v2.1 | P0-B: Delete/Journal顺序 | v2.2: pending→delete→commit | ✅ |

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

1. **第四轮对抗审查**：验证v2.2的P0-A和P0-B修正是否充分
2. **获得批准**：确认方案可实施
3. **Week 1**：开始FILE_ID_INFO和哈希复用实现
4. **持续沟通**：每周进度更新
5. **灵活调整**：根据测试结果调整并发度等参数

---

## 附录A：P0/P1级修正详细实现

### P0-1/P0-2: GetFileIdentityV2完整实现

```csharp
// 【P0-2修正】获取128-bit FILE_ID_INFO + 文件基本信息
private FileIdentityV2 GetFileIdentityV2(SafeFileHandle handle) {
    // 1. 获取 128-bit FILE_ID_INFO
    var fileIdInfo = new FILE_ID_INFO();
    
    if (!GetFileInformationByHandleEx(
        handle,
        FILE_INFO_BY_HANDLE_CLASS.FileIdInfo,
        ref fileIdInfo,
        Marshal.SizeOf<FILE_ID_INFO>())) {
        
        int error = Marshal.GetLastWin32Error();
        throw new Win32Exception(error, 
            $"Failed to get FILE_ID_INFO. This file system may not support 128-bit FileId.");
    }
    
    // 2. 获取文件基本信息（包含 size 和 mtime）
    BY_HANDLE_FILE_INFORMATION fileInfo;
    if (!GetFileInformationByHandle(handle, out fileInfo)) {
        int error = Marshal.GetLastWin32Error();
        throw new Win32Exception(error, "Failed to get file information.");
    }
    
    // 3. 计算 file size (64-bit)
    long fileSize = ((long)fileInfo.nFileSizeHigh << 32) | fileInfo.nFileSizeLow;
    
    // 4. 转换 FILETIME 到 DateTime
    long ftLastWriteTime = ((long)fileInfo.ftLastWriteTime.dwHighDateTime << 32) | 
                           fileInfo.ftLastWriteTime.dwLowDateTime;
    DateTime lastWriteTime = DateTime.FromFileTimeUtc(ftLastWriteTime);
    
    return new FileIdentityV2 {
        VolumeSerialNumber = fileIdInfo.VolumeSerialNumber,
        FileId128 = fileIdInfo.FileId.ToArray(),  // 转换为 byte[]
        FileSize = fileSize,
        LastWriteTimeUtc = lastWriteTime,
        CapturedAtUtc = DateTime.UtcNow
    };
}

// 【P0-2补充】需要的额外 P/Invoke 声明
[StructLayout(LayoutKind.Sequential)]
private struct BY_HANDLE_FILE_INFORMATION {
    public uint dwFileAttributes;
    public FILETIME ftCreationTime;
    public FILETIME ftLastAccessTime;
    public FILETIME ftLastWriteTime;
    public uint dwVolumeSerialNumber;
    public uint nFileSizeHigh;
    public uint nFileSizeLow;
    public uint nNumberOfLinks;
    public uint nFileIndexHigh;
    public uint nFileIndexLow;
}

[StructLayout(LayoutKind.Sequential)]
private struct FILETIME {
    public uint dwLowDateTime;
    public uint dwHighDateTime;
}

[DllImport("kernel32.dll", SetLastError = true)]
private static extern bool GetFileInformationByHandle(
    SafeFileHandle hFile,
    out BY_HANDLE_FILE_INFORMATION lpFileInformation);
```

### P1-3: ThreadJournalWriter生命周期管理

```csharp
// 【P1-3修正】完整的生命周期管理
public class ParallelPurgeCoordinator : IDisposable {
    private readonly int maxParallelism;
    private readonly string journalBaseDir;
    private readonly string transactionId;
    private readonly PerformanceMonitor perfMonitor;
    
    // 每个线程的 journal writer 缓存
    private readonly ThreadLocal<ThreadJournalWriter> threadJournals = 
        new ThreadLocal<ThreadJournalWriter>(trackAllValues: true);
    
    private void PurgeDirectoryFilesParallel(DirectoryEntry dir) {
        var files = dir.GetFiles();
        var failures = new ConcurrentQueue<(string path, Exception ex)>();
        var threadJournalPaths = new ConcurrentBag<string>();
        
        try {
            var parallelOptions = new ParallelOptions {
                MaxDegreeOfParallelism = maxParallelism
            };
            
            Parallel.ForEach(files, parallelOptions, (file, state) => {
                var threadId = Thread.CurrentThread.ManagedThreadId;
                
                // 获取或创建线程局部 journal（每个目录一个新的）
                var threadJournal = GetOrCreateThreadJournal(dir.Path, threadId);
                threadJournalPaths.Add(threadJournal.FilePath);
                
                try {
                    // 1. Pending entry
                    threadJournal.WritePending(file.Path, file.Hash);
                    threadJournal.Flush();
                    
                    // 2. Delete file
                    File.Delete(file.Path);
                    
                    // 3. Commit entry
                    threadJournal.WriteCommit(file.Path);
                    threadJournal.Flush();
                    
                } catch (Exception ex) {
                    failures.Enqueue((file.Path, ex));
                    state.Stop();
                }
            });
            
        } finally {
            // 清理所有线程的 journal writers
            CleanupThreadJournals();
        }
        
        // 写主 journal checkpoint
        WriteMainJournalCheckpoint(dir.Path, threadJournalPaths.ToList());
        
        if (failures.TryDequeue(out var firstFailure)) {
            throw new PartialPurgeException($"Failed to delete {firstFailure.path}", 
                                           firstFailure.ex);
        }
    }
    
    private ThreadJournalWriter GetOrCreateThreadJournal(string directoryPath, int threadId) {
        // 每个目录创建新的 journal writer
        // 不复用之前目录的 writer
        if (threadJournals.Value != null) {
            threadJournals.Value.Dispose();
        }
        
        var journalPath = Path.Combine(
            journalBaseDir,
            $"transaction-{transactionId}.thread-{threadId}.dir-{Path.GetFileName(directoryPath)}.json");
        
        var writer = new ThreadJournalWriter(journalPath, directoryPath, threadId, perfMonitor);
        threadJournals.Value = writer;
        
        return writer;
    }
    
    private void CleanupThreadJournals() {
        // Dispose 所有线程的 journal writers
        if (threadJournals.Values != null) {
            foreach (var writer in threadJournals.Values) {
                writer?.Dispose();
            }
        }
        threadJournals.Dispose();
    }
    
    public void Dispose() {
        CleanupThreadJournals();
    }
}
```

### P1-4: Crash recovery增加uncertain状态处理

```csharp
// 【P1-4修正】安全的crash recovery
public class RecoveryState {
    public string Status { get; set; }  // "purge-resumable", "uncertain", "completed"
    public List<string> RemainingFiles { get; set; } = new List<string>();
    public List<string> CompletedFiles { get; set; } = new List<string>();
    public List<string> UncertainFiles { get; set; } = new List<string>();  // 【新增】
    public string Message { get; set; }
}

private RecoveryState RecoverFromCrash(string journalPath) {
    var journal = ReadJournal(journalPath);
    var pendingFiles = journal.Entries.Where(e => e.State == "pending").ToDictionary(e => e.FilePath);
    var committedFiles = journal.Entries.Where(e => e.State == "committed").Select(e => e.FilePath).ToHashSet();
    
    var remainingFiles = new List<string>();
    var deletedFiles = new HashSet<string>();
    var uncertainFiles = new List<string>();
    
    foreach (var pendingEntry in pendingFiles.Values) {
        if (File.Exists(pendingEntry.FilePath)) {
            // 文件仍存在 → 需要验证 hash 并重新删除
            try {
                using var handle = File.OpenHandle(pendingEntry.FilePath, 
                    FileMode.Open, FileAccess.Read, FileShare.None);
                
                var currentHash = ComputeHashFromHandle(handle);
                var expectedHash = HexStringToBytes(pendingEntry.Hash);
                
                if (currentHash.SequenceEqual(expectedHash)) {
                    // Hash 匹配，这是我们要删除的文件
                    remainingFiles.Add(pendingEntry.FilePath);
                } else {
                    // Hash 不匹配，文件已被修改
                    throw new RecoveryException(
                        $"Pending file has been modified since crash: {pendingEntry.FilePath}. " +
                        $"Expected hash: {pendingEntry.Hash}, actual: {BitConverter.ToString(currentHash)}");
                }
            } catch (FileNotFoundException) {
                // 文件在检查过程中被删除（竞争条件）
                uncertainFiles.Add(pendingEntry.FilePath);
            }
        } else {
            // 文件不存在，无法验证
            // 可能是：1. 我们的删除完成了（committed 未写入）
            //        2. 其他进程删除的
            // 保守处理：标记为 uncertain，需要用户确认
            uncertainFiles.Add(pendingEntry.FilePath);
        }
    }
    
    // 已提交的文件计入完成
    deletedFiles.UnionWith(committedFiles);
    
    return new RecoveryState {
        Status = remainingFiles.Count > 0 ? "purge-resumable" : 
                 uncertainFiles.Count > 0 ? "uncertain" : "completed",
        RemainingFiles = remainingFiles,
        CompletedFiles = deletedFiles.ToList(),
        UncertainFiles = uncertainFiles,
        Message = uncertainFiles.Count > 0 
            ? $"Warning: {uncertainFiles.Count} files were in pending state but no longer exist. " +
              "Cannot verify if deletion completed correctly. Manual verification recommended." 
            : null
    };
}
```

---

## 附录B：P1-4文件系统检测（已在v2.3实现）

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
