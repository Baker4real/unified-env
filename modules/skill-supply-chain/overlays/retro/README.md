# retro 会话审计 overlay

这里维护 active `retro` skill 已有本地脚本的修复；上游 skill 正文、调用策略和来源记录由完整候选保留。此目录不包含账号配置或真实会话。

行为回归：`python -B tests/Test-RetroTranscriptAudit.py`。测试运行 `scripts/transcripts.py` 的公开 CLI，覆盖 Claude 重复请求过滤、Codex transport/报告分层、pending/unknown、预期非零标注和静态 exec 读取统计。

部署时先从当前 active `retro` 完整暂存候选，把本目录 scripts 的源码和测试覆盖到候选 scripts，保留已有 SOURCE.md。完成来源、overlay、writing-for-agents 和 candidate integrity 审查，再通过 `D:/Codex/.codex/scripts/install-skill-guarded.cmd --candidate <candidate> --decision-manifest <manifest> --update` 先 dry-run 后实际更新；最后复核 closure、ledger/catalog、菜单和 active 脚本哈希。此入口不授权直接复制到 active root。

`audit --expected-exit RESULT_LINE:CODE` 是操作者对特定日志行的显式说明；不自动猜测 grep、winget 等命令的非零含义。stdout 中形如 `name/exit_code/stdout/stderr` 的命令数组只显示为 reported outcome，不能据此证明外层工具失败。pending 是日志时点观察，可能在后续记录完成。

`audit --from-line N [--to-line M]` 只统计这段行号内的记录（如同一会话上次复盘之后的部分）；范围前发出的调用仍用来给范围内的结果命名、计算耗时，范围后才到的结果不计入。

`audit --sizes` 的 exec 路径统计只识别直接 `exec_command` 参数，以及 `functions.exec` 中受支持的静态 `tools.exec_command({cmd:"..."})` 字符串里的 `Get-Content`/`cat` literal 路径。动态命令、其他读法列为未解析；统计表示请求的读取次数，不能证明读取成功，也不把整批输出字节重复归因给每个文件。
