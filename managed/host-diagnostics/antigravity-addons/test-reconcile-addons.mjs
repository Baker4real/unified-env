import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import http from 'node:http';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  applyUpdaterLayer,
  applyWslLayer,
  detectAddonMarkers,
  detectHubLoadAnchor,
  packAsarWithOverlay,
  parseArgs,
  patchContextLocalApi,
  patchContextMeterCollector,
  patchContextMeterRenderer,
  patchContextMeterStorage,
  patchContextModulesConfig,
  unpackAsar,
  walkAsar,
} from './reconcile-addons.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const RECONCILER = path.join(SCRIPT_DIR, 'reconcile-addons.mjs');
const OFFICIAL_DIR = 'D:/agents/run-evidence/antigravity-addons/20261121-desktop-2.34.0';
const OFFICIAL_ASAR = path.join(OFFICIAL_DIR, 'd-runtime-stage/rollback/app.asar');
const OFFICIAL_LS = path.join(OFFICIAL_DIR, 'd-runtime-stage/program/resources/bin/language_server.exe');
const EXPECTED_OFFICIAL_SHA = '8934adef0622c9271c92eea950a71848764a66f7b10023ccbd82e54b959adb0e';
const EXPECTED_LS_SHA = 'cc94d648c39a67c293d0fdc8befc51e953d1a8f55617bf49fff69885ba475db9';
const LAUNCHER_TEST = path.join(SCRIPT_DIR, '../antigravity/Test-AntigravityLauncher.ps1');
const VENDOR_ROOT = 'D:/Codex/tools/antigravity-addons';
const ALL_LAYERS = ['contextViewer', 'language', 'pulse', 'updater', 'wsl'];
const ALL_MARKERS = ['context-viewer-preload', 'context-viewer-utils', 'desktop-zhcn', 'pulse', 'taskbar-aumid', 'updater-relaunch', 'wsl'];

function sha256(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

function sha256File(p) {
  return sha256(fs.readFileSync(p));
}

function buildSyntheticAsar(filesObj) {
  const header = { files: {} };
  const chunks = [];
  let offset = 0;
  for (const rel of Object.keys(filesObj).sort()) {
    const data = Buffer.isBuffer(filesObj[rel]) ? filesObj[rel] : Buffer.from(String(filesObj[rel]), 'utf8');
    const parts = rel.split('/');
    const leaf = parts.pop();
    let dir = header.files;
    for (const part of parts) {
      if (!dir[part]) dir[part] = { files: {} };
      dir = dir[part].files;
    }
    const digest = sha256(data);
    dir[leaf] = {
      size: data.length,
      offset: String(offset),
      integrity: { algorithm: 'SHA256', hash: digest, blockSize: 4194304, blocks: [digest] },
    };
    chunks.push(data);
    offset += data.length;
  }
  const headerBytes = Buffer.from(JSON.stringify(header), 'utf8');
  const padded = (headerBytes.length + 3) & ~3;
  const prefix = Buffer.alloc(16 + padded, 0);
  prefix.writeUInt32LE(4, 0);
  prefix.writeUInt32LE(8 + padded, 4);
  prefix.writeUInt32LE(4 + padded, 8);
  prefix.writeUInt32LE(headerBytes.length, 12);
  headerBytes.copy(prefix, 16);
  return Buffer.concat([prefix, ...chunks]);
}

function startMockLsServer({ htmlCsrfToken, acceptedTokens, onRpc }) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/') {
        const cfg = JSON.stringify({
          productName: 'antigravity',
          csrfToken: htmlCsrfToken,
          appVersion: '2.34.0',
          releaseChannel: 'stable',
          devMode: false,
        });
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(`<!doctype html><html><head><script>window.__APP_CONFIG__ = ${cfg};</script></head><body></body></html>`);
        return;
      }
      if (req.method === 'POST' && req.url.startsWith('/exa.language_server_pb.LanguageServerService/')) {
        const method = req.url.slice('/exa.language_server_pb.LanguageServerService/'.length);
        const token = req.headers['x-codeium-csrf-token'] || '';
        const allowed = typeof acceptedTokens === 'function' ? acceptedTokens(method) : acceptedTokens;
        if (!token || !allowed.includes(token)) {
          res.writeHead(401, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ code: 'unauthenticated', message: 'unauthenticated: missing CSRF token' }));
          return;
        }
        let body = '';
        req.on('data', (c) => { body += c; });
        req.on('end', () => {
          const payload = onRpc ? onRpc(method, body ? JSON.parse(body) : {}, token) : {};
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(payload));
        });
        return;
      }
      res.writeHead(404);
      res.end('not found');
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        port,
        origin: `http://127.0.0.1:${port}`,
        close: () => new Promise((r) => server.close(() => r())),
      });
    });
    server.on('error', reject);
  });
}

function makeMockQuotaRpcs() {
  return (method) => {
    if (method === 'GetUserStatus') {
      return {
        userStatus: {
          email: 'fixture@example.invalid',
          planStatus: { planInfo: { planName: 'Google AI Pro' } },
          cascadeModelConfigData: {
            clientModelConfigs: [
              {
                label: 'Gemini 4 Neon (XHigh)',
                modelOrAlias: { model: 'MODEL_PLACEHOLDER_M417' },
                quotaInfo: {
                  remainingFraction: 0.85,
                  resetTime: new Date(Date.now() + 3600000).toISOString(),
                },
              },
            ],
          },
        },
      };
    }
    if (method === 'RetrieveUserQuotaSummary') return { response: {} };
    if (method === 'GetAvailableModels') return { models: {} };
    if (method === 'GetCascadeTrajectory') {
      return {
        numTotalSteps: 1,
        trajectory: {
          steps: [{ type: 'CORTEX_STEP_TYPE_USER_INPUT', userInput: { items: [{ text: 'hello' }] } }],
        },
      };
    }
    return {};
  };
}

