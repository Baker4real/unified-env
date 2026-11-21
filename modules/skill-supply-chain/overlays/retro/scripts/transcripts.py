"""Search and audit agent session transcripts (Claude Code, Codex, Kimi Code, DeepSeek Harness and Google Antigravity JSONL logs). Reads only.

  transcripts.py find NEEDLE [PATH ...] [--since DATE] [--kind KIND] [--skip TEXT] [--bridge] [-i]
  transcripts.py audit FILE [--slow SECONDS] [--sizes] [--expected-exit RESULT_LINE:CODE] [--from-line N] [--to-line M]
                           [--unknown-details] [--unknown-max N] [--unknown-width N]
  transcripts.py show FILE LINE [--grep REGEX]

find   which transcripts mention a fixed string, newest last, with a timestamped snippet per hit
audit  one transcript's span, block counts, tool-call counts, failed tool results and slow calls;
       --sizes adds tool-result characters per tool, the largest results and files read more than once;
       --from-line and --to-line count only records on lines N..M, such as the turns since an earlier
       audit, and a result in range still names its call from before N; the first row, "lines:", gives
       the transcript's last line (and the counted range), so a range is chosen without counting the log
       --unknown-details adds bounded call/result pairs for unclassified REPL outputs, without
       changing their status; defaults to 5 pairs and 170 characters per call/result summary
       A Harness log with turn/start records also gets a section of turns that ended without a final
       assistant reply
       A Claude Code log with system api_error records (API failures it retried) also gets each one's
       line, time and retry attempt; the error message is not printed
show   the text of one record, optionally only lines matching a regex;
       --max limits lines and --max-chars limits each line (default 1000); omissions are marked

PATH is a transcript file or a directory walked for *.jsonl and *.jsonl.zstd. Without PATH, find walks
$CLAUDE_CONFIG_DIR/projects (default ~/.claude/projects), $CODEX_HOME/sessions and
$CODEX_HOME/archived_sessions (default ~/.codex), ~/.kimi-code/sessions,
$DSH_HOME/sessions (default ~/.dsh/sessions), and $ANTIGRAVITY_HOME/brain (default ~/.gemini/antigravity/brain).
A Claude Code session's subagents log to <session-id>/subagents/*.jsonl beside its transcript; a Kimi Code
session logs each of its agents to agents/<id>/wire.jsonl under the session directory; a Google Antigravity
session logs to <conversation-id>/.system_generated/logs/transcript.jsonl (walking that directory skips
chunks/ and prefers transcript.jsonl over transcript_full.jsonl).

A walked directory named *magpie-claude-work holds Magpie bridge backend copies: each DeepSeek Harness
turn run on a magpie/claude/* model starts a Claude Code backend there, which writes its own transcript
beginning with the whole conversation as <pasted_content> blocks and a backend-made title. They are copies
of a DeepSeek Harness session, not other sessions, so find skips them and reports how many it skipped;
--bridge searches them, labelled "claude bridge". A PATH inside such a directory is always searched.
Each find header shows the transcript's first and last record times as well as its file modified time,
which can differ from them, and how many lines it has.

Each record splits into blocks of one kind:
  user, assistant, thinking, tool_call, tool_result
  other    compaction summaries, injected meta messages, system notes and API errors, messages from other agents
  context  system prompt, AGENTS.md and CLAUDE.md text, environment, tool and skill text; find skips it unless --kind context
Claude Code api-request-blob records repeat what was sent to the API and yield no blocks, so nothing counts twice.
Codex exec transport exits, named stdout command reports, pending observations and unknown formats
are listed separately. A nonzero exit needs review; --expected-exit explicitly annotates its result
line and code. Reported stdout observations are not proof that the enclosing tool failed.
Pending processes/cells are reconciled with later terminal results by explicit identifiers
or literal poll arguments and indexed batch results. Ambiguous/dynamic calls stay pending.
Only completions inside the selected line range resolve observations; truncated or opaque
results remain unclassified even when their surrounding orchestration completed.
Direct sequential text(await tools.X(...)) outputs can pair polls when every result is present.
Recognized standalone GUI/REPL diagnostics count as failures only in calls to those tools;
process stdout remains data. Zero failed results alone never means the run was successful.
MCP bodies are data: explicit isError is terminal; text-only nested outcomes stay unclassified.
--sizes also recognizes literal Get-Content/cat paths in exec calls; dynamic commands stay unparsed.
Static exec reads count requested path occurrences, not successful reads or per-file output bytes.
find matches decoded text, so a Windows path matches as typed; it also tries the needle with JSON string
escapes, which code inside a tool call keeps.
Codex tool_search_call records are tool calls named tool_search. A short following output that mentions
tool_search but has an empty call_id is that call's result, including a parse failure.
Harness audit scopes call IDs by turn/step when present and counts identical observations once.
A replace of an already observed result message ID rewrites history, even if its body changes;
it adds no execution result or duration. Distinct message IDs and changed append results remain
evidence. This also applies across --from-line; legacy records without scope/identity keep
content-based replay handling.
find/show keep every record's line.
--sizes tracks Read, read and read_file tool names.
Antigravity PLANNER_RESPONSE tool_calls pair in order with following GENERIC results (which lack call_id);
GENERIC status ERROR/INVALID counts as a failed tool result, run_command header exits count as nonzero exits,
and RUNNING background tasks reconcile with SYSTEM_MESSAGE completion notices by explicit task ID.
Harness background jobs reconcile pwsh launch markers and job_output results by explicit job_id,
not callId or adjacency. job_output accepts its final status trailer or complete {text, job}
transport projection with a matching job ID; stdout status/exitCode examples remain data.
Completion notices require user/message source kind=tool-jobs, form=notice, a complete generated
header and a previously observed job ID. Unknown/truncated/mismatched evidence leaves jobs pending.
Notice failures are separate from failed tool results; notice replays and historical replaces
follow the same observation rules. A job_output read error does not prove that its job settled.
Turns that ended without a final assistant reply cover only Harness logs with turn/start records;
other formats print no such section. A turn is judged when its turn/start and a turn/end with the
same turn number pair up, and is listed when that turn/end's reason is not completed, or is
completed with no assistant text content after the turn's last new tool result, user message or
injected background-job notice. Reasoning and tool-call content are not text; replace records are
history. A turn whose turn/end is in the line range is judged on all its records, including those
before --from-line. Each row gives the turn's lines, turn/end kind and failure code, and its last
text and last result/message lines, then its last assistant/attempt line with finish kind, failure
code, token usage and stream item count. A message prints only as <N chars>, since upstream errors
can carry key prefixes, hosts and addresses; read a whole record with show. An attempt before the
last result/message is marked stale. An absent field or attempt prints as missing. The section ends
with the count of unpaired turns it did not judge, including a turn still open at the range end.

Exit status: find 0 with hits, 1 without; audit and show 0; 2 for a missing path or line.
"""
import argparse
import collections
import datetime
import json
import os
import re
import string
import sys
from pathlib import Path

KINDS = ("user", "assistant", "thinking", "tool_call", "tool_result", "other", "context")
# Codex records holding settings, token counts or copies of response items rather than conversation.
CODEX_SKIP = {"session_meta", "turn_context", "event_msg", "token_usage_record", "world_state",
              "inter_agent_communication_metadata"}
# Codex also sends harness text as user messages: AGENTS.md, or a block whose opening tag says what it is.
# An unknown tag stays user, so new harness text shows up in find rather than a reply going missing.
CODEX_AGENTS_MD = "# AGENTS.md instructions for "
CODEX_TAGS = {"environment_context": "context", "user_instructions": "context", "recommended_plugins": "context",
              "skill": "context", "external_codex_apps_open_page": "context",
              "turn_aborted": "other", "codex_delegation": "other"}
CODEX_TAG = re.compile(r"<([a-z_]+)>")
# Claude Code attachments that carry conversation; every other attachment type is harness context.
CLAUDE_ATTACHMENTS = {"file": "attached file", "queued_command": "queued"}
# Claude Code records copying request content (system prompt, earlier turns) rather than adding conversation.
CLAUDE_SKIP = {"api-request-blob"}
# Kimi Code wire.jsonl records that carry conversation; llm.request, usage, token and turn bookkeeping yield no blocks.
KIMI_TYPES = {"context.append_message", "context.append_loop_event", "context.apply_compaction",
              "profile.bind"}
# DeepSeek Harness session.v4 records use a slash type plus a data object. Bookkeeping types yield no blocks.
DSH_EXIT = re.compile(r'(?i)(?:exit code:?\s*|"exitCode"\s*:\s*)(-?\d+)')
EXIT_LINE = re.compile(r"(?im)^(?:exit code:?|process exited with code)\s*(-?\d+)")
ASCII_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)
EXEC_TRANSPORT = re.compile(
    r'\A(?:Chunk ID: [^\r\n]+\r?\n)?'
    r'(?:Wall time: [^\r\n]+\r?\n)?'
    r'Process exited with code (-?\d+)\r?\n'
    r'(?:Original token count: \d+\r?\n)?'
    r'Output:\r?\n')

Block = collections.namedtuple("Block", "kind name text call_id failed data", defaults=(None, False, None))


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(2)


