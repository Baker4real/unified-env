# 11 — Purge 批量处理优化

**What to build:** Purge 使用批量收集和验证，减少 PowerShell 循环开销。Invoke-CodexSafeTreeDeletePurge 不再在 foreach 循环中逐个处理文件，而是先批量收集所有待删除项到数组，然后批量验证，最后批量写入 journal 和执行删除。在 10k+ 文件场景下，累积性能提升从 3x 提高到 4x。

**Blocked by:** #10 — Phase 1 集成测试和生产验证（Phase 1 完成并验证）

**Status:** ready-for-agent

- [ ] Purge 创建批量收集数组（ArrayList 或 List<T>）
- [ ] 第一次循环：遍历所有文件，收集文件路径、identity 到数组
- [ ] 第二次循环：批量验证循环，对数组中每个文件调用 GetHashSafely
- [ ] 第三次循环：批量 journal 写入循环，将所有 pending 状态写入 journal
- [ ] 第四次循环：批量删除循环，执行 File.Delete 并写入 commit 状态
- [ ] 减少 PowerShell 对象创建和函数调用开销
- [ ] 单元测试验证：批量处理与逐个处理产生相同结果
- [ ] 单元测试验证：批量收集数组包含所有文件
- [ ] 性能测试：10k+ 文件场景，批量处理相比 Phase 1 有额外 1.2-1.5x 提升
- [ ] 性能测试：累积提升（相比 baseline）达到 3.5-4x
- [ ] 安全测试：批量处理保持所有安全属性（journal 完整性、crash safety）