async function verifyPatchedContextDistBehavior(distDir, tmpRoot) {
  const cjsRequire = createRequire(import.meta.url);
  const localApiPath = path.join(distDir, 'local-api.js');
  const collectorPath = path.join(distDir, 'meter-collector.js');
  delete cjsRequire.cache[cjsRequire.resolve(localApiPath)];
  delete cjsRequire.cache[cjsRequire.resolve(collectorPath)];
  const localApi = cjsRequire(localApiPath);
  const collector = cjsRequire(collectorPath);

  // 1. 2.34.0 empty HTML csrfToken + in-process authBootstrap match
  const srv1 = await startMockLsServer({ htmlCsrfToken: '', acceptedTokens: ['boot-tok-1'], onRpc: makeMockQuotaRpcs() });
  try {
    const api = await localApi.connect({
      origin: srv1.origin,
      authBootstrap: { getActiveLsBaseUrl: () => srv1.origin, getActiveLsCsrfToken: () => 'boot-tok-1' },
    });
    const res = await api.call('GetUserStatus', {});
    assert.equal(res.userStatus.email, 'fixture@example.invalid');
  } finally {
    await srv1.close();
  }

  // 2. authBootstrap origin mismatch fails closed when no daemon match
  const srv2 = await startMockLsServer({ htmlCsrfToken: '', acceptedTokens: ['wrong-tok'], onRpc: makeMockQuotaRpcs() });
  const emptyDaemon = await fsp.mkdtemp(path.join(tmpRoot, 'daemon-empty-'));
  try {
    await assert.rejects(
      () => localApi.connect({
        origin: srv2.origin,
        daemonDir: emptyDaemon,
        authBootstrap: { getActiveLsBaseUrl: () => `http://127.0.0.1:${srv2.port + 1}`, getActiveLsCsrfToken: () => 'wrong-tok' },
      }),
      /本地鉴权信息尚未就绪/,
    );
  } finally {
    await srv2.close();
  }

  // 3. daemon/hub_*.json live PID + exact port match (skips dead PID & wrong port) + fetchQuotaSnapshotFromHost
  const srv3 = await startMockLsServer({ htmlCsrfToken: '', acceptedTokens: ['daemon-tok-3'], onRpc: makeMockQuotaRpcs() });
  const matchDaemon = await fsp.mkdtemp(path.join(tmpRoot, 'daemon-match-'));
  try {
    await fsp.writeFile(path.join(matchDaemon, 'hub_dead.json'), JSON.stringify({ pid: 999999, httpPort: srv3.port, httpsPort: srv3.port - 1, csrfToken: 'dead-tok' }));
    await fsp.writeFile(path.join(matchDaemon, 'hub_other.json'), JSON.stringify({ pid: process.pid, httpPort: srv3.port + 10, httpsPort: srv3.port + 9, csrfToken: 'other-tok' }));
    await fsp.writeFile(path.join(matchDaemon, `hub_${srv3.port}.json`), JSON.stringify({ pid: process.pid, httpPort: srv3.port, httpsPort: srv3.port - 1, csrfToken: 'daemon-tok-3' }));
    collector.resetQuotaHostCacheForTest();
    const snap = await collector.fetchQuotaSnapshotFromHost({
      force: true,
      origin: srv3.origin,
      backendSource: 'electron-ipc',
      authBootstrap: null,
      daemonDir: matchDaemon,
      isPidAlive: (pid) => pid === process.pid,
    });
    assert.equal(snap.error, null, `unexpected quota error: ${snap.error}`);
    assert.equal(snap.errorKind, null);
    assert.ok(Array.isArray(snap.snapshot?.pools) && snap.snapshot.pools.length > 0, 'expected non-empty pools');
  } finally {
    await srv3.close();
  }

  // 4. Legacy 2.33.0 HTML csrfToken still works
  const srv4 = await startMockLsServer({ htmlCsrfToken: 'legacy-tok-4', acceptedTokens: ['legacy-tok-4'], onRpc: makeMockQuotaRpcs() });
  try {
    const api = await localApi.connect({ origin: srv4.origin, authBootstrap: null, daemonDir: emptyDaemon });
    const res = await api.call('GetUserStatus', {});
    assert.equal(res.userStatus.email, 'fixture@example.invalid');
  } finally {
    await srv4.close();
  }

  // 5. meter-collector.collect on 2.34.0 + 401 token rotation recovery
  let activeToken = 'scan-tok-v1';
  const srv5 = await startMockLsServer({ htmlCsrfToken: '', acceptedTokens: () => [activeToken], onRpc: makeMockQuotaRpcs() });
  try {
    const authBootstrap = { getActiveLsBaseUrl: () => srv5.origin, getActiveLsCsrfToken: () => activeToken };
    const first = await collector.collect(srv5.origin, '00000000-0000-0000-0000-000000000001', { force: true, authBootstrap });
    assert.equal(first.conversation, '00000000-0000-0000-0000-000000000001');
    activeToken = 'scan-tok-v2';
    const second = await collector.collect(srv5.origin, '00000000-0000-0000-0000-000000000002', { force: false, authBootstrap });
    assert.equal(second.conversation, '00000000-0000-0000-0000-000000000002');
  } finally {
    await srv5.close();
  }

  // 6. meter-renderer.js localStorage fallback present at both fetch sites
  const rendererSrc = await fsp.readFile(path.join(distDir, 'meter-renderer.js'), 'utf8');
  const fallbackHits = rendererSrc.match(/agy_session_csrf_token/g) || [];
  assert.ok(fallbackHits.length >= 2, `expected >= 2 agy_session_csrf_token fallbacks, got ${fallbackHits.length}`);

  // 7. Production default state-dir redirection (no override seam) + bounded corrupt quarantine + bounded ELV-89 backup
  const asarEnginePath = path.join(distDir, 'asar-engine.js');
  const storagePath = path.join(distDir, 'meter-storage.js');
  delete cjsRequire.cache[cjsRequire.resolve(asarEnginePath)];
  delete cjsRequire.cache[cjsRequire.resolve(storagePath)];
  delete cjsRequire.cache[cjsRequire.resolve(collectorPath)];
  const asarEngine = cjsRequire(asarEnginePath);
  const patchedCollector = cjsRequire(collectorPath);

  const prevAgDirEnv = process.env.AG_DIR;
  delete process.env.AG_DIR;
  try {
    const expectedStateDir = asarEngine.getStateDir();
    assert.ok(!expectedStateDir.toLowerCase().includes('.gemini'), `expected D-drive/fixture stateDir, got ${expectedStateDir}`);
    const defaultLedgerPath = path.join(expectedStateDir, 'pricing_ledger_v1.json');

    // Corrupt all-zero ledger + corrupt .bak.json polled repeatedly produces at most 1 .corrupt.bak.json and 0 timestamped copies
    await fsp.mkdir(expectedStateDir, { recursive: true });
    await fsp.writeFile(defaultLedgerPath, Buffer.alloc(4096, 0));
    await fsp.writeFile(path.join(expectedStateDir, 'pricing_ledger_v1.bak.json'), Buffer.alloc(4096, 0));
    for (let i = 0; i < 15; i++) {
      const guarded = patchedCollector.loadPricingLedger();
      assert.equal(guarded.__corrupted, true);
      assert.equal(guarded.__unreadable, true);
    }
    const afterCorruptFiles = await fsp.readdir(expectedStateDir);
    const corruptCopies = afterCorruptFiles.filter((n) => n.includes('.corrupt'));
    assert.deepEqual(corruptCopies, ['pricing_ledger_v1.corrupt.bak.json']);

    // Replace with valid ledger containing keepalive_bound + explicit email + recent live_confirmed_account records
    await fsp.rm(path.join(expectedStateDir, 'pricing_ledger_v1.bak.json'), { force: true });
    const nowMs = Date.now();
    const validLedger = {
      version: '1.0.0',
      updatedAt: new Date(nowMs).toISOString(),
      calls: {
        call_keepalive: {
          timestamp: nowMs - 600000,
          isKeepalive: true,
          accountScopeKey: 'acct_0123456789abcdef',
          accountAttributionConfidence: 'keepalive_bound',
        },
        call_email: {
          timestamp: nowMs - 600000,
          accountEmail: 'fixture@example.invalid',
          accountScopeKey: 'acct_fedcba9876543210',
          accountAttributionConfidence: 'explicit_account_email',
        },
        call_recent_live: {
          timestamp: nowMs - 5000,
          liveObservedAtMs: nowMs - 5000,
          accountScopeKey: 'acct_0123456789abcdef',
          accountAttributionConfidence: 'live_confirmed_account',
        },
      },
    };
    await fsp.writeFile(defaultLedgerPath, JSON.stringify(validLedger, null, 2) + '\n', 'utf8');

    // First repair persists attributionRepairVersion on keepalive & email calls and writes 1 bounded .bak-pre-elv89.json
    const rep1 = patchedCollector.repairAndMigrateAccountLedger();
    assert.equal(rep1.ok, true);
    assert.ok(rep1.updatedCount >= 2, `expected updatedCount >= 2, got ${rep1.updatedCount}`);
    assert.equal(rep1.backupPath, `${defaultLedgerPath}.bak-pre-elv89.json`);
    const bakStat1 = await fsp.stat(rep1.backupPath);

    // Subsequent zero-change repair (even while recent live call has no attributionRepairVersion) writes ZERO new backups
    const rep2 = patchedCollector.repairAndMigrateAccountLedger();
    assert.equal(rep2.ok, true);
    assert.equal(rep2.updatedCount, 0);
    assert.equal(rep2.backupPath, null);
    const bakStat2 = await fsp.stat(`${defaultLedgerPath}.bak-pre-elv89.json`);
    assert.equal(bakStat2.mtimeMs, bakStat1.mtimeMs, 'Zero-change repair unexpectedly rewrote backup');

    // Forced repair still reuses the single bounded backup file without timestamp proliferation
    const rep3 = patchedCollector.repairAndMigrateAccountLedger({ force: true });
    assert.equal(rep3.ok, true);
    const elvBaks = (await fsp.readdir(expectedStateDir)).filter((n) => n.includes('bak-pre-elv89'));
    assert.deepEqual(elvBaks, ['pricing_ledger_v1.json.bak-pre-elv89.json']);
  } finally {
    if (prevAgDirEnv === undefined) delete process.env.AG_DIR;
    else process.env.AG_DIR = prevAgDirEnv;
  }
}

