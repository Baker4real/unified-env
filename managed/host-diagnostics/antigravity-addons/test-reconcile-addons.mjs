import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import http from 'node:http';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  applyWslLayer,
  patchContextLocalApi,
  patchContextMeterCollector,
  patchContextMeterRenderer,
  detectAddonMarkers,
  detectHubLoadAnchor,
  packAsarWithOverlay,
  parseArgs,
  unpackAsar,
  walkAsar,
} from './reconcile-addons.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const RECONCILER = path.join(SCRIPT_DIR, 'reconcile-addons.mjs');
const OFFICIAL_DIR = 'D:/agents/run-evidence/antigravity-addons/20261121-desktop-2.34.0/official/resources';
const OFFICIAL_ASAR = path.join(OFFICIAL_DIR, 'app.asar');
const OFFICIAL_LS = path.join(OFFICIAL_DIR, 'bin/language_server.exe');
const EXPECTED_OFFICIAL_SHA = '8934adef0622c9271c92eea950a71848764a66f7b10023ccbd82e54b959adb0e';

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
}

function getTempBase() {
  if (fs.existsSync('D:/agents/tmp')) return 'D:/agents/tmp';
  if (process.env.TEMP && fs.existsSync(process.env.TEMP)) return process.env.TEMP;
  return os.tmpdir();
}

async function runUnitTests() {
  const tmpRoot = path.join(getTempBase(), `reconcile-unit-${Date.now()}-${process.pid}`);
  await fsp.mkdir(tmpRoot, { recursive: true });
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

    // Unit 2: detectAddonMarkers detects all 5 markers (including escaped Lxss path) and empty on clean ASAR
    const cleanUnpacked = unpackAsar(baseAsar);
    assert.deepEqual(detectAddonMarkers(walkAsar(cleanUnpacked.header), cleanUnpacked.body), []);

    const patchedAsar = buildSyntheticAsar({
      'dist/customScheme.js': "callback({ redirectURL: 'agy-zhcn://bundle/main.js' });",
      'dist/preload.js': '// AGY_CONTEXT_CAPSULE_START\n// Antigravity Context Meter preload Injection Start\n',
      'dist/utils.js': '// Antigravity Context Meter utils Injection Start\n',
      'dist/wsl.js': "const key = 'HKCU\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Lxss';\n",
    });
    const patchedUnpacked = unpackAsar(patchedAsar);
    assert.deepEqual(
      detectAddonMarkers(walkAsar(patchedUnpacked.header), patchedUnpacked.body).sort(),
      ['context-viewer-preload', 'context-viewer-utils', 'desktop-zhcn', 'pulse', 'wsl'],
    );
    console.log('UNIT PASS 2: detectAddonMarkers detects all 5 markers accurately');

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
    console.log('ALL 6 UNIT TESTS PASSED');
  } finally {
    await fsp.rm(tmpRoot, { recursive: true, force: true }).catch(() => {});
  }
}

