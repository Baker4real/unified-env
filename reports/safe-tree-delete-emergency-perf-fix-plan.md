---
type: plan
title: 受管删除紧急性能优化方案
tags: [host-safety, safe-delete, performance, critical]
priority: P0
created: 2026-08-13
---

# 受管删除紧急性能优化方案

## 问题严重性

**用户报告：删除GB级数据耗时1小时以上**

这与benchmark预期（1GB约0.7分钟）相差**85倍**，已严重影响可用性。

## 根因分析

### 实际瓶颈定位

通过代码审查和理论计算，确认瓶颈**不是**7x哈希读取本身，而是：

| 瓶颈类型 | 影响因子 | 估算影响 |
|---------|---------|---------|
| **文件数量** | 数万到数十万小文件（node_modules/worktrees） | 50-70x |
| **PowerShell循环** | 每文件~2-5ms对象创建/函数调用开销 | 3-5x |
| **串行处理** | 单线程逐文件，无并行 | 2-4x |
| **7x哈希** | 每文件读7遍（当前实现） | 2-3x |

**复合效应：50x × 3x × 2x × 2x = 600x理论最差情况**

用户遇到85x放缓，说明命中了**文件数量多 + PowerShell开销大**的组合。

### 证据链

1. **代码证据**：
   - `CodexSafeTreeDelete.ps1` 使用 `foreach` 循环逐文件处理
   - `CodexHostSafety.ps1:1126` 和 `:1135` 每文件计算2次SHA-256
   - 无并行化代码路径

2. **Benchmark证据**：
   - 32MB/4文件耗时1.9秒 → 约17MB/s有效吞吐
   - 对比SSD顺序读500MB/s，利用率仅**3.4%**
   - 小文件场景更差：4KB/4文件耗时2.2秒 → 约2KB/s

3. **用户场景推断**：
   - "以G为单位的数据" + "用了至少一个小时"
   - 假设2GB数据，1小时 = 3600秒 → 吞吐约0.57MB/s
   - 这意味着：**要么文件极多（数万+），要么有其他IO瓶颈**

## 三大核心优化方向

### 优化1：减少重复哈希（7x → 2-3x）⭐

**当前问题：**
- Plan阶段计算1次完整树hash
- Apply阶段重新计算3次
- Purge阶段再计算3次
- 总计7次完整读取

**优化方案：**
```csharp
// 在Apply/Purge阶段复用Plan的hash
public byte[] ValidateAndReusePlanHash(
    byte[] planHash, 
    string[] planIdentity) {
    
    // 1. 验证FILE_ID_INFO未变（128-bit FileId）
    string[] currentIdentity = GetFileIdentity(handle);
    if (!IdentityMatches(currentIdentity, planIdentity)) {
        return null;  // Identity漂移，必须重算
    }
    
    // 2. 句柄持续拒绝write sharing，保证内容未变
    // 3. 直接返回Plan的hash，跳过重新计算
    return planHash;
}
```

**安全边界：**
- FILE_ID_INFO验证确保是同一文件对象
- Write-excluding handle确保内容未被修改
- 任何identity漂移立即回退到完整重哈希

**预期收益：** 从7x降到2-3x，理论提升**55-70%**

### 优化2：批量处理减少PowerShell开销⭐⭐

**当前问题：**
- PowerShell逐文件调用C#
- 每文件创建PSObject、参数marshal、结果unmarshal
- 10k文件 × 2ms开销 = 20秒纯overhead

**优化方案：**
```csharp
public class BatchDeleteResult {
    public int ProcessedFiles;
    public int SuccessFiles;
    public Dictionary<string, string> Failures;  // path -> reason
    public long TotalBytesHashed;
    public long ElapsedMs;
}

public BatchDeleteResult PurgeFileBatch(
    FileManifest[] files,
    DirectoryGuard guard,
    Action<string, long> progressCallback) {
    
    var result = new BatchDeleteResult();
    // C#内部循环，避免PowerShell往返
    foreach (var file in files) {
        try {
            ProcessSingleFile(file, guard);
            result.SuccessFiles++;
            progressCallback?.Invoke(file.Path, file.Size);
        } catch (Exception ex) {
            result.Failures[file.Path] = ex.Message;
        }
    }
    return result;
}
```

**预期收益：** 减少70% PowerShell循环开销，额外提升**30-40%**

### 优化3：并行文件处理⭐⭐⭐

**当前问题：**
- 单线程串行处理
- CPU利用率低（大部分时间在等IO）
- 现代SSD支持高并发随机读