async function createTestRoot(mode) {
  let base = os.tmpdir();
  if (process.platform === 'win32') {
    base = ['D:/agents/tmp', 'D:/Codex/temp'].find((dir) => fs.existsSync(dir));
    assert.ok(base, 'Antigravity fixtures require the managed D: temp directory');
    base = path.resolve(base);
    const parents = [base];
    while (path.dirname(parents[0]) !== parents[0]) parents.unshift(path.dirname(parents[0]));
    for (const dir of parents) {
      assert.ok(fs.lstatSync(dir).isDirectory(), `Expected an ordinary fixture directory: ${dir}`);
      assert.equal(fs.realpathSync(dir).toLowerCase(), dir.toLowerCase(), `Redirected fixture directory: ${dir}`);
    }
  }
  return fsp.mkdtemp(path.join(base, `antigravity-addons-${mode}-`));
}

async function runUnitTests() {
  const tmpRoot = await createTestRoot('unit');
  try {
    // Unit 1: packAsarWithOverlay preserves untouched bytes & updates offsets cleanly
    const baseAsar = buildSyntheticAsar({
      'package.json': '{"name":"antigravity","version":"2.99.0"}',
      'dist/alpha.js': 'console.log("alpha-orig");\n',
      'dist/beta.js': 'console.log("beta-untouched-bytes");\n',
      'dist/omega.js': 'console.log("omega-untouched");\n',
    });
    const replacements = new Map([
      ['dist/alpha.js', Buffer.from('console.log("alpha-longer-patched-payload");\n', 'utf8')],
    ]);
    const additions = new Map([
      ['dist/nested/added.json', Buffer.from('{"ok":true}\n', 'utf8')],
    ]);
    const packed = packAsarWithOverlay(baseAsar, replacements, additions);
    assert.equal(packed.unchangedCount, 3);
    const { header: h1, body: b1 } = unpackAsar(packed.buffer);
    const e1 = walkAsar(h1);
    assert.equal(e1.size, 5);
    assert.equal(
      b1.subarray(Number(e1.get('dist/beta.js').offset), Number(e1.get('dist/beta.js').offset) + e1.get('dist/beta.js').size).toString('utf8'),
      'console.log("beta-untouched-bytes");\n',
    );
    assert.equal(
      b1.subarray(Number(e1.get('dist/nested/added.json').offset), Number(e1.get('dist/nested/added.json').offset) + e1.get('dist/nested/added.json').size).toString('utf8'),
      '{"ok":true}\n',
    );
    console.log('UNIT PASS 1: packAsarWithOverlay replacement, addition, and untouched readback');

    // Unit 2: detectAddonMarkers detects all 7 markers (including escaped Lxss path, updater relaunch & taskbar AUMID) and empty on clean ASAR
    const cleanUnpacked = unpackAsar(baseAsar);
    assert.deepEqual(detectAddonMarkers(walkAsar(cleanUnpacked.header), cleanUnpacked.body), []);

    const patchedAsar = buildSyntheticAsar({
      'dist/customScheme.js': "callback({ redirectURL: 'agy-zhcn://bundle/main.js' });",
      'dist/preload.js': '// AGY_CONTEXT_CAPSULE_START\n// Antigravity Context Meter preload Injection Start\n',
      'dist/utils.js': '// Antigravity Context Meter utils Injection Start\n',
      'dist/updater.js': "electron_1.app.setAppUserModelId('com.google.antigravity');\nelectron_1.app.__zhcnUpdaterRelaunchHandedOff = true;\n",
      'dist/wsl.js': "const key = 'HKCU\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Lxss';\n",
    });
    const patchedUnpacked = unpackAsar(patchedAsar);
    assert.deepEqual(
      detectAddonMarkers(walkAsar(patchedUnpacked.header), patchedUnpacked.body).sort(),
      ALL_MARKERS,
    );
    console.log('UNIT PASS 2: detectAddonMarkers detects all 7 markers accurately');

    // Unit 3: detectHubLoadAnchor handles 2.34.0, legacy, future signature, and refuses absent/ambiguous
    assert.equal(
      detectHubLoadAnchor('function f() {\n    void loadHubWindowUrl(win, url, { skipBootstrapMint });\n}'),
      '    void loadHubWindowUrl(win, url, { skipBootstrapMint });',
    );
    assert.equal(
      detectHubLoadAnchor('function f() {\n    void win.loadURL(url);\n}'),
      '    void win.loadURL(url);',
    );
    assert.equal(
      detectHubLoadAnchor('function f() {\n    void loadHubWindowUrl(win, url, { mode: "v3" });\n}'),
      '    void loadHubWindowUrl(win, url, { mode: "v3" });',
    );
    assert.equal(detectHubLoadAnchor('function f() {\n    void otherNav(win, url);\n}'), null);
    assert.equal(
      detectHubLoadAnchor('    void loadHubWindowUrl(win, url, { a: 1 });\n    void loadHubWindowUrl(win, url, { b: 2 });'),
      null,
    );
    console.log('UNIT PASS 3: detectHubLoadAnchor unique match and fail-closed refusal');

    // Unit 4: applyWslLayer passes offline behavioral fixture and degrades cleanly when anchor changes
    const syntheticWslJs = [
      '"use strict";',
      'const child_process = require("child_process");',
      'const fs = require("fs");',
      'const path = require("path");',
      'const { promisify } = require("util");',
      'const execFileAsync = promisify(child_process.execFile);',
      'exports.WSL_EXE = path.join(process.env.SystemRoot || "C:\\\\Windows", "System32", "wsl.exe");',
      'function isWslAvailable() { return process.platform === "win32" && fs.existsSync(exports.WSL_EXE); }',
      'function decodeWslOutput(buf) { return buf.includes(0) ? buf.toString("utf16le").replace(/^\\uFEFF/, "") : buf.toString("utf8"); }',
      'async function execWsl(args) {',
      '    const { stdout } = await execFileAsync(exports.WSL_EXE, args, {',
      '        encoding: "buffer",',
      '            timeout: 30000,',
      '        });',
      '        return decodeWslOutput(stdout);',
      '}',
      'async function listWslDistros() {',
      "    const output = await execWsl(['--list', '--verbose']);",
      '    return output.split(/\\r?\\n/).slice(1).map((line) => line.replace(/^\\*\\s*/, "").trim()).filter(Boolean).map((line) => {',
      '        const [name, state, version] = line.split(/\\s+/);',
      '        return { name, state, version: Number(version) };',
      '    }).filter((d) => d.version === 2 && !d.name.startsWith("docker-desktop"));',
      '}',
      'exports.listWslDistros = listWslDistros;',
    ].join('\n');
    const wslRes = applyWslLayer(syntheticWslJs, tmpRoot);
    assert.equal(wslRes.status, 'ready');
    await wslRes.verifyAsync();
    const wslSkipped = applyWslLayer('exports.listWslDistros = async () => [];', tmpRoot);
    assert.equal(wslSkipped.status, 'skipped');
    console.log('UNIT PASS 4: applyWslLayer behavioral fixture and anchor degradation');

    // Unit 5: parseArgs handles flags cleanly and rejects unknown flags
    const parsed = parseArgs(['reconcile', '--apply', '--from-backup', '--app-dir', 'D:/tmp/app']);
    assert.equal(parsed.command, 'reconcile');
    assert.equal(parsed.apply, true);
    assert.equal(parsed.fromBackup, true);
    assert.equal(parsed.appDir, 'D:/tmp/app');
    assert.throws(() => parseArgs(['status', '--bogus']), /Unknown argument/);
    console.log('UNIT PASS 5: parseArgs flag handling');

    // Unit 6: 2.34+ context-viewer CSRF patchers fail closed on missing anchors and resolve authBootstrap / daemon_hub / legacy HTML
    assert.throws(() => patchContextLocalApi('module.exports = {};'), /Anchor local-api:/);
    assert.throws(() => patchContextMeterCollector('module.exports = {};'), /Anchor meter-collector:/);
    assert.throws(() => patchContextMeterRenderer('console.log(1);'), /Anchor meter-renderer:/);
    assert.throws(() => patchContextMeterStorage('module.exports = {};'), /Anchor meter-storage:/);
    assert.throws(() => patchContextModulesConfig('module.exports = {};'), /Anchor modules-config:/);

    const syntheticLocalApi = `'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const getAppDataDir = () => '';
const isIsolatedTestPath = () => false;
const HANS_CANDIDATE_PORTS = [];
const LOOPBACK_ORIGIN_RE = /^https?:\\/\\/127\\.0\\.0\\.1:(\\d+)$/;
function normalizeLoopbackOrigin(raw) {
  if (!raw || typeof raw !== 'string') return null;
  try { const o = new URL(raw.trim()).origin; return LOOPBACK_ORIGIN_RE.test(o) ? o : null; } catch { return null; }
}
function parseExplicitPort(raw) { const n = Number(raw); return Number.isInteger(n) && n >= 1 && n <= 65535 ? n : null; }
function request(url, body, token) {
  return new Promise((resolve, reject) => {
    const req = (url.startsWith('https:') ? https : http).request(url, {
      agent: false, rejectUnauthorized: false, method: body ? 'POST' : 'GET',
      headers: body ? { 'Content-Type': 'application/json', 'Connect-Protocol-Version': '1', 'x-codeium-csrf-token': token } : {},
    }, (res) => {
      let text = ''; res.on('data', (c) => { text += c; });
      res.on('end', () => (res.statusCode === 200 ? resolve(text) : reject(new Error(\`HTTP \${res.statusCode}: \${text}\`))));
    });
    req.on('error', reject);
    req.end(body ? JSON.stringify(body) : undefined);
  });
}
function getDevToolsActivePort() { return null; }
function getCandidateCdpPorts() { return []; }
async function discoverAntigravityCdp() { throw new Error('no cdp'); }
function connectCdpWebSocket() {}
function createCdpClient() {}
async function extractAppConfigViaCdp() {
  const cfg = {
        expression:
          '(() => { try { if (!window.__APP_CONFIG__) return null; return { hasConfig: true, csrfToken: window.__APP_CONFIG__.csrfToken || "" }; } catch (e) { return null; } })()',
  };
  return cfg ? null : null;
}

/**
 * 解析并缓存或实时提取指定本地页面原点的 CSRF Token 并构造 RPC 客户端。
 */
async function connectOrigin(rawOrigin, page = null, origins = null, extraMeta = {}) {
  const origin = normalizeLoopbackOrigin(rawOrigin);
  if (!origin) {
    throw new Error('非法的本机回环页面地址');
  }
  let hasConfig = false;
  let token = null;
  try {
    const html = await request(origin + '/');
    const config = html.match(/window\\.__APP_CONFIG__\\s*=\\s*(\\{.*?\\})\\s*;/s);
    if (config) {
      hasConfig = true;
      token = JSON.parse(config[1]).csrfToken;
    }
  } catch (err) {
    if (!page || !page.webSocketDebuggerUrl) throw err;
  }

  if (!hasConfig && page && page.webSocketDebuggerUrl) {
    const cdpCfg = await extractAppConfigViaCdp(page);
    if (cdpCfg && cdpCfg.hasConfig) {
      hasConfig = true;
      token = cdpCfg.csrfToken;
    }
  }

  if (!hasConfig) {
    throw new Error('Antigravity 本地连接信息尚未就绪，请稍后重试');
  }
  if (!token) {
    throw new Error('Antigravity 本地鉴权信息尚未就绪，请稍后重试');
  }

  return {
    origin,
    page,
    ...(extraMeta.port ? { port: extraMeta.port } : {}),
    ...(Array.isArray(extraMeta.pages) ? { pages: extraMeta.pages } : {}),
    origins: Array.isArray(origins) && origins.length ? origins : [origin],
    call: async (method, body) =>
      JSON.parse(
        await request(\`\${origin}/exa.language_server_pb.LanguageServerService/\${method}\`, body, token)
      )
  };
}

/**
 * 连接到本地 Antigravity LanguageServerService。
 * 支持直接传入已知 \`options.origin\` 免 CDP/DevToolsActivePort 直连，亦可通过 CDP 发现所有运行窗口原点。
 */
async function connect(options = {}) {
  if (
    options &&
    options.origin !== undefined &&
    options.origin !== null &&
    String(options.origin).trim() !== ''
  ) {
    const explicitOrigin = normalizeLoopbackOrigin(options.origin);
    if (!explicitOrigin) {
      throw new Error('非法的本机回环页面地址');
    }
    return connectOrigin(explicitOrigin, null, [explicitOrigin]);
  }
  const { port, page, pages } = await discoverAntigravityCdp(options);
  const origins = Array.from(
    new Set((Array.isArray(pages) ? pages : [page]).map(item => normalizeLoopbackOrigin(item?.url)).filter(Boolean))
  );
  const targetOrigin = normalizeLoopbackOrigin(page.url);
  return connectOrigin(targetOrigin, page, origins, { port, pages });
}

module.exports = {
  connect,
  connectOrigin,
  normalizeLoopbackOrigin,
  parseExplicitPort,
  getAppDataDir,
  getDevToolsActivePort,
  getCandidateCdpPorts,
  discoverAntigravityCdp,
  connectCdpWebSocket,
  createCdpClient,
  HANS_CANDIDATE_PORTS
};`;

    const synthDir = path.join(tmpRoot, 'synth-csrf');
    await fsp.mkdir(synthDir, { recursive: true });
    const patchedLocalApiBuf = patchContextLocalApi(syntheticLocalApi);
    await fsp.writeFile(path.join(synthDir, 'local-api.js'), patchedLocalApiBuf);
    const cjsRequire = createRequire(import.meta.url);
    const synthApi = cjsRequire(path.join(synthDir, 'local-api.js'));

    const uSrv = await startMockLsServer({ htmlCsrfToken: '', acceptedTokens: ['u-boot-tok', 'u-daemon-tok'], onRpc: makeMockQuotaRpcs() });
    const uDaemon = await fsp.mkdtemp(path.join(tmpRoot, 'u-daemon-'));
    try {
      // authBootstrap match
      const c1 = await synthApi.connect({
        origin: uSrv.origin,
        authBootstrap: { getActiveLsBaseUrl: () => uSrv.origin, getActiveLsCsrfToken: () => 'u-boot-tok' },
      });
      assert.equal((await c1.call('GetUserStatus', {})).userStatus.email, 'fixture@example.invalid');
      // authBootstrap mismatch + empty daemon fails closed
      await assert.rejects(
        () => synthApi.connect({
          origin: uSrv.origin,
          daemonDir: uDaemon,
          authBootstrap: { getActiveLsBaseUrl: () => `http://127.0.0.1:${uSrv.port + 1}`, getActiveLsCsrfToken: () => 'u-boot-tok' },
        }),
        /本地鉴权信息尚未就绪/,
      );
      // daemon_hub live match (ignoring dead PID & wrong port)
      await fsp.writeFile(path.join(uDaemon, 'hub_dead.json'), JSON.stringify({ pid: 999999, httpPort: uSrv.port, csrfToken: 'dead' }));
      await fsp.writeFile(path.join(uDaemon, `hub_${uSrv.port}.json`), JSON.stringify({ pid: process.pid, httpPort: uSrv.port, csrfToken: 'u-daemon-tok' }));
      const c2 = await synthApi.connect({ origin: uSrv.origin, authBootstrap: null, daemonDir: uDaemon, isPidAlive: (p) => p === process.pid });
      assert.equal((await c2.call('GetUserStatus', {})).userStatus.email, 'fixture@example.invalid');
    } finally {
      await uSrv.close();
    }

    const patchedRenderer = patchContextMeterRenderer(
      "      const csrf = window.__APP_CONFIG__?.csrfToken; if (!csrf) throw new Error('后台尚未就绪');\n" +
      "    const csrf = typeof window !== 'undefined' ? window.__APP_CONFIG__?.csrfToken : null;\n",
    ).toString('utf8');
    assert.equal((patchedRenderer.match(/agy_session_csrf_token/g) || []).length, 2);
    console.log('UNIT PASS 6: 2.34+ context-viewer CSRF patchers & authBootstrap/daemon_hub behavior');

    // Unit 7: applyUpdaterLayer behavioral fixture and anchor degradation
    const syntheticUpdaterJs = [
      '"use strict";',
      'var __importStar = (m) => m;',
      'const electron_updater_1 = require("electron-updater");',
      'const electron_1 = require("electron");',
      'const child_process_1 = require("child_process");',
      'let installingUpdate = false;',
      'async function quitAndInstall(isSilent = false) {',
      '    if (!electron_1.app.isPackaged) return;',
      '    if (installingUpdate) return;',
      '    const updater = electron_updater_1.autoUpdater;',
      "    if (process.platform === 'win32' && updater.installerPath) {",
      '        installingUpdate = true;',
      '        let launched = false;',
      '        try {',
      "            const { killLanguageServer } = await Promise.resolve().then(() => __importStar(require('./languageServer')));",
      '            await killLanguageServer();',
      '            electron_updater_1.autoUpdater.quitAndInstall(isSilent, true);',
      '            launched = Boolean(updater.quitAndInstallCalled);',
      '        }',
      '        finally {',
      '            if (!launched) installingUpdate = false;',
      '        }',
      '        return;',
      '    }',
      '    electron_updater_1.autoUpdater.quitAndInstall(isSilent, true);',
      '}',
      'exports.quitAndInstall = quitAndInstall;',
    ].join('\n');
    const updRes = applyUpdaterLayer(
      syntheticUpdaterJs,
      'D:/fixture/state/post-quit-hook.json',
      'D:/fixture/backup/LaunchAntigravity.exe',
      tmpRoot,
    );
    assert.equal(updRes.status, 'ready');
    await updRes.verifyAsync();
    const updSkipped = applyUpdaterLayer('exports.quitAndInstall = async () => {};', 'D:/h.json', 'D:/l.exe', tmpRoot);
    assert.equal(updSkipped.status, 'skipped');
    console.log('UNIT PASS 7: applyUpdaterLayer behavioral fixture and anchor degradation');

    // Unit 8: stale pending-apply.json from an older reconcilerSha256 invalidates pending-ready and rebuilds cleanly
    const fStale = await setupFixture(tmpRoot, 'unit8-stale-pending', false);
    const staleBaseAsar = buildSyntheticAsar({
      'package.json': JSON.stringify({ name: 'antigravity', version: '2.99.1' }),
      'dist/wsl.js': syntheticWslJs,
    });
    await fsp.writeFile(fStale.asarPath, staleBaseAsar);
    await fsp.writeFile(fStale.lsPath, 'synthetic ls for unit8');
    const stagedUnit8 = runCli(['reconcile', '--stage-only', ...fStale.commonArgs]);
    assert.equal(stagedUnit8.status, 'staged-pending');
    assert.equal(stagedUnit8.reconcilerSha256, sha256File(RECONCILER));
    assert.equal(runCli(['status', ...fStale.commonArgs]).status, 'pending-ready');

    const pendingJsonPath = path.join(fStale.stateRoot, 'pending-apply.json');
    const pendingAsarPath = path.join(fStale.stateRoot, 'pending-app.asar');
    const staleMeta = JSON.parse(await fsp.readFile(pendingJsonPath, 'utf8'));
    staleMeta.reconcilerSha256 = '0'.repeat(64);
    await fsp.writeFile(pendingJsonPath, JSON.stringify(staleMeta, null, 2) + '\n', 'utf8');
    await fsp.writeFile(pendingAsarPath, Buffer.from('stale-corrupt-pending-asar', 'utf8'));
    assert.equal(runCli(['status', ...fStale.commonArgs]).status, 'needs-reconcile');

    const rebuiltUnit8 = runCli(['reconcile', '--apply', ...fStale.commonArgs]);
    assert.equal(rebuiltUnit8.status, 'applied');
    assert.equal(sha256File(fStale.asarPath), stagedUnit8.combinedSha256);
    assert.ok(!fs.existsSync(pendingAsarPath));
    assert.ok(!fs.existsSync(pendingJsonPath));
    assert.equal(runCli(['status', ...fStale.commonArgs]).status, 'up-to-date');
    console.log('UNIT PASS 8: reconcilerSha256 mismatch invalidates stale pending-app.asar and rebuilds cleanly');

    if (process.platform === 'win32') {
      const fixture = await setupFixture(tmpRoot, 'synthetic-upgrade', false);
      const oldVersion = '2.98.0';
      const newVersion = '2.99.0';
      const archive = (version) => buildSyntheticAsar({
        'package.json': JSON.stringify({ name: 'antigravity', version }),
        'dist/wsl.js': syntheticWslJs,
      });
      const originalAsar = archive(oldVersion);
      await fsp.writeFile(fixture.asarPath, originalAsar);
      await fsp.writeFile(fixture.lsPath, 'synthetic old language server');
      const old = runCli(['reconcile', '--apply', ...fixture.commonArgs]);
      assert.equal(old.status, 'applied');
      assert.equal(sha256File(path.join(fixture.backupDir, `app.asar.${oldVersion}.original`)), sha256(originalAsar));

      // Surrogate for the NSIS overwrite. The fixture below holds the new ASAR open before Apply.
      const updatedAsar = archive(newVersion);
      const updatedLs = Buffer.from('synthetic new language server');
      await fsp.writeFile(fixture.asarPath, updatedAsar);
      await fsp.writeFile(fixture.lsPath, updatedLs);
      await verifyLockedUpdate(fixture, RECONCILER, newVersion, sha256(updatedAsar), sha256(updatedLs), ['wsl'], ['wsl']);
      assert.equal(sha256File(path.join(fixture.backupDir, `app.asar.${oldVersion}.original`)), sha256(originalAsar));
      await verifyReparseRefusal(tmpRoot, fixture);
      console.log('FIXTURE PASS: synthetic cross-version overwrite, real launcher probe, promotion, backups and reparse refusal');
    }
    console.log('ALL 8 UNIT TESTS PASSED');
  } finally {
    await fsp.rm(tmpRoot, { recursive: true, force: true }).catch(() => {});
  }
}

