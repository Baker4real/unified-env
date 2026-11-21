# retro 会话审计 overlay

这里维护 active `retro` skill 已有本地脚本的修复；上游 skill 正文、调用策略和来源记录由完整候选保留。此目录不包含账号配置或真实会话。

行为回归：在统一环境仓库根运行 `py -3.14 -B tests/Test-RetroTranscriptAudit.py`。测试运行 `scripts/transcripts.py` 的公开 CLI，覆盖 Claude 重复请求过滤、Codex transport/报告分层、pending/unknown、预期非零标注、静态 exec 读取统计，以及 DSH JSONL/Zstd 和 tool_search 配对；DSH 压缩 fixture 需要 Python 3.14+ 的 `compression.zstd`。

部署时先从当前 active `retro` 完整暂存候选，把本目录 scripts 的源码和测试覆盖到候选 scripts，保留已有 SOURCE.md。完成来源、overlay、writing-for-agents 和 candidate integrity 审查，再通过 `pwsh -NoProfile -File D:/Codex/.codex/scripts/install-skill-guarded.ps1 --candidate <candidate> --name retro --decision-manifest <manifest> --update` 先附加 `--dry-run` 检查后实际更新；显式 `--name retro` 避免将暂存目录名误作 skill 名。最后复核 closure、ledger/catalog、菜单和 active 脚本哈希。此入口不授权直接复制到 active root。

`audit --expected-exit RESULT_LINE:CODE` 是操作者对特定日志行的显式说明；不自动猜测 grep、winget 等命令的非零含义。stdout 中形如 `name/exit_code/stdout/stderr` 的命令数组只显示为 reported outcome，不能据此证明外层工具失败。pending 是日志时点观察，可能在后续记录完成。

`find --from-line N [--to-line M]` 只报告每份转录这段行号内的命中；范围倒置时以退出码 2 失败。`find` 默认按字面子串匹配，加 `--regex` 时按 Python 正则匹配（配合 `-i` 忽略大小写，非法正则以退出码 2 失败）。

`audit --from-line N [--to-line M]` 只统计这段行号内的记录（如同一会话上次复盘之后的部分）；范围前发出的调用仍用来给范围内的结果命名、计算耗时，范围后才到的结果不计入。

DSH V4 正文优先读取 `data.message.content`，兼容旧 `data.content`；audit 按 turn/step 限定 call_id，并按消息身份、正文和错误状态识别相同观察的重放。不同 turn/step、不同消息 ID、变化后的异步结果均保留；find/show 仍保留每条原始记录的行号。`--sizes` 同时识别 `Read` 和 `read`。公开 CLI 回归可用 `RETRO_TEST_TEMP` 指定 fixture 根，默认位置保持不变。

`audit --unknown-details` 为未分类 REPL 结果补充调用行号、结果行号、工具名及两段短摘要，默认最多 5 对、每段 170 字符。`--unknown-max` 允许 1–40 对，`--unknown-width` 允许每段 1–400 字符；超界参数退出 2，截断和未展示条数均明确标记。配对只使用已关联的非空 call_id，仍可找到 `--from-line` 之前的调用；非 REPL、缺失调用及不含未知观察项的结果不进入此视图。摘要不改变分类，文档中的错误例子仍是数据；省略此选项时原有报告不变。

编排结果会递归解析结构化 JSON 信封；显式 `isError` 的 MCP 结果是终端，不再解释其正文，无状态 MCP text 中的信封只记 unknown，进程 stdout 也仍作为数据。异步结束按显式 session/cell ID、带索引的结果或完整的顺序 `text(await tools.X(...))` 输出配对；截断、多余输出或动态调用不猜归属。GUI/REPL 独立错误诊断只在对应工具调用中计失败；`failed tool results: 0` 不代表非零、pending 和 unknown 均为空。`show` 默认限制每行长度，截断会给出省略字符数。

带 `Chunk ID`、`Wall time`、`Process exited with code`、`Original token count` 和 `Output:` 的完整 exec 包装按其首个 transport 退出码分类。该包装内 `Output:` 正文中的退出码文本是数据；截断输出仍保留 unknown，不因包装上的零退出码消除未分类边界。

混合输出额外支持两种有界前缀：`ALL_TOOLS` 名称/描述投影，以及静态参数 MCP 调用后的 `structuredContent?.result ?? content?.find(...)?.text` 投影。后续必须是完整、顺序直出的 `exec_command`/`write_stdin` 结果，并保留原始 `input_text` 分块及完整编排结束头；投影块仅记 opaque unknown，不能把其中或进程 stdout 内的 JSON 当作进程终态。动态参数、额外输出、截断或块数不符保持 pending/unknown。

`audit --sizes` 的 exec 路径统计只识别直接 `exec_command`、`run_command` 参数，以及 `functions.exec` 中受支持的静态 `tools.exec_command({cmd:"..."})` 字符串里的 `Get-Content`/`cat` literal 路径。动态命令、其他读法列为未解析；统计表示请求的读取次数，不能证明读取成功，也不把整批输出字节重复归因给每个文件。

Google Antigravity `transcript.jsonl` 支持：`USER_INPUT`、`PLANNER_RESPONSE`、`GENERIC`、`SYSTEM_MESSAGE`、`CHECKPOINT`、`ERROR_MESSAGE` 统一解析并解码 JSON 字符串形式的 `tool_calls[].args`；因记录不含 `call_id`，按 FIFO 顺序将 `PLANNER_RESPONSE` 工具调用与后续 `GENERIC` 配对。`GENERIC` 的 `ERROR`/`INVALID` 计为失败，`run_command` 包装头的 `Command exited with code N.` 计为待复核非零（支持 `--expected-exit`），`RUNNING` 后台任务按显式 task ID 与 `SYSTEM_MESSAGE` 完成通知对账；耗时优先读 `Created At..Completed At`；`--sizes` 纳入 `read_file` 重复读取。`default_roots()` 纳入 `$ANTIGRAVITY_HOME/brain`（默认 `~/.gemini/antigravity/brain`），遍历 `.system_generated/logs/` 时自动跳过 `chunks/`，有紧凑 `transcript.jsonl` 时跳过重复的 `transcript_full.jsonl`（直接指定文件时照常读取）。
