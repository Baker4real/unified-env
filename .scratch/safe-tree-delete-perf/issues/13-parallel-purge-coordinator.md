# 13 — ParallelPurgeCoordinator 目录级并行

**What to build:** 目录级并行删除可工作，journal 保持完整性。ParallelPurgeCoordinator 使用 Parallel.ForEach 在目录级别并行处理删除操作。每个工作线程处理一个目录树，使用独立的 ThreadJournalWriter 写入线程本地 journal 文件。删除操作严格遵循 pending → delete → commit 原子序列，journal 立即 flush 到磁盘。异常处理确保部分失败可以恢复。

**Blocked by:** #12 — ThreadJournalWriter 和生命周期管理（需要 ThreadJournalWriter）

**Status:** ready-for-agent

- [ ] ParallelPurgeCoordinator 类定义
- [ ] 将待删除目录树分组（按顶级子目录）
- [ ] 使用 Parallel.ForEach 并行处理每个目录组
- [ ] ParallelOptions.MaxDegreeOfParallelism 配置（从 FileSystemCapabilities 读取）
- [ ] 每个线程使用 GetOrCreateThreadJournal 获取独立 writer
- [ ] 对目录中每个文件执行：WriteEntry(pending) → Flush → File.Delete → WriteEntry(commit) → Flush
- [ ] 异常处理：捕获单个文件失败，继续处理其他文件，最后汇总错误
- [ ] finally 块：清理所有 ThreadJournalWriter
- [ ] 单元测试验证：并行删除多个目录，所有文件正确删除
- [ ] 单元测试验证：每个线程写入独立 journal 文件
- [ ] 单元测试验证：pending → delete → commit 序列正确
- [ ] 单元测试验证：单个文件失败不影响其他文件删除
- [ ] 集成测试：10k+ 文件场景，验证并行删除正确性和 journal 完整性
