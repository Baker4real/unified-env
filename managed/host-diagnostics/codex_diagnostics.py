"""Bounded, read-only Codex diagnostics. Python 3.11+, standard library only."""
import argparse
import hashlib
import json
import ntpath
import os
from pathlib import Path
import re
import queue
import sqlite3
import subprocess
import threading
import time
import tomllib
import uuid
from urllib.parse import urlsplit, urlunsplit


class DiagnosticError(Exception):
    """Only fixed reason codes cross the diagnostic output boundary."""


def config_hash(home):
    return hashlib.sha256((Path(home) / 'config.toml').read_bytes()).hexdigest()


def endpoint(value):
    if not value:
        return None
    parsed = urlsplit(value)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        raise DiagnosticError('invalid-endpoint')
    host = parsed.hostname
    if ':' in host:
        host = '[' + host + ']'
    if parsed.port:
        host += ':' + str(parsed.port)
    return urlunsplit((parsed.scheme, host, parsed.path, '', ''))


def path_key(value):
    return ntpath.normcase(ntpath.normpath(value or ''))


def desktop_backend(inventory):
    """Accept a registered Codex app's interactive child, including its cache CLI."""
    roots = [p['root'] for p in inventory.get('packages', []) if p.get('family') == 'OpenAI.Codex_2p2nqsd0c76g0']
    processes = inventory.get('processes', [])
    parents = {p['pid']: p for p in processes}
    gui_paths = {path_key(ntpath.join(root, 'app/ChatGPT.exe')) for root in roots}
    cli_paths = {path_key(ntpath.join(root, 'app/resources/codex.exe')) for root in roots}
    cache_root = path_key(ntpath.join(inventory['localAppData'], 'OpenAI/Codex/bin'))
    candidates = []
    for proc in processes:
        parent = parents.get(proc.get('parent'), {})
        if path_key(parent.get('path', '')) not in gui_paths or proc.get('session', 0) <= 0 or proc['session'] != parent.get('session'):
            continue
        if not (0 < parent.get('started', 0) <= proc.get('started', 0)):
            continue
        actual = path_key(proc['path'])
        cached = actual.startswith(cache_root + '\\') and re.fullmatch(r'[0-9a-f]{16,64}\\codex\.exe', actual[len(cache_root) + 1:])
        if actual in cli_paths or cached:
            candidates.append({k: proc[k] for k in ('pid', 'parent', 'session', 'started', 'path')})
    if len(candidates) != 1:
        raise DiagnosticError('desktop-missing-or-ambiguous')
    return candidates[0]


def snapshot(home, inventory, profile=None):
    home = Path(home)
    raw = (home / 'config.toml').read_bytes()
    config = tomllib.loads(raw.decode('utf-8-sig'))
    profile = profile or config.get('profile')
    if profile:
        overlay = config.get('profiles', {}).get(profile)
        if not isinstance(overlay, dict):
            raise DiagnosticError('profile-not-found')
        config = config | overlay
    provider = config.get('model_provider', 'openai')
    settings = config.get('model_providers', {}).get(provider, {})
    url = settings.get('base_url') if provider != 'openai' else config.get('openai_base_url')
    result = dict(provider=provider, model=config.get('model'), profile=profile, endpoint=endpoint(url),
                  login_mode=('builtin-account' if provider == 'openai' else 'unknown'),
                  requires_openai_auth=settings.get('requires_openai_auth', False),
                  untrusted_as_tool_output=config.get('features', {}).get('untrusted_as_tool_output', True),
                  config_sha256=hashlib.sha256(raw).hexdigest(),
                  config_modified=(home / 'config.toml').stat().st_mtime,
                  backend=desktop_backend(inventory))
    if not isinstance(result['model'], str) or not result['model']:
        raise DiagnosticError('model-not-explicit')
    return result


def magpie_login_mode(executable):
    result = subprocess.run([str(executable), 'codex', 'login'], capture_output=True, text=True, encoding='utf-8', timeout=8)
    modes = re.findall(r'\b(?:api|companion|chatgpt)\b', result.stdout.lower())
    if result.returncode or len(result.stdout) > 1000 or len(modes) != 1:
        raise DiagnosticError('magpie-login-unavailable')
    return modes[0]


