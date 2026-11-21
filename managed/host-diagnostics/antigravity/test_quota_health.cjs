'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const SCRIPT = path.join(__dirname, 'Get-AntigravityQuotaHealth.cjs');
const SECRET_CSRF = 'fixture-secret-csrf-token-do-not-leak-9f8e7d6c';
const SECRET_OAUTH = 'ya29.fixture-secret-oauth-token-do-not-leak';

function startMockHub({ htmlCsrfToken, expectedCsrf }) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/') {
        const cfg = JSON.stringify({
          productName: 'antigravity',
          csrfToken: htmlCsrfToken,
          appVersion: '2.34.0',
        });
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(`<!doctype html><script>window.__APP_CONFIG__ = ${cfg};</script>`);
        return;
      }
      if (req.method === 'POST' && req.url.startsWith('/exa.language_server_pb.LanguageServerService/')) {
        const method = req.url.slice('/exa.language_server_pb.LanguageServerService/'.length);
        if (req.headers['x-codeium-csrf-token'] !== expectedCsrf) {
          res.writeHead(401, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ code: 'unauthenticated', message: 'missing CSRF token' }));
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        if (method === 'GetUserStatus') {
          res.end(JSON.stringify({ userStatus: { email: 'fixture@example.invalid', cascadeModelConfigData: { clientModelConfigs: [{ label: 'm1' }] } } }));
        } else {
          res.end(JSON.stringify({ response: {} }));
        }
        return;
      }
      res.writeHead(404);
      res.end();
    });
    server.listen(0, '127.0.0.1', () => {
      resolve({ port: server.address().port, close: () => new Promise((r) => server.close(() => r())) });
    });
    server.on('error', reject);
  });
}

function runCli(args, envOverrides = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [SCRIPT, ...args], {
      env: { ...process.env, ...envOverrides },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c) => { stdout += c; });
    child.stderr.on('data', (c) => { stderr += c; });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('CLI test timed out'));
    }, 15000);
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (status) => {
      clearTimeout(timer);
      resolve({ status, stdout, stderr });
    });
  });
}

(async () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-quota-health-test-'));
  const srv = await startMockHub({ htmlCsrfToken: '', expectedCsrf: SECRET_CSRF });
  try {
    // Prepare a fixture HOME so default daemon-dir resolution (without --daemon-dir seam!) is exercised directly.
    const fakeHome = path.join(tmpRoot, 'home');
    const daemonDir = path.join(fakeHome, '.gemini', 'antigravity', 'daemon');
    const stateDir = path.join(tmpRoot, 'state');
    const contextDir = path.join(stateDir, 'context');
    fs.mkdirSync(daemonDir, { recursive: true });
    fs.mkdirSync(contextDir, { recursive: true });

    fs.writeFileSync(path.join(daemonDir, 'hub_dead.json'), JSON.stringify({ pid: 999999, httpPort: srv.port, csrfToken: 'stale' }));
    fs.writeFileSync(
      path.join(daemonDir, `hub_${srv.port}.json`),
      JSON.stringify({ pid: process.pid, httpPort: srv.port, httpsPort: 0, lsVersion: '2.34.0', csrfToken: SECRET_CSRF }),
    );
    fs.writeFileSync(
      path.join(stateDir, 'active-build.json'),
      JSON.stringify({ version: '2.34.0', combinedSha256: 'abc123' }),
    );

    const accountsPath = path.join(contextDir, 'accounts_v1.json');
    const makeAccounts = (lastQuotaError, syncState, pools) => ({
      activeAccountEmail: 'fixture@example.invalid',
      accounts: {
        'fixture@example.invalid': {
          credential: { accessToken: SECRET_OAUTH },
          lastQuotaUpdatedAtMs: Date.now(),
          lastQuotaError,
          quotaSnapshot: { syncState, planTierName: 'Google AI Ultra', pools },
        },
      },
      quotaIntervals: Array.from({ length: 50 }, (_, i) => ({ id: `qi_${i}`, bigPayload: 'x'.repeat(200) })),
    });

    // Case 1: Default daemon path (NO --daemon-dir seam; resolved via USERPROFILE/HOME) + healthy accounts
    fs.writeFileSync(
      accountsPath,
      JSON.stringify(makeAccounts(null, 'fresh', [{ title: 'Gemini Models', percentText: '68%', statusLabel: '正常可用', buckets: [{ windowShort: '5h', percentText: '68%', resetTimeText: '21:57' }] }])),
    );
    const resOk = await runCli(['--state-dir', stateDir], { USERPROFILE: fakeHome, HOME: fakeHome });
    assert.equal(resOk.status, 0, `expected exit 0, stderr=${resOk.stderr}, stdout=${resOk.stdout}`);
    assert.ok(!resOk.stdout.includes(SECRET_CSRF), 'CSRF token leaked to stdout');
    assert.ok(!resOk.stdout.includes(SECRET_OAUTH), 'OAuth token leaked to stdout');
    assert.ok(!resOk.stdout.includes('bigPayload'), 'quotaIntervals should not be dumped');
    const parsedOk = JSON.parse(resOk.stdout);
    assert.equal(parsedOk.ok, true);
    assert.equal(parsedOk.daemon.liveCount, 1);
    assert.equal(parsedOk.daemon.staleCount, 1);
    assert.equal(parsedOk.backend.authenticatedBootstrapActive, true);
    assert.equal(parsedOk.backend.rpcWithDaemonCsrf.GetUserStatus.statusCode, 200);
    assert.equal(parsedOk.backend.rpcWithDaemonCsrf.RetrieveUserQuotaSummary.statusCode, 200);
    assert.equal(parsedOk.backend.rpcWithoutCsrfStatusCode, 401);
    assert.equal(parsedOk.accounts.quotaIntervalsSkipped, 50);
    assert.equal(parsedOk.accounts.poolsCount, 1);

    // Case 2: Unhealthy accounts_v1.json (lastQuotaError present) fails with exit 1 while --backend-only passes
    fs.writeFileSync(accountsPath, JSON.stringify(makeAccounts('本地鉴权失败或已失效', 'error', [])));
    const resFail = await runCli(['--daemon-dir', daemonDir, '--state-dir', stateDir]);
    assert.equal(resFail.status, 1);
    const parsedFail = JSON.parse(resFail.stdout);
    assert.equal(parsedFail.ok, false);
    assert.equal(parsedFail.backend.ok, true);
    assert.equal(parsedFail.accounts.ok, false);
    assert.equal(parsedFail.accounts.lastQuotaError, '本地鉴权失败或已失效');

    const resBackendOnly = await runCli(['--daemon-dir', daemonDir, '--state-dir', stateDir, '--backend-only']);
    assert.equal(resBackendOnly.status, 0);
    assert.equal(JSON.parse(resBackendOnly.stdout).ok, true);

    console.log('Antigravity quota health probe tests passed (default home path, redaction, healthy & auth-error branches).');
  } finally {
    await srv.close();
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  }
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
