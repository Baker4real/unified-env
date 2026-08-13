# 01 — FILE_ID_INFO P/Invoke 基础设施

**What to build:** FILE_ID_INFO 互操作代码可编译并通过单元测试，能正确获取 128-bit FileId。从 PowerShell 调用 GetFileIdentityV2 函数，可以返回包含 VolumeSerialNumber、FileId128（16字节数组）、FileSize 和 LastWriteTimeUtc 的完整文件身份信息。

**Blocked by:** None — 可立即开始

**Status:** ready-for-agent

- [ ] FILE_ID_128 结构体定义（16个独立 byte 字段 B0-B15，不是托管数组）
- [ ] GetFileInformationByHandleEx P/Invoke 声明（FILE_INFO_BY_HANDLE_CLASS.FileIdInfo = 18）
- [ ] GetFileInformationByHandle P/Invoke 声明和 BY_HANDLE_FILE_INFORMATION 结构体
- [ ] FILETIME 转换逻辑（转换为 DateTime.FromFileTimeUtc）
- [ ] GetFileIdentityV2 函数实现（返回 FileIdentityV2 对象）
- [ ] 单元测试验证：在 NTFS 驱动器上打开文件句柄，获取 identity，验证所有字段非空且合理
- [ ] 单元测试验证：同一文件多次获取 identity，FileId128 保持一致
- [ ] 代码可在 Windows 8+ 上编译和运行
