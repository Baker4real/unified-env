"""Managed, hidden pre/post-update probes. Does not install any runtime."""
import argparse
import datetime
import json
import ntpath
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

ALIASES = {'python': ('python', 'python3', 'py'), 'node': ('node', 'npm', 'npx'),
           'git': ('git',), 'pwsh': ('pwsh',)}
PROJECT = pathlib.Path(__file__).resolve().parents[2]


def fresh_environment():
    """Use current machine/user PATH, not the long-lived agent's inherited PATH."""
    env = os.environ.copy()
    if os.name == 'nt':
        import winreg
        values = []
        for hive, key in ((winreg.HKEY_LOCAL_MACHINE, r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'),
                          (winreg.HKEY_CURRENT_USER, 'Environment')):
            with winreg.OpenKey(hive, key) as handle:
                try:
                    values.append(os.path.expandvars(winreg.QueryValueEx(handle, 'Path')[0]))
                except FileNotFoundError:
                    pass
        if not values:
            raise ValueError('live-path-unavailable')
        env['PATH'] = os.pathsep.join(values)
    return env


def run_hidden(argv, timeout=30, env=None, cwd=None):
    """Own only this synchronous child; do not discover or stop unrelated processes."""
    try:
        result = subprocess.run(argv, cwd=cwd or PROJECT, env=env, capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=timeout,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        return {'status': 'exited', 'exit_code': result.returncode,
                'stdout': result.stdout, 'stderr': result.stderr}
    except subprocess.TimeoutExpired:
        return {'status': 'timeout', 'exit_code': None, 'stdout': '', 'stderr': ''}
    except OSError:
        return {'status': 'launch-failed', 'exit_code': None, 'stdout': '', 'stderr': ''}


def shell_command(shell, executable, alias):
    if alias not in {name for names in ALIASES.values() for name in names}:
        raise ValueError('unsupported-runtime-alias')
    if shell == 'cmd':
        return [ntpath.normpath(executable), '/d', '/c', f'{alias} --version']
    if shell == 'powershell':
        return [executable, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                f"$ErrorActionPreference='Stop'; {alias} --version; exit $LASTEXITCODE"]
    if shell == 'bash':
        return [executable, '--noprofile', '--norc', '-c', f'{alias} --version']
    raise ValueError('unsupported-shell')


def observed_version(alias, output):
    patterns = {
        'python': r'Python (\d+\.\d+\.\d+)', 'python3': r'Python (\d+\.\d+\.\d+)',
        'py': r'Python (\d+\.\d+\.\d+)', 'node': r'v(\d+\.\d+\.\d+)',
        'npm': r'(\d+\.\d+\.\d+)', 'npx': r'(\d+\.\d+\.\d+)',
        'git': r'git version (\d+\.\d+\.\d+(?:\.windows\.\d+)?)',
        'pwsh': r'PowerShell (\d+\.\d+\.\d+)',
    }
    match = re.fullmatch(patterns[alias], output.strip())
    return match[1] if match else None


def version_matches(alias, output, expected):
    return observed_version(alias, output) == expected


def validate_mcp_rows(rows):
    if not isinstance(rows, list) or len(rows) != 2 or any(not isinstance(r, dict) for r in rows):
        return {'ok': False, 'reason': 'protocol-result-count'}
    if {r.get('name') for r in rows} != {'serena', 'codegraph'}:
        return {'ok': False, 'reason': 'protocol-server-identity'}
    for row in rows:
        initialize, listed = row.get('initialize'), row.get('toolsList')
        if not isinstance(initialize, dict) or not isinstance(listed, dict):
            return {'ok': False, 'reason': 'protocol-result-missing'}
        info = initialize.get('serverInfo')
        if (not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', str(initialize.get('protocol', '')))
                or not isinstance(info, dict)
                or not all(isinstance(info.get(key), str) and info[key].strip() for key in ('name', 'version'))):
            return {'ok': False, 'reason': 'initialize-result-incomplete'}
        count = listed.get('count')
        if initialize.get('ok') is not True or listed.get('ok') is not True or type(count) is not int or count <= 0:
            return {'ok': False, 'reason': 'protocol-result-failed'}
    return {'ok': True, 'servers': [{'name': r['name'], 'tools': r['toolsList']['count']} for r in rows]}


def read_mcp_result(path, started_ns):
    try:
        if path.stat().st_mtime_ns < started_ns:
            return {'ok': False, 'reason': 'stale-result'}
        rows = [json.loads(line) for line in path.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
        return validate_mcp_rows(rows)
    except (OSError, ValueError):
        return {'ok': False, 'reason': 'missing-or-invalid-result'}


def check_shells(runtime, expected, aliases=None):
    env = fresh_environment()
    aliases = aliases if aliases is not None else (('node',) if runtime == 'node' else ALIASES[runtime])
    if not aliases or any(alias not in ALIASES[runtime] for alias in aliases):
        raise ValueError('alias-outside-runtime')
    # npm's own version is independent of Node's version: callers must probe it separately.
    if runtime == 'node' and any(alias in ('npm', 'npx') for alias in aliases) and 'node' in aliases:
        raise ValueError('node-and-npm-require-separate-expected-versions')
    git = shutil.which('git', path=env['PATH'])
    bash = pathlib.Path(git).resolve().parent.parent / 'bin/bash.exe' if git else None
    shells = {'powershell': shutil.which('pwsh', path=env['PATH']),
              'cmd': os.environ.get('COMSPEC', r'C:\Windows\System32\cmd.exe'),
              'bash': str(bash) if bash and bash.is_file() else None}
    records = []
    for name, executable in shells.items():
        for alias in aliases:
            if not executable:
                records.append({'shell': name, 'alias': alias, 'ok': False, 'status': 'shell-unavailable'})
                continue
            child = run_hidden(shell_command(name, executable, alias), env=env)
            records.append({'shell': name, 'alias': alias, 'status': child['status'],
                            'exit_code': child['exit_code'], 'observed_version': observed_version(alias, child['stdout']),
                            'ok': child['exit_code'] == 0 and version_matches(alias, child['stdout'], expected)})
    return {'schema_version': 1, 'runtime': runtime, 'expected_version': expected,
            'ok': all(r['ok'] for r in records), 'checks': records,
            'phase': 'read-only-shell-validation', 'observed_at': datetime.datetime.now().astimezone().isoformat()}


def check_mcp(out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    result_file = out_dir / 'mcp-smoke-result.json'
    if result_file.exists():
        raise ValueError('use-new-mcp-evidence-directory')
    env = fresh_environment()
    node = shutil.which('node', path=env['PATH'])
    if not node:
        raise ValueError('node-unavailable')
    started = time.time_ns()
    child = run_hidden([node, str(pathlib.Path(__file__).with_name('mcp-smoke.cjs')), str(out_dir)],
                       timeout=200, env=env)
    protocol = read_mcp_result(result_file, started)
    result = {'schema_version': 1, 'ok': child['exit_code'] == 0 and protocol['ok'],
              'process_status': child['status'], 'exit_code': child['exit_code'], 'protocol': protocol}
    (out_dir / 'mcp-health.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    shells = commands.add_parser('shells', help='Run before mutation at current version, then after at target version')
    shells.add_argument('--runtime', choices=ALIASES, required=True)
    shells.add_argument('--expected-version', required=True)
    shells.add_argument('--aliases', nargs='+')
    shells.add_argument('--output', type=pathlib.Path)
    mcp = commands.add_parser('mcp', help='Require a fresh managed MCP smoke result, not only exit 0')
    mcp.add_argument('--out-dir', type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        if args.mode == 'shells':
            result = check_shells(args.runtime, args.expected_version, args.aliases)
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        else:
            result = check_mcp(args.out_dir)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result['ok'] else 1
    except (ValueError, OSError) as error:
        print(json.dumps({'ok': False, 'status': 'invalid-input', 'error_type': type(error).__name__}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