function runCli(args, reconciler = RECONCILER) {
  const res = spawnSync(process.execPath, [reconciler, ...args], {
    encoding: 'utf8',
    timeout: 120000,
  });
  if (res.status !== 0) {
    throw new Error(`CLI failed (exit ${res.status}):\nSTDOUT:\n${res.stdout}\nSTDERR:\n${res.stderr}`);
  }
  const trimmed = res.stdout.trim();
  assert.ok(trimmed.startsWith('{') && trimmed.endsWith('}'), `Expected single JSON object on stdout, got:\n${res.stdout}`);
  assert.equal(trimmed.split(/\r?\n/).length, 1, `Expected single-line JSON on stdout, got:\n${res.stdout}`);
  return JSON.parse(trimmed);
}

function unpackAsarMember(asarBuf, relPath) {
  const { header, body } = unpackAsar(asarBuf);
  const entry = walkAsar(header).get(relPath);
  if (!entry) return null;
  const start = Number(entry.offset);
  return body.subarray(start, start + entry.size);
}

function replaceMemberInAsar(asarBuf, relPath, transformFn) {
  const orig = unpackAsarMember(asarBuf, relPath);
  assert.ok(orig, `Missing member: ${relPath}`);
  const next = Buffer.from(transformFn(orig.toString('utf8')), 'utf8');
  return packAsarWithOverlay(asarBuf, new Map([[relPath, next]]), new Map()).buffer;
}

