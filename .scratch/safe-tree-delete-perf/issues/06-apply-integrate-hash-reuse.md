# 06 — Apply 阶段集成哈希复用

**What to build:** Apply 使用 GetHashSafely，在真实场景下验证性能提升。运行 Invoke-CodexSafeTreeDeleteApply 时，从 Plan evidence 读取 FileIdentityV2，使用 GetHashSafely 验证文件哈希。第一次验证时重新计算哈希，后续同一文件的验证（如果存在）从缓存读取。在 10k+ 文件场景下，Apply 阶段相比 baseline 有约 2x 性能提升。

**Blocked by:** #04 — GetHashSafely 安全哈希复用协议, #05 — Plan 阶段升级到 FileIdentityV2

**Status:** ready-for-agent

- [ ] Invoke-CodexSafeTreeDeleteApply 读取 Plan evidence 的 FileIdentityV2
- [ ] Apply 创建 SessionHashCache 实例（会话生命周期）
- [ ] Apply 验证每个文件时调用 GetHashSafely(filePath, expectedIdentity, sessionCache)
- [ ] Apply 处理 IdentityMismatchException（记录错误并拒绝操作）
- [ ] Apply 正常完成时清理 SessionHashCache
- [ ] 单元测试验证：Apply 第一次验证文件时缓存未命中
- [ ] 单元测试验证：Apply 第二次验证同一文件时缓存命中（如果有重复验证场景）
- [ ] 集成测试：在 1000 个文件上运行 Plan → Apply，验证 Apply 成功完成
- [ ] 性能基准测试：10k+ 文件场景，Apply 阶段相比 baseline（无哈希复用）有 1.5-2x 提升
- [ ] 安全测试：在 Apply 过程中修改文件，验证 IdentityMismatchException 被正确抛出
