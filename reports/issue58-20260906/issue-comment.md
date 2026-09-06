## 实现进展与计时勘误（2026-09-06）

继续按 Matt `/implement -> /code-review` 推进修正版 B。当前代码仍未提交或部署，本票保持 OPEN。

### 本轮补齐

- `StatusPlanValidationReceipt` 绑定 plan 路径、SHA-256 和原文，v2/v3 approval 复用已验证内容，减少重复严格 JSON/manifest 校验与解析。
- 保留第二次 live plan read/hash 和 policy read；v2 policy 漂移拒绝、v3 schema 5、namespace/journal 验证没有放宽。
- 补齐 live plan 漂移、跨 run 路径、同 SHA 字段不同原文、v2 policy 漂移、Windows `*`/`?` 文件名和三组完整 fast/slow 语义等价测试。修改版 Status 共 32 项通过，exit 0。
- 基线与独立回滚副本各 24 项 Status 测试通过，exit 0；回滚后 SHA-256 与基线原始字节相同，修改版文件保持改变。

### 局部收益与旧计时勘误

上条评论的 **fast scan=7ms 是 I/O 子段，不是完整扫描耗时**，在此更正。

对同一 6,039,074-byte plan，最新探针测得完整 fast scan 为 **287ms**；带命令断点的 control resolve 为 **9731ms**，receipt resolve 为 **1961ms**。两条路径 operation 完全相同，均为 `manual-review`，输入 SHA 前后不变。

优化路径的重复 strict JSON 次数从红色探针的 1 降到 0，fallback 内 live plan reread 仍为 1。另一次无断点组件测量为 resolve **2226ms**、完整 fast scan **288ms**。这些都是单样本局部证据，不代表全量达标。

### 全量验收仍失败

三次独立冷启动 `<60s` 的正式验收在首轮 **60295ms** 超时，未取得 Status 输出；子进程退出码 `-1`，停止已确认，harness exit `1`。后两轮未执行，不宣称满足性能合同。

完整 evidence snapshot 前后均为 23,663 entries，manifest SHA 均为 `03a837bc09bd2cf9c25658d9928023e12bdd12b869a9e31ee885d2c0d281b13a`；policy SHA 前后也相同。此处证明前后内容与 identity 不变，不声称完成期间零写事件审计。

独立 review 未发现核心 receipt 新增阻断性问题。Standards review 发现验收 harness 可能接受稳定空 operations，已补独立 snapshot 的预期 ID count/digest 对照；空输出、重复 ID、错误 ID 负例均拒绝，4 项内存覆盖测试通过。该补强尚未再次运行全量，不改变已有超时失败结论。

### 当前状态

- 本轮 `git diff --check` 通过。
- 全仓模块 gate 仍有 5 个既有 ownership 缺口，本票新增路径 ownership 错误为 0；未夹带修复无关文件。
- 本任务核心、Restore、schema compatibility、uncertain recovery 回归已通过。
- 未 commit、push、部署或关闭 issue，保留 `bug`、`needs-triage`。
- 完整本地记录位于 `reports/issue58-20260906/VERIFICATION.txt`，全量失败原始记录为同目录 `full-coldstart-result.json`。

下一步继续沿修正版 B 定位剩余大 plan 的读取、解析及 policy/target-tree 校验成本；保留 live 漂移检查，在全量验收真正通过前不关闭本票。