def render(value):
    """Readable text of a JSON value: strings stay raw, objects become key: value lines."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return "\n".join(f"{key}: {render(item)}" for key, item in value.items())
    if isinstance(value, list):
        return "\n".join(map(render, value))
    return json.dumps(value)


def content_text(value):
    """Text of message content: a string or a list of content blocks."""
    if value is None:
        return ""
    if isinstance(value, list):
        return "\n".join(text for text in map(content_text, value) if text)
    if isinstance(value, dict):
        if isinstance(value.get("text"), str):
            return value["text"]
        if value.get("type") in ("image", "input_image"):
            return "[image]"
        if "encrypted_content" in value:
            return ""
    return render(value)


def codex_failed(text):
    head = text.lstrip()[:120].lower()
    if head.startswith(("script failed", "execution error")) or "exec_command failed" in head:
        return True
    return any(int(code) != 0 for code in EXIT_LINE.findall(text))


def codex_outcomes(text, process_slots=None, ordered=False, gui_result=False,
                   mixed_plan=None, parts=None):
    """Recognize transport envelopes; never search arbitrary stdout for exit_code text.

    Named command-result arrays in stdout are reported observations, not transport
    results. Their meaning remains unclassified until the operator reviews them.
    """
    outcomes = []
    transport = EXEC_TRANSPORT.match(text)
    if transport:
        transport_code = int(transport.group(1))
        # Only the wrapper's first exit is transport. Output may contain logs,
        # examples, or an incomplete structured result with the same wording.
        if re.search(r'(?i)(?:truncated output|output-truncated)', text):
            outcomes.append(('unknown', None, 'truncated orchestration output', None))
        return [('success' if transport_code == 0 else 'nonzero',
                 transport_code, 'process', None), *outcomes]
    if mixed_plan is not None:
        # Keep the harness' output boundaries: an opaque MCP projection may itself
        # contain JSON resembling a process result. Never flatten it into transport.
        valid_parts = isinstance(parts, list) and all(
            isinstance(part, dict) and part.get('type') == 'input_text'
            and isinstance(part.get('text'), str) for part in parts)
        if not valid_parts or len(parts) != len(mixed_plan) + 1 or not re.fullmatch(
                r'Script completed\r?\n(?:Wall time [^\r\n]+\r?\n)?Output:\r?\n', parts[0]['text']):
            return [('unknown', None, 'incomplete mixed orchestration output', None)]
        for slot, part in zip(mixed_plan, parts[1:]):
            if slot is None:
                outcomes.append(('unknown', None, 'opaque mixed orchestration output', None))
                continue
            try:
                value = json.loads(part['text'])
            except ValueError:
                value = None
            if not isinstance(value, dict) or not isinstance(value.get('output'), str) or not (
                    isinstance(value.get('chunk_id'), str) or
                    isinstance(value.get('wall_time_seconds'), (int, float))):
                outcomes.append(('unknown', None, 'unrecognized mixed transport block', None))
                continue
            outcomes.extend(codex_outcomes(part['text'], {0: (process_slots or {}).get(slot)}, True))
        return outcomes
    body = re.split(r'\r?\nOutput:\r?\n', text, maxsplit=1)[-1].strip()
    # These are tool diagnostics, not a substring search of page text or shell stdout.
    if gui_result and (body == 'coordinate input geometry is unavailable' or
                       re.match(r'^(?:Error|TypeError|ReferenceError): [^\n]+(?:\n\s+at .+)*$', body)):
        return [('failure', None, 'GUI tool diagnostic', None)]
    decoder = json.JSONDecoder()
    values = []
    while body:
        try:
            value, end = decoder.raw_decode(body)
        except ValueError:
            # 编排器可能在完整 JSON 行前插入截断提示；缺失段仍记为未知。
            for line in body.splitlines():
                try:
                    values.append(json.loads(line))
                except ValueError:
                    continue
            if 'truncated output' in body.lower():
                outcomes.append(('unknown', None, 'truncated orchestration output', None))
            break
        values.append(value)
        body = body[end:].lstrip()

    def walk(value, depth=0, slot=None):
        if depth > 16:
            return
        if isinstance(value, str):
            try:
                nested = json.loads(value)
            except ValueError:
                return
            walk(nested, depth + 1, slot)
        elif isinstance(value, list):
            for index, item in enumerate(value):
                walk(item, depth + 1, index)
        elif isinstance(value, dict):
            slot = value.get('i', value.get('index', slot))
            if value.get('status') == 'fulfilled' and 'value' in value:
                walk(value['value'], depth + 1, slot)
            elif value.get('status') == 'rejected' and 'reason' in value:
                outcomes.append(('failure', None, 'rejected tool promise', None))
            elif isinstance(value.get('content'), list):
                if type(value.get('isError')) is bool:
                    outcomes.append(('failure' if value['isError'] else 'success', None, 'MCP tool result', None))
                    return  # A terminal tool's body can contain documentation of any result shape.
                # Text-only MCP content has no trustworthy execution status. Keep nested
                # observations as unknown; do not resolve sessions or invent tool failures.
                start = len(outcomes)
                for item in value['content']:
                    nested = item.get('text', '') if isinstance(item, dict) else ''
                    if nested.startswith(('Script completed', 'Script running with cell ID')):
                        outcomes.extend(codex_outcomes(nested))
                    else:
                        walk(nested, depth + 1, slot)
                nested_outcomes = outcomes[start:]
                del outcomes[start:]
                if nested_outcomes:
                    outcomes.append(('unknown', None, 'MCP text contains unverified outcome envelopes', None))
            elif isinstance(value.get('output'), str) and (
                    isinstance(value.get('chunk_id'), str) or
                    isinstance(value.get('wall_time_seconds'), (int, float))):
                code = value.get('exit_code')
                key = ('process', str(value['session_id'])) if type(value.get('session_id')) in (int, str) else None
                if key is None and process_slots and type(slot) is int:
                    hint = process_slots.get(slot)
                    if hint and hint[0] == 'process':
                        key = hint
                if type(code) is int:
                    outcomes.append(('success' if code == 0 else 'nonzero', code, 'process', key))
                elif key:
                    outcomes.append(('pending', None, 'running process', key))
                else:
                    outcomes.append(('unknown', None, 'transport without final exit', None))
                try:
                    report = json.loads(value['output'])
                except ValueError:
                    return
                if isinstance(report, list) and report and all(
                    isinstance(row, dict) and isinstance(row.get('name'), str)
                    and type(row.get('exit_code')) is int
                    and isinstance(row.get('stdout'), str) and isinstance(row.get('stderr'), str)
                    for row in report
                ):
                    for row in report:
                        if row['exit_code'] != 0:
                            outcomes.append(('reported', row['exit_code'], 'named command report', None))
            else:
                for key in ('result', 'results', 'value'):
                    nested = value.get(key)
                    if isinstance(nested, (dict, list)):
                        walk(nested, depth + 1, slot)
                    elif isinstance(nested, str) and nested.startswith(('Script completed', 'Script running with cell ID')):
                        outcomes.extend(codex_outcomes(nested))
                    elif isinstance(nested, str):
                        walk(nested, depth + 1, slot)

    ordered_values = ordered and len(values) == len(process_slots or {}) and not outcomes
    for index, value in enumerate(values):
        # A series of direct text(await tool(...)) statements preserves output order.
        # A batch, extra output, or truncation needs explicit indices instead.
        slot = index if ordered_values else None
        walk(value, slot=slot)
    cell = re.match(r'(?i)script running with cell id\s+([A-Za-z0-9_-]+)', text.lstrip())
    if cell:
        outcomes.append(('pending', None, 'running orchestration cell', ('cell', cell.group(1))))
    if not outcomes:
        codes = [int(code) for code in EXIT_LINE.findall(text)]
        outcomes.extend(('success' if code == 0 else 'nonzero', code, 'process', None) for code in codes)
    if not outcomes:
        outcomes.append(('unknown', None, 'unrecognized result format', None))
    return outcomes


def async_call_slots(block):
    """从显式轮询实参取得关联键；无法解析或有多个键时不猜测归属。"""
    slots = {}
    if isinstance(block.data, dict):
        for field, kind in (('session_id', 'process'), ('cell_id', 'cell')):
            if type(block.data.get(field)) in (int, str):
                slots[0] = (kind, str(block.data[field]))
    if block.name.rsplit('.', 1)[-1] == 'exec':
        # 跳过字符串中的示例代码；只解析直接调用的字面实参，不执行 JavaScript。
        tokens = re.compile(r"""(?P<string>//[^\n]*|/\*[\s\S]*?\*/|/(?:\\.|[^/\n\\])+/[dgimsuvy]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\x60(?:\\.|[^\x60\\])*\x60)|(?P<call>\btools\.(?P<name>\w+)\s*\()""")
        calls = [match for match in tokens.finditer(block.text) if match.group('call')]
        for index, call in enumerate(calls):
            slots[index] = None
            if call.group('name') not in ('write_stdin', 'wait'):
                continue
            argument = re.match(r'\s*\{([^{}]*)\}', block.text[call.end():])
            if not argument:
                continue
            field, kind = ('session_id', 'process') if call.group('name') == 'write_stdin' else ('cell_id', 'cell')
            pattern = r'(?:^|,)\s*["\']?' + field + r'["\']?\s*:\s*(?:"([A-Za-z0-9_-]+)"|\'([A-Za-z0-9_-]+)\'|(\d+))\s*(?=,|$)'
            match = re.search(pattern, argument.group(1))
            if match:
                slots[index] = (kind, next(value for value in match.groups() if value is not None))
    return slots


def ordered_results(block):
    """Accept only complete direct text(await tools.X(...)) statements, not arbitrary JS."""
    if block.name.rsplit('.', 1)[-1] != 'exec':
        return False
    text = block.text
    # Tokenize literals/comments before balancing statements; semicolons in commands are data.
    token = re.compile(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/''')
    masked = token.sub(lambda match: ' ' * len(match.group()), text)
    depth, start, statements = 0, 0, []
    for index, char in enumerate(masked):
        if char in '({[':
            depth += 1
        elif char in ')}]':
            depth -= 1
            if depth < 0:
                return False
        elif char == ';' and depth == 0:
            statements.append(masked[start:index].strip())
            start = index + 1
    statements.append(masked[start:].strip())
    statements = [statement for statement in statements if statement]
    if depth != 0 or not statements:
        return False
    for statement in statements:
        prefix = re.match(r'text\s*\(\s*await\s+tools\.\w+\s*\(', statement)
        if not prefix or len(re.findall(r'\btools\.\w+\s*\(', statement)) != 1:
            return False
        nested = 1
        for index in range(prefix.end(), len(statement)):
            nested += (statement[index] == '(') - (statement[index] == ')')
            if nested == 0:
                # Reject transformations such as .then(...), || fallback or comma expressions.
                if statement[index + 1:].strip() != ')':
                    return False
                break
        else:
            return False
    return True


def mixed_output_slots(block):
    """Recognize bounded metadata/MCP projections before direct tool-result prints."""
    if block.name.rsplit('.', 1)[-1] != 'exec':
        return None
    metadata = re.match(
        r'\s*text\(ALL_TOOLS\.filter\((\w+)=>/(?:\\.|[^/\\\r\n])+/[dgimsuvy]*'
        r'\.test\(\1\.name\)\)\.map\(\1=>\(\{name:\1\.name,description:'
        r'\1\.description\.slice\(0,\d+\)\}\)\)\)\s*;\s*', block.text)
    offset = 0
    if metadata:
        end = metadata.end()
    else:
        literal = r'''(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|-?\d+(?:\.\d+)?|true|false|null)'''
        field = r'''(?:[A-Za-z_$]\w*|"[A-Za-z_$]\w*"|'[A-Za-z_$]\w*')\s*:\s*''' + literal
        projection = re.match(
            r'\s*const\s+(\w+)\s*=\s*await\s+tools\.mcp__\w+\s*\(\s*\{\s*'
            + r'(?:' + field + r'(?:\s*,\s*' + field + r')*)?\s*\}\s*\)\s*;\s*'
            r'text\(\1\.structuredContent\?\.result\?\?\1\.content\?\.find\('
            r"(\w+)=>\2\.type==='text'\)\?\.text\)\s*;\s*", block.text)
        if not projection:
            # A recognizable mixed prefix with unsupported expressions is not
            # evidence of transport. An empty plan forces an unknown result.
            if (re.match(r'\s*text\(ALL_TOOLS', block.text)
                    or (re.match(r'\s*const\s+\w+\s*=\s*await\s+tools\.mcp__', block.text)
                        and re.search(r'text\(\w+\.structuredContent\?\.result\?\?', block.text))):
                return []
            return None
        end, offset = projection.end(), 1
    tail = block._replace(text=block.text[end:])
    if not ordered_results(tail):
        return []
    # Only these process transports have the envelope contract checked above.
    literal = re.compile(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/''')
    names = re.findall(r'\btools\.(\w+)\s*\(', literal.sub('', tail.text))
    if any(name not in ('exec_command', 'write_stdin') for name in names):
        return []
    return [None, *range(offset, offset + len(async_call_slots(tail)))]


def repl_result(block):
    if block.name.startswith(('mcp__cua_repl.', 'mcp__cua_repl__', 'mcp__node_repl.', 'mcp__node_repl__')):
        return True
    if block.name.rsplit('.', 1)[-1] != 'exec':
        return False
    tokens = re.compile(r'''(?P<literal>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/)|(?P<call>\btools\.mcp__(?:cua|node)_repl__js\s*\()''')
    return any(match.group('call') for match in tokens.finditer(block.text))


def claude_blocks(record):
    kind = record.get("type")
    if kind in CLAUDE_SKIP:
        return
    if kind == "system":
        name = " ".join(filter(None, ("system", record.get("subtype"))))
        parts = (content_text(record.get("content")), render(record["hookErrors"]) if record.get("hookErrors") else "")
        yield Block("other", name, "\n".join(filter(None, parts)))
        return
    if kind == "attachment":
        attachment = record.get("attachment")
        sort = attachment.get("type", "") if isinstance(attachment, dict) else ""
        yield Block("other" if sort in CLAUDE_ATTACHMENTS else "context", CLAUDE_ATTACHMENTS.get(sort, sort),
                    render(attachment))
        return
    message = record.get("message")
    if not isinstance(message, dict):
        return
    if record.get("isCompactSummary"):
        speaker, name = "other", "compact summary"
    elif record.get("isMeta"):
        speaker, name = "other", "meta"
    else:
        speaker, name = ("user" if message.get("role") == "user" else "assistant"), ""
    content = message.get("content")
    if isinstance(content, str):
        yield Block(speaker, name, content)
        return
    for block in content or []:
        if not isinstance(block, dict):
            continue
        sort = block.get("type")
        if sort == "text":
            yield Block(speaker, name, block.get("text", ""))
        elif sort == "image":
            yield Block(speaker, name, "[image]")
        elif sort == "thinking":
            yield Block("thinking", "", block.get("thinking", ""))
        elif sort == "tool_use":
            yield Block("tool_call", block.get("name", ""), render(block.get("input")), block.get("id"),
                        data=block.get("input"))
        elif sort == "tool_result":
            yield Block("tool_result", "", content_text(block.get("content")), block.get("tool_use_id"),
                        bool(block.get("is_error")))


def codex_blocks(record):
    payload = record.get("payload")
    if not isinstance(payload, dict) or record.get("type") in CODEX_SKIP:
        return
    if record.get("type") == "compacted":
        yield Block("other", "compacted", content_text(payload.get("message")))
        return
    sort = payload.get("type")
    name = ".".join(filter(None, (payload.get("namespace"), payload.get("name"))))
    if sort == "message":
        role = payload.get("role") or ""
        text = content_text(payload.get("content"))
        head = text.lstrip()
        tag = CODEX_TAG.match(head)
        tag = tag.group(1) if tag else ""
        if role == "user" and head.startswith(CODEX_AGENTS_MD):
            yield Block("context", "AGENTS.md", text)
        elif role == "user" and tag in CODEX_TAGS:
            yield Block(CODEX_TAGS[tag], tag, text)
        elif role in ("user", "assistant"):
            yield Block(role, "", text)
        else:
            yield Block("context", role, text)
    elif sort == "reasoning":
        yield Block("thinking", "", content_text(payload.get("summary")))
    elif sort == "tool_search_call":
        arguments = payload.get("arguments")
        query = arguments.get("query") if isinstance(arguments, dict) else ""
        if not isinstance(query, str):
            query = render(query)
        yield Block("tool_call", "tool_search", f"tool_search query={query}", payload.get("call_id"),
                    data=arguments if isinstance(arguments, dict) else None)
    elif sort == "function_call":
        try:
            data = json.loads(payload.get("arguments") or "null")
        except (TypeError, ValueError):
            data = payload.get("arguments")
        yield Block("tool_call", name, render(data), payload.get("call_id"), data=data)
    elif sort == "custom_tool_call":
        yield Block("tool_call", name, content_text(payload.get("input")), payload.get("call_id"))
    elif sort in ("function_call_output", "custom_tool_call_output"):
        text = content_text(payload.get("output"))
        head = text.lstrip()[:120].lower()
        explicit_failure = head.startswith(('script failed', 'execution error')) or 'exec_command failed' in head
        yield Block("tool_result", "", text, payload.get("call_id"), explicit_failure,
                    data={"outcomes": codex_outcomes(text), "parts": payload.get("output")})
    elif sort == "agent_message":
        yield Block("other", " ".join(filter(None, ("agent_message", payload.get("author")))),
                    content_text(payload.get("content")))


def kimi_blocks(record):
    sort = record.get("type")
    if sort == "context.append_message":
        message = record.get("message")
        if not isinstance(message, dict):
            return
        role = message.get("role") or ""
        if role in ("user", "assistant"):
            yield Block(role, "", content_text(message.get("content")))
        else:
            yield Block("context", role, content_text(message.get("content")))
        return
    if sort == "context.apply_compaction":
        yield Block("other", "compacted", content_text(record.get("summary")))
        return
    if sort == "profile.bind":
        prompt = record.get("systemPrompt")
        if isinstance(prompt, str) and prompt:
            yield Block("context", "system prompt", prompt)
        return
    # context.append_loop_event; step.begin/step.end are bookkeeping. agent.message.appended and
    # turn.prompt restate the same text as these events, so they stay unread to avoid double counts.
    event = record.get("event")
    if not isinstance(event, dict):
        return
    sort = event.get("type")
    if sort == "content.part":
        part = event.get("part")
        if not isinstance(part, dict):
            return
        if part.get("type") == "text":
            yield Block("assistant", "", part.get("text", ""))
        elif part.get("type") == "think":
            yield Block("thinking", "", part.get("think", ""))
    elif sort == "tool.call":
        args = event.get("args", event.get("arguments"))
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                pass
        yield Block("tool_call", event.get("name", ""), render(args),
                    event.get("toolCallId") or event.get("id"),
                    data=args if isinstance(args, dict) else None)
    elif sort == "tool.result":
        result = event.get("result")
        if isinstance(result, dict):
            text = content_text(result.get("output"))
            failed = bool(result.get("isError")) or codex_failed(text)
            duration = result.get("durationMs")
        else:
            text, failed, duration = render(result), False, None
        yield Block("tool_result", "", text, event.get("toolCallId") or event.get("id"),
                    failed, data=duration)


def is_dsh_record(record):
    sort = record.get("type")
    return isinstance(sort, str) and "/" in sort and isinstance(record.get("data"), dict) and "payload" not in record


DSH_TEXT_FAILURE_TOOLS = {"pwsh", "plugin_manager"}


def dsh_failed(text):
    if "ERR_PNPM_" in text or '"code": "operation-error"' in text or '"code":"operation-error"' in text:
        return True
    return any(int(code) != 0 for code in DSH_EXIT.findall(text))


DSH_JOB_STATUS = re.compile(r'\[status: (running|stopping|completed|failed|killed)(?:, ([^\r\n]*))?\]')


def dsh_job_outcome(name, text, arguments):
    """Read job transport metadata, never status-like strings inside stdout."""
    if name == 'pwsh':
        # These are the shell renderer's complete last line, after any stdout.
        launch = re.fullmatch(r'(?:started background job ([\w-]+)|'
                              r'\[still running after \d+ms; moved to background job ([\w-]+)\])',
                              text.rstrip('\r\n').rsplit('\n', 1)[-1])
        return (launch[1] or launch[2], 'running', None) if launch else None
    if name != 'job_output':
        return None
    job_id = arguments.get('job_id') if isinstance(arguments, dict) else None
    if not isinstance(job_id, str) or not job_id:
        return None
    trailer = DSH_JOB_STATUS.fullmatch(text.rstrip('\r\n').rsplit('\n', 1)[-1])
    if trailer:
        state, detail = trailer.groups()
    else:
        try:
            value = json.loads(text)
        except ValueError:
            return None
        # The public job_output envelope keeps the job projection beside opaque text.
        # A producer's {status, exitCode, output} stdout is not this transport.
        if not isinstance(value, dict) or not isinstance(value.get('text'), str):
            return None
        job = value.get('job')
        if (not isinstance(job, dict) or job.get('id') != job_id
                or job.get('status') not in ('running', 'stopping', 'completed', 'failed', 'killed')
                or not isinstance(job.get('kind'), str) or not isinstance(job.get('label'), str)
                or type(job.get('startedAt')) is not int):
            return None
        state, detail = job['status'], job.get('detail')
        if detail is not None and not isinstance(detail, str):
            return None
    exit_match = re.fullmatch(r'exit code: (-?\d+)', detail or '')
    code = int(exit_match[1]) if exit_match and state not in ('running', 'stopping') else None
    return job_id, state, code


def dsh_job_notice(text):
    """The generated header is metadata; the optional Output body remains data."""
    head, newline, _body = text.partition('\n')
    notice = re.fullmatch(r'background job ([\w-]+) \([^\r\n]*\) finished '
                          r'(\[status: [^\r\n]+\])\. '
                          r'(Output:|No new output\.|Read its output with job_output\.)', head.rstrip('\r'))
    if not notice or bool(newline) != (notice[3] == 'Output:'):
        return None
    outcome = dsh_job_outcome('job_output', notice[2], {'job_id': notice[1]})
    return outcome if outcome and outcome[1] in ('completed', 'failed', 'killed') else None


def dsh_blocks(record):
    sort = record.get("type")
    data = record["data"]
    if sort == "user/message":
        text = content_text(data.get("content"))
        source = data.get('source')
        if isinstance(source, dict) and source.get('kind') == 'tool-jobs' and source.get('form') == 'notice':
            yield Block('other', 'background-job notice', text)
            return
        head = text.lstrip()
        kind = "context" if head.startswith(("<system-reminder", "<skill_content", "Current runtime context")) else "user"
        yield Block(kind, "", text)
        return
    if sort == "assistant/message":
        message = data.get("message")
        content = message.get("content") if isinstance(message, dict) else data.get("content")
        yield Block("assistant", "", content_text(content))
        return
    if sort == "tool/call":
        args = data.get("arguments")
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                pass
        yield Block("tool_call", data.get("name") or "", render(args), data.get("callId"),
                    data=args if isinstance(args, dict) else None)
        return
    if sort == "tool/result":
        message = data.get("message")
        if isinstance(message, dict):
            text = content_text(message.get("content"))
            failed = bool(message.get("isError"))
            call_id = (message.get("source") or {}).get("callId") or message.get("toolCallId")
        else:
            text, failed, call_id = render(message), False, data.get("callId")
        yield Block("tool_result", "", text, call_id, failed)
        return


def dsh_has_reply_text(data):
    """Whether a Harness assistant message carries text content; reasoning and tool calls are not a reply."""
    message = data.get("message")
    content = message.get("content") if isinstance(message, dict) else data.get("content")
    if isinstance(content, str):
        return bool(content.strip())
    return isinstance(content, list) and any(
        (isinstance(item, str) and item.strip())
        or (isinstance(item, dict) and item.get("type") == "text"
            and isinstance(item.get("text"), str) and item["text"].strip())
        for item in content)


def dsh_reason(reason):
    """kind, nested reason kind, failure code and message length of a turn/end or finish reason.
    Upstream messages can carry key prefixes, hosts and addresses, so only their length is printed."""
    if not isinstance(reason, dict):
        return "missing"
    text = str(reason.get("kind", "missing"))
    nested = reason.get("reason")
    if isinstance(nested, dict):
        text += f"({nested.get('kind', 'missing')})"
    failure = reason.get("failure", reason.get("error"))
    if isinstance(failure, dict) or reason.get("kind") == "error":
        failure = failure if isinstance(failure, dict) else {}
        code = failure.get("code")
        message = failure.get("message")
        text += " code=" + ("missing" if code is None else str(code))
        text += " message=" + (f"<{len(message)} chars>" if isinstance(message, str) else "missing")
    return text


def dsh_attempt_status(data):
    """Finish reason, token usage and stream size recorded by one assistant/attempt."""
    stream = data.get("stream")
    if not isinstance(stream, list):
        return "stream=missing"
    finish = usage = None
    for item in stream:
        chunk = item.get("chunk") if isinstance(item, dict) else None
        if isinstance(chunk, dict) and chunk.get("type") == "finish":
            finish = chunk.get("reason")
        elif isinstance(chunk, dict) and chunk.get("type") == "usage":
            usage = chunk.get("usage")
    tokens = (" ".join(f"{name}={usage.get(key, 'missing')}" for name, key in
                       (("in", "inputTokens"), ("out", "outputTokens"), ("total", "totalTokens")))
              if isinstance(usage, dict) else None)
    return (f"finish={dsh_reason(finish)}; " + (f"tokens {tokens}" if tokens else "tokens=missing")
            + f"; stream items={len(stream)}")


ANTIGRAVITY_TYPES = {"USER_INPUT", "PLANNER_RESPONSE", "GENERIC", "SYSTEM_MESSAGE", "CHECKPOINT", "ERROR_MESSAGE"}
AG_TIMING = re.compile(
    r'\A(?:Created At: ([^\r\n]+)\r?\n(?:Completed At: ([^\r\n]+)\r?\n)?)+')
AG_COMMAND_EXIT = re.compile(
    r'\A(?:(?:Created|Completed) At: [^\r\n]+\r?\n)*Command exited with code (-?\d+)\.')
AG_TASK_LAUNCH = re.compile(
    r'\A(?:(?:Created|Completed) At: [^\r\n]+\r?\n)*Tool is running as a background task with task id: ([^\r\n]+)')
AG_TASK_FINISH = re.compile(
    r'Task id "([^"]+)" finished with result:\r?\n(?:Command exited with code (-?\d+)\.)?')


def is_antigravity_record(record):
    return (isinstance(record.get("step_index"), int)
            and isinstance(record.get("type"), str)
            and "payload" not in record and "data" not in record
            and (record["type"] in ANTIGRAVITY_TYPES or isinstance(record.get("source"), str)))


def antigravity_decode_args(raw_args):
    """Unwrap Antigravity's JSON-encoded tool_calls[].args values without failing on plain strings."""
    if isinstance(raw_args, str):
        try:
            raw_args = json.loads(raw_args)
        except ValueError:
            return raw_args
    if not isinstance(raw_args, dict):
        return raw_args
    decoded = {}
    for key, value in raw_args.items():
        if isinstance(value, str):
            try:
                decoded[key] = json.loads(value)
            except ValueError:
                decoded[key] = value
        else:
            decoded[key] = value
    return decoded


def antigravity_duration_ms(text):
    match = AG_TIMING.match(text)
    if not match or not match.group(1) or not match.group(2):
        return None
    try:
        start = datetime.datetime.fromisoformat(match.group(1).strip().replace("Z", "+00:00"))
        end = datetime.datetime.fromisoformat(match.group(2).strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if not start.tzinfo or not end.tzinfo:
        return None
    delta = (end - start).total_seconds()
    return delta * 1000 if delta >= 0 else None


def antigravity_blocks(record):
    sort = record.get("type")
    content = record.get("content")
    text = content if isinstance(content, str) else render(content) if content is not None else ""
    if sort == "USER_INPUT":
        yield Block("user", "", text)
        return
    if sort == "PLANNER_RESPONSE":
        thinking = record.get("thinking")
        if isinstance(thinking, str) and thinking:
            yield Block("thinking", "", thinking)
        if text:
            yield Block("assistant", "", text)
        step_index = record.get("step_index")
        for index, call in enumerate(record.get("tool_calls") or []):
            if not isinstance(call, dict):
                continue
            args = antigravity_decode_args(call.get("args"))
            call_id = f"ag:{step_index}:{index}"
            yield Block("tool_call", call.get("name") or "", render(args), call_id,
                        data=args if isinstance(args, dict) else None)
        return
    if sort == "GENERIC":
        error = record.get("error")
        if not text and error is not None:
            text = render(error)
        status = record.get("status") or ""
        failed = status in ("ERROR", "INVALID")
        yield Block("tool_result", "", text, None, failed,
                    data={"antigravity_status": status, "duration_ms": antigravity_duration_ms(text)})
        return
    if sort in ("SYSTEM_MESSAGE", "CHECKPOINT", "ERROR_MESSAGE"):
        if not text and record.get("error") is not None:
            text = render(record.get("error"))
        yield Block("other", sort.lower(), text)


def blocks(record):
    if is_dsh_record(record):
        return dsh_blocks(record)
    if record.get("type") in KIMI_TYPES:
        return kimi_blocks(record)
    if "payload" in record:
        return codex_blocks(record)
    if is_antigravity_record(record):
        return antigravity_blocks(record)
    return claude_blocks(record)


def transcript_bytes(path):
    """Raw JSONL bytes. session.v4.jsonl.zstd is inflated with the stdlib zstd module."""
    data = Path(path).read_bytes()
    if str(path).endswith(".jsonl.zstd"):
        try:
            import compression.zstd as zstd
        except ImportError:
            fail(f"{path}: this Python has no compression.zstd; use Python 3.14 or newer")
        data = zstd.decompress(data)
    return data


def read_records(path):
    """(line number, record) for every JSON object line of a transcript."""
    for number, raw in enumerate(transcript_bytes(path).splitlines(), 1):
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        if isinstance(record, dict):
            yield number, record


def label(block):
    text = block.kind
    if block.name:
        text += " " + block.name
    return text + (" FAILED" if block.failed else "")


def title(data):
    """The latest Claude Code session title in a transcript's bytes, or ''."""
    for key in ("customTitle", "aiTitle"):
        at = data.rfind(f'"{key}":'.encode())
        if at < 0:
            continue
        end = data.find(b"\n", at)
        try:
            record = json.loads(data[data.rfind(b"\n", 0, at) + 1:end if end >= 0 else None])
        except ValueError:
            continue
        if isinstance(record, dict) and isinstance(record.get(key), str) and record[key].strip():
            return record[key].strip()
    return ""


def default_roots():
    claude = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    codex = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    kimi = Path.home() / ".kimi-code"
    dsh = Path(os.environ.get("DSH_HOME") or Path.home() / ".dsh") / "sessions"
    antigravity = Path(os.environ.get("ANTIGRAVITY_HOME") or Path.home() / ".gemini" / "antigravity") / "brain"
    return [root for root in (claude / "projects", codex / "sessions", codex / "archived_sessions",
                              kimi / "sessions", dsh, antigravity) if root.is_dir()]


BRIDGE_DIRECTORY_SUFFIX = "magpie-claude-work"


def is_bridge(path):
    """True for a path inside a Magpie bridge backend directory."""
    return any(part.lower().endswith(BRIDGE_DIRECTORY_SUFFIX) for part in Path(path).parts)


def record_span(lines):
    """(first, last) record moments of a transcript's raw lines, scanning in from each end, or (None, None)."""
    def first_moment(raws):
        for raw in raws:
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if isinstance(record, dict):
                moment = record_when(record)
                if moment:
                    return moment
        return None
    return first_moment(lines), first_moment(reversed(lines))


def span_text(first, last):
    if not first or not last:
        return ""
    start, end = first.astimezone(), last.astimezone()
    tail = end.strftime("%H:%M") if start.date() == end.date() else end.strftime("%Y-%m-%d %H:%M")
    return f", records {start:%Y-%m-%d %H:%M}..{tail}"


def transcript_files(paths, since):
    """(modified time, path) of each transcript; directories are walked and filtered by --since."""
    for path in paths:
        if path.is_file():
            yield path.stat().st_mtime, path
            continue
        for base, _dirs, names in os.walk(path):
            base_path = Path(base)
            if base_path.name == "logs" and base_path.parent.name == ".system_generated":
                if "chunks" in _dirs:
                    _dirs.remove("chunks")
                has_compact = "transcript.jsonl" in names
            else:
                has_compact = False
            for name in names:
                if has_compact and name == "transcript_full.jsonl":
                    continue
                if name.endswith(".jsonl") or name.endswith(".jsonl.zstd"):
                    file = Path(base, name)
                    try:
                        modified = file.stat().st_mtime
                    except OSError:
                        continue
                    if modified >= since:
                        yield modified, file


def snippet(text, at, width):
    start = max(0, at - width // 2)
    piece = " | ".join(text[start:start + width].splitlines())
    return ("..." if start else "") + piece + ("..." if start + width < len(text) else "")


def escaped(text, times, ascii_only=False):
    for _ in range(times):
        text = json.dumps(text, ensure_ascii=ascii_only)[1:-1]
    return text


def link_tool_search_result(block, pending):
    """Pair a tool_search result whose writer left call_id empty with the open call."""
    if block.kind == "tool_call":
        pending["call_id"] = block.call_id if block.name == "tool_search" and block.call_id else None
        return block
    call_id = pending.get("call_id")
    if (block.kind == "tool_result" and not block.call_id and call_id
            and len(block.text) <= 500 and "tool_search" in block.text):
        failed = block.failed or block.text.lstrip().startswith("failed to parse tool_search")
        pending["call_id"] = None
        return block._replace(call_id=call_id, failed=failed)
    return block


def cmd_find(args):
    paths = [Path(p) for p in args.paths] or default_roots()
    missing = [str(p) for p in paths if not p.exists()]
    if missing:
        fail("not found: " + ", ".join(missing))
    if args.to_line is not None and args.to_line < args.from_line:
        fail(f"--to-line {args.to_line} is before --from-line {args.from_line}")
    fold = (lambda s: s.translate(ASCII_LOWER)) if args.ignore_case else (lambda s: s)
    # A block's decoded text holds the needle as typed, or JSON-escaped inside code; a raw JSON line holds
    # either of those escaped once more, with or without \u escapes for non-ASCII.
    text_forms = list({fold(escaped(args.needle, times)) for times in (0, 1)})
    byte_forms = {fold(escaped(args.needle, times, ascii_only)).encode("utf-8")
                  for times in (0, 1, 2) for ascii_only in (False, True)}
    kinds = set(args.kind or KINDS[:-1])
    skips = [skip.lower() for skip in args.skip]
    since = args.since.timestamp() if args.since else 0
    files = sorted((modified, file) for modified, file in transcript_files(paths, since)
                   if not any(skip in str(file).lower() for skip in skips))
    bridged = 0
    if not args.bridge and not any(is_bridge(path) for path in paths):
        bridged = sum(1 for _modified, file in files if is_bridge(file))
        files = [(modified, file) for modified, file in files if not is_bridge(file)]
    head = (args.max_per_file + 1) // 2
    tail = args.max_per_file - head
    reports = []
    for modified, file in files:
        try:
            data = transcript_bytes(file)
        except OSError as error:
            print(f"skipped {file}: {error}", file=sys.stderr)
            continue
        probe = data.lower() if args.ignore_case else data
        if not any(form in probe for form in byte_forms):
            continue
        lines = data.split(b"\n")
        probes = probe.split(b"\n") if args.ignore_case else lines
        hits = []
        pending_tool_search = {"call_id": None}
        for number, (raw, low) in enumerate(zip(lines, probes), 1):
            if args.to_line is not None and number > args.to_line:
                break
            if number < args.from_line or not any(form in low for form in byte_forms):
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            for block in blocks(record):
                block = link_tool_search_result(block, pending_tool_search)
                if block.kind not in kinds:
                    continue
                text = fold(block.text)
                at = min((i for i in (text.find(form) for form in text_forms) if i >= 0), default=-1)
                if at >= 0:
                    hits.append((number, record, block, at))
        if not hits:
            continue
        first = hits[0][1]
        source = ("dsh" if is_dsh_record(first) else
                  "codex" if "payload" in first else
                  "kimi" if first.get("type") in KIMI_TYPES else
                  "antigravity" if is_antigravity_record(first) else "claude")
        stamp = datetime.datetime.fromtimestamp(modified).strftime("%Y-%m-%d %H:%M")
        name = title(data) if source == "claude" else ""
        if is_bridge(file):
            source += " bridge"
        span = span_text(*record_span(lines))
        total_lines = len(lines) - (0 if lines[-1] else 1)
        report = [f"=== {file}  ({source}, modified {stamp}{span}, {total_lines} lines, {len(hits)} hits"
                  f"{', ' + repr(name) if name else ''})"]
        shown = hits if len(hits) <= args.max_per_file else hits[:head] + (hits[-tail:] if tail else [])
        for number, record, block, at in shown:
            report.append(f"  L{number} {record_stamp(record)} {label(block)}: "
                          f"{snippet(block.text, at, args.width)}")
        if len(hits) > len(shown):
            report.append(f"  ... {len(hits) - len(shown)} more hits not shown (raise --max-per-file)")
        reports.append("\n".join(report))
    for report in reports[-args.max_files:]:
        print(report)
    hidden = max(0, len(reports) - args.max_files)
    print(f"{len(reports)} of {len(files)} transcripts matched"
          + (f"; the {hidden} oldest are not shown (raise --max-files)" if hidden else "")
          + (f"; {bridged} Magpie bridge backend copies not searched (add --bridge)" if bridged else ""))
    return 0 if reports else 1


def describe_call(block):
    text = block.text
    if isinstance(block.data, dict):
        for key in ("description", "command", "cmd", "CommandLine", "pattern", "file_path", "path", "Path",
                    "skill", "query", "Query", "url", "Role", "prompt", "Prompt", "target", "action", "Action",
                    "toolSummary"):
            if isinstance(block.data.get(key), str) and block.data[key].strip():
                text = block.data[key]
                break
    return " ".join(text.split())[:90]


def record_stamp(record):
    """Display timestamp of a record: ISO strings (timestamp/created_at) or Kimi Code epoch ms."""
    stamp = record.get("timestamp") or record.get("created_at")
    if isinstance(stamp, str):
        return stamp
    ms = record.get("time")
    if isinstance(ms, (int, float)):
        return datetime.datetime.fromtimestamp(ms / 1000).isoformat(timespec="seconds")
    return ""


def record_when(record):
    """Timezone-aware moment of a record, or None."""
    stamp = record.get("timestamp") or record.get("created_at")
    if isinstance(stamp, str):
        try:
            moment = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            return None
        return moment if moment.tzinfo else None
    ms = record.get("time")
    if isinstance(ms, (int, float)):
        return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).astimezone()
    return None


def size_sections(results, reads):
    """audit --sizes sections from (characters, line, tool, call) per result and (line, characters) per Read path."""
    total = sum(size for size, *_ in results)
    chars, counts = collections.Counter(), collections.Counter()
    for size, _number, name, _about in results:
        chars[name] += size
        counts[name] += 1
    repeated = sorted(((sum(size for _, size in hits), path, hits) for path, hits in reads.items() if len(hits) > 1),
                      reverse=True)
    return [
        (f"tool result characters: {total} in {len(results)} results",
         [f"{name}: {size} ({size * 100 // max(total, 1)}%), {counts[name]} results" for name, size in chars.most_common()]),
        ("largest tool results:",
         [f"L{number} {size:7} {name} [{about}]" for size, number, name, about in sorted(results, reverse=True)]),
        (f"files read more than once (Read tool): {len(repeated)}",
         [f"{size:7} x{len(hits)} {path}  L{hits[0][0]}..L{hits[-1][0]}" for size, path, hits in repeated]),
    ]


def expected_exit(value):
    match = re.fullmatch(r'([1-9]\d*):(-?\d+)', value)
    if not match or int(match.group(2)) == 0:
        raise argparse.ArgumentTypeError('expected RESULT_LINE:NONZERO_CODE')
    return int(match.group(1)), int(match.group(2))


def line_number(value):
    if not re.fullmatch(r'[1-9]\d*', value):
        raise argparse.ArgumentTypeError('expected a line number of 1 or more')
    return int(value)


def detail_limit(value, maximum):
    if not re.fullmatch(r'[1-9]\d*', value) or int(value) > maximum:
        raise argparse.ArgumentTypeError(f'expected an integer from 1 to {maximum}')
    return int(value)


def compact_detail(text, width):
    text = ' '.join(text.split())
    return text if len(text) <= width else text[:width] + f'... [{len(text) - width} chars omitted]'


def static_exec_reads(block):
    """Return literal read operands and whether a read-like exec could not be parsed.

    This is deliberately not a shell/JavaScript evaluator. Only quoted command
    properties and Get-Content/cat operands are supported. Other forms remain
    visible in the uncovered count instead of being guessed from a path mention.
    """
    if block.name.split('.')[-1] not in ('exec', 'exec_command', 'Bash', 'run_command'):
        return [], False
    commands = []
    if isinstance(block.data, dict):
        command = block.data.get('cmd', block.data.get('command', block.data.get('CommandLine')))
        if isinstance(command, str):
            commands.append(command)
    elif block.name.split('.')[-1] == 'exec':
        for match in re.finditer(r'\btools\.exec_command\s*\(\s*\{\s*(?:cmd|command)\s*:\s*("(?:\\.|[^"\\])*")', block.text):
            try:
                commands.append(json.loads(match.group(1)))
            except ValueError:
                pass
    paths = []
    uncovered = False
    for command in commands:
        segments, quote, escaped, start = [], None, False, 0
        for index, char in enumerate(command):
            if escaped:
                escaped = False
            elif char == '`' and quote != "'":
                escaped = True
            elif quote:
                if char == quote:
                    quote = None
            elif char in "'\"":
                quote = char
            elif char in ';|\n':
                segments.append(command[start:index])
                start = index + 1
        segments.append(command[start:])
        matches = []
        for segment in segments:
            match = re.match(r'(?i)^\s*(?:Get-Content|cat)\s+(?:-(?:LiteralPath|Path)\s+)?', segment)
            if match:
                matches.append((segment, match))
        for segment, match in matches:
            tail = segment[match.end():]
            found = 0
            while True:
                operand = re.match(r'''\s*(?:'([^']*)'|"([^"$`\r\n]*)"|([A-Za-z]:[/\\][^\s,;|]+))''', tail)
                if not operand:
                    break
                path = next(value for value in operand.groups() if value is not None)
                if not path or path.startswith('-'):
                    break
                paths.append(path.replace('\\', '/'))
                found += 1
                tail = tail[operand.end():]
                comma = re.match(r'\s*,\s*', tail)
                if not comma:
                    break
                tail = tail[comma.end():]
            uncovered = uncovered or not found
        if not matches and re.search(r'(?i)\b(?:Get-Content|cat|Select-String|rg|grep)\b', command):
            uncovered = True
    if not commands and re.search(r'(?i)\b(?:Get-Content|cat|Select-String|rg|grep)\b', block.text):
        uncovered = True
    return paths, uncovered


def cmd_audit(args):
    path = Path(args.file)
    if not path.is_file():
        fail(f"not found: {path}")
    if args.to_line is not None and args.to_line < args.from_line:
        fail(f"--to-line {args.to_line} is before --from-line {args.from_line}")
    calls, stamps, errors, slow, results = {}, [], [], [], []
    poll_keys, ordered_calls, gui_calls, mixed_calls = {}, {}, {}, {}
    active_pending, resolved = collections.defaultdict(list), []
    nonzero, reported, pending, unknown, expected = [], [], [], [], []
    api_errors = []
    repl_calls, unknown_details, unknown_repl_count = {}, [], 0
    expectations = set(args.expected_exit)
    used_expectations = set()
    exec_reads, unparsed_reads = collections.defaultdict(list), 0
    read_paths, reads = {}, collections.defaultdict(list)
    tools, kinds, others = collections.Counter(), collections.Counter(), collections.Counter()
    codex = kimi = dsh = antigravity = False
    pending_tool_search = {"call_id": None}
    ag_pending_calls = collections.deque()
    ag_known_tasks = set()
    dsh_observations = set()
    dsh_result_messages = set()
    dsh_arguments, dsh_known_jobs = {}, set()
    dsh_notices, dsh_notice_messages, notice_errors = set(), set(), []
    turn_bounds, open_turn, silent_turns, unpaired_turns, last_number = False, None, [], 0, 0
    for number, record in read_records(path):
        if args.to_line is not None and number > args.to_line:
            break
        last_number = number
        codex = codex or "payload" in record
        kimi = kimi or record.get("type") in KIMI_TYPES
        dsh = dsh or is_dsh_record(record)
        is_ag = is_antigravity_record(record)
        antigravity = antigravity or is_ag
        if is_ag and record.get("type") in ("PLANNER_RESPONSE", "USER_INPUT", "CHECKPOINT"):
            ag_pending_calls.clear()
        stamp = record_when(record)
        before_range = number < args.from_line
        if stamp and not before_range:
            stamps.append(stamp)
        surface_op = record.get("surfaceOp")
        if is_dsh_record(record) and not (isinstance(surface_op, dict) and surface_op.get("op") == "replace"):
            # A replace rewrites history; only new records move a turn toward or away from a reply.
            sort, data = record["type"], record["data"]
            if sort == "turn/start":
                turn_bounds = True
                if open_turn is not None and not before_range:
                    unpaired_turns += 1  # its turn/end never came before the next turn/start
                open_turn = {"turn": data.get("turn"), "start": number, "replied": False,
                             "attempt": None, "text": None, "input": None}
            elif sort == "turn/end" and (open_turn is None or data.get("turn") != open_turn["turn"]):
                if not before_range:
                    unpaired_turns += 1 + (open_turn is not None)
                open_turn = None
            elif open_turn is not None:
                if sort == "assistant/message" and dsh_has_reply_text(data):
                    open_turn["replied"], open_turn["text"] = True, number
                elif sort == "tool/result" or (sort == "user/message"
                                               and any(block.kind in ("user", "other") for block in dsh_blocks(record))):
                    # A tool result, user message or injected notice awaits a new reply.
                    open_turn["replied"], open_turn["input"] = False, number
                elif sort == "assistant/attempt":
                    open_turn["attempt"] = (number, data)
                elif sort == "turn/end":
                    reason = data.get("reason")
                    completed = isinstance(reason, dict) and reason.get("kind") == "completed"
                    if (not completed or not open_turn["replied"]) and not before_range:
                        row = (f"L{open_turn['start']}..L{number} turn {open_turn['turn']} "
                               f"end={dsh_reason(reason)}; last text "
                               + (f"L{open_turn['text']}" if open_turn["text"] else "missing")
                               + ", last result/message "
                               + (f"L{open_turn['input']}" if open_turn["input"] else "missing")
                               + "\n    last attempt")
                        if open_turn["attempt"]:
                            line, attempt = open_turn["attempt"]
                            row += f" L{line}"
                            if open_turn["input"] and line < open_turn["input"]:
                                row += f" (stale: before L{open_turn['input']})"
                            row += f": {dsh_attempt_status(attempt)}"
                        else:
                            row += ": missing (no assistant/attempt in turn)"
                        silent_turns.append(row)
                    open_turn = None
        for block in blocks(record):
            block = link_tool_search_result(block, pending_tool_search)
            if is_ag:
                if block.kind == "tool_call" and block.call_id:
                    ag_pending_calls.append(block.call_id)
                elif block.kind == "tool_result" and not block.call_id and ag_pending_calls:
                    block = block._replace(call_id=ag_pending_calls.popleft())
            if is_dsh_record(record) and block.call_id and block.kind in ("tool_call", "tool_result"):
                dsh_data = record["data"]
                if "turn" in dsh_data or "step" in dsh_data:
                    block = block._replace(call_id=(dsh_data.get("turn"), dsh_data.get("step"), block.call_id))
                message = dsh_data.get("message")
                message_id = message.get("id") if isinstance(message, dict) else None
                if block.kind == "tool_result" and message_id:
                    identity = (block.call_id, message_id)
                    surface_op = record.get("surfaceOp")
                    if (isinstance(surface_op, dict) and surface_op.get("op") == "replace"
                            and identity in dsh_result_messages):
                        # Historical message rewrites are not new execution completions.
                        continue
                    dsh_result_messages.add(identity)
                # Identical observations replay once within an execution; changed append
                # results remain new evidence even when they retain the message identity.
                observation = (block.kind, block.call_id, message_id, block.name, block.text, block.failed)
                if observation in dsh_observations:
                    continue
                dsh_observations.add(observation)
            if block.kind == "tool_call":
                if is_dsh_record(record) and block.call_id:
                    dsh_arguments[block.call_id] = block.data
                calls[block.call_id] = (block.name, describe_call(block), stamp, number)
                poll_keys[block.call_id] = async_call_slots(block)
                ordered_calls[block.call_id] = ordered_results(block)
                gui_calls[block.call_id] = repl_result(block)
                if args.unknown_details and block.call_id and gui_calls[block.call_id]:
                    repl_calls[block.call_id] = compact_detail(block.text, args.unknown_width)
                mixed_calls[block.call_id] = mixed_output_slots(block)
                if block.name in ("Read", "read", "read_file") and isinstance(block.data, dict):
                    read_path = block.data.get("file_path") or block.data.get("path") or block.data.get("Path")
                    if isinstance(read_path, str):
                        read_paths[block.call_id] = read_path
            ag_task_launch = None
            if is_ag and block.kind == "tool_result" and not block.failed:
                launch_match = AG_TASK_LAUNCH.match(block.text)
                if launch_match:
                    ag_task_launch = launch_match.group(1).strip()
                    ag_known_tasks.add(ag_task_launch)
            job_outcome, job_name = None, ''
            job_notice = is_dsh_record(record) and block.kind == 'other' and block.name == 'background-job notice'
            if is_dsh_record(record) and block.kind == 'tool_result' and not block.failed:
                job_name = calls.get(block.call_id, ('?',))[0]
                job_outcome = dsh_job_outcome(job_name, block.text, dsh_arguments.get(block.call_id))
                if job_outcome:
                    dsh_known_jobs.add(job_outcome[0])
            elif job_notice:
                message_id = record['data'].get('id')
                surface_op = record.get('surfaceOp')
                if message_id:
                    if (isinstance(surface_op, dict) and surface_op.get('op') == 'replace'
                            and message_id in dsh_notice_messages):
                        continue
                    dsh_notice_messages.add(message_id)
                identity = (message_id, block.text)
                if identity in dsh_notices:
                    continue
                dsh_notices.add(identity)
                job_name = 'background-job notice'
                job_outcome = dsh_job_notice(block.text)
                if job_outcome and job_outcome[0] not in dsh_known_jobs:
                    job_outcome = None
            if before_range:
                continue
            if job_outcome:
                job_id, state, code = job_outcome
                row = f'L{number} {job_name}: DSH job {job_id} status={state}'
                if code is not None:
                    row += f' exit_code={code}'
                key = ('dsh-job', job_id)
                if state in ('running', 'stopping'):
                    active_pending[key].append(row)
                else:
                    terminal = f'L{number} status={state}' + (f' exit_code={code}' if code is not None else '')
                    resolved.extend(f'{old} -> {terminal}' for old in active_pending.pop(key, []))
                if state in ('failed', 'killed') or code not in (None, 0):
                    (notice_errors if job_notice else errors).append(row)
                if code not in (None, 0):
                    if (number, code) in expectations:
                        expected.append(row)
                        used_expectations.add((number, code))
                    else:
                        nonzero.append(row)
            elif job_notice or job_name == 'job_output':
                unknown.append(f'L{number} {job_name}: unrecognized or uncorrelated DSH job result')
            kinds[block.kind] += 1
            if block.kind == "other":
                others[block.name] += 1
                if is_ag and block.name == "system_message":
                    for task_match in AG_TASK_FINISH.finditer(block.text):
                        task_id = task_match.group(1)
                        if task_id not in ag_known_tasks:
                            continue
                        code = int(task_match.group(2)) if task_match.group(2) is not None else None
                        terminal = f"L{number} " + (f"exit_code={code}" if code is not None else "completed")
                        resolved.extend(f"{old} -> {terminal}" for old in active_pending.pop(("ag-task", task_id), []))
                        if code not in (None, 0):
                            row = f"L{number} system_message: background task {task_id} exit_code={code}"
                            if (number, code) in expectations:
                                expected.append(row)
                                used_expectations.add((number, code))
                            else:
                                nonzero.append(row)
                if block.name == "system api_error":
                    # The record has no text for find to match, so its line is listed for a retro to cite.
                    attempt, limit = record.get("retryAttempt"), record.get("maxRetries")
                    retry = f" attempt {attempt}/{limit}" if isinstance(attempt, int) and isinstance(limit, int) else ""
                    api_errors.append(f"L{number} {record_stamp(record)}{retry}")
            elif block.kind == "tool_call":
                tools[block.name] += 1
                if args.sizes:
                    paths, uncovered = static_exec_reads(block)
                    for read_path in paths:
                        exec_reads[read_path].append(number)
                    unparsed_reads += int(uncovered)
            elif block.kind == "tool_result":
                name, about, start, origin = calls.get(block.call_id, ("?", "", None, 0))
                results.append((len(block.text), number, name, about))
                if block.call_id in read_paths:
                    reads[read_paths[block.call_id]].append((number, len(block.text)))
                # Error-like text is evidence only for tools that execute or install;
                # document reads and fetched pages may legitimately quote those tokens.
                failed = block.failed or (is_dsh_record(record) and not job_outcome
                                          and name in DSH_TEXT_FAILURE_TOOLS and dsh_failed(block.text))
                if failed:
                    errors.append(f"L{number} {record_stamp(record)} {name} [{about}] "
                                  f"{' '.join(block.text.split())[:args.width]}")
                if is_ag and ag_task_launch:
                    active_pending[("ag-task", ag_task_launch)].append(
                        f"L{number} {name}: background task {ag_task_launch}")
                elif is_ag and name == "run_command" and not failed:
                    exit_match = AG_COMMAND_EXIT.match(block.text)
                    if exit_match:
                        code = int(exit_match.group(1))
                        if code != 0:
                            row = f"L{number} {name}: exit_code={code} [{about}]"
                            if (number, code) in expectations:
                                expected.append(row)
                                used_expectations.add((number, code))
                            else:
                                nonzero.append(row)
                if isinstance(block.data, dict) and 'outcomes' in block.data:
                    slots = poll_keys.get(block.call_id, {})
                    outcomes = codex_outcomes(block.text, slots, ordered_calls.get(block.call_id, False),
                                              gui_calls.get(block.call_id, False),
                                              mixed_calls.get(block.call_id), block.data.get('parts'))
                    hints = {value for value in slots.values() if value is not None}
                    terminals = [o for o in outcomes if o[0] in ('success', 'nonzero') and o[2] == 'process']
                    for status, code, source, key in outcomes:
                        direct_poll = name.rsplit('.', 1)[-1] in ('write_stdin', 'wait')
                        if (key is None and source == 'process' and direct_poll
                                and len(terminals) == 1 and len(slots) == 1 and len(hints) == 1):
                            hint = next(iter(hints))
                            if hint[0] == 'process':
                                key = hint
                        row = f"L{number} {name}: {source}" + (f" exit_code={code}" if code is not None else '')
                        if status in ('success', 'nonzero') and key in active_pending:
                            resolved.extend(f"{old} -> L{number} exit_code={code}" for old in active_pending.pop(key))
                        if status in ('nonzero', 'reported') and (number, code) in expectations:
                            expected.append(row)
                            used_expectations.add((number, code))
                        elif status == 'nonzero':
                            nonzero.append(row)
                        elif status == 'reported':
                            reported.append(row)
                        elif status == 'pending':
                            if key:
                                active_pending[key].append(row)
                            else:
                                pending.append(row)
                        elif status == 'unknown' and not block.failed:
                            unknown.append(row)
                        elif status == 'failure' and not block.failed:
                            errors.append(row)
                    if (args.unknown_details and block.call_id in repl_calls and not block.failed
                            and any(outcome[0] == 'unknown' for outcome in outcomes)):
                        unknown_repl_count += 1
                        if len(unknown_details) < args.unknown_max:
                            body = re.sub(
                                r'\A(?:Wall time: [^\r\n]+|Script completed(?:\r?\nWall time[^\r\n]+)?)\r?\nOutput:\r?\n',
                                '', block.text, count=1)
                            unknown_details.append((origin, number, name, repl_calls[block.call_id],
                                                    compact_detail(body, args.unknown_width)))
                    # wait 的完成只关闭编排单元，内部进程仍按自己的 session_id 对账。
                    if block.text.lstrip().startswith(('Script completed', 'Script failed')) and len(hints) == 1:
                        key = next(iter(hints))
                        if key[0] == 'cell':
                            resolved.extend(f"{old} -> L{number} cell completed" for old in active_pending.pop(key, []))
                duration = (block.data if isinstance(block.data, (int, float)) else
                            block.data.get("duration_ms") if isinstance(block.data, dict)
                            and isinstance(block.data.get("duration_ms"), (int, float)) else None)
                if duration is not None:  # Kimi Code durationMs or Antigravity Created At..Completed At
                    if duration / 1000 > args.slow:
                        slow.append(f"L{origin} {duration / 1000:7.0f}s {name} [{about}]")
                elif start and stamp and (stamp - start).total_seconds() > args.slow:
                    slow.append(f"L{origin} {(stamp - start).total_seconds():7.0f}s {name} [{about}]")
    pending.extend(row for rows in active_pending.values() for row in rows)
    data = transcript_bytes(path)
    session_title = "" if codex or kimi or dsh or antigravity else title(data)
    total_lines = len(data.splitlines())
    last_line = total_lines if args.to_line is None else min(args.to_line, total_lines)
    ranged = args.from_line > 1 or args.to_line is not None
    print(f"lines: L{args.from_line}..L{last_line}" + (f" of L1..L{total_lines}" if ranged else ""))
    if stamps:
        print(f"span: {min(stamps).isoformat()} .. {max(stamps).isoformat()}"
              + (f"  {session_title!r}" if session_title else ""))
    print("blocks: " + ", ".join(f"{kind}={kinds[kind]}" for kind in KINDS if kinds[kind]))
    print("other: " + ", ".join(f"{name}={count}" for name, count in others.most_common()))
    print("tool calls: " + ", ".join(f"{name}={count}" for name, count in tools.most_common()))
    sections = [(f"failed tool results: {len(errors)}", errors),
                (f"failed background job notices: {len(notice_errors)}", notice_errors),
                (f"nonzero exits requiring review: {len(nonzero)}", nonzero),
                (f"reported nonzero outcomes (unclassified): {len(reported)}", reported),
                (f"expected nonzero exits (operator annotations): {len(expected)}", expected),
                (f"pending observations (may finish in a later result): {len(pending)}", pending),
                (f"resolved asynchronous observations: {len(resolved)}", resolved),
                (f"unclassified result formats: {len(unknown)}", unknown),
                (f"slow calls (over {args.slow:g}s): {len(slow)}", slow)]
    if api_errors:
        sections.insert(1, (f"API error records: {len(api_errors)}", api_errors))
    if turn_bounds:
        if open_turn is not None and last_number >= args.from_line:
            unpaired_turns += 1  # still open at the end of the range
        footer = [f"unpaired turns not judged: {unpaired_turns} (turn/start without its turn/end in range, "
                  "or turn/end without its turn/start)"]
        if silent_turns:
            footer.append("messages print as their length only; read a whole record with: show FILE LINE")
        sections.append((f"turns that ended without a final assistant reply "
                         f"(explicit turn/start..turn/end): {len(silent_turns)}", silent_turns, footer))
    print('Result coverage: explicit failures, nonzero exits, pending and unclassified results are separate; zero failures is not a clean-run verdict.')
    if args.sizes:
        sections += size_sections(results, reads)
        repeated = sorted((path, lines) for path, lines in exec_reads.items() if len(lines) > 1)
        sections += [
            (f"files read more than once (static exec reads): {len(repeated)}",
             [f"x{len(lines)} {path}  L{lines[0]}..L{lines[-1]} (per-file result characters unavailable)" for path, lines in repeated]),
            (f"exec read calls not statically parsed: {unparsed_reads}", []),
        ]
    unused = sorted(expectations - used_expectations)
    if unused:
        sections.append((f"unmatched expected-exit annotations: {len(unused)}",
                         [f"L{line} exit_code={code}" for line, code in unused]))
    for heading, rows, *footer in sections:
        print("\n" + heading)
        for row in rows[:args.max]:
            print("  " + row)
        if len(rows) > args.max:
            print(f"  ... {len(rows) - args.max} more")
        for line in (footer[0] if footer else []):
            print("  " + line)
    if args.unknown_details:
        print(f'\nunclassified REPL details: {unknown_repl_count}')
        for origin, number, name, call_summary, result_summary in unknown_details:
            print(f'  L{origin} -> L{number} {name}')
            print(f'    call: {call_summary}')
            print(f'    result: {result_summary}')
        if unknown_repl_count > len(unknown_details):
            print(f'  ... {unknown_repl_count - len(unknown_details)} more (raise --unknown-max)')
    return 0


def cmd_show(args):
    path = Path(args.file)
    if not path.is_file():
        fail(f"not found: {path}")
    pattern = re.compile(args.grep) if args.grep else None
    for number, record in read_records(path):
        if number != args.line:
            continue
        found = list(blocks(record))
        if not found:
            print(f"--- L{number} {record.get('type', '')}: no conversation blocks")
        for block in found:
            print(f"--- L{number} {record_stamp(record)} {label(block)}")
            lines = block.text.splitlines()
            if pattern:
                lines = [line for line in lines if pattern.search(line)]
            for line in lines[:args.max]:
                if len(line) > args.max_chars:
                    print(line[:args.max_chars] + f"... [{len(line) - args.max_chars} chars omitted]")
                else:
                    print(line)
            if len(lines) > args.max:
                print(f"... {len(lines) - args.max} more lines (raise --max)")
        return 0
    fail(f"line {args.line} is not a JSON record in {path}")


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    find = commands.add_parser("find", help="which transcripts mention a fixed string")
    find.add_argument("needle")
    find.add_argument("paths", nargs="*", help="transcript files or directories (default: Claude and Codex session roots)")
    find.add_argument("--since", type=datetime.datetime.fromisoformat,
                      help="skip files in walked directories last modified before this date, YYYY-MM-DD")
    find.add_argument("--kind", action="append", choices=KINDS, help="only blocks of this kind; repeatable")
    find.add_argument("--skip", action="append", default=[],
                      help="skip files whose path contains this text, such as the current session id; repeatable")
    find.add_argument("--bridge", action="store_true",
                      help="also search Magpie bridge backend copies in walked *magpie-claude-work directories")
    find.add_argument("-i", "--ignore-case", action="store_true", help="fold ASCII letter case")
    find.add_argument("--width", type=int, default=240, help="snippet characters")
    find.add_argument("--max-per-file", type=int, default=6, help="hits shown per file, split between first and last")
    find.add_argument("--max-files", type=int, default=20, help="matching transcripts shown, newest kept")
    find.add_argument("--from-line", type=line_number, default=1,
                      help="only hits on this line and later of each transcript, such as after the last retro")
    find.add_argument("--to-line", type=line_number, help="only hits on this line and earlier of each transcript")

    audit = commands.add_parser("audit", help="span, block counts, tool calls, failed results and slow calls of one transcript")
    audit.add_argument("file")
    audit.add_argument("--slow", type=float, default=60, help="seconds from tool call to its result")
    audit.add_argument("--width", type=int, default=170, help="characters of each failed result; turn and attempt messages print only their length")
    audit.add_argument("--max", type=int, default=40, help="rows per section")
    audit.add_argument("--sizes", action="store_true",
                       help="add tool-result characters per tool, the largest results and files read more than once")
    audit.add_argument("--expected-exit", action="append", type=expected_exit, default=[],
                       help="annotate a known expected nonzero at RESULT_LINE:CODE; repeatable, unmatched annotations are shown")
    audit.add_argument("--from-line", type=line_number, default=1, help="count only records on this line and later")
    audit.add_argument("--to-line", type=line_number, help="count only records on this line and earlier")
    audit.add_argument("--unknown-details", action="store_true",
                       help="pair unclassified REPL results with their calls; classification stays unchanged")
    audit.add_argument("--unknown-max", type=lambda value: detail_limit(value, 40), default=5,
                       help="maximum REPL detail pairs, 1..40 (default: 5)")
    audit.add_argument("--unknown-width", type=lambda value: detail_limit(value, 400), default=170,
                       help="characters per REPL call/result summary, 1..400 (default: 170)")

    show = commands.add_parser("show", help="text of one record")
    show.add_argument("file")
    show.add_argument("line", type=int)
    show.add_argument("--grep", help="only lines matching this regex")
    show.add_argument("--max-chars", type=line_number, default=1000, help="maximum characters per displayed line")
    show.add_argument("--max", type=int, default=80, help="lines per block")

    args = parser.parse_args()
    sys.exit({"find": cmd_find, "audit": cmd_audit, "show": cmd_show}[args.command](args))


if __name__ == "__main__":
    main()
