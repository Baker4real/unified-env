# 05 — Plan 阶段升级到 FileIdentityV2

**What to build:** Plan 生成的 evidence 包含 128-bit identity，可被后续阶段读取。运行 Invoke-CodexSafeTreeDeletePlan 后，生成的 evidence.json 文件包含每个文件的 volumeSerialNumber、fileId128（16字节数组）、fileSize 和 lastWriteTimeUtc 字段。Apply 和 Purge 阶段可以读取这些字段并重建 FileIdentityV2 对象。

**Blocked by:** #01 — FILE_ID_INFO P/Invoke 基础设施（需要 GetFileIdentityV2）

**Status:** ready-for-agent

- [ ] Invoke-CodexSafeTreeDeletePlan 调用 GetFileIdentityV2 获取文件 identity
- [ ] Plan evidence schema 添加 volumeSerialNumber（uint64）字段
- [ ] Plan evidence schema 添加 fileId128（byte[] 长度16）字段
- [ ] Plan evidence schema 保留现有 fileSize 和 lastWriteTimeUtc 字段
- [ ] Plan evidence 序列化时将 FileIdentityV2 写入 JSON（fileId128 使用 Base64 编码）
- [ ] Plan evidence 反序列化时从 JSON 重建 FileIdentityV2 对象
- [ ] 单元测试验证：Plan 生成的 evidence 包含完整 FileIdentityV2 信息
- [ ] 单元测试验证：反序列化后的 FileIdentityV2 与原始对象相等
- [ ] 集成测试验证：在 NTFS 驱动器上 Plan 一个目录，evidence 包含所有文件的 128-bit identity
- [ ] 向后兼容性测试：旧版本 evidence（无 volumeSerialNumber/fileId128）可以降级处理或拒绝
