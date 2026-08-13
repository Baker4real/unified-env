# 17 — 文档和用户指南更新

**What to build:** 用户可查阅文档了解优化特性和故障排查。更新用户指南，说明新的 128-bit file identity 系统、性能优化特性（哈希复用、批量处理、并行化）、不同文件系统的预期性能表现、以及故障排查建议。添加迁移指南，说明旧 Plan evidence 需要重新生成。更新 API 文档，记录新函数的契约和使用方式。

**Blocked by:** #16 — Phase 3 集成测试和生产验证（所有实现完成）

**Status:** ready-for-agent

- [ ] 用户指南：添加"性能优化"章节，说明三个优化阶段
- [ ] 用户指南：说明 FILE_ID_INFO 升级和 128-bit identity
- [ ] 用户指南：说明哈希复用协议和会话缓存
- [ ] 用户指南：说明并行化特性和文件系统自动检测
- [ ] 用户指南：添加性能预期表格（不同文件系统和场景的提升倍数）
- [ ] 故障排查指南：网络驱动器性能问题（自动降级到串行）
- [ ] 故障排查指南：非 NTFS 文件系统不支持 FILE_ID_INFO
- [ ] 故障排查指南：journal flush 慢的诊断和处理（检查磁盘性能、降低并行度）
- [ ] 故障排查指南：crash recovery uncertain 状态的处理建议
- [ ] 迁移指南：说明旧 Plan evidence（schema v4）需要重新生成
- [ ] 迁移指南：向后兼容性策略（检测旧 schema 并提示重新 Plan）
- [ ] API 文档：GetFileIdentityV2 函数文档（参数、返回值、异常）
- [ ] API 文档：GetHashSafely 函数文档（哈希复用协议、TOCTOU 防御）
- [ ] API 文档：ComputeHashFromHandle 契约文档（stream position 保证）
- [ ] API 文档：FileSystemCapabilities 字段含义
- [ ] 发布说明：总结性能提升、新特性、破坏性变更（需要重新 Plan）
