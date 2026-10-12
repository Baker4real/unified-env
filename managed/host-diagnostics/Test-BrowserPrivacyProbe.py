"""Public CLI/HTTP tests; synthetic payloads never access the user's browser."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener


ENTRY = Path(__file__).with_name('BrowserPrivacyProbe.py')
BASE = Path(os.environ.get('BROWSER_PROBE_TEST_ROOT', 'D:/agents/run-evidence/browser-probe-tests'))
BASE.mkdir(parents=True, exist_ok=True)
HTTP = build_opener(ProxyHandler({}))


def payload(attempt):
    return {
        'runId': attempt['runId'], 'attemptId': attempt['attemptId'],
        'language': 'en-US', 'languages': ['en-US'],
        'intl': {'DateTimeFormat': 'en-US', 'NumberFormat': 'en-US'},
        'worker': {'languages': ['en-US'], 'dateLocale': 'en-US', 'numberLocale': 'en-US'},
        'localFontsPermission': 'denied',
        'fontProbe': {'Microsoft YaHei': True},
        'probes': [{'label': label, 'completed': True, 'stopReason': 'complete', 'errors': [], 'candidates': []}
                   for label in ('host-only', 'cloudflare', 'google')],
    }


class BrowserProbeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='case-', dir=BASE))
        self.run_dir = self.root / 'run'
        self.routing = self.root / 'routing.json'
        self.started = False

    def cli(self, action, *args, expected=0):
        result = subprocess.run([sys.executable, '-B', str(ENTRY), action,
                                 '--run-dir', str(self.run_dir), '--routing-file', str(self.routing), *args],
                                capture_output=True, text=True, encoding='utf-8', timeout=25)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def start(self, *args):
        result = self.cli('start', *args)
        self.started = True
        self.url = result['url']
        return result

    def post(self, value, expected=200, origin=None):
        headers = {'Content-Type': 'application/json', 'Origin': origin or self.url.rstrip('/'),
                   'Accept-Language': 'en-US,en;q=0.9'}
        req = Request(self.url + 'result', data=json.dumps(value).encode(), headers=headers)
        try:
            with HTTP.open(req, timeout=5) as response:
                status, body = response.status, json.load(response)
        except HTTPError as error:
            with error:
                status, body = error.code, json.load(error)
        self.assertEqual(status, expected, body)
        return body

    def tearDown(self):
        if self.started:
            self.cli('stop')

    def test_fresh_attempt_rejects_stale_and_incomplete_results(self):
        first = self.start()
        self.assertEqual(self.cli('status', expected=3)['status'], 'waiting')
        self.post(payload(first))
        green = self.cli('status')
        self.assertEqual(green['status'], 'passed')
        self.assertEqual(green['fontIsolation'], 'not-provided')
        second = self.cli('prepare')
        self.assertNotEqual(first['attemptId'], second['attemptId'])
        self.assertEqual(self.cli('status', expected=3)['status'], 'waiting')
        self.post(payload(first), expected=409)
        missing = payload(second)
        missing.pop('worker')
        self.post(missing, expected=400)
        empty = payload(second)
        empty['probes'] = []
        self.post(empty, expected=400)
        bad = payload(second)
        bad['languages'] = ['en-US', 'zh-CN']
        self.post(bad)
        self.assertEqual(self.cli('status', expected=1)['status'], 'failed')
        self.post(payload(second), expected=409)
        third = self.cli('prepare')
        good = self.post(payload(third))
        self.assertIn('receivedAt', good)
        self.assertEqual(good['attemptId'], third['attemptId'])
        self.assertEqual(self.cli('status')['status'], 'passed')
        self.assertTrue((self.run_dir / ('result-' + first['attemptId'] + '.json')).exists())
        self.assertTrue((self.run_dir / ('result-' + second['attemptId'] + '.json')).exists())

    def test_failure_route_is_sticky_and_does_not_launch_automation(self):
        recorded = self.cli('record-failure', '--reason', 'navigation-timeout')
        self.assertFalse(recorded['automationAllowed'])
        self.assertFalse(self.cli('route')['automationAllowed'])
        blocked = self.cli('start', '--transport', 'automation', expected=5)
        self.assertEqual(blocked['status'], 'manual-required')
        self.assertFalse(self.run_dir.exists())
        self.start()
        self.assertFalse(self.cli('route')['automationAllowed'])

    def test_duplicate_start_and_cross_origin_are_safe(self):
        first = self.start()
        duplicate = self.cli('start')
        self.assertEqual(first['pid'], duplicate['pid'])
        self.assertEqual(duplicate['status'], 'already-running')
        self.post(payload(first), expected=403, origin='https://example.invalid')
        self.assertEqual(self.cli('status', expected=3)['status'], 'waiting')
        self.cli('stop')
        self.started = False
        ended = self.cli('start', expected=2)
        self.assertEqual(ended['status'], 'error')

    def test_network_addresses_are_classified_and_timeout_cannot_pass(self):
        attempt = self.start()
        value = payload(attempt)
        value['probes'][1]['candidates'] = [{'type': 'srflx', 'address': '203.0.113.42', 'relatedAddress': '192.168.1.23'}]
        self.post(value)
        failed = self.cli('status', expected=1)
        self.assertFalse(failed['webrtcNoCandidates'])
        saved = Path(failed['evidence']).read_text(encoding='utf-8')
        self.assertNotIn('203.0.113.42', saved)
        self.assertNotIn('192.168.1.23', saved)
        attempt = self.cli('prepare')
        value = payload(attempt)
        value['probes'][0].update(completed=False, stopReason='timeout')
        self.post(value)
        self.assertFalse(self.cli('status', expected=1)['webrtcNoCandidates'])

    def test_record_timestamp_and_server_identity_are_checked(self):
        attempt = self.start()
        self.post(payload(attempt))
        report_path = self.run_dir / ('result-' + attempt['attemptId'] + '.json')
        report = json.loads(report_path.read_text(encoding='utf-8'))
        report['receivedAt'] = '2000-01-01T00:00:00+00:00'
        report_path.write_text(json.dumps(report), encoding='utf-8')
        self.assertEqual(self.cli('status', expected=2)['status'], 'error')
        ready_path = self.run_dir / 'ready.json'
        original = ready_path.read_text(encoding='utf-8')
        ready = json.loads(original)
        ready['identity']['createdTicks'] += 1
        try:
            ready_path.write_text(json.dumps(ready), encoding='utf-8')
            self.assertEqual(self.cli('stop', expected=2)['status'], 'error')
        finally:
            ready_path.write_text(original, encoding='utf-8')


if __name__ == '__main__':
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(BrowserProbeTests))
    log = BASE / ('suite-' + str(os.getpid()) + '.txt')
    log.write_text(output.getvalue(), encoding='utf-8')
    print(json.dumps({'status': 'passed' if result.wasSuccessful() else 'failed', 'cases': result.testsRun,
                      'failures': len(result.failures), 'errors': len(result.errors), 'browserTouched': False,
                      'evidence': str(log)}))
    sys.exit(0 if result.wasSuccessful() else 1)
