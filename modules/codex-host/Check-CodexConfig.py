"""Read-only Codex config verification. Never equates a fresh probe with desktop acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import tomllib

CREATE_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
WARNING = re.compile(r'unrecognized configuration|deprecated and ignored|ignoring \d+ unrecognized', re.I)


def retired_keys(value, prefix=()):
    found = []
    if not isinstance(value, dict):
        return found
    paths = (('disable_response_storage',), ('features', 'code_mode_tool_description_first'),
             ('features', 'guardianv2', 'thread_context'), ('features', 'guardianv2.thread_context'))
    for path in paths:
        current = value
        for key in path:
            if not isinstance(current, dict) or key not in current:
                break
            current = current[key]
        else:
            found.append('.'.join((*prefix, *path)))
    profiles = value.get('profiles', {})
    if not prefix and isinstance(profiles, dict):
        for name, profile in profiles.items():
            found.extend(retired_keys(profile, ('profiles', name)))
    return found


def probe(command, home, cwd, timeout):
    """Exercise initialize -> initialized -> config/read, with a bounded child lifetime."""
    result = {'ok': False, 'initialize': False, 'configRead': False, 'exitCode': None,
              'warningCount': 0, 'failure': None}
    events = queue.Queue()
    warnings = []
    stream_failures = []
    environment = dict(os.environ, CODEX_HOME=str(home))
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=environment, cwd=cwd,
                                   creationflags=CREATE_FLAGS)
    except OSError:
        result['failure'] = 'launch-failed'
        return result

    def read_stream(stream, is_stdout):
        size = 0
        try:
            while True:
                line = stream.readline(1024 * 1024 + 1)
                if not line:
                    break
                size += len(line)
                if len(line) > 1024 * 1024 or size > 8 * 1024 * 1024:
                    stream_failures.append('output-limit')
                    events.put(('failure', 'output-limit'))
                    return
                text = line.decode('utf-8', errors='replace')
                if not is_stdout and WARNING.search(text):
                    warnings.append(True)
                if is_stdout:
                    events.put(('line', text))
        finally:
            if is_stdout:
                events.put(('eof', None))

    readers = [threading.Thread(target=read_stream, args=(stream, stdout), daemon=True)
               for stream, stdout in ((process.stdout, True), (process.stderr, False))]
    for reader in readers:
        reader.start()

    def send(message):
        process.stdin.write((json.dumps(message) + '\n').encode('utf-8'))
        process.stdin.flush()

    try:
        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'config-validation', 'version': '1.0'},
            'capabilities': {'experimentalApi': True}}})
        while not result['configRead']:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            kind, value = events.get(timeout=remaining)
            if kind == 'failure':
                result['failure'] = value
                break
            if kind == 'eof':
                result['failure'] = 'missing-response'
                break
            try:
                message = json.loads(value)
            except (ValueError, TypeError):
                result['failure'] = 'invalid-protocol-json'
                break
            if not isinstance(message, dict):
                result['failure'] = 'invalid-protocol-message'
                break
            if 'id' not in message:
                # Notifications are not a substitute for the requested response.
                if message.get('method') in ('configWarning', 'deprecationNotice'):
                    warnings.append(True)
                continue
            expected = 2 if result['initialize'] else 1
            if type(message['id']) is not int or message['id'] != expected:
                result['failure'] = 'unexpected-response-id'
                break
            if 'error' in message or not isinstance(message.get('result'), dict):
                result['failure'] = 'rpc-error'
                break
            if expected == 1:
                result['initialize'] = True
                send({'method': 'initialized'})
                send({'id': 2, 'method': 'config/read', 'params': {'includeLayers': False, 'cwd': str(cwd)}})
            elif not isinstance(message['result'].get('config'), dict):
                result['failure'] = 'invalid-config-response'
                break
            else:
                result['configRead'] = True
        process.stdin.close()
        process.wait(timeout=max(0.01, deadline - time.monotonic()))
    except (TimeoutError, queue.Empty, subprocess.TimeoutExpired):
        result['failure'] = 'timeout'
    except (BrokenPipeError, OSError):
        result['failure'] = 'protocol-io-failed'
    finally:
        if process.poll() is None:
            process.kill()  # Only the process handle created by this probe.
        process.wait(timeout=5)
        for reader in readers:
            reader.join(timeout=1)
        for stream in (process.stdin, process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass
    result['exitCode'] = process.returncode
    result['warningCount'] = len(warnings)
    if stream_failures:
        result['failure'] = stream_failures[0]
    if not result['failure'] and process.returncode != 0:
        result['failure'] = 'nonzero-exit'
    if not result['failure'] and warnings:
        result['failure'] = 'configuration-warning'
    result['ok'] = bool(result['initialize'] and result['configRead'] and not result['failure'])
    return result


def probe_profile(command, home, cwd, timeout):
    # app-server deliberately rejects --profile. mcp list loads the selected
    # profile locally without starting a thread or connecting to MCP servers.
    result = {'ok': False, 'configRead': False, 'exitCode': None, 'warningCount': 0, 'failure': None}
    try:
        process = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                 timeout=timeout, env=dict(os.environ, CODEX_HOME=str(home)),
                                 cwd=cwd, creationflags=CREATE_FLAGS)
        result['exitCode'] = process.returncode
        result['warningCount'] = len(WARNING.findall(process.stderr.decode('utf-8', errors='replace')))
        if len(process.stdout) + len(process.stderr) > 8 * 1024 * 1024:
            result['failure'] = 'output-limit'
        elif process.returncode != 0:
            result['failure'] = 'nonzero-exit'
        elif result['warningCount']:
            result['failure'] = 'configuration-warning'
        else:
            value = json.loads(process.stdout)
            result['configRead'] = isinstance(value, list)
            if not result['configRead']:
                result['failure'] = 'invalid-profile-response'
    except subprocess.TimeoutExpired:
        result['failure'] = 'timeout'
    except OSError:
        result['failure'] = 'launch-failed'
    except ValueError:
        result['failure'] = 'invalid-protocol-json'
    result['ok'] = result['configRead'] and not result['failure']
    return result


def check(home, runtime_command, timeout=20, cwd=None):
    """Public read-only seam, usable with a native runtime or an isolated protocol peer."""
    home = Path(home).resolve()
    cwd = Path(cwd or Path.cwd()).resolve()
    report = {'ok': False, 'home': str(home), 'cwd': str(cwd), 'files': [], 'runtime': [],
              'acceptance': {'files': 'failed', 'runtime': 'unverified', 'desktopSession': 'unverified'}}
    paths = [home / 'config.toml', *sorted(home.glob('*.config.toml'))]
    snapshots = {}
    for path in paths:
        item = {'path': str(path), 'ok': False, 'retiredKeys': [], 'failure': None}
        try:
            raw = path.read_bytes()
            snapshots[path] = hashlib.sha256(raw).hexdigest()
            config = tomllib.loads(raw.decode('utf-8-sig'))
            item['retiredKeys'] = retired_keys(config)
            item['ok'] = not item['retiredKeys']
            if not item['ok']:
                item['failure'] = 'retired-key'
        except (OSError, ValueError):
            item['failure'] = 'file-unreadable-or-invalid-toml'
        report['files'].append(item)
    if not all(item['ok'] for item in report['files']):
        return report
    report['acceptance']['files'] = 'passed'
    for path in paths:
        profile = None if path.name == 'config.toml' else path.name[:-len('.config.toml')]
        if profile is None:
            command = [*runtime_command, 'app-server', '--strict-config', '--stdio']
            result = probe(command, home, cwd, timeout)
            method = 'app-server-strict-config-read'
        else:
            command = [*runtime_command, '-p', profile, 'mcp', 'list', '--json']
            result = probe_profile(command, home, cwd, timeout)
            method = 'profile-mcp-list'
        report['runtime'].append({'profile': profile, 'method': method, **result})
    # Detect external writers during validation without rewriting their changes.
    for item in report['files']:
        path = Path(item['path'])
        try:
            unchanged = hashlib.sha256(path.read_bytes()).hexdigest() == snapshots[path]
        except OSError:
            unchanged = False
        if not unchanged:
            item.update(ok=False, failure='changed-during-check')
    report['acceptance']['files'] = 'passed' if all(x['ok'] for x in report['files']) else 'failed'
    report['acceptance']['runtime'] = 'passed' if all(x['ok'] for x in report['runtime']) else 'failed'
    report['ok'] = report['acceptance']['files'] == report['acceptance']['runtime'] == 'passed'
    return report


def discover_runtime():
    """Prefer the live app-server binary; ambiguous processes require an explicit path."""
    if os.name == 'nt':
        shell = shutil.which('pwsh')
        if not shell:
            raise ValueError('powershell-core-unavailable')
        command = "@(Get-CimInstance Win32_Process -Filter \"Name='codex.exe'\" | Where-Object { $_.CommandLine -match '\\bapp-server\\b' } | Select-Object -ExpandProperty ExecutablePath -Unique) | ConvertTo-Json -Compress"
        result = subprocess.run([shell, '-NoLogo', '-NoProfile', '-Command', command],
                                capture_output=True, text=True, encoding='utf-8', timeout=10,
                                creationflags=CREATE_FLAGS)
        if result.returncode:
            raise ValueError('runtime-discovery-failed')
        paths = json.loads(result.stdout.strip() or '[]')
        if isinstance(paths, str):
            paths = [paths]
        if len(paths) > 1:
            raise ValueError('multiple-live-runtimes-use-codex-exe')
        if len(paths) == 1 and paths[0] and Path(paths[0]).is_file():
            return paths[0], 'running-app-server'
    executable = shutil.which('codex')
    if not executable:
        raise ValueError('runtime-not-found-use-codex-exe')
    return executable, 'path-cli'


def main(argv=None):
    parser = argparse.ArgumentParser(description='只读验证 Codex 配置；桌面会话始终单列为未验证。')
    parser.add_argument('--home', default=os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    parser.add_argument('--codex-exe', help='明确指定运行时；默认发现正在运行的 app-server')
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--cwd', default=str(Path.cwd()))
    args = parser.parse_args(argv)
    if not 0 < args.timeout <= 120:
        parser.error('--timeout must be greater than 0 and at most 120 seconds')
    try:
        executable, source = (args.codex_exe, 'explicit') if args.codex_exe else discover_runtime()
        report = check(args.home, [executable], args.timeout, args.cwd)
        report['runtimeIdentity'] = {'path': executable, 'source': source}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        report = {'ok': False, 'failure': 'runtime-discovery-failed-use-codex-exe',
                  'acceptance': {'files': 'unverified', 'runtime': 'unverified', 'desktopSession': 'unverified'}}
    print(json.dumps(report, ensure_ascii=True, separators=(',', ':')))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
