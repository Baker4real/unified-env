# 15 — Journal 性能监控和告警

**What to build:** Journal flush 开销被监控，超过10%时告警。ThreadJournalWriter 添加性能计数器，记录每次 flush 的耗时和次数。计算 journal flush 总耗时占整体删除时间的百分比。生成 JournalPerformanceReport，如果 overhead 超过 10% 则记录警告日志。验收标准是 journal overhead 在正常场景下 <10%。

**Blocked by:** #13 — ParallelPurgeCoordinator 目录级并行（需要 journal 写入路径）

**Status:** ready-for-agent

- [ ] ThreadJournalWriter 添加 TotalFlushTimeMs 属性（累积 flush 耗时）
- [ ] ThreadJournalWriter 添加 FlushCount 属性（flush 次数）
- [ ] ThreadJournalWriter.Flush 方法内测量每次 flush 耗时（使用 Stopwatch）
- [ ] 记录慢 flush 日志（单次 flush >100ms）
- [ ] ParallelPurgeCoordinator 汇总所有线程的 TotalFlushTimeMs
- [ ] 计算 journal overhead 百分比：TotalFlushTimeMs / TotalOperationTimeMs
- [ ] JournalPerformanceReport 类（包含 TotalFlushTimeMs, FlushCount, OverheadPercent, IsWithinTarget）
- [ ] 生成性能报告，IsWithinTarget = (OverheadPercent < 10%)
- [ ] 如果 overhead ≥10%，记录警告日志并建议降低并行度或检查磁盘性能
- [ ] 单元测试验证：性能计数器正确累积
- [ ] 单元测试验证：overhead 计算公式正确
- [ ] 集成测试：在 10k+ 文件场景下，验证 journal overhead <10%
- [ ] 性能报告输出示例（包含 flush 统计和 overhead 分析）
