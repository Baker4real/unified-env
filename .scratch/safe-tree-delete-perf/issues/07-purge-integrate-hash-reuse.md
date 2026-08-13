# 07 — Purge 阶段集成哈希复用

**What to build:** Purge 使用 GetHashSafely，完整的哈希复用路径端到端工作。运行 Invoke-CodexSafeTreeDeletePurge 时，从 Plan evidence 读取 FileIdentityV2，使用 GetHashSafely 进行三次验证。由于 Apply 阶段已经验证过文件并将哈希写入缓存，Purge 的三次验证全部命中缓存。在 10k+ 文件场景下，完整的 Plan → Apply → Purge 流程相比 baseline 有约 3x 性能提升。

**Blocked by:** #04 — GetHashSafely 安全哈希复用协议, #05 — Plan 阶段升级到 FileIdentityV2

**Status:** ready-for-agent

- [ ] Invoke-CodexSafeTreeDeletePurge 读取 Plan evidence 的 FileIdentityV2
- [ ] Purge 创建 SessionHashCache 实例（会话生命周期）
- [ ] Purge 三次验证时都调用 GetHashSafely(filePath, expectedIdentity, sessionCache)
- [ ] Purge 处理 IdentityMismatchException（记录错误并拒绝删除）
- [ ] Purge 正常完成时清理 SessionHashCache
- [ ] 单元测试验证：Purge 三次验证都调用 GetHashSafely
- [ ] 单元测试验证：如果缓存中已有哈希，三次验证都命中缓存
- [ ] 集成测试：在 1000 个文件上运行 Plan → Apply → Purge，验证 Purge 成功完成删除
- [ ] 性能基准测试：10k+ 文件场景，完整流程相比 baseline 有 2.5-3x 提升
- [ ] 端到端测试：验证所有安全属性保持（content-authenticated, crash safety, TOCTOU 防御）
- [ ] 安全测试：在 Purge 过程中修改文件，验证 IdentityMismatchException 被正确抛出并阻止删除
