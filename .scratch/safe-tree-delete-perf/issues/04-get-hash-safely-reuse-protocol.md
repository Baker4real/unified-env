# 04 — GetHashSafely 安全哈希复用协议

**What to build:** Apply/Purge 可安全复用哈希，TOCTOU 防御保持。GetHashSafely 函数接受文件路径和预期 identity，打开独占文件句柄，验证当前 identity 匹配预期值，然后查缓存或重新计算哈希。如果 identity 不匹配则抛出异常。整个过程保持独占锁，防止 TOCTOU 攻击。

**Blocked by:** #03 — SessionHashCache 和 ComputeHashFromHandle（需要缓存和哈希计算）

**Status:** ready-for-agent

- [ ] GetHashSafely 函数签名（接受 filePath, expectedIdentity, sessionCache）
- [ ] 使用 FileShare.None 打开独占文件句柄
- [ ] 使用 GetFileIdentityV2 获取当前 identity
- [ ] 验证当前 identity == expectedIdentity，不匹配时抛出 IdentityMismatchException
- [ ] 调用 sessionCache.TryGet(currentIdentity)
- [ ] 缓存命中时返回缓存的哈希
- [ ] 缓存未命中时调用 ComputeHashFromHandle 并更新缓存
- [ ] 单元测试验证：identity 匹配且缓存命中时返回缓存哈希
- [ ] 单元测试验证：identity 匹配但缓存未命中时重新计算并缓存
- [ ] 单元测试验证：identity 不匹配时抛出 IdentityMismatchException
- [ ] 单元测试验证：文件在打开期间被独占锁定（其他进程无法写入）
- [ ] 单元测试验证：同一文件第二次调用 GetHashSafely 命中缓存