**优化方案：**
```csharp
public BatchDeleteResult PurgeFileBatchParallel(
    FileManifest[] files,
    DirectoryGuard guard,
    int maxParallelism = 4) {
    
    var options = new ParallelOptions {
        MaxDegreeOfParallelism = Math.Min(
            Environment.ProcessorCount, 
            maxParallelism)
    };
    
    var result = new ConcurrentBag<FileResult>();
    
    Parallel.ForEach(files, options, file => {
        try {
            ProcessSingleFile(file, guard);
            result.Add(new FileResult { Success = true, Path = file.Path });
        } catch (Exception ex) {
            result.Add(new FileResult { Success = false, Path = file.Path, Error = ex.Message });
        }
    });
    
    return AggregateResults(result);
}
```

**约束：**
- 只并行处理独立文件（同一目录下的文件可并行）
- 保持目录删除的顺序依赖
- 每个文件独立的句柄和验证
- Transaction journal按原子性要求串行写入

**预期收益：** 4核并行，理论再提升**3-4x**

## 综合收益预测

| 场景 | 当前耗时 | 优化1后 | +优化2后 | +优化3后 | 总提升 |
|------|---------|---------|----------|----------|--------|
| 1GB/1k文件 | 12分钟 | 5分钟 | 3.5分钟 | 1分钟 | **12x** |
| 1GB/10k文件 | 60分钟 | 26分钟 | 16分钟 | 5分钟 | **12x** |
| 5GB/50k文件 | 5小时 | 2.2小时 | 1.3小时 | 25分钟 | **12x** |

**用户场景（GB级1小时）预期降至5-8分钟**

## 实施路线图

### 阶段0：诊断（立即，1天）

**目标：确认用户真实场景**

```powershell
# 诊断脚本
function Get-SafeDeletePerformanceProfile {
    param([string]$TargetPath)
    
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $files = Get-ChildItem -LiteralPath $TargetPath -Recurse -File -Force
    $dirs = Get-ChildItem -LiteralPath $TargetPath -Recurse -Directory -Force
    $sw.Stop()
    
    $fileStats = $files | Measure-Object -Property Length -Sum
    
    [PSCustomObject]@{
        TargetPath = $TargetPath
        FileCount = $fileStats.Count
        DirectoryCount = $dirs.Count
        TotalSizeMB = [math]::Round($fileStats.Sum / 1MB, 2)
        AvgFileSizeKB = [math]::Round(($fileStats.Sum / $fileStats.Count) / 1KB, 2)
        EnumerationTimeMs = $sw.ElapsedMilliseconds
        
        # 性能预测
        EstimatedHashTimeMin_Current = [math]::Round(($fileStats.Sum * 7 / 1MB / 300) / 60, 1)
        EstimatedLoopTimeMin_Current = [math]::Round(($fileStats.Count * 2 / 1000) / 60, 1)
        EstimatedTotalMin_Current = $null  # 计算后填充
        
        EstimatedTotalMin_Optimized = $null  # 优化后预期
        ExpectedSpeedup = $null
    }
}
```

**决策点：**
- FileCount > 10k → 优先优化2（批量处理）
- AvgFileSizeKB < 10 → 优先优化3（并行）
- TotalSizeMB > 5000 → 优先优化1（哈希复用）

### 阶段1：快速胜利（P0，3-5天）

**实施优化1 + 优化2**

**Day 1-2：哈希复用**
- 实现FILE_ID_INFO验证
- 修改Apply/Purge复用Plan hash
- 单元测试：identity漂移检测
- Crash safety测试：中断后重哈希

**Day 3-4：批量处理**
- C#批量文件处理API
- PowerShell wrapper调用批量API
- 进度回调和错误处理

**Day 5：集成测试**
- 运行完整test suite
- Benchmark对比
- 用户场景smoke test

**验收标准：**
- 所有现有测试通过
- 1GB/10k文件从60分钟降到15-20分钟（3-4x提升）
- 无security/safety regression

### 阶段2：架构优化（P1，1-2周）

**实施优化3：并行化**

**Week 1：设计与实现**
- 并行处理设计文档
- 实现TPL Dataflow pipeline
- 保持transaction语义
- 错误隔离和聚合

**Week 2：测试与验证**
- 并发stress测试
- Crash safety with并发
- Production smoke test
- Benchmark全场景

**验收标准：**
- 1GB/10k文件从15分钟降到5-8分钟（cumulative 8-12x）
- 有效吞吐从6MB/s提升到30-50MB/s
- 所有safety保证不变

### 阶段3：可选优化（P2，按需）

**仅在阶段1+2仍不满足时考虑**

1. 流式哈希（内存映射文件）
2. 增量删除（超大目录分批）
3. 快速模式（降级安全，需显式授权）

## 技术实现细节

### 哈希复用的安全保证

