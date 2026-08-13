# 02 — FileIdentityV2 相等性和缓存基础

**What to build:** FileIdentityV2 实现完整的值相等性语义，可作为哈希表键使用。两个 FileIdentityV2 对象如果 VolumeSerialNumber、FileSize、LastWriteTimeUtc 和 FileId128 内容相同，则相等。可以将 FileIdentityV2 作为 Dictionary 的键进行查找。

**Blocked by:** #01 — FILE_ID_INFO P/Invoke 基础设施（需要 FileIdentityV2 结构体定义）

**Status:** ready-for-agent

- [ ] IEquatable<FileIdentityV2> 接口实现
- [ ] Equals(FileIdentityV2 other) 方法（使用 SequenceEqual 比较 FileId128 字节数组）
- [ ] Equals(object obj) 重写
- [ ] GetHashCode() 重写（组合 VolumeSerialNumber、FileSize、LastWriteTimeUtc 和 FileId128 前8字节）
- [ ] == 和 != 运算符重载
- [ ] 单元测试验证：相同内容的两个 identity 对象 Equals 返回 true
- [ ] 单元测试验证：不同 FileId128 的 identity 对象 Equals 返回 false
- [ ] 单元测试验证：作为 Dictionary 键时，相同 identity 可以查找到值
- [ ] 单元测试验证：GetHashCode 对相等对象返回相同值
