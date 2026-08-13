# 16 — Phase 3 集成测试和生产验证

**What to build:** 完整优化路径在真实场景达到 6x 提升。创建包含 10,000+ 小文件的测试目录，运行完整的 Plan → Apply → Purge 流程（启用哈希复用 + 批量处理 + 并行化），测量总耗时并验证相比 baseline 有 ≥6x 性能提升（最佳情况）或 ≥4x（典型情况）。所有安全属性测试通过，包括并行场景下的 crash safety 和 journal 完整性。

**Blocked by:** #13 — ParallelPurgeCoordinator 目录级并行, #14 — 并行度基准测试和调优, #15 — Journal 性能监控和告警

**Status:** ready-for-agent

- [ ] 创建完整优化路径性能测试套件（10k+ 小文件）
- [ ] Baseline 测试：使用原始实现运行完整流程，记录耗时
- [ ] Phase 3 测试（最佳场景）：本地 NTFS，4 线程并行，记录耗时
- [ ] Phase 3 测试（典型场景）：本地 NTFS，2 线程并行，记录耗时
- [ ] 验证最佳情况性能提升：Phase 3 耗时 / Baseline 耗时 ≤ 0.17（即 ≥6x 提升）
- [ ] 验证典型情况性能提升：Phase 3 耗时 / Baseline 耗时 ≤ 0.25（即 ≥4x 提升）
- [ ] 并行场景 crash safety 测试：在并行删除过程中强制中断，验证恢复正确
- [ ] 并行场景 journal 完整性测试：验证多个线程的 journal 文件都完整且可解析
- [ ] TOCTOU 防御测试：在并行操作过程中修改文件，验证操作被拒绝
- [ ] 端到端测试：验证所有文件正确删除，无遗漏
- [ ] Journal overhead 验证：确认 <10%
- [ ] 文件系统兼容性测试：在网络驱动器上自动降级到串行处理
- [ ] 回归测试：运行所有现有测试套件，验证无回归
- [ ] 性能报告：baseline vs Phase 1 vs Phase 2 vs Phase 3 完整对比
