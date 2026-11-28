"""Bounded daily-update navigation, worktree evidence, proxy facts and runtime recipes."""
import argparse
import collections
import datetime
import hashlib
import importlib.util
import ipaddress
import json
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.parse

BASE = pathlib.Path(__file__).resolve().parent
ROOT = BASE.parents[1]
_spec = importlib.util.spec_from_file_location('preflight_runtime', BASE / 'runtime-health.py')
runtime = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runtime)


def proxy_config(value):
    if not value:
        return dict(status='missing')
    try:
        uri = urllib.parse.urlsplit(value.strip())
        if uri.username or uri.password or uri.scheme not in {'http', 'https', 'socks5', 'socks5h'} or uri.path not in {'', '/'} or uri.query or uri.fragment:
            raise ValueError('invalid-proxy')
        host = uri.hostname
        if host != 'localhost' and not ipaddress.ip_address(host).is_loopback:
            raise ValueError('non-loopback-proxy')
        return dict(status='valid', scheme=uri.scheme, port=uri.port or (443 if uri.scheme == 'https' else 80))
    except (ValueError, TypeError):
        return dict(status='invalid')


def proxy_summary(rows, git_proxy, user_proxy):
    git, user = proxy_config(git_proxy), proxy_config(user_proxy)
    listeners = []
    seen = set()
    for row in rows:
        try:
            if row['state'].lower() not in {'listen', 'listening'} or not ipaddress.ip_address(row['address']).is_loopback:
                continue
            key = (row['address'], int(row['port']), int(row['pid']))
            if key in seen:
                continue
            seen.add(key)
            # Process is a process name only; never return executable paths or command lines.
            listeners.append(dict(address=key[0], port=key[1], pid=key[2], process=row.get('process', 'unknown')))
        except (ValueError, KeyError, TypeError):
            continue
    configured = git.get('port') if git == user and git.get('status') == 'valid' else None
    candidate_ports = {row['port'] for row in listeners if re.fullmatch(r'(?:verge-)?mihomo|clash(?:-meta)?', row['process'], re.I)}
    if configured in candidate_ports:
        selected = configured
    elif len(candidate_ports) == 1:
        selected = next(iter(candidate_ports))
    elif not candidate_ports and configured is not None and any(row['port'] == configured for row in listeners):
        selected = configured
    else:
        selected = None
    consistent = selected is not None and git == user and git.get('port') == selected
    scheme = git.get('scheme') if git.get('port') == selected else user.get('scheme') if user.get('port') == selected else 'http'
    return dict(ok=selected is not None, status='resolved' if selected is not None else 'ambiguous-or-unavailable',
                proxy=f'{scheme}://127.0.0.1:{selected}' if selected is not None else None,
                git=git, user_https=user, three_faces_consistent=consistent,
                listener_count=len(listeners), listeners=listeners[:16], omitted_count=max(0, len(listeners)-16))


def live_proxy():
    command = r'''$ErrorActionPreference='Stop';$PSNativeCommandUseErrorActionPreference=$false;
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$rows=@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {$_.LocalAddress -in @('127.0.0.1','::1')} | ForEach-Object {
 $name='unknown';try{$name=(Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName}catch{}
 [pscustomobject]@{state='Listen';address=$_.LocalAddress;port=$_.LocalPort;pid=$_.OwningProcess;process=$name}
})
$git=& git config --global --get http.proxy;$code=$LASTEXITCODE
if($code -notin @(0,1)){throw 'Git proxy query failed'}
[pscustomobject]@{listeners=$rows;git=([string]$git);user=[Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')} | ConvertTo-Json -Depth 5 -Compress'''
    pwsh = shutil.which('pwsh')
    if not pwsh:
        return dict(ok=False, status='unknown', reason='powershell-unavailable')
    child = runtime.run_hidden([pwsh, '-NoProfile', '-NonInteractive', '-Command', command], timeout=60)
    if child['status'] != 'exited' or child['exit_code'] != 0:
        return dict(ok=False, status='unknown', reason='proxy-observation-unavailable')
    data = json.loads(child['stdout'])
    return proxy_summary(data['listeners'], data.get('git'), data.get('user'))


def module_summary(identity):
    manifest = json.loads((ROOT / 'modules/manifest.json').read_text(encoding='utf-8'))
    rows = [row for row in manifest['modules'] if row['id'] == identity]
    if len(rows) != 1:
        raise ValueError('unknown-module')
    module = rows[0]
    tests = {profile: {kind: len(files) for kind, files in selection.items()} for profile, selection in module.get('tests', {}).items()}
    return dict(ok=True, module=identity, context=module['context'], interfaces=module['interfaces'],
                depends_on=module.get('dependsOn', []), tests=tests, omitted_count=0)


def runtime_recipe(component, expected):
    mapping = {'npm': ('node', ['npm','npx']), 'npx': ('node', ['npx']),
               'node': ('node', ['node']), 'python': ('python', ['python','python3','py']),
               'git': ('git', ['git']), 'pwsh': ('pwsh', ['pwsh'])}
    owner, aliases = mapping[component]
    return [str(BASE / 'runtime-health.py'), 'shells', '--runtime', owner, '--expected-version', expected, '--aliases', *aliases]


