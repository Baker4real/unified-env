# 10 — Phase 1 集成测试和生产验证

**What to build:** Phase 1（哈希复用）在真实 10k+ 文件场景下达到 3x 提升。创建包含 10,000+ 小文件的测试目录，运行完整的 Plan → Apply → Purge 流程，测量总耗时并验证相比 baseline 有 ≥3x 性能提升。所有安全属性测试通过，包括 content-authenticated deletion、crash safety 和 TOCTOU 防御。

**Blocked by:** #06 — Apply 阶段集成哈希复用, #07 — Purge 阶段集成哈希复用, #08 — Crash recovery uncertain 状态处理, #09 — 文件系统检测和能力探测

**Status:** ready-for-agent

- [ ] 创建性能测试套件（10k+ 小文件，总大小 1-2 GB）
- [ ] Baseline 测试：使用旧实现运行完整流程，记录耗时
- [ ] Phase 1 测试：使用哈希复用实现运行完整流程，记录耗时
- [ ] 验证性能提升：Phase 1 耗时 / Baseline 耗时 ≤ 0.33（即 ≥3x 提升）
- [ ] 安全属性测试：验证所有文件哈希正确验证
- [ ] TOCTOU 防御测试：在操作过程中修改文件，验证操作被拒绝
- [ ] Crash safety 测试：在不同阶段强制中断，验证恢复正确
- [ ] 文件系统兼容性测试：在 NTFS、网络驱动器、FAT32（如果可用）上测试
- [ ] 集成测试：端到端运行 Plan → Apply → Purge，验证所有文件正确删除
- [ ] 回归测试：运行现有所有测试套件，验证无回归
- [ ] 性能报告：生成包含 baseline vs Phase 1 对比、不同文件系统表现的报告
