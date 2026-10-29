"""Search and audit agent session transcripts (Claude Code, Codex and Kimi Code JSONL logs). Reads only.

  transcripts.py find NEEDLE [PATH ...] [--since DATE] [--kind KIND] [--skip TEXT] [-i]
  transcripts.py audit FILE [--slow SECONDS] [--sizes] [--expected-exit RESULT_LINE:CODE] [--from-line N] [--to-line M]
  transcripts.py show FILE LINE [--grep REGEX]

find   which transcripts mention a fixed string, newest last, with a timestamped snippet per hit
audit  one transcript's span, block counts, tool-call counts, failed tool results and slow calls;
       --sizes adds tool-result characters per tool, the largest results and files read more than once;
       --from-line and --to-line count only records on lines N..M, such as the turns since an earlier
       audit, and a result in range still names its call from before N
show   the text of one record (a line number printed by find or audit), optionally only lines matching a regex

PATH is a transcript file or a directory walked for *.jsonl. Without PATH, find walks
$CLAUDE_CONFIG_DIR/projects (default ~/.claude/projects), $CODEX_HOME/sessions and
$CODEX_HOME/archived_sessions (default ~/.codex), and ~/.kimi-code/sessions. A Claude Code
session's subagents log to <session-id>/subagents/*.jsonl beside its transcript; a Kimi Code
session logs each of its agents to agents/<id>/wire.jsonl under the session directory.

Each record splits into blocks of one kind:
  user, assistant, thinking, tool_call, tool_result
  other    compaction summaries, injected meta messages, system notes and API errors, messages from other agents
  context  system prompt, AGENTS.md and CLAUDE.md text, environment, tool and skill text; find skips it unless --kind context
Claude Code api-request-blob records repeat what was sent to the API and yield no blocks, so nothing counts twice.
Codex exec transport exits, named stdout command reports, pending observations and unknown formats
are listed separately. A nonzero exit needs review; --expected-exit explicitly annotates its result
line and code. Reported stdout observations are not proof that the enclosing tool failed.
--sizes also recognizes literal Get-Content/cat paths in exec calls; dynamic commands stay unparsed.
Static exec reads count requested path occurrences, not successful reads or per-file output bytes.
find matches decoded text, so a Windows path matches as typed; it also tries the needle with JSON string
escapes, which code inside a tool call keeps.

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
EXIT_LINE = re.compile(r"(?im)^(?:exit code:?|process exited with code)\s*(-?\d+)")
ASCII_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)

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


def codex_outcomes(text):
    """Recognize transport envelopes; never search arbitrary stdout for exit_code text.

    Named command-result arrays in stdout are reported observations, not transport
    results. Their meaning remains unclassified until the operator reviews them.
    """
    outcomes = []
    body = re.split(r'\r?\nOutput:\r?\n', text, maxsplit=1)[-1].strip()
    decoder = json.JSONDecoder()
    values = []
    while body:
        try:
            value, end = decoder.raw_decode(body)
        except ValueError:
            break
        values.append(value)
        body = body[end:].lstrip()

    def walk(value):
        if isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, dict):
            if value.get('status') == 'fulfilled' and 'value' in value:
                walk(value['value'])
            elif value.get('status') == 'rejected' and 'reason' in value:
                outcomes.append(('failure', None, 'rejected tool promise'))
            elif type(value.get('isError')) is bool and isinstance(value.get('content'), list):
                outcomes.append(('failure' if value['isError'] else 'success', None, 'MCP tool result'))
            elif isinstance(value.get('output'), str) and (
                    isinstance(value.get('chunk_id'), str) or
                    isinstance(value.get('wall_time_seconds'), (int, float))):
                code = value.get('exit_code')
                if type(code) is int:
                    outcomes.append(('success' if code == 0 else 'nonzero', code, 'process'))
                elif type(value.get('session_id')) is int:
                    outcomes.append(('pending', None, 'running process'))
                else:
                    outcomes.append(('unknown', None, 'transport without final exit'))
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
                            outcomes.append(('reported', row['exit_code'], 'named command report'))

    for value in values:
        walk(value)
    if text.lstrip().lower().startswith('script running with cell id'):
        outcomes.append(('pending', None, 'running orchestration cell'))
    if not outcomes:
        codes = [int(code) for code in EXIT_LINE.findall(text)]
        outcomes.extend(('success' if code == 0 else 'nonzero', code, 'process') for code in codes)
    if not outcomes:
        outcomes.append(('unknown', None, 'unrecognized result format'))
    return outcomes


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
                    data={"outcomes": codex_outcomes(text)})
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


def blocks(record):
    if record.get("type") in KIMI_TYPES:
        return kimi_blocks(record)
    return codex_blocks(record) if "payload" in record else claude_blocks(record)


def read_records(path):
    """(line number, record) for every JSON object line of a transcript."""
    with open(path, "rb") as handle:
        for number, raw in enumerate(handle, 1):
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
    return [root for root in (claude / "projects", codex / "sessions", codex / "archived_sessions",
                              kimi / "sessions") if root.is_dir()]


def transcript_files(paths, since):
    """(modified time, path) of each transcript; directories are walked and filtered by --since."""
    for path in paths:
        if path.is_file():
            yield path.stat().st_mtime, path
            continue
        for base, _dirs, names in os.walk(path):
            for name in names:
                if name.endswith(".jsonl"):
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


def cmd_find(args):
    paths = [Path(p) for p in args.paths] or default_roots()
    missing = [str(p) for p in paths if not p.exists()]
    if missing:
        fail("not found: " + ", ".join(missing))
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
    head = (args.max_per_file + 1) // 2
    tail = args.max_per_file - head
    reports = []
    for modified, file in files:
        try:
            data = file.read_bytes()
        except OSError as error:
            print(f"skipped {file}: {error}", file=sys.stderr)
            continue
        probe = data.lower() if args.ignore_case else data
        if not any(form in probe for form in byte_forms):
            continue
        lines = data.split(b"\n")
        probes = probe.split(b"\n") if args.ignore_case else lines
        hits = []
        for number, (raw, low) in enumerate(zip(lines, probes), 1):
            if not any(form in low for form in byte_forms):
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            for block in blocks(record):
                if block.kind not in kinds:
                    continue
                text = fold(block.text)
                at = min((i for i in (text.find(form) for form in text_forms) if i >= 0), default=-1)
                if at >= 0:
                    hits.append((number, record, block, at))
        if not hits:
            continue
        first = hits[0][1]
        source = "codex" if "payload" in first else "kimi" if first.get("type") in KIMI_TYPES else "claude"
        stamp = datetime.datetime.fromtimestamp(modified).strftime("%Y-%m-%d %H:%M")
        name = title(data) if source == "claude" else ""
        report = [f"=== {file}  ({source}, modified {stamp}, {len(hits)} hits{', ' + repr(name) if name else ''})"]
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
          + (f"; the {hidden} oldest are not shown (raise --max-files)" if hidden else ""))
    return 0 if reports else 1


def describe_call(block):
    text = block.text
    if isinstance(block.data, dict):
        for key in ("description", "command", "cmd", "pattern", "file_path", "path", "skill", "query", "url", "prompt"):
            if isinstance(block.data.get(key), str) and block.data[key].strip():
                text = block.data[key]
                break
    return " ".join(text.split())[:90]


def record_stamp(record):
    """Display timestamp of a record: Claude Code and Codex keep their ISO string, Kimi Code logs epoch ms."""
    stamp = record.get("timestamp")
    if isinstance(stamp, str):
        return stamp
    ms = record.get("time")
    if isinstance(ms, (int, float)):
        return datetime.datetime.fromtimestamp(ms / 1000).isoformat(timespec="seconds")
    return ""


def record_when(record):
    """Timezone-aware moment of a record, or None."""
    stamp = record.get("timestamp")
    if isinstance(stamp, str):
        try:
            moment = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError:
            return None
        return moment if moment.tzinfo else None
    ms = record.get("time")
    if isinstance(ms, (int, float)):
        return datetime.datetime.fromtimestamp(ms / 1000).astimezone()
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


def static_exec_reads(block):
    """Return literal read operands and whether a read-like exec could not be parsed.

    This is deliberately not a shell/JavaScript evaluator. Only quoted command
    properties and Get-Content/cat operands are supported. Other forms remain
    visible in the uncovered count instead of being guessed from a path mention.
    """
    if block.name.split('.')[-1] not in ('exec', 'exec_command', 'Bash'):
        return [], False
    commands = []
    if isinstance(block.data, dict):
        command = block.data.get('cmd', block.data.get('command'))
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
    nonzero, reported, pending, unknown, expected = [], [], [], [], []
    expectations = set(args.expected_exit)
    used_expectations = set()
    exec_reads, unparsed_reads = collections.defaultdict(list), 0
    read_paths, reads = {}, collections.defaultdict(list)
    tools, kinds, others = collections.Counter(), collections.Counter(), collections.Counter()
    codex = kimi = False
    for number, record in read_records(path):
        if args.to_line is not None and number > args.to_line:
            break
        codex = codex or "payload" in record
        kimi = kimi or record.get("type") in KIMI_TYPES
        stamp = record_when(record)
        before_range = number < args.from_line
        if stamp and not before_range:
            stamps.append(stamp)
        for block in blocks(record):
            if block.kind == "tool_call":
                calls[block.call_id] = (block.name, describe_call(block), stamp, number)
                if block.name == "Read" and isinstance(block.data, dict):
                    read_path = block.data.get("file_path") or block.data.get("path")
                    if isinstance(read_path, str):
                        read_paths[block.call_id] = read_path
            if before_range:
                continue
            kinds[block.kind] += 1
            if block.kind == "other":
                others[block.name] += 1
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
                if block.failed:
                    errors.append(f"L{number} {record_stamp(record)} {name} [{about}] "
                                  f"{' '.join(block.text.split())[:args.width]}")
                if isinstance(block.data, dict) and 'outcomes' in block.data:
                    for status, code, source in block.data['outcomes']:
                        row = f"L{number} {name}: {source}" + (f" exit_code={code}" if code is not None else '')
                        if status in ('nonzero', 'reported') and (number, code) in expectations:
                            expected.append(row)
                            used_expectations.add((number, code))
                        elif status == 'nonzero':
                            nonzero.append(row)
                        elif status == 'reported':
                            reported.append(row)
                        elif status == 'pending':
                            pending.append(row)
                        elif status == 'unknown' and not block.failed:
                            unknown.append(row)
                        elif status == 'failure' and not block.failed:
                            errors.append(row)
                duration = block.data if isinstance(block.data, (int, float)) else None
                if duration is not None:  # Kimi Code reports the tool's own durationMs
                    if duration / 1000 > args.slow:
                        slow.append(f"L{origin} {duration / 1000:7.0f}s {name} [{about}]")
                elif start and stamp and (stamp - start).total_seconds() > args.slow:
                    slow.append(f"L{origin} {(stamp - start).total_seconds():7.0f}s {name} [{about}]")
    session_title = "" if codex or kimi else title(path.read_bytes())
    if args.from_line > 1 or args.to_line is not None:
        print(f"lines: L{args.from_line}..{'end' if args.to_line is None else f'L{args.to_line}'}")
    if stamps:
        print(f"span: {min(stamps).isoformat()} .. {max(stamps).isoformat()}"
              + (f"  {session_title!r}" if session_title else ""))
    print("blocks: " + ", ".join(f"{kind}={kinds[kind]}" for kind in KINDS if kinds[kind]))
    print("other: " + ", ".join(f"{name}={count}" for name, count in others.most_common()))
    print("tool calls: " + ", ".join(f"{name}={count}" for name, count in tools.most_common()))
    sections = [(f"failed tool results: {len(errors)}", errors),
                (f"nonzero exits requiring review: {len(nonzero)}", nonzero),
                (f"reported nonzero outcomes (unclassified): {len(reported)}", reported),
                (f"expected nonzero exits (operator annotations): {len(expected)}", expected),
                (f"pending observations (may finish in a later result): {len(pending)}", pending),
                (f"unclassified result formats: {len(unknown)}", unknown),
                (f"slow calls (over {args.slow:g}s): {len(slow)}", slow)]
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
    for heading, rows in sections:
        print("\n" + heading)
        for row in rows[:args.max]:
            print("  " + row)
        if len(rows) > args.max:
            print(f"  ... {len(rows) - args.max} more")
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
    find.add_argument("-i", "--ignore-case", action="store_true", help="fold ASCII letter case")
    find.add_argument("--width", type=int, default=240, help="snippet characters")
    find.add_argument("--max-per-file", type=int, default=6, help="hits shown per file, split between first and last")
    find.add_argument("--max-files", type=int, default=20, help="matching transcripts shown, newest kept")

    audit = commands.add_parser("audit", help="span, block counts, tool calls, failed results and slow calls of one transcript")
    audit.add_argument("file")
    audit.add_argument("--slow", type=float, default=60, help="seconds from tool call to its result")
    audit.add_argument("--width", type=int, default=170, help="characters of each failed result")
    audit.add_argument("--max", type=int, default=40, help="rows per section")
    audit.add_argument("--sizes", action="store_true",
                       help="add tool-result characters per tool, the largest results and files read more than once")
    audit.add_argument("--expected-exit", action="append", type=expected_exit, default=[],
                       help="annotate a known expected nonzero at RESULT_LINE:CODE; repeatable, unmatched annotations are shown")
    audit.add_argument("--from-line", type=line_number, default=1, help="count only records on this line and later")
    audit.add_argument("--to-line", type=line_number, help="count only records on this line and earlier")

    show = commands.add_parser("show", help="text of one record")
    show.add_argument("file")
    show.add_argument("line", type=int)
    show.add_argument("--grep", help="only lines matching this regex")
    show.add_argument("--max", type=int, default=80, help="lines per block")

    args = parser.parse_args()
    sys.exit({"find": cmd_find, "audit": cmd_audit, "show": cmd_show}[args.command](args))


if __name__ == "__main__":
    main()