```csharp
private struct FileIdentitySnapshot {
    public ulong VolumeSerial;
    public byte[] FileId;  // 128-bit
    public long FileSize;
    public DateTime LastWriteTime;
}

private bool ValidateIdentityForHashReuse(
    FileIdentitySnapshot planIdentity,
    SafeFileHandle handle) {
    
    // 1. 获取当前FILE_ID_INFO
    var currentId = GetFileIdInfo(handle);
    if (currentId.VolumeSerial != planIdentity.VolumeSerial ||
        !ByteArrayEquals(currentId.FileId, planIdentity.FileId)) {
        return false;  // 文件对象已变
    }
    
    // 2. 验证文件大小未变（快速检查）
    var currentSize = GetFileSize(handle);
    if (currentSize != planIdentity.FileSize) {
        return false;
    }
    
    // 3. Write-excluding handle已保证内容未被修改
    // （在获取句柄时已指定FILE_SHARE_READ | FILE_SHARE_DELETE）
    
    return true;
}
```

### 批量处理的事务语义

```csharp
public class BatchPurgeTransaction {
    private readonly List<string> committedFiles = new List<string>();
    private readonly JournalWriter journal;
    
    public void ProcessBatch(FileManifest[] files) {
        foreach (var file in files) {
            // 1. 验证和删除文件
            DeleteFileWithValidation(file);
            
            // 2. 立即记录到journal（保持crash safety）
            journal.WriteCommit(file.Path, file.Identity);
            committedFiles.Add(file.Path);
        }
        
        // 3. 批量刷新journal
        journal.Flush();
    }
    
    public void Rollback() {
        // 已commit的文件无法恢复（这是purge的语义）
        // 但journal完整记录了哪些已删除
    }
}
```

### 并行处理的边界

```csharp
// 正确：同一目录的独立文件可并行
var filesInSameDir = manifest.GetFilesInDirectory("D:\\target\\subdir");
Parallel.ForEach(filesInSameDir, file => DeleteFile(file));

// 错误：父子目录关系必须串行
// 先删子目录的文件，再删父目录的文件，最后删目录本身
foreach (var dir in manifest.GetDirectoriesBottomUp()) {
    Parallel.ForEach(dir.Files, file => DeleteFile(file));
    DeleteDirectory(dir);
}
```

## 不应做的事（明确禁止）

❌ **移除content-authenticated合同**：任何"只验证metadata"的轻量模式都不能成为默认  
❌ **跨卷copy+delete**：Windows不保证原子性，会破坏quarantine语义  
❌ **用rimraf/fs.rm替换**：失去所有安全保证  
❌ **禁用crash journal**：transaction完整性不能妥协  
❌ **假设FileId永不重用**：必须结合size/timestamp/handle验证  
❌ **无限并行度**：必须有合理上限（建议4-8）避免资源耗尽  

## 度量与验证

### 关键指标

```json
{
  "metrics": {
    "effectiveThroughputMBps": "实际数据处理速率",
    "hashReuseRate": "成功复用Plan hash的文件占比",
    "parallelismUtilization": "并行度实际利用率",
    "powerShellOverheadPercent": "PowerShell调用开销占比",
    
    "before": {
      "totalTimeMin": 60,
      "effectiveThroughputMBps": 0.57
    },
    "after": {
      "totalTimeMin": 5,
      "effectiveThroughputMBps": 6.8
    },
    "speedup": "12x"
  }
}
```

### Benchmark场景

| 场景ID | 描述 | 文件数 | 总大小 | 目标耗时 |
|--------|------|--------|--------|----------|
| B1 | 小文件密集 | 10k | 100MB | <2分钟 |
| B2 | 中等均衡 | 5k | 1GB | <3分钟 |
| B3 | 大文件主导 | 100 | 5GB | <5分钟 |
| B4 | 极度碎片 | 50k | 500MB | <8分钟 |
| B5 | 用户真实场景 | TBD | TBD | <10分钟 |

## 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 哈希复用引入安全漏洞 | 高 | FILE_ID_INFO强验证；任何不确定回退到完整重哈希 |
| 并行导致race condition | 中 | 独立文件无共享状态；目录操作仍串行 |
| 性能提升不达预期 | 中 | 阶段性验证；保留回退路径 |
| 破坏crash safety | 高 | 完整crash injection测试；journal语义不变 |

## 后续工作

- [ ] 用户提供真实场景profiling数据
- [ ] 阶段1实施（哈希复用 + 批量）
- [ ] Benchmark验证3-4x提升
- [ ] 决定是否进入阶段2（并行化）
- [ ] 生产验收和rollout

## 参考资料

- [优化调研报告](./safe-tree-delete-optimization-research-20260809.md)
- [Benchmark基线](./safe-tree-delete-benchmark-20260809.json)
- [GitHub Issue #1](https://github.com/Baker4real/unified-env/issues/1)
- rimraf Windows实现：有界重试机制
- restic prune：可续租锁和crash-safe设计
- Nix GC：liveness roots和删除前复验
