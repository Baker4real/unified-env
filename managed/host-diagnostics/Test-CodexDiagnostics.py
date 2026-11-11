"""Codex diagnostics contract: public CLI exits and native app-server protocol."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / 'codex_diagnostics.py'


class DiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base = Path('D:/agents/run-evidence/codex-diagnostics-tests') if os.name == 'nt' else ROOT / '.scratch/codex-diagnostics'
        base.mkdir(parents=True, exist_ok=True)
        cls.root = Path(tempfile.mkdtemp(dir=base))
        spec = importlib.util.spec_from_file_location('codex_diagnostics', SOURCE)
        cls.d = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.d)

    def fixture_home(self):
        home = Path(tempfile.mkdtemp(dir=self.root))
        (home / 'config.toml').write_text('model_provider="magpie"\nmodel="ai/fixture"\n[model_providers.magpie]\nbase_url="https://user:secret@example.invalid/v1?key=secret#secret"\nexperimental_bearer_token="secret"\n[features]\nuntrusted_as_tool_output=false\n', encoding='utf-8')
        return home

    def test_magpie_login_is_read_only_and_rejects_unknown_output(self):
        response = subprocess.CompletedProcess([], 0, stdout='codex login: api', stderr='')
        with patch.object(self.d.subprocess, 'run', return_value=response) as run:
            self.assertEqual(self.d.magpie_login_mode('fixture.exe'), 'api')
            self.assertEqual(run.call_args.args[0], ['fixture.exe', 'codex', 'login'])
        for code, value in ((0, 'secret'), (1, 'api'), (0, 'api companion')):
            with patch.object(self.d.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, stdout=value, stderr='secret')):
                with self.assertRaises(self.d.DiagnosticError):
                    self.d.magpie_login_mode('fixture.exe')

    def inventory(self, cached=True):
        package = 'C:/Program Files/WindowsApps/OpenAI.Codex_fixture'
        gui = dict(pid=10, parent=1, session=1, started=100, path=package + '/app/ChatGPT.exe')
        backend = dict(pid=20, parent=10, session=1, started=120, path=('C:/Users/test/AppData/Local/OpenAI/Codex/bin/abcdef0123456789/codex.exe' if cached else package + '/app/resources/codex.exe'))
        return dict(packages=[dict(family='OpenAI.Codex_2p2nqsd0c76g0', root=package)], localAppData='C:/Users/test/AppData/Local', processes=[gui, backend])

    def test_snapshot_binds_current_provider_and_redacts_credentials(self):
        home = self.fixture_home()
        result = self.d.snapshot(home, self.inventory())
        self.assertEqual(result['provider'], 'magpie')
        self.assertEqual(result['model'], 'ai/fixture')
        self.assertEqual(result['endpoint'], 'https://example.invalid/v1')
        self.assertEqual(result['backend']['pid'], 20)
        self.assertNotIn('secret', json.dumps(result))
        self.assertEqual(result['config_sha256'], self.d.config_hash(home))
        (home / 'config.toml').write_text('model_provider="other"\nmodel="changed"\n', encoding='utf-8')
        self.assertNotEqual(result['config_sha256'], self.d.config_hash(home))
        self.assertEqual(self.d.snapshot(home, self.inventory())['provider'], 'other')

    def test_desktop_verifier_accepts_cache_and_ignores_stale_history(self):
        home = self.fixture_home()
        os.utime(home / 'config.toml', (110, 110))
        conn = sqlite3.connect(home / 'thread_history_1.sqlite')
        conn.execute('create table thread_turns (status text, started_at integer, completed_at integer)')
        conn.execute("insert into thread_turns values ('inProgress', 80, null)")
        conn.commit()
        for cached in (True, False):
            snap = self.d.snapshot(home, self.inventory(cached))
            self.assertTrue(self.d.desktop_status(home, snap, previous_pid=19)['ok'])
            self.assertFalse(self.d.desktop_status(home, snap, previous_pid=20)['ok'])
            self.assertFalse(self.d.desktop_status(home, snap, expected_hash='wrong')['ok'])
        conn.execute("insert into thread_turns values ('inProgress', 125, null)")
        conn.commit()
        self.assertFalse(self.d.desktop_status(home, snap)['ok'])
        conn.close()
        reused = self.inventory()
        reused['processes'][0]['started'] = 200
        with self.assertRaises(self.d.DiagnosticError):
            self.d.snapshot(home, reused)
        same_second = self.inventory()
        same_second['processes'][1]['started'] = 125.9
        self.assertFalse(self.d.desktop_status(home, self.d.snapshot(home, same_second))['ok'])
        bad = self.inventory()
        bad['processes'][1]['path'] = 'C:/other/codex.exe'
        with self.assertRaises(self.d.DiagnosticError):
            self.d.snapshot(home, bad)
        os.utime(home / 'config.toml', (130, 130))
        self.assertIn('backend-predates-config', self.d.desktop_status(home, self.d.snapshot(home, self.inventory()))['failures'])

    def test_native_protocol_probe_success_and_failures(self):
        home = self.fixture_home()
        peer = self.root / 'peer.py'
        peer.write_text('''import json, sys, pathlib
mode = sys.argv[1]
def emit(x): print(json.dumps(x), flush=True)
for line in sys.stdin:
 req = json.loads(line)
 method = req.get('method')
 if method == 'initialize': emit({'id':req['id'],'result':{}})
 elif method == 'thread/start':
  if req['params']['modelProvider'] != 'magpie': sys.exit(8)
  if req['params'].get('config',{}).get('features.shell_tool') is not False: sys.exit(9)
  emit({'id':req['id'],'result':{'thread':{'id':'thread-fixture'}}})
 elif method == 'turn/start':
  if mode == 'rpc-error':
   emit({'id':req['id'],'error':{'message':'secret'}}); continue
  if mode == 'early-extra':
   emit({'method':'item/completed','params':{'threadId':'thread-fixture','turnId':'turn-fixture','item':{'type':'commandExecution','status':'completed','exitCode':0}}})
  emit({'id':req['id'],'result':{'turn':{'id':'turn-fixture'}}})
  if mode == 'timeout': continue
  if mode == 'eof': sys.exit(0)
  if mode == 'drift': pathlib.Path(sys.argv[2]).write_text('model="changed"')
  if mode == 'extra-tool':
   emit({'method':'item/completed','params':{'threadId':'thread-fixture','turnId':'turn-fixture','item':{'type':'commandExecution','status':'completed','exitCode':0}}})
  if mode == 'no-tool':
   emit({'method':'turn/completed','params':{'threadId':'thread-fixture','turn':{'id':'turn-fixture','status':'completed'}}}); continue
  token = list(req['params']['additionalContext'].values())[0]['value']
  emit({'id':101,'method':'item/tool/call','params':{'threadId':'thread-fixture','turnId':'turn-fixture','callId':'call-fixture','tool':'diagnostic_echo','arguments':{'token':('wrong' if mode == 'bad-arg' else token)}}})
 elif req.get('id') == 101:
  receipt = req['result']['contentItems'][0]['text']
  emit({'method':'item/completed','params':{'threadId':'thread-fixture','turnId':('other-turn' if mode == 'other-turn' else 'turn-fixture'),'item':{'type':'agentMessage','text':receipt}}})
  if mode == 'wrong-final':
   emit({'method':'item/completed','params':{'threadId':'thread-fixture','turnId':'turn-fixture','item':{'type':'agentMessage','phase':'final_answer','text':'wrong final answer'}}})
  emit({'method':'turn/completed','params':{'threadId':'thread-fixture','turn':{'id':'turn-fixture','status':'completed'}}})
''', encoding='utf-8')
        for mode in ('success', 'no-tool', 'bad-arg', 'rpc-error', 'timeout', 'eof', 'drift', 'wrong-final', 'other-turn', 'extra-tool', 'early-extra'):
            with self.subTest(mode=mode):
                home = self.fixture_home()
                expected = self.d.snapshot(home, self.inventory())
                report = self.d.probe(home, [sys.executable, str(peer), mode, str(home / 'config.toml')], expected, timeout=0.6 if mode == 'timeout' else 4)
                self.assertEqual(report['ok'], mode == 'success', report)
                self.assertNotIn('secret', json.dumps(report))
                if mode == 'success':
                    self.assertTrue(report['final_receipt'])
                    self.assertTrue(report['tool_calls'][0]['has_call_id'])
                else:
                    self.assertTrue(report['failures'])

    def accept(self, result):
        path = self.root / 'result.json'
        path.write_text(json.dumps(result), encoding='utf-8')
        proc = subprocess.run([sys.executable, '-B', str(SOURCE), 'accept', '--result', str(path)], capture_output=True, text=True, encoding='utf-8', timeout=10)
        self.assertTrue(proc.stdout.strip(), proc.stderr)
        return proc.returncode, json.loads(proc.stdout)

    def test_cli_requires_real_tool_receipt(self):
        good = dict(terminal_status='completed', tool_calls=[dict(valid_argument=True, has_call_id=True)], attachment_token_used=True, final_receipt=True, errors=[], config_unchanged=True)
        self.assertEqual(self.accept(good)[0], 0)
        cases = [dict(tool_calls=[]), dict(attachment_token_used=False), dict(final_receipt=False), dict(terminal_status='failed'), dict(errors=['timeout']), dict(config_unchanged=False), dict(tool_calls=[dict(valid_argument=False, has_call_id=True)]), dict(tool_calls=[dict(valid_argument=True, has_call_id=False)])]
        for change in cases:
            with self.subTest(change=change):
                code, report = self.accept(good | change)
                self.assertNotEqual(code, 0)
                self.assertFalse(report['ok'])
                self.assertTrue(report['failures'])


if __name__ == '__main__':
    import io
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.defaultTestLoader.loadTestsFromTestCase(DiagnosticsTests))
    if not result.wasSuccessful():
        print(stream.getvalue()[-8000:], file=sys.stderr)
    print(json.dumps(dict(status='passed' if result.wasSuccessful() else 'failed', cases=result.testsRun, failures=len(result.failures), errors=len(result.errors), live_model_touched=False)))
    raise SystemExit(0 if result.wasSuccessful() else 1)
