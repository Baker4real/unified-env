"""Run the production HEAD CLI against a local server with synthetic secrets."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/daily-update/http-metadata.py'


class Source(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        if self.path == '/missing':
            self.send_response(404, 'fixture-secret-reason')
        else:
            self.send_response(200)
        self.send_header('Set-Cookie', 'fixture-secret-cookie=1')
        self.send_header('Proxy-Authenticate', 'Bearer fixture-secret-authorization')
        self.send_header('X-Other', 'fixture-secret-extension')
        self.send_header('Location', 'https://example.invalid/a?token=fixture-secret-location')
        self.send_header('Content-Length', '12345')
        self.send_header('Last-Modified', 'Wed, 18 Nov 2026 10:22:45 GMT')
        self.send_header('ETag', ('"fixture-secret-etag"' if self.path == '/private-etag' else '"' + 'ab' * 16 + '"'))
        self.end_headers()


class HttpMetadataTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Source)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def probe(self, url, code=0):
        proc = subprocess.run([sys.executable, '-B', str(SCRIPT), url], capture_output=True, text=True, timeout=10)
        self.assertNotIn('fixture-secret', proc.stdout + proc.stderr)
        self.assertEqual(proc.stderr, '')
        self.assertEqual(proc.returncode, code, proc.stdout)
        return json.loads(proc.stdout)

    def test_head_keeps_only_validated_metadata(self):
        self.assertEqual(self.probe(self.url + '/asset'), {
            'ok': True, 'status_code': 200, 'content_length': 12345,
            'last_modified': '2026-11-18T10:22:45+00:00', 'etag': 'ab' * 16,
        })
        self.assertNotIn('etag', self.probe(self.url + '/private-etag'))

    def test_failure_does_not_echo_reason_headers_or_user_input(self):
        self.assertEqual(self.probe(self.url + '/missing', 1), {'ok': False, 'status_code': 404})
        self.assertEqual(self.probe(self.url + '/?token=fixture-secret-input', 1),
                         {'ok': False, 'error_code': 'invalid-probe-url'})


if __name__ == '__main__':
    unittest.main()