async function setupFixture(rootDir, name, installOfficial = true) {
  const base = path.join(rootDir, name);
  const appDir = path.join(base, 'app');
  const backupDir = path.join(base, 'backup');
  const stateRoot = path.join(base, 'state');
  const evidenceRoot = path.join(base, 'evidence');
  const asarPath = path.join(appDir, 'resources/app.asar');
  const lsPath = path.join(appDir, 'resources/bin/language_server.exe');
  await fsp.mkdir(path.dirname(lsPath), { recursive: true });
  const fixture = {
    base, appDir, backupDir, stateRoot, asarPath, lsPath,
    commonArgs: ['--app-dir', appDir, '--backup-dir', backupDir, '--state-root', stateRoot, '--evidence-root', evidenceRoot],
  };
  if (installOfficial) await installOfficialPayload(fixture);
  return fixture;
}

async function installOfficialPayload({ asarPath, lsPath }) {
  await fsp.copyFile(OFFICIAL_ASAR, asarPath);
  await fsp.copyFile(OFFICIAL_LS, lsPath);
}

function runUpgradeLauncher(root, reconciler) {
  return spawnSync('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', LAUNCHER_TEST,
    '-UpgradeFixtureRoot', root, '-ReconcilerPath', reconciler, '-NodeExe', process.execPath],
  { encoding: 'utf8', timeout: 120000 });
}

