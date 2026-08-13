# 08 — Crash recovery uncertain 状态处理

**What to build:** Crash recovery 正确处理 pending 文件消失的场景。当从 crash 恢复时，如果 journal 中标记为 pending 的文件在磁盘上不存在，系统将其标记为 uncertain 状态（无法确定是否已删除），而不是假设已成功删除。RecoveryState 报告包含 uncertain 文件列表，用户可以手动检查。

**Blocked by:** #07 — Purge 阶段集成哈希复用（需要完整的 Purge 流程）

**Status:** ready-for-agent

- [ ] RecoveryState 添加 UncertainFiles 字段（List<string> 文件路径）
- [ ] Crash recovery 逻辑检查 pending 文件是否存在
- [ ] Pending 文件存在 → 分类为 PendingFiles（需要重新处理）
- [ ] Pending 文件不存在 → 分类为 UncertainFiles（无法确定状态）
- [ ] RecoveryState 报告输出 UncertainFiles 列表
- [ ] 单元测试验证：pending 文件存在时分类为 PendingFiles
- [ ] 单元测试验证：pending 文件不存在时分类为 UncertainFiles
- [ ] 集成测试：模拟 crash（Purge pending 后强制退出），删除 pending 文件，运行恢复，验证文件出现在 UncertainFiles
- [ ] 集成测试：模拟 crash 后不删除 pending 文件，运行恢复，验证文件出现在 PendingFiles
- [ ] 文档更新：说明 uncertain 状态的含义和用户处理建议