def collect_inventory():
    script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$packages = @(Get-AppxPackage -Name OpenAI.Codex | ForEach-Object { @{family=$_.PackageFamilyName;root=$_.InstallLocation} })
$processes = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe' OR Name='ChatGPT.exe'" | ForEach-Object {
    @{pid=$_.ProcessId;parent=$_.ParentProcessId;session=$_.SessionId;path=$_.ExecutablePath;started=([DateTimeOffset]$_.CreationDate).ToUnixTimeMilliseconds()/1000.0}
})
@{packages=$packages;processes=$processes;localAppData=$env:LOCALAPPDATA} | ConvertTo-Json -Depth 5 -Compress
'''
    proc = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-Command', script], capture_output=True, encoding='utf-8', timeout=20)
    if proc.returncode:
        raise DiagnosticError('inventory-failed')
    return json.loads(proc.stdout)



def desktop_status(home, observed, previous_pid=None, expected_hash=None):
    """Verify reload evidence without stopping any process or changing history."""
    failures = []
    backend = observed['backend']
    if previous_pid == backend['pid']:
        failures.append('backend-not-restarted')
    if backend['started'] <= observed['config_modified']:
        failures.append('backend-predates-config')
    current_hash = config_hash(home)
    if current_hash != observed['config_sha256'] or (expected_hash and current_hash != expected_hash):
        failures.append('config-changed')
    db_path = Path(home) / 'thread_history_1.sqlite'
    current, stale = None, None
    try:
        with sqlite3.connect(db_path.as_uri() + '?mode=ro', uri=True, timeout=2) as db:
            rows = db.execute("select started_at from thread_turns where completed_at is null and status = 'inProgress'").fetchall()
            current = sum(start >= int(backend['started']) for (start,) in rows)
            stale = len(rows) - current
            if current:
                failures.append('current-turn-records')
    except sqlite3.Error:
        failures.append('activity-unavailable')
    return dict(ok=not failures, failures=failures, backend=backend,
                current_turn_records=current, historical_open_records=stale,
                activity_scope='history-since-backend-start; not proof that resumed work is idle')


def acceptance(result):
    """Evaluate recorded tool-roundtrip observations; not a fresh live check."""
    calls = result.get('tool_calls', [])
    checks = {
        'turn-completed': result.get('terminal_status') == 'completed',
        'one-valid-tool-call': isinstance(calls, list) and len(calls) == 1 and calls[0].get('valid_argument') is True and calls[0].get('has_call_id') is True,
        'attachment-used': result.get('attachment_token_used') is True,
        'tool-receipt-returned': result.get('final_receipt') is True,
        'no-protocol-error': result.get('errors') == [],
        'config-unchanged': result.get('config_unchanged') is True,
    }
    return {'ok': all(checks.values()), 'failures': [k for k, passed in checks.items() if not passed]}


def probe_overrides(home):
    """Process-local isolation: never change provider, credentials or live config."""
    config = tomllib.loads((Path(home) / 'config.toml').read_text(encoding='utf-8-sig'))
    overrides = {'web_search': 'disabled'}
    for feature in ('shell_tool', 'unified_exec', 'js_repl', 'code_mode', 'code_mode_only',
                    'multi_agent', 'multi_agent_v2', 'apps', 'plugins', 'enable_mcp_apps',
                    'view_image', 'image_generation', 'artifact', 'hooks'):
        overrides['features.' + feature] = False
    scopes = [config] + list(config.get('profiles', {}).values())
    for scope in scopes:
        for name in scope.get('mcp_servers', {}):
            if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
                raise DiagnosticError('unsupported-mcp-name')
            overrides['mcp_servers.' + name + '.enabled'] = False
    return overrides


def probe(home, command, expected, timeout=90):
    """Exercise an ephemeral app-server thread with an unguessable tool receipt."""
    result = dict(terminal_status=None, tool_calls=[], attachment_token_used=False,
                  final_receipt=False, errors=[], config_unchanged=False)
    started = time.monotonic()
    proc = None
    token, receipt = uuid.uuid4().hex, uuid.uuid4().hex
    events = queue.Queue(maxsize=2048)
    pending = []
    deadline = started + timeout
    try:
        if config_hash(home) != expected['config_sha256']:
            raise DiagnosticError('config-changed')
        env = dict(os.environ, CODEX_HOME=str(home))
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, encoding='utf-8', env=env)

        def reader():
            total = 0
            try:
                while True:
                    line = proc.stdout.readline(131073)
                    if not line:
                        events.put_nowait({'diagnostic': 'eof'})
                        return
                    total += len(line)
                    if len(line) > 131072 or total > 2 * 1024 * 1024:
                        events.put_nowait({'diagnostic': 'output-limit'})
                        return
                    events.put_nowait(json.loads(line))
            except (ValueError, UnicodeError):
                events.put_nowait({'diagnostic': 'invalid-protocol'})
            except queue.Full:
                pass  # The deadline still closes this owned process.

        threading.Thread(target=reader, daemon=True).start()

        def send(method=None, params=None, rid=None, response=None):
            if config_hash(home) != expected['config_sha256']:
                raise DiagnosticError('config-changed')
            message = {'id': rid} if rid is not None else {}
            if method:
                message.update(method=method)
            if params is not None:
                message['params'] = params
            if response is not None:
                message['result'] = response
            proc.stdin.write(json.dumps(message) + '\n')
            proc.stdin.flush()

        def receive():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DiagnosticError('timeout')
            try:
                event = events.get(timeout=remaining)
            except queue.Empty:
                raise DiagnosticError('timeout') from None
            if not isinstance(event, dict):
                raise DiagnosticError('invalid-protocol')
            if 'diagnostic' in event:
                raise DiagnosticError(event['diagnostic'])
            if event.get('method') == 'error':
                raise DiagnosticError('server-error')
            return event

        def rpc(method, params, rid):
            send(method, params, rid)
            while True:
                event = receive()
                if event.get('id') == rid:
                    if 'error' in event:
                        raise DiagnosticError('rpc-error')
                    return event['result']
                pending.append(event)

        rpc('initialize', {'clientInfo': {'name': 'codex_diagnostics', 'version': '1.0'}, 'capabilities': {'experimentalApi': True}}, 1)
        send('initialized')
        thread = rpc('thread/start', dict(model=expected['model'], modelProvider=expected['provider'],
                     cwd=str(home), approvalPolicy='never', sandbox='read-only', ephemeral=True,
                     config=probe_overrides(home),
                     dynamicTools=[dict(type='function', name='diagnostic_echo', description='Return a unique diagnostic receipt for an attachment token.',
                     inputSchema=dict(type='object', properties={'token': {'type': 'string'}}, required=['token'], additionalProperties=False))]), 2)
        tid = thread['thread']['id']
        turn = rpc('turn/start', {'threadId': tid,
                   'input': [{'type': 'text', 'text': 'Protocol check: read the browser attachment, call diagnostic_echo exactly once with its entire token, then reply with exactly the tool receipt. The receipt can only be obtained by calling the tool. Do not run a shell, read files or use any other tool.', 'text_elements': []}],
                   'additionalContext': {'codex_apps_open_page': {'kind': 'untrusted', 'name': 'browser', 'value': token}}}, 3)
        turn_id = turn['turn']['id']
        final_text = None
        while True:
            event = pending.pop(0) if pending else receive()
            params = event.get('params', {})
            if event.get('method') == 'item/tool/call' and 'id' in event:
                valid = (params.get('threadId') == tid and params.get('turnId') == turn_id and
                         params.get('tool') == 'diagnostic_echo' and params.get('arguments') == {'token': token})
                result['tool_calls'].append(dict(valid_argument=valid, has_call_id=bool(params.get('callId'))))
                result['attachment_token_used'] |= valid
                send(rid=event['id'], response=dict(success=valid, contentItems=[dict(type='inputText', text=receipt if valid else 'invalid-diagnostic-call')]))
            elif params.get('threadId') == tid:
                if event.get('method') in ('item/started', 'item/completed') and params.get('turnId') == turn_id:
                    if params.get('item', {}).get('type') not in ('agentMessage', 'reasoning', 'contextCompaction', 'dynamicToolCall', 'userMessage', 'plan'):
                        raise DiagnosticError('unexpected-tool-execution')
                if event.get('method') == 'item/completed' and params.get('turnId') == turn_id and params.get('item', {}).get('type') == 'agentMessage':
                    item = params['item']
                    final_text = item.get('text', '') if item.get('phase') in (None, 'final_answer') else None
                if event.get('method') == 'turn/completed' and params.get('turn', {}).get('id') == turn_id:
                    result['final_receipt'] = final_text is not None and final_text.strip() == receipt
                    result['terminal_status'] = params['turn'].get('status')
                    break
    except DiagnosticError as exc:
        result['errors'].append(str(exc))
    except (OSError, KeyError, TypeError, ValueError):
        result['errors'].append('invalid-runtime-response')
    finally:
        if proc is not None:
            if proc.poll() is None:
                if os.name == 'nt':
                    subprocess.run(['taskkill.exe', '/PID', str(proc.pid), '/T', '/F'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                else:
                    proc.kill()
            proc.wait(timeout=10)
            proc.stdin.close()
            proc.stdout.close()
        result['config_unchanged'] = config_hash(home) == expected['config_sha256']
    result['seconds'] = round(time.monotonic() - started, 3)
    result.update(acceptance(result))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    accept = sub.add_parser('accept', help='Evaluate a recorded probe; nonzero on any unmet criterion.')
    accept.add_argument('--result', type=Path, required=True)
    for action in ('snapshot', 'desktop-check', 'tool-roundtrip'):
        cmd = sub.add_parser(action, help={'snapshot': 'Read current config and the registered desktop backend; no model request.', 'desktop-check': 'Verify config reload and current turn records; never restarts the app.', 'tool-roundtrip': 'Make one ephemeral model turn with browser context and a diagnostic tool; incurs model usage.'}[action])
        cmd.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')))
        cmd.add_argument('--profile')
        cmd.add_argument('--magpie-executable', type=Path, help='Explicit Magpie executable for the read-only codex login field; otherwise login mode is unknown.')
        if action == 'desktop-check':
            cmd.add_argument('--previous-pid', type=int)
            cmd.add_argument('--expected-config-sha256')
        if action == 'tool-roundtrip':
            cmd.add_argument('--timeout', type=float, default=90)
            cmd.add_argument('--expected-config-sha256')
    args = parser.parse_args(argv)
    try:
        if args.action == 'accept':
            report = acceptance(json.loads(args.result.read_text(encoding='utf-8-sig')))
            report['scope'] = 'recorded-result-only'
        else:
            observed = snapshot(args.codex_home, collect_inventory(), args.profile)
            if args.magpie_executable:
                if observed['provider'] != 'magpie' or not args.magpie_executable.is_absolute():
                    raise DiagnosticError('magpie-mode-target-mismatch')
                observed['login_mode'] = magpie_login_mode(args.magpie_executable)
            if args.action == 'desktop-check':
                report = desktop_status(args.codex_home, observed, args.previous_pid, args.expected_config_sha256)
                report['snapshot'] = observed
            elif args.action == 'tool-roundtrip':
                if not 0 < args.timeout <= 300:
                    raise DiagnosticError('invalid-timeout')
                if args.expected_config_sha256 and observed['config_sha256'] != args.expected_config_sha256:
                    raise DiagnosticError('config-changed')
                command = [observed['backend']['path']]
                if args.profile:
                    command += ['--profile', args.profile]
                for key, value in probe_overrides(args.codex_home).items():
                    command += ['-c', key + '=' + json.dumps(value)]
                command += ['app-server']
                report = probe(args.codex_home, command, observed, args.timeout)
                report['snapshot'] = observed
            else:
                report = dict(ok=True, snapshot=observed, scope='observation-only')
            executable = Path(observed['backend']['path'])
            version = subprocess.run([str(executable), '--version'], capture_output=True, text=True, encoding='utf-8', timeout=10)
            match = re.fullmatch(r'codex-cli ([0-9A-Za-z.+-]+)\s*', version.stdout)
            if version.returncode or not match:
                raise DiagnosticError('runtime-version-unavailable')
            with executable.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            report['runtime'] = dict(version=match[1], sha256=digest)
            if config_hash(args.codex_home) != observed['config_sha256']:
                report.update(ok=False, failures=['config-changed'])
    except DiagnosticError as exc:
        report = {'ok': False, 'failures': [str(exc)]}
    except (OSError, ValueError, TypeError, AttributeError, KeyError, subprocess.SubprocessError):
        report = {'ok': False, 'failures': ['diagnostic-input-or-runtime-error']}
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