async function verifyReparseRefusal(tmpRoot, fixture) {
  const outside = await fsp.mkdtemp(path.join(tmpRoot, 'junction-sentinel-'));
  const sentinel = path.join(outside, 'sentinel.txt');
  const redirect = path.join(fixture.stateRoot, 'redirect');
  await fsp.writeFile(sentinel, 'outside fixture state');
  await fsp.symlink(outside, redirect, 'junction');
  try {
    const outer = runUpgradeLauncher(fixture.base, RECONCILER);
    assert.notEqual(outer.status, 0);
    assert.match(outer.stderr, /Launcher fixture contains a reparse point/);
    const inner = spawnSync(path.join(fixture.base, 'TestLauncher.exe'), ['--reconcile-fixture'], {
      encoding: 'utf8', timeout: 10000,
    });
    assert.notEqual(inner.status, 0);
    assert.match(inner.stderr, /Launcher fixture contains a reparse point/);
    assert.deepEqual(await fsp.readdir(outside), ['sentinel.txt']);
    assert.equal(await fsp.readFile(sentinel, 'utf8'), 'outside fixture state');
  } finally {
    await fsp.unlink(redirect);
  }
}

async function verifyLockedUpdate(fixture, reconciler, version, officialSha, lsSha, layers, markers) {
  const activePath = path.join(fixture.stateRoot, 'active-build.json');
  const previousActiveSha = sha256File(activePath);
  const backupPath = path.join(fixture.backupDir, `app.asar.${version}.original`);
  const backupBefore = fs.existsSync(backupPath) ? fs.statSync(backupPath) : null;
  const before = runCli(['status', ...fixture.commonArgs], reconciler);
  assert.equal(before.status, 'needs-reconcile');
  assert.equal(before.version, version);
  assert.equal(before.currentAsarSha, officialSha);
  assert.equal(before.languageServerSha256, lsSha);
  assert.deepEqual(before.markers, []);

  const res = runUpgradeLauncher(fixture.base, reconciler);
  assert.equal(res.status, 0, `Locked update fixture failed (${res.error || res.status}): ${res.stderr}\n${res.stdout}`);
  const { staged, pendingStatus, retry, launcherWhileReopened, launcherWhileLocked, asarWhileLocked,
    pendingWhileLocked, activeWhileLocked, promotion, subsequentLaunch } = JSON.parse(res.stdout);
  assert.equal(staged.status, 'staged-pending-locked');
  assert.equal(pendingStatus.status, 'pending-ready');
  assert.equal(pendingStatus.currentAsarSha, officialSha);
  assert.deepEqual(pendingStatus.markers, []);
  assert.equal(staged.version, version);
  assert.equal(staged.officialSha256, officialSha);
  assert.equal(staged.replaceTargetSha256, officialSha);
  assert.equal(staged.languageServerSha256, lsSha);
  assert.deepEqual([...staged.appliedLayers].sort(), layers);
  assert.equal(retry.status, 'pending-still-locked');
  assert.equal(retry.combinedSha256, staged.combinedSha256);
  assert.equal(launcherWhileReopened, 'SkippedDesktopRunning');
  assert.equal(launcherWhileLocked, 'FailedOpen');
  assert.equal(asarWhileLocked, officialSha);
  assert.equal(pendingWhileLocked, staged.combinedSha256);
  assert.equal(activeWhileLocked, previousActiveSha);

  assert.equal(promotion, 'AppliedPending');
  assert.equal(subsequentLaunch, 'FastPathUpToDate');
  for (const name of ['pending-app.asar', 'pending-apply.json']) {
    assert.ok(!fs.existsSync(path.join(fixture.stateRoot, name)), `Launcher left ${name} behind`);
  }
  const active = JSON.parse(await fsp.readFile(activePath, 'utf8'));
  assert.equal(active.version, version);
  assert.equal(active.officialSha256, officialSha);
  assert.equal(active.languageServerSha256, lsSha);
  assert.equal(active.combinedSha256, staged.combinedSha256);
  assert.deepEqual([...active.appliedLayers].sort(), layers);
  const after = runCli(['status', ...fixture.commonArgs], reconciler);
  assert.equal(after.status, 'up-to-date');
  assert.equal(after.currentAsarSha, active.combinedSha256);
  assert.deepEqual([...after.markers].sort(), markers);
  assert.equal(sha256File(fixture.lsPath), lsSha);
  assert.equal(sha256File(backupPath), officialSha);
  if (backupBefore) {
    const backupAfter = fs.statSync(backupPath);
    assert.equal(backupAfter.ino, backupBefore.ino, 'Same-version backup was replaced');
    assert.equal(backupAfter.mtimeMs, backupBefore.mtimeMs, 'Same-version backup was rewritten');
  }
}

