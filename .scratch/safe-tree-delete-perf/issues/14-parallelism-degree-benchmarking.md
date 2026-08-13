# 14 — 并行度基准测试和调优

**What to build:** 确定最优并行度配置（1/2/4/8/16线程对比）。创建性能测试套件，在不同文件数量和大小场景下，测试 1、2、4、8、16 线程配置的性能表现。测量总耗时、CPU 利用率和 journal flush 开销。基于测试结果确定推荐配置：对于典型场景（10k+ 小文件），推荐 min(4, ProcessorCount - 2)。

**Blocked by:** #13 — ParallelPurgeCoordinator 目录级并行（需要并行实现）

**Status:** ready-for-agent

- [ ] 创建并行度基准测试套件
- [ ] 测试场景 1：10k 个 1KB 小文件
- [ ] 测试场景 2：5k 个 10KB 中等文件
- [ ] 测试场景 3：1k 个 1MB 大文件
- [ ] 对每个场景测试 1、2、4、8、16 线程配置
- [ ] 测量总耗时（wall-clock time）
- [ ] 测量 CPU 利用率（通过 Process.TotalProcessorTime）
- [ ] 测量 journal flush 总耗时和开销百分比
- [ ] 绘制性能曲线图（线程数 vs 耗时）
- [ ] 分析收益递减点（diminishing returns）
- [ ] 确定推荐配置：小文件场景推荐 4 线程，中等文件推荐 2-4 线程，大文件推荐 1-2 线程
- [ ] 更新 FileSystemCapabilities.RecommendedMaxParallelism 逻辑
- [ ] 性能报告：包含不同场景下的最优配置建议
