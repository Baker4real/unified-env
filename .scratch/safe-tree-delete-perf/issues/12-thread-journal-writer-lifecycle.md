# 12 — ThreadJournalWriter 和生命周期管理

**What to build:** 每线程独立 journal writer，异常安全的资源清理。创建 ThreadJournalWriter 类，每个并行工作线程拥有独立的 journal 文件句柄和 StreamWriter。使用 ThreadLocal<ThreadJournalWriter> 管理线程本地实例，trackAllValues=true 确保可以枚举所有线程的 writer。在 finally 块中清理所有线程的 journal，即使发生异常也保证资源释放。

**Blocked by:** #11 — Purge 批量处理优化（批量处理为并行化铺路）

**Status:** ready-for-agent

- [ ] ThreadJournalWriter 类定义（封装 StreamWriter 和 FileStream）
- [ ] ThreadJournalWriter 构造函数（接受 journalFilePath, threadId）
- [ ] ThreadJournalWriter.WriteEntry 方法（写入 journal 条目）
- [ ] ThreadJournalWriter.Flush 方法（flush 到磁盘）
- [ ] ThreadJournalWriter 实现 IDisposable 接口
- [ ] 使用 ThreadLocal<ThreadJournalWriter>(trackAllValues: true) 管理线程本地实例
- [ ] 工厂方法 GetOrCreateThreadJournal 获取当前线程的 writer
- [ ] finally 块枚举 ThreadLocal.Values，调用每个 writer 的 Dispose
- [ ] 单元测试验证：创建多个线程，每个线程获取独立的 writer
- [ ] 单元测试验证：ThreadLocal.Values 包含所有线程的 writer
- [ ] 单元测试验证：finally 块中 Dispose 被调用，即使发生异常
- [ ] 单元测试验证：Dispose 后文件句柄正确关闭
