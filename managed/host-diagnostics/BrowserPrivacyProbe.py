"""Loopback browser checks with fresh attempts and persistent manual routing.

This Windows host tool never launches or attaches to a browser. Use --help.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import time
from urllib.request import ProxyHandler, Request, build_opener


HTTP = build_opener(ProxyHandler({}))
LABELS = {'host-only', 'cloudflare', 'google'}
DEFAULT_ROUTE = 'D:/agents/run-evidence/browser-privacy-routing/state.json'
TOKEN_ENV = 'BROWSER_PRIVACY_PROBE_OWNER'


def now():
    return datetime.now(timezone.utc).isoformat()


def timestamp(value):
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise ValueError('Timestamp must have a timezone')
    return parsed


def checked_path(value):
    path = Path(os.path.abspath(value))
    if not Path(value).is_absolute() or path.drive.lower() != 'd:' or len(path.parts) < 2:
        raise ValueError('Evidence must use an absolute D drive path')
    if ':' in str(path)[2:]:
        raise ValueError('Alternate data streams are not allowed')
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink() or ancestor.is_junction():
            raise ValueError('Reparse paths are not allowed')
    return path


def save(path, value):
    checked_path(path)
    temporary = path.with_name(path.name + '.' + secrets.token_hex(6) + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, path)


def load(path):
    checked_path(path)
    return json.loads(path.read_text(encoding='utf-8'))


def process_identity(pid):
    """Use kernel creation time and executable to reject PID reuse."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    handle = kernel.OpenProcess(0x1000 | 0x100000, False, pid)
    if not handle:
        if ctypes.get_last_error() == 87:
            return None
        raise OSError('Process identity unavailable')
    try:
        if kernel.WaitForSingleObject(handle, 0) == 0:
            return None
        times = [wintypes.FILETIME() for _ in range(4)]
        if not kernel.GetProcessTimes(handle, *(ctypes.byref(t) for t in times)):
            if kernel.WaitForSingleObject(handle, 200) == 0:
                return None
            raise OSError('Process creation time unavailable')
        size = wintypes.DWORD(32768)
        name = ctypes.create_unicode_buffer(size.value)
        if not kernel.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(size)):
            if kernel.WaitForSingleObject(handle, 200) == 0:
                return None
            raise OSError('Process executable unavailable')
        return {'pid': pid, 'createdTicks': (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime,
                'executable': os.path.normcase(os.path.abspath(name.value))}
    finally:
        kernel.CloseHandle(handle)


def request(ready, endpoint, data=None):
    headers = {'X-Browser-Probe-Control': ready['runId']}
    body = None if data is None else json.dumps(data).encode('utf-8')
    with HTTP.open(Request(ready['url'] + endpoint, data=body, headers=headers), timeout=4) as response:
        return json.load(response)


def verified_server(root):
    manifest = load(root / 'manifest.json')
    ready = load(root / 'ready.json')
    if ready['runId'] != manifest['runId'] or ready['ownerHash'] != manifest['ownerHash']:
        raise ValueError('Server ownership mismatch')
    if ready['parentPid'] != manifest['launcherPid']:
        raise ValueError('Server parent does not match the launch intent')
    if process_identity(ready['pid']) != ready['identity']:
        raise ValueError('Server identity changed or exited; use a new run directory')
    health = request(ready, 'health')
    if any(health.get(key) != ready[key] for key in ('runId', 'pid', 'ownerHash')):
        raise ValueError('Server health identity mismatch')
    return ready


def route(args):
    path = checked_path(args.routing_file)
    state = load(path) if path.exists() else {'schemaVersion': 1, 'browsers': {}}
    if state.get('schemaVersion') != 1 or not isinstance(state.get('browsers'), dict):
        raise ValueError('Routing state has an unsupported schema')
    record = state['browsers'].get(args.browser, {})
    if args.action == 'record-failure':
        path.parent.mkdir(parents=True, exist_ok=True)
        record = {'automationAllowed': False, 'reason': args.reason, 'recordedAt': now()}
        state['browsers'][args.browser] = record
        save(path, state)
    allowed = record.get('automationAllowed', True)
    if not isinstance(allowed, bool):
        raise ValueError('Invalid routing decision')
    return {'status': 'route', 'browser': args.browser, 'automationAllowed': allowed,
            'transport': 'automation-eligible' if allowed else 'manual',
            'reason': record.get('reason'), 'routingFile': str(path)}


def new_attempt(run_id):
    return {'runId': run_id, 'attemptId': secrets.token_hex(16), 'requestedAt': now()}


def start(args, root):
    policy = route(args)
    if args.transport == 'automation' and not policy['automationAllowed']:
        return {'status': 'manual-required', **{k: policy[k] for k in ('browser', 'reason')}}, 5
    if root.exists():
        ready = verified_server(root)
        return {'status': 'already-running', **request(ready, 'attempt'), 'url': ready['url'], 'pid': ready['pid']}, 0
    # An exclusive directory reservation makes an uncertain launch non-retryable.
    root.mkdir(parents=True, exist_ok=False)
    token = secrets.token_hex(32)
    owner_hash = hashlib.sha256(token.encode()).hexdigest()
    attempt = new_attempt(secrets.token_hex(16))
    manifest = {**attempt, 'schemaVersion': 1, 'ownerHash': owner_hash,
                'browser': args.browser, 'transport': args.transport,
                'launcherPid': os.getpid(), 'lifetime': 'task-scoped', 'tokenChannel': 'child-environment-only',
                'readinessTimeoutSeconds': 10, 'stopTimeoutSeconds': 5,
                'readiness': 'owner hash, PID, OS creation time, executable, parent and HTTP health match',
                'expectedResult': 'fresh complete browser report; graceful server exit',
                'executable': sys.executable, 'entrypoint': str(Path(__file__).resolve()), 'cwd': str(root),
                'deadlineSeconds': args.ttl_seconds, 'sourceSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    save(root / 'manifest.json', manifest)
    save(root / 'attempt.json', attempt)
    environment = dict(os.environ, **{TOKEN_ENV: token})
    command = [sys.executable, '-B', str(Path(__file__).resolve()), 'serve', '--run-dir', str(root)]
    with (root / 'server.stdout.log').open('xb') as out, (root / 'server.stderr.log').open('xb') as err:
        process = subprocess.Popen(command, env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, close_fds=True, creationflags=subprocess.CREATE_NO_WINDOW)
    deadline = time.monotonic() + 10
    while not (root / 'ready.json').exists():
        if process.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError('Readiness failed; inspect this run directory before retrying. Child TTL remains active.')
        time.sleep(0.05)
    ready = verified_server(root)
    if ready['pid'] != process.pid:
        raise RuntimeError('Launched PID does not match server readiness')
    save(root / 'launch-verified.json', {'verifiedAt': now(), 'ready': ready, 'status': 'running-identity-verified'})
    return {'status': 'waiting', **attempt, 'url': ready['url'], 'pid': ready['pid']}, 0


def is_string_list(value):
    return isinstance(value, list) and 0 < len(value) <= 32 and all(isinstance(x, str) and 0 < len(x) <= 100 for x in value)


def address_class(value):
    if value is None or value == '':
        return None
    if not isinstance(value, str) or len(value) > 256:
        raise ValueError('Invalid ICE address')
    try:
        address = ipaddress.ip_address(value)
        return {'kind': 'global' if address.is_global else 'local-or-special', 'version': address.version}
    except ValueError:
        return {'kind': 'mdns' if value.endswith('.local') else 'hostname'}


def validate_report(value):
    if not isinstance(value, dict) or not isinstance(value.get('language'), str) or not value['language']:
        raise ValueError('Missing browser language')
    if not is_string_list(value.get('languages')):
        raise ValueError('Missing browser languages')
    intl, worker = value.get('intl'), value.get('worker')
    if not isinstance(intl, dict) or any(not isinstance(intl.get(k), str) or not intl[k] for k in ('DateTimeFormat', 'NumberFormat')):
        raise ValueError('Incomplete Intl result')
    if not isinstance(worker, dict) or not is_string_list(worker.get('languages')) or any(not isinstance(worker.get(k), str) or not worker[k] for k in ('dateLocale', 'numberLocale')):
        raise ValueError('Incomplete Worker result')
    fonts = value.get('fontProbe')
    if not isinstance(fonts, dict) or not fonts or len(fonts) > 32 or any(type(v) is not bool for v in fonts.values()):
        raise ValueError('Incomplete font observation')
    if value.get('localFontsPermission') not in ('denied', 'prompt', 'granted', 'unsupported'):
        raise ValueError('Missing local font permission result')
    probes = value.get('probes')
    if not isinstance(probes, list) or len(probes) != 3 or any(not isinstance(p, dict) for p in probes) or {p.get('label') for p in probes} != LABELS:
        raise ValueError('Expected three distinct ICE probes')
    clean = []
    for probe in probes:
        if type(probe.get('completed')) is not bool or probe.get('stopReason') not in ('complete', 'timeout', 'error') or not isinstance(probe.get('errors'), list) or not isinstance(probe.get('candidates'), list):
            raise ValueError('Incomplete ICE probe')
        if len(probe['candidates']) > 100 or len(probe['errors']) > 100:
            raise ValueError('ICE probe exceeded limits')
        candidates = []
        for candidate in probe['candidates']:
            if not isinstance(candidate, dict) or candidate.get('type') not in ('host', 'srflx', 'prflx', 'relay'):
                raise ValueError('Invalid ICE candidate')
            candidates.append({'type': candidate['type'], 'address': address_class(candidate.get('address')),
                               'relatedAddress': address_class(candidate.get('relatedAddress'))})
        # Retain error presence and numeric codes, never arbitrary network error text.
        errors = [{'code': e.get('code') if isinstance(e, dict) and isinstance(e.get('code'), int) else None} for e in probe['errors']]
        clean.append({'label': probe['label'], 'completed': probe['completed'], 'stopReason': probe['stopReason'],
                      'errors': errors, 'candidates': candidates})
    return {'language': value['language'], 'languages': value['languages'],
            'intl': {k: intl[k] for k in ('DateTimeFormat', 'NumberFormat')},
            'worker': {k: worker[k] for k in ('languages', 'dateLocale', 'numberLocale')},
            'localFontsPermission': value['localFontsPermission'], 'fontProbe': fonts, 'probes': clean}


def status(root):
    manifest, attempt = load(root / 'manifest.json'), load(root / 'attempt.json')
    if manifest['runId'] != attempt['runId']:
        raise ValueError('Attempt does not belong to this run')
    result_path = root / ('result-' + attempt['attemptId'] + '.json')
    if not result_path.exists():
        return {'status': 'waiting', **attempt}, 3
    report = load(result_path)
    if any(report.get(k) != attempt[k] for k in ('runId', 'attemptId', 'requestedAt')):
        raise ValueError('Result does not belong to the requested attempt')
    if not timestamp(attempt['requestedAt']) <= timestamp(report['receivedAt']) <= datetime.now(timezone.utc):
        raise ValueError('Result timestamp is outside the current attempt')
    # Only server-accepted reports have this envelope; raw client time is never authoritative.
    if report.get('sourceSha256') != manifest['sourceSha256']:
        raise ValueError('Result source does not match this run')
    locales = [report['language'], *report['languages'], *report['intl'].values(),
               *report['worker']['languages'], report['worker']['dateLocale'], report['worker']['numberLocale']]
    header_locales = [part.strip().split(';')[0] for part in report['acceptLanguage'].split(',') if part.strip()]
    locale_ok = bool(header_locales) and all(locale.lower().split('-')[0] == 'en' for locale in locales + header_locales)
    rtc_ok = len(report['probes']) == 3 and all(p['completed'] and p['stopReason'] == 'complete' and not p['errors'] and not p['candidates'] for p in report['probes'])
    font_api_ok = report['localFontsPermission'] == 'denied'
    passed = locale_ok and rtc_ok and font_api_ok
    return {'status': 'passed' if passed else 'failed', **attempt, 'receivedAt': report['receivedAt'],
            'englishOnly': locale_ok, 'webrtcNoCandidates': rtc_ok, 'localFontAccessDenied': font_api_ok,
            'fontIsolation': 'not-provided', 'detectedFontCount': sum(report['fontProbe'].values()),
            'evidence': str(result_path)}, 0 if passed else 1


HTML = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>浏览器隐私检查</title>
<style>body{font:18px system-ui;max-width:760px;margin:4rem auto;padding:0 20px;line-height:1.6}pre{white-space:pre-wrap}</style>
<h1>浏览器隐私检查</h1><p id="status">检查中，请等待约 20 秒。</p>
<p>检查语言、区域格式和三组 WebRTC ICE 候选。Canvas 字体检测仅作观察。结果只保存到本机。</p><pre id="output"></pre>
<script>
const attempt = __ATTEMPT__;
(async()=>{
 const worker = await new Promise(resolve=>{
  const url=URL.createObjectURL(new Blob([`postMessage({languages:[...navigator.languages],dateLocale:new Intl.DateTimeFormat().resolvedOptions().locale,numberLocale:new Intl.NumberFormat().resolvedOptions().locale})`],{type:'text/javascript'}));
  const w=new Worker(url);let timer;
  const finish=value=>{clearTimeout(timer);w.terminate();URL.revokeObjectURL(url);resolve(value)};
  w.onmessage=e=>finish(e.data);w.onerror=()=>finish({error:'worker_error'});
  timer=setTimeout(()=>finish({error:'timeout'}),5000);
 });
 let localFontsPermission='unsupported';
 try{localFontsPermission=(await navigator.permissions.query({name:'local-fonts'})).state}catch{}
 const fonts=['Microsoft YaHei','Microsoft YaHei UI','PingFang SC','PingFang TC','MiSans','HarmonyOS Sans','HarmonyOS Sans SC','鸿蒙黑体','SimSun','Microsoft JhengHei'];
 const ctx=document.createElement('canvas').getContext('2d');
 const width=(font,fallback,sample)=>{ctx.font=`32px "${font}", ${fallback}`;return ctx.measureText(sample).width};
 const fontProbe=Object.fromEntries(fonts.map(font=>[font,['monospace','serif','sans-serif'].some(f=>['mmmmWWWWiiii1234','中文字体測試'].some(s=>width(font,f,s)!==width('MissingFont_9bfa27d1',f,s)))]));
 async function gather(label,urls){
  const result={label,completed:false,stopReason:'error',errors:[],candidates:[]};let pc,timer;
  try{
   pc=new RTCPeerConnection({iceServers:urls.length?[{urls}]:[],iceCandidatePoolSize:0});
   let done;const completion=new Promise(r=>done=r);
   timer=setTimeout(()=>done('timeout'),18000);
   pc.onicecandidate=e=>{if(e.candidate)result.candidates.push({type:e.candidate.type,address:e.candidate.address,relatedAddress:e.candidate.relatedAddress});else{result.completed=true;done('complete')}};
   pc.onicecandidateerror=e=>result.errors.push({code:e.errorCode});
   pc.createDataChannel('privacy-check');await pc.setLocalDescription(await pc.createOffer());result.stopReason=await completion;
  }catch{result.errors.push({code:null})}finally{clearTimeout(timer);pc?.close()}
  return result;
 }
 const probes=await Promise.all([gather('host-only',[]),gather('cloudflare',['stun:stun.cloudflare.com:3478']),gather('google',['stun:stun.l.google.com:19302'])]);
 const response=await fetch('/result',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...attempt,language:navigator.language,languages:[...navigator.languages],intl:{DateTimeFormat:new Intl.DateTimeFormat().resolvedOptions().locale,NumberFormat:new Intl.NumberFormat().resolvedOptions().locale},worker,localFontsPermission,fontProbe,probes})});
 const saved=await response.json();if(!response.ok)throw new Error(saved.error||'结果保存失败');
 document.getElementById('output').textContent=JSON.stringify(saved,null,2);
 document.getElementById('status').textContent='检查完成。结果已保存到本机，可以回复 Codex。';
})().catch(e=>{document.getElementById('status').textContent='检查未完成：'+e.message});
</script></html>'''


def serve(root):
    token = os.environ.pop(TOKEN_ENV)
    manifest = load(root / 'manifest.json')
    if hashlib.sha256(token.encode()).hexdigest() != manifest['ownerHash']:
        raise ValueError('Child ownership mismatch')
    lock = threading.Lock()
    ready = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, code, value, html=False):
            body = value.encode('utf-8') if html else json.dumps(value, ensure_ascii=False).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'text/html; charset=utf-8' if html else 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def local_host(self):
            return self.headers.get('Host') == ready['url'].split('/')[2]

        def controlled(self):
            return self.local_host() and self.headers.get('Origin') is None and self.headers.get('X-Browser-Probe-Control') == manifest['runId']

        def do_GET(self):
            if not self.local_host():
                self.reply(403, {'error': 'host-rejected'})
            elif self.path == '/':
                with lock:
                    self.reply(200, HTML.replace('__ATTEMPT__', json.dumps(load(root / 'attempt.json'))), html=True)
            elif self.path in ('/health', '/attempt') and self.controlled():
                with lock:
                    self.reply(200, ready if self.path == '/health' else load(root / 'attempt.json'))
            else:
                self.reply(404, {'error': 'not-found'})

        def do_POST(self):
            if self.path in ('/prepare', '/shutdown'):
                if not self.controlled():
                    self.reply(403, {'error': 'control-rejected'})
                    return
                with lock:
                    if self.path == '/prepare':
                        attempt = new_attempt(manifest['runId'])
                        save(root / 'attempt.json', attempt)
                        self.reply(200, attempt)
                    else:
                        self.reply(200, {'status': 'stopping'})
                        threading.Thread(target=server.shutdown, daemon=True).start()
                return
            if self.path != '/result' or not self.local_host() or self.headers.get('Origin') != ready['url'].rstrip('/'):
                self.reply(403, {'error': 'origin-rejected'})
                return
            self.connection.settimeout(4)
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if size < 2 or size > 65536:
                    raise ValueError('Invalid report size')
                value = json.loads(self.rfile.read(size))
                with lock:
                    attempt = load(root / 'attempt.json')
                    if not isinstance(value, dict) or any(value.get(k) != attempt[k] for k in ('runId', 'attemptId')):
                        self.reply(409, {'error': 'stale-attempt'})
                        return
                    path = root / ('result-' + attempt['attemptId'] + '.json')
                    if path.exists():
                        self.reply(409, {'error': 'attempt-already-recorded; prepare a new attempt'})
                        return
                    cleaned = validate_report(value)
                    header = self.headers.get('Accept-Language', '')
                    if not header or len(header) > 1024:
                        raise ValueError('Missing Accept-Language')
                    report = {**cleaned, **attempt, 'receivedAt': now(), 'acceptLanguage': header,
                              'sourceSha256': manifest['sourceSha256']}
                    save(path, report)
                    self.reply(200, {'status': 'recorded', **attempt, 'receivedAt': report['receivedAt']})
            except (ValueError, TypeError, OSError, KeyError):
                self.reply(400, {'error': 'invalid-or-incomplete-report'})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    ready.update({'runId': manifest['runId'], 'pid': os.getpid(), 'parentPid': os.getppid(),
                  'identity': process_identity(os.getpid()), 'ownerHash': manifest['ownerHash'],
                  'url': f'http://127.0.0.1:{server.server_port}/', 'startedAt': now()})
    save(root / 'ready.json', ready)
    expiry = threading.Timer(manifest['deadlineSeconds'], server.shutdown)
    expiry.daemon = True
    expiry.start()
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        expiry.cancel()
        server.server_close()
        save(root / 'exited.json', {'runId': manifest['runId'], 'exitedAt': now(), 'pid': os.getpid()})


def stop(root):
    ready = load(root / 'ready.json')
    actual = process_identity(ready['pid'])
    if actual is None and (root / 'exited.json').exists():
        return {'status': 'already-stopped', 'pid': ready['pid']}
    ready = verified_server(root)
    request(ready, 'shutdown', {})
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        actual = process_identity(ready['pid'])
        if actual is None or actual != ready['identity']:
            save(root / 'stop-verified.json', {'verifiedAt': now(), 'runId': ready['runId'],
                                             'status': 'stopped', 'identity': ready['identity'], 'processExited': True})
            return {'status': 'stopped', 'pid': ready['pid'], 'processExited': True}
        time.sleep(0.05)
    raise RuntimeError('Owned server has not exited; inspect before retrying')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['route', 'record-failure', 'start', 'prepare', 'status', 'stop', 'serve'])
    parser.add_argument('--run-dir', help='New absolute D directory for each server lifetime')
    parser.add_argument('--routing-file', default=DEFAULT_ROUTE)
    parser.add_argument('--browser', choices=['edge', 'chrome'], default='edge')
    parser.add_argument('--transport', choices=['manual', 'automation'], default='manual', help='Records intended transport; never starts a browser')
    parser.add_argument('--reason', choices=['navigation-timeout', 'debug-permission-loop', 'browser-unresponsive'], default='navigation-timeout')
    parser.add_argument('--ttl-seconds', type=int, default=900)
    args = parser.parse_args()
    try:
        if args.action in ('route', 'record-failure'):
            result, code = route(args), 0
        else:
            if not args.run_dir or not 30 <= args.ttl_seconds <= 3600:
                raise ValueError('A run directory and TTL between 30 and 3600 seconds are required')
            root = checked_path(args.run_dir)
            if args.action == 'serve':
                serve(root)
                return 0
            if args.action == 'start':
                result, code = start(args, root)
            elif args.action == 'prepare':
                ready = verified_server(root)
                result, code = {**request(ready, 'prepare', {}), 'url': ready['url']}, 0
            elif args.action == 'status':
                result, code = status(root)
            else:
                result, code = stop(root), 0
        print(json.dumps(result, ensure_ascii=False))
        return code
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(json.dumps({'status': 'error', 'error': str(error)}, ensure_ascii=False))
        return 2


if __name__ == '__main__':
    sys.exit(main())