def worktree_summary(repo, run_directory, started_at):
    evidence_spec = importlib.util.spec_from_file_location('daily_evidence', BASE / 'evidence_io.py')
    evidence_module = importlib.util.module_from_spec(evidence_spec)
    evidence_spec.loader.exec_module(evidence_module)
    evidence = evidence_module.RunEvidence(run_directory)
    started = datetime.datetime.fromisoformat(started_at)
    if started.tzinfo is None:
        raise ValueError('need-time-offset')

    def git(*args):
        return subprocess.check_output(['git', '--no-optional-locks', '-C', str(repo), *args],
                                       stderr=subprocess.PIPE, timeout=30)

    reported_root = git('rev-parse', '--show-toplevel').decode('utf-8').rstrip('\r\n')
    if not pathlib.Path(repo).is_absolute() or pathlib.Path(reported_root).resolve() != pathlib.Path(repo).resolve():
        raise ValueError('expected-repository-root')
    head, timestamp = git('log', '-1', '--format=%H%n%cI').decode('ascii').splitlines()
    age = started - datetime.datetime.fromisoformat(timestamp)
    if git('rev-parse', 'HEAD').decode('ascii').strip() != head:
        raise ValueError('head-drift')
    raw = git('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if git('rev-parse', 'HEAD').decode('ascii').strip() != head:
        raise ValueError('head-drift')
    records = raw.decode('utf-8').split('\0')
    if records.pop() != '':
        raise ValueError('truncated-porcelain')
    counts = collections.Counter()
    sample = []
    paths = iter(records)
    for record in paths:
        status, path = record[:2], record[3:]
        if record[2:3] != ' ' or not path or not re.fullmatch(r'[ MADRCUT?]{2}', status):
            raise ValueError('invalid-porcelain')
        row = dict(status=status, path=path)
        if 'R' in status or 'C' in status:
            original = next(paths, '')
            if not original:
                raise ValueError('truncated-rename')
            row['from'] = original
        counts[status] += 1
        if len(sample) < 8:
            sample.append(row)
    total = sum(counts.values())
    target = evidence.output_path('skills-worktree.porcelain.z')
    with target.open('xb') as stream:
        stream.write(raw)
    return dict(ok=True, head=head, last_commit_at=timestamp, started_at=started_at,
                latest_commit_age_seconds=int(age.total_seconds()), dirty=bool(total),
                dirty_age_gate_failed=bool(total and age > datetime.timedelta(days=1)),
                counts=dict(counts), total=total, sample=sample, omitted_count=total - len(sample),
                status_evidence=target.name, status_sha256=hashlib.sha256(raw).hexdigest())


def bounded_json(result, budget):
    if not 512 <= budget <= 6000:
        raise ValueError('budget-outside-512-6000')
    def encode():
        return json.dumps(result, ensure_ascii=False, separators=(',', ':'))
    text = encode()
    for key in ('listeners', 'interfaces', 'sample'):
        while len(text.encode('utf-8')) + 1 > budget and result.get(key):
            result[key].pop()
            result['omitted_count'] = result.get('omitted_count', 0) + 1
            text = encode()
    if len(text.encode('utf-8')) + 1 > budget:
        return json.dumps(dict(ok=False, status='budget-too-small', omitted_count=1))
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--max-bytes', type=int, default=6000)
    modes = parser.add_subparsers(dest='mode', required=True)
    modes.add_parser('proxy')
    worktree = modes.add_parser('worktree')
    worktree.add_argument('--repo', required=True, type=pathlib.Path)
    worktree.add_argument('--run-directory', required=True, type=pathlib.Path)
    worktree.add_argument('--started-at', required=True)
    module = modes.add_parser('module')
    module.add_argument('--id', required=True)
    recipe = modes.add_parser('runtime-command')
    recipe.add_argument('--component', required=True, choices=('npm','npx','node','python','git','pwsh'))
    recipe.add_argument('--expected-version', required=True)
    args = parser.parse_args()
    try:
        if args.mode == 'proxy':
            result = live_proxy()
        elif args.mode == 'module':
            result = module_summary(args.id)
        elif args.mode == 'worktree':
            result = worktree_summary(args.repo, args.run_directory, args.started_at)
        else:
            result = dict(ok=True, argv=runtime_recipe(args.component, args.expected_version))
        output = bounded_json(result, args.max_bytes)
        if args.mode == 'worktree':
            evidence_spec = importlib.util.spec_from_file_location('daily_evidence', BASE / 'evidence_io.py')
            evidence_module = importlib.util.module_from_spec(evidence_spec)
            evidence_spec.loader.exec_module(evidence_module)
            evidence_module.RunEvidence(args.run_directory).write_text_new('skills-worktree.json', output + '\n')
        sys.stdout.buffer.write(output.encode('utf-8') + b'\n')
        return 0 if json.loads(output)['ok'] else 1
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        sys.stdout.buffer.write(b'{"ok":false,"status":"unknown","reason":"summary-unavailable"}\n')
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
