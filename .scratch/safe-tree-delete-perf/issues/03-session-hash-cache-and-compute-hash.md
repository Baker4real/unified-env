# 03 — SessionHashCache 和 ComputeHashFromHandle

**What to build:** 会话内哈希缓存可工作，ComputeHashFromHandle 有清晰的 stream position 契约文档。缓存可以存储和检索 FileIdentityV2 → SHA-256 哈希的映射。ComputeHashFromHandle 在计算哈希后将句柄 position 重置为 0，调用者无需担心 position 污染。

**Blocked by:** #02 — FileIdentityV2 相等性和缓存基础（需要 FileIdentityV2 作为缓存键）

**Status:** ready-for-agent

- [ ] SessionHashCache 类实现（内部使用 Dictionary<FileIdentityV2, byte[]>）
- [ ] SessionHashCache.TryGet(identity) 方法
- [ ] SessionHashCache.Set(identity, hash) 方法
- [ ] SessionHashCache.Clear() 方法（会话结束时清理）
- [ ] ComputeHashFromHandle 函数实现（接受 SafeFileHandle）
- [ ] ComputeHashFromHandle XML 文档注释说明契约：调用前 position 可以是任意值，调用后 position 重置为 0
- [ ] ComputeHashFromHandle 实现在计算前 Seek(0) 并在计算后 Seek(0)
- [ ] 单元测试验证：缓存命中时返回正确的哈希值
- [ ] 单元测试验证：缓存未命中时返回 null
- [ ] 单元测试验证：ComputeHashFromHandle 在 position=100 时调用，返回后 position=0
- [ ] 单元测试验证：同一文件多次 ComputeHashFromHandle 返回相同哈希