function runCli(args) {
  const res = spawnSync(process.execPath, [RECONCILER, ...args], {
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

async function setupFixture(rootDir, name) {
  const base = path.join(rootDir, name);
  const appDir = path.join(base, 'app');
  const backupDir = path.join(base, 'backup');
  const stateRoot = path.join(base, 'state');
  const evidenceRoot = path.join(base, 'evidence');
  await fsp.mkdir(path.join(appDir, 'resources/bin'), { recursive: true });
  await fsp.copyFile(OFFICIAL_ASAR, path.join(appDir, 'resources/app.asar'));
  try {
    await fsp.link(OFFICIAL_LS, path.join(appDir, 'resources/bin/language_server.exe'));
  } catch {
    await fsp.copyFile(OFFICIAL_LS, path.join(appDir, 'resources/bin/language_server.exe'));
  }
  return {
    appDir,
    backupDir,
    stateRoot,
    evidenceRoot,
    commonArgs: ['--app-dir', appDir, '--backup-dir', backupDir, '--state-root', stateRoot, '--evidence-root', evidenceRoot],
  };
}

async function runE2eTests() {
  assert.equal(sha256File(OFFICIAL_ASAR), EXPECTED_OFFICIAL_SHA, 'Official 2.34.0 fixture hash mismatch');

  const tmpRoot = path.join(getTempBase(), `reconcile-e2e-${Date.now()}-${process.pid}`);
  await fsp.mkdir(tmpRoot, { recursive: true });
  try {
    // Test 1: Full 4-layer reconcile on official 2.34.0
    const f1 = await setupFixture(tmpRoot, 'case1-full');
    const st0 = runCli(['status', ...f1.commonArgs]);
    assert.equal(st0.status, 'needs-reconcile');
    assert.equal(st0.version, '2.34.0');

    const r1 = runCli(['reconcile', '--apply', ...f1.commonArgs]);
    assert.equal(r1.status, 'applied');
    assert.deepEqual([...r1.appliedLayers].sort(), ['contextViewer', 'language', 'pulse', 'wsl']);
    assert.equal(r1.skippedLayers.length, 0);
    assert.equal(r1.unchangedPackedMembers, 785, 'Expected exact unchanged packed members count for 2.34.0');

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
    assert.ok(!customSchemeSrc.includes('agy_zhcn_autofollow_hook.json'), 'Old userData hook path still present');
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
    const st1 = runCli(['status', ...f1.commonArgs]);
    assert.equal(st1.status, 'up-to-date');
    assert.deepEqual([...st1.markers].sort(), ['context-viewer-preload', 'context-viewer-utils', 'desktop-zhcn', 'pulse', 'wsl']);
    const r2 = runCli(['reconcile', '--apply', ...f1.commonArgs]);
    assert.equal(r2.status, 'up-to-date');
    assert.equal(fs.statSync(patchedAsarPath).mtimeMs, mtimeBefore, 'Up-to-date fast-path mutated app.asar');
    console.log('E2E PASS 2: idempotency fast-path');

    // Test 3: Double-patch refusal when active-build.json is missing
    await fsp.rm(path.join(f1.stateRoot, 'active-build.json'));
    const r3 = runCli(['reconcile', '--apply', ...f1.commonArgs]);
    assert.equal(r3.status, 'refused-already-patched');
    assert.equal(sha256File(patchedAsarPath), r1.combinedSha256, 'Refused run mutated app.asar');
    console.log('E2E PASS 3: double-patch refusal');

    // Test 4: Clean rebuild from immutable backup
    const r4 = runCli(['reconcile', '--from-backup', '--apply', ...f1.commonArgs]);
    assert.equal(r4.status, 'applied');
    assert.equal(r4.officialSha256, EXPECTED_OFFICIAL_SHA);
    assert.equal(r4.replaceTargetSha256, r1.combinedSha256);
    assert.deepEqual([...r4.appliedLayers].sort(), ['contextViewer', 'language', 'pulse', 'wsl']);
    assert.equal(runCli(['status', ...f1.commonArgs]).status, 'up-to-date');
    console.log('E2E PASS 4: clean rebuild from immutable backup');

    // Test 5: Stage-only + instant pending promotion
    const f2 = await setupFixture(tmpRoot, 'case2-pending');
    const r5 = runCli(['reconcile', '--stage-only', ...f2.commonArgs]);
    assert.equal(r5.status, 'staged-pending');
    assert.equal(sha256File(path.join(f2.appDir, 'resources/app.asar')), EXPECTED_OFFICIAL_SHA, 'stage-only touched live app.asar');
    assert.ok(fs.existsSync(path.join(f2.stateRoot, 'pending-app.asar')));
    assert.ok(fs.existsSync(path.join(f2.stateRoot, 'pending-apply.json')));
    assert.equal(runCli(['status', ...f2.commonArgs]).status, 'pending-ready');

    const r5b = runCli(['reconcile', '--apply', ...f2.commonArgs]);
    assert.equal(r5b.status, 'applied-from-pending');
    assert.equal(sha256File(path.join(f2.appDir, 'resources/app.asar')), r5.combinedSha256);
    assert.ok(!fs.existsSync(path.join(f2.stateRoot, 'pending-app.asar')));
    assert.ok(!fs.existsSync(path.join(f2.stateRoot, 'pending-apply.json')));
    assert.equal(runCli(['status', ...f2.commonArgs]).status, 'up-to-date');
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

    const r6 = runCli(['reconcile', '--apply', ...f3.commonArgs]);
    assert.equal(r6.status, 'applied');
    assert.deepEqual([...r6.appliedLayers].sort(), ['language', 'pulse', 'wsl']);
    assert.equal(r6.skippedLayers.length, 1);
    assert.equal(r6.skippedLayers[0].layer, 'contextViewer');
    console.log('E2E PASS 6: fail-closed per-layer degradation');

    console.log('ALL 6 E2E RECONCILER TESTS PASSED');
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