async function prepareE2eReconciler(root) {
  // The same source file runs beside the real vendor assets. Its state and payloads stay in the fixture.
  const tools = path.join(root, 'tools');
  await fsp.mkdir(tools);
  const reconciler = path.join(tools, 'reconcile-addons.mjs');
  await fsp.copyFile(RECONCILER, reconciler);
  for (const dir of ['desktop-zhcn-v3.0.8', 'pulse-v1.3.2', 'context-viewer-v0.8.8']) {
    const source = path.join(VENDOR_ROOT, dir);
    assert.ok((await fsp.lstat(source)).isDirectory(), `Expected local vendor directory: ${source}`);
    await fsp.symlink(source, path.join(tools, dir), 'junction');
  }
  return reconciler;
}

async function runE2eTests() {
  assert.equal(process.platform, 'win32', 'The offline update rehearsal uses a Windows file share lock');
  const baseline = JSON.parse(await fsp.readFile(path.join(OFFICIAL_DIR, 'official-baseline.json'), 'utf8'));
  assert.equal(baseline.status, 'verified');
  assert.equal(baseline.installerVersion, '2.34.0');
  assert.equal(baseline.signedBy, 'Google LLC');
  const manifest = new Map(baseline.members.map(({ relative, sha256: sha }) => [relative, sha]));
  assert.equal(manifest.get('resources/app.asar'), EXPECTED_OFFICIAL_SHA);
  assert.equal(manifest.get('resources/bin/language_server.exe'), EXPECTED_LS_SHA);
  assert.equal(sha256File(OFFICIAL_ASAR), EXPECTED_OFFICIAL_SHA, 'Official 2.34.0 ASAR fixture hash mismatch');
  assert.equal(sha256File(OFFICIAL_LS), EXPECTED_LS_SHA, 'Official 2.34.0 language server fixture hash mismatch');

  const tmpRoot = await createTestRoot('e2e');
  try {
    const reconciler = await prepareE2eReconciler(tmpRoot);
    const cli = (args) => runCli(args, reconciler);
    // Test 1: Full 4-layer reconcile on official 2.34.0
    const f1 = await setupFixture(tmpRoot, 'case1-full');
    const st0 = cli(['status', ...f1.commonArgs]);
    assert.equal(st0.status, 'needs-reconcile');
    assert.equal(st0.version, '2.34.0');

    const r1 = cli(['reconcile', '--apply', ...f1.commonArgs]);
    assert.equal(r1.status, 'applied');
    assert.deepEqual([...r1.appliedLayers].sort(), ALL_LAYERS);
    assert.equal(r1.skippedLayers.length, 0);
    assert.equal(r1.unchangedPackedMembers, 784, 'Expected exact unchanged packed members count for 2.34.0');

    const backupFile = path.join(f1.backupDir, 'app.asar.2.34.0.original');
    assert.equal(sha256File(backupFile), EXPECTED_OFFICIAL_SHA, 'Immutable backup SHA mismatch');

    const patchedAsarPath = path.join(f1.appDir, 'resources/app.asar');
    assert.equal(sha256File(patchedAsarPath), r1.combinedSha256);

    const langUi = path.join(f1.stateRoot, 'language-2.34.0/agy_zhcn_ui_main.js');
    assert.ok(fs.existsSync(langUi), 'Localized UI bundle missing');
    const langSettings = JSON.parse(fs.readFileSync(path.join(f1.stateRoot, 'language-2.34.0/settings.json'), 'utf8'));
    assert.equal(langSettings.onlineTranslate, false);
    assert.equal(langSettings.titleWriteBack, false);

    const ctxModules = JSON.parse(fs.readFileSync(path.join(f1.stateRoot, 'context/modules.json'), 'utf8'));
    assert.equal(ctxModules.modules.meter.enabled, true);
    assert.equal(ctxModules.modules.chinese.enabled, false);
    assert.equal(ctxModules.modules.proxy.enabled, false);

    const customSchemeSrc = unpackAsarMember(fs.readFileSync(patchedAsarPath), 'dist/customScheme.js').toString('utf8');
    assert.ok(customSchemeSrc.includes('post-quit-hook.json'), 'Hook path not redirected to D: stateRoot');
    assert.ok(customSchemeSrc.includes('__zhcnUpdaterRelaunchHandedOff'), 'will-quit duplicate guard missing');
    assert.ok(!customSchemeSrc.includes('agy_zhcn_autofollow_hook.json'), 'Old userData hook path still present');
    const updaterSrc = unpackAsarMember(fs.readFileSync(patchedAsarPath), 'dist/updater.js').toString('utf8');
    assert.ok(updaterSrc.includes('__zhcnUpdaterRelaunchHandedOff'), 'Updater relaunch hand-off missing');
    assert.ok(updaterSrc.includes('setAppUserModelId') && updaterSrc.includes('com.google.antigravity'), 'Updater canonical AUMID binding missing');
    assert.ok(updaterSrc.includes('setAppDetails'), 'Updater window relaunch details binding missing');
    assert.ok(!fs.existsSync(path.join(r1.stageDir, '.work')), '.work staging dir was not cleaned up');
    assert.ok(fs.existsSync(path.join(r1.stageDir, 'result.json')), 'Audit receipt missing');

    // Extract dist/* from the reconciled 2.34.0 ASAR and verify 2.34+ CSRF auth behavior end-to-end
    const extractedDist = path.join(tmpRoot, 'case1-extracted-dist');
    const reconciledBuf = await fsp.readFile(patchedAsarPath);
    const { header: recHeader, body: recBody } = unpackAsar(reconciledBuf);
    for (const [rel, entry] of walkAsar(recHeader)) {
      if (rel.startsWith('dist/') && !entry.unpacked && entry.offset !== undefined) {
        const dest = path.join(extractedDist, rel.slice('dist/'.length));
        await fsp.mkdir(path.dirname(dest), { recursive: true });
        await fsp.writeFile(dest, recBody.subarray(Number(entry.offset), Number(entry.offset) + entry.size));
      }
    }
    // The collector has a secondary status read that omits fixture options.
    const previousMeterTestMode = process.env.AG_METER_TEST_MODE;
    process.env.AG_METER_TEST_MODE = '1';
    try {
      await verifyPatchedContextDistBehavior(extractedDist, tmpRoot);
    } finally {
      if (previousMeterTestMode === undefined) delete process.env.AG_METER_TEST_MODE;
      else process.env.AG_METER_TEST_MODE = previousMeterTestMode;
    }
    console.log('E2E PASS 1: full 4-layer reconcile + 2.34+ CSRF auth gate on official 2.34.0');

    // Test 2: Idempotency fast-path
    const mtimeBefore = fs.statSync(patchedAsarPath).mtimeMs;
    const st1 = cli(['status', ...f1.commonArgs]);
    assert.equal(st1.status, 'up-to-date');
    assert.deepEqual([...st1.markers].sort(), ALL_MARKERS);
    const r2 = cli(['reconcile', '--apply', ...f1.commonArgs]);
    assert.equal(r2.status, 'up-to-date');
    assert.equal(fs.statSync(patchedAsarPath).mtimeMs, mtimeBefore, 'Up-to-date fast-path mutated app.asar');
    console.log('E2E PASS 2: idempotency fast-path');

    // Test 3: Double-patch refusal when active-build.json is missing
    await fsp.rm(path.join(f1.stateRoot, 'active-build.json'));
    const r3 = cli(['reconcile', '--apply', ...f1.commonArgs]);
    assert.equal(r3.status, 'refused-already-patched');
    assert.equal(sha256File(patchedAsarPath), r1.combinedSha256, 'Refused run mutated app.asar');
    console.log('E2E PASS 3: double-patch refusal');

    // Test 4: Clean rebuild from immutable backup
    const r4 = cli(['reconcile', '--from-backup', '--apply', ...f1.commonArgs]);
    assert.equal(r4.status, 'applied');
    assert.equal(r4.officialSha256, EXPECTED_OFFICIAL_SHA);
    assert.equal(r4.replaceTargetSha256, r1.combinedSha256);
    assert.deepEqual([...r4.appliedLayers].sort(), ALL_LAYERS);
    assert.equal(cli(['status', ...f1.commonArgs]).status, 'up-to-date');
    console.log('E2E PASS 4: clean rebuild from immutable backup');

    // Test 5: Stage-only + instant pending promotion
    const f2 = await setupFixture(tmpRoot, 'case2-pending');
    const r5 = cli(['reconcile', '--stage-only', ...f2.commonArgs]);
    assert.equal(r5.status, 'staged-pending');
    assert.equal(sha256File(f2.asarPath), EXPECTED_OFFICIAL_SHA, 'stage-only touched live app.asar');
    assert.ok(fs.existsSync(path.join(f2.stateRoot, 'pending-app.asar')));
    assert.ok(fs.existsSync(path.join(f2.stateRoot, 'pending-apply.json')));
    assert.equal(cli(['status', ...f2.commonArgs]).status, 'pending-ready');

    const r5b = cli(['reconcile', '--apply', ...f2.commonArgs]);
    assert.equal(r5b.status, 'applied-from-pending');
    assert.equal(sha256File(f2.asarPath), r5.combinedSha256);
    assert.ok(!fs.existsSync(path.join(f2.stateRoot, 'pending-app.asar')));
    assert.ok(!fs.existsSync(path.join(f2.stateRoot, 'pending-apply.json')));
    assert.equal(cli(['status', ...f2.commonArgs]).status, 'up-to-date');
    console.log('E2E PASS 5: stage-only and instant pending promotion');

    // Test 6: Fail-closed per-layer degradation when an upstream anchor breaks
    const f3 = await setupFixture(tmpRoot, 'case3-degrade');
    const brokenAsarPath = path.join(f3.appDir, 'resources/app.asar');
    const mutatedBuf = replaceMemberInAsar(fs.readFileSync(brokenAsarPath), 'dist/utils.js', (src) => {
      const needle = '    void loadHubWindowUrl(win, url, { skipBootstrapMint });';
      assert.ok(src.includes(needle), 'Fixture anchor missing');
      return src.replace(needle, '    void unknownUpstreamNavV99(win, url);');
    });
    await fsp.writeFile(brokenAsarPath, mutatedBuf);

    const r6 = cli(['reconcile', '--apply', ...f3.commonArgs]);
    assert.equal(r6.status, 'applied');
    assert.deepEqual([...r6.appliedLayers].sort(), ['language', 'pulse', 'updater', 'wsl']);
    assert.equal(r6.skippedLayers.length, 1);
    assert.equal(r6.skippedLayers[0].layer, 'contextViewer');
    console.log('E2E PASS 6: fail-closed per-layer degradation');

    // Reinstall the verified official bytes over the patched 2.34.0 fixture, then simulate the NSIS relaunch lock.
    await installOfficialPayload(f1);
    await verifyLockedUpdate(f1, reconciler, '2.34.0', EXPECTED_OFFICIAL_SHA, EXPECTED_LS_SHA, ALL_LAYERS, ALL_MARKERS);
    console.log('E2E PASS 7: signed 2.34.0 payload overwrite, lock, all four layers promoted, original backup preserved');

    console.log('ALL 7 E2E RECONCILER TESTS PASSED');
  } finally {
    await fsp.rm(tmpRoot, { recursive: true, force: true }).catch(() => {});
  }
}

async function main() {
  const args = new Set(process.argv.slice(2));
  const unitOnly = args.has('--unit');
  const e2eOnly = args.has('--e2e');
  if (!e2eOnly) await runUnitTests();
  if (!unitOnly) await runE2eTests();
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exitCode = 1;
});
