# 对抗性审查报告 Round 5：v2.3 方案

**审查日期：** 2026-08-13  
**审查目标：** 验证 v2.3 是否修复了所有 P1 级问题，是否具备生产就绪能力  
**审查结论：** ❌ **未通过 - 发现 2 个 P0 缺陷和 4 个 P1 缺陷**

---

## 执行摘要

v2.3 方案在修复第四轮审查发现的 P1 问题时引入了新的 **P0 级编译错误**和逻辑缺陷。核心功能 GetFileIdentityV2 和 FILE_ID_INFO 互操作代码**无法编译或运行**，必须修复后才能继续。

**关键发现：**
- 2 个 P0 级缺陷（数据安全/编译错误）
- 4 个 P1 级缺陷（生产阻塞问题）
- 5 个 P2 级次要问题

---

## P0 级缺陷（阻塞性问题）

### P0-1: FILE_ID_INFO 结构体互操作定义错误

**位置：** 第 1474-1479 行

**问题代码：**
```csharp
[StructLayout(LayoutKind.Sequential)]
private struct FILE_ID_INFO {
    public ulong VolumeSerialNumber;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
    public byte[] FileId;  // 托管数组 - 错误！
}
```

**缺陷描述：**
`byte[]` 是托管数组（引用类型），不能直接用于 P/Invoke 结构体：
- 托管数组在结构体中只是一个引用（指针），不是实际的 16 字节数据
- `MarshalAs` 属性对嵌入式数组的支持有限，不保证正确的内存布局
- GetFileInformationByHandleEx 会写入错误的内存位置
- 导致 FileId 字段为 null 或包含垃圾数据

**失败场景：**
1. GetFileInformationByHandleEx 返回 true，但 FileId 为 null
2. 所有 FileIdentityV2.Equals() 比较失败（NullReferenceException 或始终不相等）
3. 哈希复用完全失效，性能目标无法达成
4. 可能读取错误的 identity 导致删除错误的文件

**严重性：** P0 - 核心功能完全失效且可能导致数据安全问题

**修复方案：**
```csharp
[StructLayout(LayoutKind.Sequential)]
private struct FILE_ID_INFO {
    public ulong VolumeSerialNumber;
    public FILE_ID_128 FileId;  // 嵌入式结构体
}

[StructLayout(LayoutKind.Sequential)]
private struct FILE_ID_128 {
    public byte B0, B1, B2, B3, B4, B5, B6, B7;
    public byte B8, B9, B10, B11, B12, B13, B14, B15;
    
    public byte[] ToArray() => new[] { 
        B0, B1, B2, B3, B4, B5, B6, B7,
        B8, B9, B10, B11, B12, B13, B14, B15 
    };
}
```

---

### P0-2: GetFileIdentityV2 使用不存在的 API

**位置：** 第 1462-1463 行

**问题代码：**
```csharp
var fileSize = new FileInfo(handle).Length;
var lastWriteTime = File.GetLastWriteTimeUtc(handle);
```

**缺陷描述：**
这两行代码**无法编译**：
1. `FileInfo` 构造函数不接受 `SafeFileHandle` 参数
2. `File.GetLastWriteTimeUtc()` 不接受 `SafeFileHandle` 参数

**失败场景：**
编译错误，代码无法运行。

**严重性：** P0 - 编译错误，核心功能无法使用

**修复方案：**
```csharp
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
            "Failed to get FILE_ID_INFO.");
    }
    
    // 2. 获取文件基本信息（size + mtime）
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
        FileId128 = fileIdInfo.FileId.ToArray(),
        FileSize = fileSize,
        LastWriteTimeUtc = lastWriteTime,
        CapturedAtUtc = DateTime.UtcNow
    };
}

// 需要的额外 P/Invoke 声明
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

---

## P1 级缺陷（生产阻塞）

### P1-1: ComputeHashFromHandle 契约缺少实际实现

**位置：** 方案中多次提到（第 27 行、第 1074 行、第 1253 行），但从未展示实现

**缺陷描述：**
方案只提到"明确 ComputeHashFromHandle 契约"，但从未展示实际实现代码。关键问题未解决：
- 函数是否修改 handle 的 position？
- 调用前是否需要 Seek(0)？
- 调用后 position 在哪里？
- 谁负责重置 position？

**失败场景：**
如果实现不当，在同一个 handle 上多次调用会导致：
- 第二次从错误的 position 开始，计算错误的 hash
- Identity 验证通过但 hash 验证失败
- 文件被错误地拒绝删除

**严重性：** P1 - 核心安全功能可能失效

**修复方案：**
```csharp
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
```

---

### P1-2: FileIdentityV2 缺少 Equals 实现

**位置：** 第 242-250 行

**缺陷描述：**
FileIdentityV2 是 struct，但没有重写 Equals() 和 GetHashCode()。第 299 行调用：
```csharp
if (cached.RevalidatedInSession && cached.Identity.Equals(currentIdentity))
```

默认的 struct Equals 实现：
1. 使用反射逐字段比较（性能极差）
2. 对 `byte[] FileId128` 进行引用比较，不是内容比较（逻辑错误）

**失败场景：**
即使两个 FileIdentityV2 的所有字段值相同，Equals 也会返回 false：
- 会话内缓存完全失效
- 每次都重新哈希，性能优化目标无法达成

**严重性：** P1 - 性能优化核心功能失效

**修复方案：**
```csharp
public struct FileIdentityV2 : IEquatable<FileIdentityV2> {
    public ulong VolumeSerialNumber;
    public byte[] FileId128;
    public long FileSize;
    public DateTime LastWriteTimeUtc;
    public DateTime CapturedAtUtc;
    
