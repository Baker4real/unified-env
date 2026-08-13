# 09 — 文件系统检测和能力探测

**What to build:** 系统自动检测文件系统类型并推荐优化级别。运行删除操作时，系统使用 DriveInfo 检测目标路径的文件系统（NTFS/ReFS/FAT32/Network），测试 FILE_ID_INFO 支持，并返回 FileSystemCapabilities 对象。对于本地 NTFS，推荐启用哈希复用和并行化；对于网络驱动器或 FAT32，推荐保守策略（禁用并行化）。

**Blocked by:** #01 — FILE_ID_INFO P/Invoke 基础设施（需要测试 FILE_ID_INFO 支持）

**Status:** ready-for-agent

- [ ] FileSystemCapabilities 类定义（FileSystemType, IsRemote, SupportsFileId128, RecommendHashReuse, RecommendParallel, RecommendedMaxParallelism）
- [ ] DetectFileSystem 函数实现（接受 targetPath）
- [ ] 使用 DriveInfo.DriveFormat 获取文件系统类型（NTFS/ReFS/FAT32/exFAT）
- [ ] 使用 DriveInfo.DriveType 判断是否为网络驱动器
- [ ] TestFileIdSupport 函数实现（尝试调用 GetFileInformationByHandleEx，捕获异常判断支持）
- [ ] NTFS 本地驱动器推荐策略：RecommendHashReuse=true, RecommendParallel=true, MaxParallelism=4
- [ ] 网络驱动器推荐策略：RecommendHashReuse=false, RecommendParallel=false, MaxParallelism=1
- [ ] FAT32/exFAT 推荐策略：RecommendHashReuse=false（不支持 FILE_ID_INFO）, RecommendParallel=true
- [ ] 单元测试验证：在 NTFS 驱动器上检测返回正确的 capabilities
- [ ] 单元测试验证：TestFileIdSupport 在支持的文件系统返回 true
- [ ] 集成测试：在不同文件系统上运行检测，验证推荐策略正确