    public bool Equals(FileIdentityV2 other) {
        return VolumeSerialNumber == other.VolumeSerialNumber &&
               FileId128.SequenceEqual(other.FileId128) &&
               FileSize == other.FileSize &&
               LastWriteTimeUtc == other.LastWriteTimeUtc;
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
```

---

### P1-3: ThreadJournalWriter 生命周期管理不明确

**位置：** 第 594-601 行

**缺陷描述：**
代码展示了 GetOrCreateThreadJournal 的调用（第 555 行），但没有展示：
1. 是否有缓存？存储在哪里？
2. 何时 Dispose？
3. 同一线程处理多个目录时，是复用还是创建新的？
4. Parallel.ForEach 结束后如何清理所有线程的 journal？

**失败场景：**
- 如果每次调用都创建新的，会产生资源泄漏（未关闭的 StreamWriter）
- 如果跨目录复用，不同目录的 journal 会混在一起（数据混乱）
- 如果 Dispose 不当，journal 文件可能未完整写入（crash safety 失效）

**严重性：** P1 - 资源泄漏和 crash safety 问题

**修复方案：** 见完整代码实现（使用 ThreadLocal<> + finally cleanup）

---

### P1-4: Crash recovery 对 pending 文件的处理不安全

**位置：** 第 956-965 行

**问题代码：**
```csharp
foreach (var pendingEntry in pendingFiles.Values) {
    if (File.Exists(pendingEntry.FilePath)) {
        // 文件仍存在 → 删除未完成
    } else {
        // 文件不存在 → 删除已完成
        deletedFiles.Add(pendingEntry.FilePath);
    }
}
```

**缺陷描述：**
逻辑假设"文件不存在 = 我们成功删除了"，但这不安全：
1. 文件可能被其他进程删除
2. 文件可能被移动或重命名
3. 无法验证删除的是正确的文件

**失败场景：**
1. Crash 前文件 A 处于 pending 状态
2. Crash 后、Recovery 前，其他进程删除了文件 A
3. Recovery 错误地认为"我们成功删除了 A"
4. 但实际上我们的删除操作从未完成，journal 不完整

**严重性：** P1 - Crash safety 保证被破坏

**修复方案：** 见完整代码实现（加入 uncertain 状态，需要 hash 验证）

---

## P2 级问题（次要问题，不阻塞生产）

### P2-1: 并行度验证测试缺少具体实现
只有测试计划，没有可执行代码。建议补充完整的基准测试代码。

### P2-2: 云同步检测不可靠
路径字符串检测太简单。建议增加 OneDrive 占位符检测。

### P2-3: PerformanceMonitor 可能为 null
构造函数接受 monitor 但不检查 null。

### P2-4: BatchPurgeResult 字段语义混乱
ProcessedCount 语义不清晰。

### P2-5: TestFileIdSupport 测试文件管理不够健壮
临时文件可能被占用。

---

## 第四轮 P1 问题修复情况

| 问题 | 状态 | 评估 |
|------|------|------|
| P1-1: GetFileIdentityV2 实现 | ❌ | P/Invoke 声明错误，API 使用错误 |
| P1-2: ComputeHashFromHandle 契约 | ❌ | 只提到要明确，但未展示实现 |
| P1-3: 并行度验证测试 | ⚠️ | 有计划但缺少可执行代码 |
| P1-4: 文件系统检测 | ✅ | 覆盖主要场景，有降级机制 |
| P1-5: Journal 性能监控 | ✅ | 有完整实现和验收标准 |

---

## 最终评估

### 生产就绪能力：❌ **不具备**

**阻塞问题：**
- 2 个 P0 级缺陷：核心代码无法编译或运行
- 4 个 P1 级缺陷：关键功能逻辑错误或不完整

**必须修复优先级：**
1. **P0-1 和 P0-2**（立即）：GetFileIdentityV2 完整实现
2. **P1-1**（Day 1-2）：ComputeHashFromHandle 契约实现
3. **P1-2**（Day 1-2）：FileIdentityV2.Equals 实现
4. **P1-3**（Day 11-13）：ThreadJournalWriter 生命周期管理
5. **P1-4**（Day 13）：Crash recovery 安全性修复

**预估修复时间：** 3-5 天

**建议：** 修复所有 P0 和 P1 问题后进行第六轮审查。
