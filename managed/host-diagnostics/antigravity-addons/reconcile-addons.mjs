import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

const RECONCILER_FILE = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(RECONCILER_FILE);
const DEFAULT_APP_DIR = 'D:/Apps/Google.Antigravity';
const DEFAULT_BACKUP_DIR = 'D:/Apps/Google.Antigravity.Local';
const DEFAULT_TOOLS_DIR = SCRIPT_DIR;
const DEFAULT_STATE_ROOT = path.join(DEFAULT_TOOLS_DIR, 'state');
const DEFAULT_EVIDENCE_ROOT = 'D:/agents/run-evidence/antigravity-addons';
const ZHCN_PACK_DIR = path.join(DEFAULT_TOOLS_DIR, 'desktop-zhcn-v3.0.8/antigravity汉化包/语言包');
const ZHCN_LIB_DIR = path.join(ZHCN_PACK_DIR, '核心程序/src/lib');
const PULSE_DIR = path.join(DEFAULT_TOOLS_DIR, 'pulse-v1.3.2');
const CONTEXT_DIR = path.join(DEFAULT_TOOLS_DIR, 'context-viewer-v0.8.8');

const CONTEXT_VENDOR_FILES = [
  'asar-engine.js', 'modules-config.js', 'modular-installer.js', 'install.js', 'restore.js',
  'meter-main.js', 'meter-core.js', 'meter-renderer.js', 'meter-collector.js', 'meter-storage.js',
  'meter-proxy.js', 'meter-cli-launcher.js', 'meter-context-unlock.js', 'meter-enhance.js',
  'meter-accounts.js', 'macos-binary-utils.js', 'local-api.js', 'attachment_scan.py',
  'i18n/zh-CN.json', 'i18n/i18n-runtime.js',
];

const DEFAULT_CONTEXT_MODULES = {
  schemaVersion: '0.8.8',
  modules: {
    meter: { enabled: true },
    chinese: { enabled: false, language: 'en', brandTitle: 'english' },
    proxy: { enabled: false },
  },
};

const require = createRequire(import.meta.url);

function sha256(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

async function sha256File(filePath) {
  return sha256(await fsp.readFile(filePath));
}

function toPosix(p) {
  return p.replaceAll('\\', '/');
}

function countOccurrences(text, needle) {
  if (!needle) return 0;
  return text.split(needle).length - 1;
}

// ---------------------------------------------------------------------------
// Pure in-memory ASAR reader & writer
// ---------------------------------------------------------------------------

function unpackAsar(buffer) {
  if (buffer.length < 16) throw new Error('ASAR buffer too small');
  const marker = buffer.readUInt32LE(0);
  const headerSize = buffer.readUInt32LE(4);
  const payloadSize = buffer.readUInt32LE(8);
  const jsonSize = buffer.readUInt32LE(12);
  if (marker !== 4 || headerSize !== payloadSize + 4 || payloadSize - 4 - jsonSize < 0 || payloadSize - 4 - jsonSize > 3) {
    throw new Error('Unexpected ASAR header framing');
  }
  const header = JSON.parse(buffer.toString('utf8', 16, 16 + jsonSize));
  const body = buffer.subarray(8 + headerSize);
  return { header, body };
}

function walkAsar(node, prefix = '', out = new Map()) {
  for (const [name, entry] of Object.entries(node.files || {})) {
    const rel = prefix + name;
    if (entry.files) {
      walkAsar(entry, rel + '/', out);
    } else {
      out.set(rel, entry);
    }
  }
  return out;
}

function getAsarMember(body, entry) {
  if (!entry || entry.offset === undefined) throw new Error('Entry has no packed offset');
  const start = Number(entry.offset);
  return body.subarray(start, start + entry.size);
}

function buildIntegrity(data, blockSize = 4194304) {
  const hash = sha256(data);
  const blocks = [];
  if (data.length === 0) {
    blocks.push(hash);
  } else {
    for (let i = 0; i < data.length; i += blockSize) {
      blocks.push(sha256(data.subarray(i, Math.min(data.length, i + blockSize))));
    }
  }
  return { algorithm: 'SHA256', hash, blockSize, blocks };
}

function packAsarWithOverlay(officialBuffer, replacements, additions) {
  const { header, body } = unpackAsar(officialBuffer);
  const entries = walkAsar(header);
  const origMeta = new Map();
  for (const [rel, e] of entries.entries()) {
    origMeta.set(rel, {
      offset: e.offset,
      size: e.size,
      unpacked: Boolean(e.unpacked),
      link: e.link,
      executable: Boolean(e.executable),
    });
  }

  // Verify packed contiguous layout and rebuild packed stream in original offset order
  const packedEntries = [...entries.entries()]
    .filter(([, entry]) => entry.offset !== undefined && !entry.unpacked)
    .sort((a, b) => Number(a[1].offset) - Number(b[1].offset) || (a[1].size === 0 ? -1 : 1));

  const chunks = [];
  let sourceCursor = 0;
  let currentOffset = 0;

  for (const [rel, entry] of packedEntries) {
    const origStart = Number(entry.offset);
    const origSize = entry.size;
    if (origStart !== sourceCursor) {
      throw new Error(`Non-contiguous ASAR layout at ${rel}: expected ${sourceCursor}, got ${origStart}`);
    }
    const data = replacements.has(rel) ? replacements.get(rel) : body.subarray(origStart, origStart + origSize);
    entry.offset = String(currentOffset);
    entry.size = data.length;
    if (replacements.has(rel)) {
      const blockSize = entry.integrity?.blockSize || 4194304;
      entry.integrity = buildIntegrity(data, blockSize);
    }
    chunks.push(data);
    sourceCursor += origSize;
    currentOffset += data.length;
  }
  if (sourceCursor !== body.length) {
    throw new Error(`ASAR body tail mismatch: cursor=${sourceCursor}, len=${body.length}`);
  }

  for (const rel of [...additions.keys()].sort()) {
    if (entries.has(rel)) {
      throw new Error(`Addition collides with existing ASAR member: ${rel}`);
    }
    const data = additions.get(rel);
    const parts = rel.split('/');
    const leaf = parts.pop();
    let dirNode = header.files;
    for (const part of parts) {
      if (!dirNode[part]) dirNode[part] = { files: {} };
      dirNode = dirNode[part].files;
    }
    dirNode[leaf] = {
      size: data.length,
      offset: String(currentOffset),
      integrity: buildIntegrity(data, 4194304),
    };
    chunks.push(data);
    currentOffset += data.length;
  }

  const headerBytes = Buffer.from(JSON.stringify(header), 'utf8');
  const padded = (headerBytes.length + 3) & ~3;
  const prefix = Buffer.alloc(16 + padded, 0);
  prefix.writeUInt32LE(4, 0);
  prefix.writeUInt32LE(8 + padded, 4);
  prefix.writeUInt32LE(4 + padded, 8);
  prefix.writeUInt32LE(headerBytes.length, 12);
  headerBytes.copy(prefix, 16);

  const assembled = Buffer.concat([prefix, ...chunks]);

  // Independent structural & byte-for-byte readback check
  const { header: newHeader, body: newBody } = unpackAsar(assembled);
  const newEntries = walkAsar(newHeader);
  const expectedKeys = new Set([...entries.keys(), ...additions.keys()]);
  if (newEntries.size !== expectedKeys.size) {
    throw new Error(`ASAR entry count mismatch: expected ${expectedKeys.size}, got ${newEntries.size}`);
  }
  let unchangedCount = 0;
  for (const [rel, oldEntry] of origMeta.entries()) {
    const newEntry = newEntries.get(rel);
    if (!newEntry) throw new Error(`Missing member after repack: ${rel}`);
    if (oldEntry.unpacked !== Boolean(newEntry.unpacked) || oldEntry.link !== newEntry.link || oldEntry.executable !== Boolean(newEntry.executable)) {
      throw new Error(`Metadata flag drift for ${rel}`);
    }
    if (oldEntry.unpacked || oldEntry.link) {
      if (oldEntry.size !== newEntry.size) throw new Error(`Unpacked/link size drift for ${rel}`);
      continue;
    }
    const actual = getAsarMember(newBody, newEntry);
    if (replacements.has(rel)) {
      const expected = replacements.get(rel);
      if (!actual.equals(expected)) throw new Error(`Modified member mismatch: ${rel}`);
      if (newEntry.integrity?.hash !== sha256(actual)) throw new Error(`Modified member integrity hash mismatch: ${rel}`);
    } else {
      const orig = getAsarMember(body, oldEntry);
      if (!actual.equals(orig)) throw new Error(`Untouched member drifted: ${rel}`);
      unchangedCount++;
    }
  }
  for (const [rel, expected] of additions.entries()) {
    const newEntry = newEntries.get(rel);
    if (!newEntry) throw new Error(`Added member missing: ${rel}`);
    const actual = getAsarMember(newBody, newEntry);
    if (!actual.equals(expected)) throw new Error(`Added member mismatch: ${rel}`);
    if (newEntry.integrity?.hash !== sha256(actual)) throw new Error(`Added member integrity hash mismatch: ${rel}`);
  }

  return { buffer: assembled, unchangedCount };
}

function verifyNodeSyntax(code, stageDir, label) {
  new vm.Script(code, { filename: label });
  const checkFile = path.join(stageDir, 'syntax-' + label.replace(/[^a-zA-Z0-9._-]/g, '_'));
  fs.writeFileSync(checkFile, code, 'utf8');
  const res = spawnSync(process.execPath, ['--check', checkFile], { encoding: 'utf8', timeout: 15000 });
  if (res.status !== 0) {
    throw new Error(`node --check failed for ${label}: ${(res.stderr || '').trim()}`);
  }
}

// ---------------------------------------------------------------------------
// Layer 1: WSL guard (dist/wsl.js)
// ---------------------------------------------------------------------------

function applyWslLayer(origSource, stageDir) {
  const hideOld = '            timeout: 30000,\n        });\n        return decodeWslOutput(stdout);';
  const hideNew = '            timeout: 30000,\n            windowsHide: true,\n        });\n        return decodeWslOutput(stdout);';
  const listOld = "async function listWslDistros() {\n    const output = await execWsl(['--list', '--verbose']);";
  const listNew = [
    'async function listWslDistros() {',
    '    // Windows keeps the wsl.exe launcher even when WSL has been uninstalled.',
    '    // A distribution must be registered before querying that launcher.',
    '    if (!isWslAvailable()) {',
    '        return [];',
    '    }',
    '    try {',
    "        const { stdout } = await execFileAsync(path.join(path.dirname(exports.WSL_EXE), 'reg.exe'), [",
    "            'query', 'HKCU\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Lxss', '/s', '/v', 'DistributionName',",
    "        ], { encoding: 'buffer', timeout: 2000, windowsHide: true });",
    '        if (!/\\bDistributionName[ \\t]+REG_SZ[ \\t]+\\S/.test(decodeWslOutput(stdout))) {',
    '            return [];',
    '        }',
    '    }',
    '    catch {',
    '        return [];',
    '    }',
    "    const output = await execWsl(['--list', '--verbose']);",
  ].join('\n');

  if (countOccurrences(origSource, hideOld) !== 1 || countOccurrences(origSource, listOld) !== 1) {
    return { status: 'skipped', reason: 'Upstream dist/wsl.js anchor changed or already guarded (IFEO host guard still active)' };
  }
  const patched = origSource.replace(hideOld, () => hideNew).replace(listOld, () => listNew);
  verifyNodeSyntax(patched, stageDir, 'dist/wsl.js');

  // Offline behavioral fixture
  const runCase = async ({ registry = null, platform = 'win32', launcherExists = true } = {}) => {
    const calls = [];
    const exp = {};
    const deps = {
      child_process: {
        execFile(exe, args, opts, cb) {
          const name = path.win32.basename(exe);
          calls.push([name, [...args], opts.windowsHide]);
          if (registry === null) return cb(new Error('absent'));
          if (name === 'reg.exe') return cb(null, { stdout: Buffer.from(registry) });
          cb(null, { stdout: Buffer.from('\uFEFF  NAME STATE VERSION\r\n* Ubuntu Running 2\r\n  Debian Stopped 1\r\n  docker-desktop Running 2\r\n', 'utf16le') });
        },
      },
      fs: { existsSync: () => launcherExists },
      crypto: {},
      path: path.win32,
      util: { promisify },
      'js-yaml': {},
    };
    vm.runInNewContext(patched, {
      exports: exp,
      Buffer,
      process: { platform, env: { SystemRoot: 'C:\\Windows' } },
      require: (name) => {
        if (!Object.hasOwn(deps, name)) throw new Error(`Unexpected WSL require: ${name}`);
        return deps[name];
      },
    }, { filename: 'dist/wsl.js' });
    const distros = await exp.listWslDistros();
    return { calls, distros };
  };

  return {
    status: 'ready',
    source: patched,
    verifyAsync: async () => {
      const noDistro = await runCase({ registry: null });
      if (noDistro.distros.length !== 0 || noDistro.calls.length !== 1 || noDistro.calls[0][0] !== 'reg.exe' || noDistro.calls[0][2] !== true) {
        throw new Error('WSL noDistro behavioral gate failed');
      }
      const wsl2 = await runCase({ registry: '    DistributionName    REG_SZ    Ubuntu\r\n' });
      if (wsl2.distros.length !== 1 || wsl2.distros[0].name !== 'Ubuntu' || wsl2.calls.length !== 2 || wsl2.calls[1][0] !== 'wsl.exe' || wsl2.calls[1][2] !== true) {
        throw new Error('WSL registeredWsl2 behavioral gate failed');
      }
      const nonWin = await runCase({ platform: 'linux' });
      if (nonWin.distros.length !== 0 || nonWin.calls.length !== 0) {
        throw new Error('WSL nonWindows behavioral gate failed');
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Layer 2: desktop-zhcn (3.0.8)
// ---------------------------------------------------------------------------

async function applyLanguageLayer({ appAsarPath, hostVersion, origCustomScheme, origLoadingOverlay, stateRoot, postQuitHookPath, stageDir }) {
  const fromLib = (name) => import(pathToFileURL(path.join(ZHCN_LIB_DIR, name)).href);
  const prevPack = process.env.AGY_LANGUAGE_PACK;
  const prevState = process.env.AGY_ZHCN_STATE_DIR;
  process.env.AGY_LANGUAGE_PACK = ZHCN_PACK_DIR;
  process.env.AGY_ZHCN_STATE_DIR = stageDir;
  try {
    const { readEmbeddedWindowsUi } = await fromLib('runtime-bundle.mjs');
    const { loadDomTranslations } = await fromLib('translator.mjs');
    const { createLocalizedBundleWithProgress } = await fromLib('localize-progress.mjs');
    const { patchCustomSchemeSource, patchLoadingOverlaySource } = await fromLib('patcher-d-hosted.mjs');

    const embedded = await readEmbeddedWindowsUi({ appAsarPath });
    if (!embedded || embedded.source !== 'embedded' || !embedded.buffer || embedded.buffer.length < 500_000) {
      return { status: 'skipped', reason: 'Embedded UI bundle could not be extracted from language_server.exe' };
    }
    const dictionary = await loadDomTranslations();
    const localized = await createLocalizedBundleWithProgress(embedded.buffer, dictionary, { skipCoverage: true, log: () => {} });
    if (!localized || !localized.buffer || localized.buffer.equals(embedded.buffer)) {
      return { status: 'skipped', reason: 'Localization produced no changes against embedded UI bundle' };
    }
    const uiStagePath = path.join(stageDir, 'agy_zhcn_ui_main.js');
    await fsp.writeFile(uiStagePath, localized.buffer);
    const uiCheck = spawnSync(process.execPath, ['--check', uiStagePath], { encoding: 'utf8', timeout: 30000 });
    if (uiCheck.status !== 0) {
      throw new Error(`Localized UI bundle syntax check failed: ${(uiCheck.stderr || '').trim()}`);
    }

    const versionStateDir = toPosix(path.join(stateRoot, `language-${hostVersion}`));
    let patchedScheme = patchCustomSchemeSource(origCustomScheme);

    const defaultStateLiteral = '"D:/Codex/tools/antigravity-addons/state/language"';
    if (countOccurrences(patchedScheme, defaultStateLiteral) !== 1) {
      throw new Error('Unexpected state directory literal count in patched customScheme.js');
    }
    patchedScheme = patchedScheme.replace(defaultStateLiteral, () => JSON.stringify(versionStateDir));

    const oldHookExpr = "path.join(electron_1.app.getPath('userData'), 'agy_zhcn_autofollow_hook.json')";
    if (countOccurrences(patchedScheme, oldHookExpr) === 1 && postQuitHookPath) {
      patchedScheme = patchedScheme.replace(oldHookExpr, () => JSON.stringify(toPosix(postQuitHookPath)));
    }

    const willQuitAnchor = "            electron_1.app.on('will-quit', () => {\n                try {";
    const willQuitGuarded = "            electron_1.app.on('will-quit', () => {\n                if (electron_1.app.__zhcnUpdaterRelaunchHandedOff) return;\n                try {";
    if (countOccurrences(patchedScheme, willQuitAnchor) === 1) {
      patchedScheme = patchedScheme.replace(willQuitAnchor, () => willQuitGuarded);
    }

    if (!patchedScheme.includes('agy-zhcn://bundle/main.js') || !patchedScheme.includes('onlineTranslate: false, titleWriteBack: false')) {
      throw new Error('Patched customScheme.js missing expected loader or offline defaults');
    }
    verifyNodeSyntax(patchedScheme, stageDir, 'dist/customScheme.js');

    let patchedOverlay = null;
    if (origLoadingOverlay !== null) {
      const candidateOverlay = patchLoadingOverlaySource(origLoadingOverlay);
      if (candidateOverlay !== origLoadingOverlay) {
        verifyNodeSyntax(candidateOverlay, stageDir, 'dist/loadingOverlay.js');
        patchedOverlay = candidateOverlay;
      }
    }

    return {
      status: 'applied',
      version: '3.0.8',
      customScheme: patchedScheme,
      loadingOverlay: patchedOverlay,
      uiBuffer: localized.buffer,
      uiSha256: sha256(localized.buffer),
      embeddedUiSha256: sha256(embedded.buffer),
      stateDir: versionStateDir,
    };
  } finally {
    if (prevPack === undefined) delete process.env.AGY_LANGUAGE_PACK; else process.env.AGY_LANGUAGE_PACK = prevPack;
    if (prevState === undefined) delete process.env.AGY_ZHCN_STATE_DIR; else process.env.AGY_ZHCN_STATE_DIR = prevState;
  }
}

// ---------------------------------------------------------------------------
// Layer 3: pulse (1.3.2, embed-only)
// ---------------------------------------------------------------------------

function applyPulseLayer(officialBuffer, origPreload, stageDir) {
  const pulse = require(path.join(PULSE_DIR, 'install-context-capsule.js'));
  const payload = fs.readFileSync(path.join(PULSE_DIR, 'context-capsule-payload.js'), 'utf8');
  new vm.Script(payload, { filename: 'context-capsule-payload.js' });

  if (!origPreload.includes('const electron_1 = require("electron");') || !origPreload.includes('electron_1.webFrame.executeJavaScript')) {
    return { status: 'skipped', reason: 'Upstream dist/preload.js missing electron_1/webFrame anchors' };
  }

  const patchedBuf = pulse.patchAsarBufferInMemory(officialBuffer, payload, { embedOnly: true });
  const { header, body } = unpackAsar(patchedBuf);
  const preloadEntry = walkAsar(header).get('dist/preload.js');
  const pulsePreload = getAsarMember(body, preloadEntry).toString('utf8');
  if (!pulsePreload.startsWith(origPreload)) {
    throw new Error('Pulse preload transform did not append cleanly to official preload.js');
  }
  const snippet = pulsePreload.slice(origPreload.length);
  if (!snippet.includes(pulse.CAPSULE_START) || !snippet.includes(pulse.CAPSULE_END) || snippet.includes(pulse.HOT_LOADER_TAG)) {
    throw new Error('Pulse snippet failed embed-only marker checks');
  }

  // Offline behavioral fixture
  const script = new vm.Script(snippet, { filename: 'pulse-loader.js' });
  const expectedPayloadSha = sha256(Buffer.from(payload, 'utf8'));
  for (const readyState of ['loading', 'complete']) {
    const observed = [];
    const events = {};
    const timers = {};
    script.runInNewContext({
      electron_1: { webFrame: { executeJavaScript: (val) => { observed.push(sha256(Buffer.from(String(val), 'utf8'))); } } },
      document: { readyState, addEventListener: (n, cb) => { events[n] = cb; } },
      window: { addEventListener: (n, cb) => { events[n] = cb; } },
      setTimeout: (cb, delay) => { timers[delay] = cb; },
    });
    if (observed.length !== (readyState === 'loading' ? 0 : 1)) throw new Error(`Pulse immediate count mismatch (${readyState})`);
    if (readyState === 'loading') events.DOMContentLoaded();
    events.load();
    timers[600]();
    timers[2000]();
    if (observed.length !== 4 || !observed.every((h) => h === expectedPayloadSha)) {
      throw new Error(`Pulse delivery fixture mismatch (${readyState})`);
    }
  }
  verifyNodeSyntax(origPreload + snippet, stageDir, 'dist/preload-pulse.js');
  return {
    status: 'applied',
    version: pulse.INSTALLER_VERSION || '1.3.2',
    payloadSha256: expectedPayloadSha,
    snippet,
  };
}

// ---------------------------------------------------------------------------
// Layer 4: context-viewer (0.8.8, meter-only, resilient anchor)
// ---------------------------------------------------------------------------

function replaceUniqueAnchor(text, oldStr, newStr, label) {
  const count = countOccurrences(text, oldStr);
  if (count !== 1) {
    throw new Error(`Anchor ${label} matched ${count} times (expected 1)`);
  }
  return text.replace(oldStr, () => newStr);
}

function patchContextLocalApi(raw) {
  const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  let norm = text.replace(/\r\n/g, '\n');

  norm = replaceUniqueAnchor(
    norm,
    "const fs = require('fs');\nconst path = require('path');\n",
    "const fs = require('fs');\nconst os = require('os');\nconst path = require('path');\n",
    'local-api:require-os',
  );

  norm = replaceUniqueAnchor(
    norm,
    "        expression:\n          '(() => { try { if (!window.__APP_CONFIG__) return null; return { hasConfig: true, csrfToken: window.__APP_CONFIG__.csrfToken || \"\" }; } catch (e) { return null; } })()',\n",
    "        expression:\n          '(() => { try { const cfg = window.__APP_CONFIG__; const tok = (cfg && cfg.csrfToken) || (window.localStorage && window.localStorage.getItem(\"agy_session_csrf_token\")) || \"\"; if (!cfg && !tok) return null; return { hasConfig: Boolean(cfg || tok), csrfToken: tok }; } catch (e) { return null; } })()',\n",
    'local-api:cdp-expr',
  );

  const oldConnectBlock = `/**
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

  const newConnectBlock = `function isPidAlive(pid) {
  const num = Number(pid);
  if (!Number.isInteger(num) || num <= 0) return false;
  try {
    process.kill(num, 0);
    return true;
  } catch (e) {
    return e?.code === 'EPERM';
  }
}

function loadOptionalAuthBootstrap() {
  try {
    return require('./authBootstrap');
  } catch {
    return null;
  }
}

function resolveAuthBootstrapCsrfToken(rawOrigin, options = {}) {
  const origin = normalizeLoopbackOrigin(rawOrigin);
  if (!origin) return null;
  const authMod = options && options.authBootstrap !== undefined
    ? options.authBootstrap
    : loadOptionalAuthBootstrap();
  if (!authMod || typeof authMod !== 'object') return null;
  try {
    const token = typeof authMod.getActiveLsCsrfToken === 'function'
      ? String(authMod.getActiveLsCsrfToken() || '').trim()
      : '';
    if (!token) return null;
    let activeBase = typeof authMod.getActiveLsBaseUrl === 'function'
      ? normalizeLoopbackOrigin(authMod.getActiveLsBaseUrl())
      : null;
    if (!activeBase && typeof authMod.getActiveLsPort === 'function') {
      const port = parseExplicitPort(authMod.getActiveLsPort());
      if (port) activeBase = \`https://127.0.0.1:\${port}\`;
    }
    if (!activeBase || activeBase !== origin) return null;
    return token;
  } catch {
    return null;
  }
}

function resolveDaemonHubCsrfToken(rawOrigin, options = {}) {
  const origin = normalizeLoopbackOrigin(rawOrigin);
  if (!origin) return null;
  const inIsolatedTest =
    Boolean(options && (options.appDataDir || options.platform)) ||
    process.env.AG_METER_TEST_MODE === '1' ||
    isIsolatedTestPath(process.env.APPDATA) ||
    isIsolatedTestPath(process.env.AG_METER_STATE_DIR);
  if (inIsolatedTest && !options?.daemonDir && !options?.homeDir) {
    return null;
  }
  const daemonDir = options?.daemonDir || path.join(options?.homeDir || os.homedir(), '.gemini', 'antigravity', 'daemon');
  const checkAlive = typeof options?.isPidAlive === 'function' ? options.isPidAlive : isPidAlive;
  const matches = [];
  try {
    if (!fs.existsSync(daemonDir)) return null;
    const files = fs.readdirSync(daemonDir);
    for (const name of files) {
      if (!/^hub_.*\\.json$/i.test(name)) continue;
      const filePath = path.join(daemonDir, name);
      try {
        const st = fs.statSync(filePath);
        const raw = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        const csrfToken = typeof raw?.csrfToken === 'string' ? raw.csrfToken.trim() : '';
        if (!csrfToken) continue;
        if (!checkAlive(raw?.pid)) continue;
        const httpsPort = parseExplicitPort(raw?.httpsPort);
        const httpPort = parseExplicitPort(raw?.httpPort);
        const originMatches =
          (httpsPort && origin === \`https://127.0.0.1:\${httpsPort}\`) ||
          (httpPort && origin === \`http://127.0.0.1:\${httpPort}\`);
        if (!originMatches) continue;
        matches.push({ csrfToken, mtimeMs: Number(st.mtimeMs) || 0 });
      } catch { }
    }
  } catch {
    return null;
  }
  if (matches.length === 0) return null;
  matches.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return matches[0].csrfToken;
}

function extractCsrfTokenFromHtml(html) {
  if (typeof html !== 'string' || !html) return { hasConfig: false, token: '' };
  const config = html.match(/window\\.__APP_CONFIG__\\s*=\\s*(\\{.*?\\})\\s*;/s);
  if (!config) return { hasConfig: false, token: '' };
  try {
    const parsed = JSON.parse(config[1]);
    const token = typeof parsed?.csrfToken === 'string' ? parsed.csrfToken.trim() : '';
    return { hasConfig: true, token };
  } catch {
    return { hasConfig: false, token: '' };
  }
}

/**
 * 解析指定本地回环页面原点的 CSRF Token：
 * 1. Antigravity 2.34+ 主进程内存 authBootstrap（与 origin 精确匹配）
 * 2. GET / 页面 HTML 中的 window.__APP_CONFIG__.csrfToken（兼容 2.33 及以下）
 * 3. CDP 页面内 window.__APP_CONFIG__.csrfToken / localStorage agy_session_csrf_token
 * 4. ~/.gemini/antigravity/daemon/hub_*.json 存活语言服务（按 origin 精确匹配端口与存活 PID）
 */
async function resolveOriginCsrfToken(rawOrigin, options = {}) {
  const origin = normalizeLoopbackOrigin(rawOrigin);
  if (!origin) {
    throw new Error('非法的本机回环页面地址');
  }
  const bootToken = resolveAuthBootstrapCsrfToken(origin, options);
  if (bootToken) {
    return { origin, token: bootToken, source: 'auth_bootstrap', hasConfig: true };
  }

  let hasConfig = false;
  let token = '';
  let htmlErr = null;
  const page = options?.page || null;
  try {
    const html = typeof options?.fetchHtml === 'function'
      ? await options.fetchHtml(origin)
      : await request(origin + '/');
    const parsed = extractCsrfTokenFromHtml(html);
    if (parsed.hasConfig) {
      hasConfig = true;
      token = parsed.token;
    }
  } catch (err) {
    htmlErr = err;
  }

  if (token) {
    return { origin, token, source: 'html_app_config', hasConfig: true };
  }

  if (page && page.webSocketDebuggerUrl) {
    const cdpCfg = await extractAppConfigViaCdp(page);
    if (cdpCfg && cdpCfg.hasConfig) {
      hasConfig = true;
      if (typeof cdpCfg.csrfToken === 'string' && cdpCfg.csrfToken.trim()) {
        token = cdpCfg.csrfToken.trim();
        return { origin, token, source: 'cdp_app_config', hasConfig: true };
      }
    }
  }

  const daemonToken = resolveDaemonHubCsrfToken(origin, options);
  if (daemonToken) {
    return { origin, token: daemonToken, source: 'daemon_hub', hasConfig: true };
  }

  if (!hasConfig && htmlErr) {
    throw htmlErr;
  }
  if (!hasConfig) {
    throw new Error('Antigravity 本地连接信息尚未就绪，请稍后重试');
  }
  throw new Error('Antigravity 本地鉴权信息尚未就绪，请稍后重试');
}

/**
 * 解析并缓存或实时提取指定本地页面原点的 CSRF Token 并构造 RPC 客户端。
 */
async function connectOrigin(rawOrigin, page = null, origins = null, extraMeta = {}, options = {}) {
  const { origin, token } = await resolveOriginCsrfToken(rawOrigin, {
    ...(options && typeof options === 'object' ? options : {}),
    page
  });

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
    return connectOrigin(explicitOrigin, null, [explicitOrigin], {}, options);
  }
  const { port, page, pages } = await discoverAntigravityCdp(options);
  const origins = Array.from(
    new Set((Array.isArray(pages) ? pages : [page]).map(item => normalizeLoopbackOrigin(item?.url)).filter(Boolean))
  );
  const targetOrigin = normalizeLoopbackOrigin(page.url);
  return connectOrigin(targetOrigin, page, origins, { port, pages }, options);
}

module.exports = {
  connect,
  connectOrigin,
  resolveOriginCsrfToken,
  resolveAuthBootstrapCsrfToken,
  resolveDaemonHubCsrfToken,
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

  norm = replaceUniqueAnchor(norm, oldConnectBlock, newConnectBlock, 'local-api:connect-block');
  return Buffer.from(norm.replace(/\n/g, newline), 'utf8');
}

function patchContextMeterStorage(raw) {
  const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  let norm = text.replace(/\r\n/g, '\n');

  const oldQuarantine = `    let quarantinePath = null;
    if (options.quarantineCorrupt !== false) {
      try {
        const stamp = new Date().toISOString().replace(/[:.]/g, '-');
        quarantinePath = resolved.replace(/\\.json$/i, '') + \`.corrupt.\${stamp}.json\`;
        fsImpl.copyFileSync(resolved, quarantinePath);
      } catch {}
    }`;

  const newQuarantine = `    let quarantinePath = null;
    if (options.quarantineCorrupt !== false) {
      try {
        quarantinePath = resolved.replace(/\\.json$/i, '') + '.corrupt.bak.json';
        let shouldCopy = true;
        if (typeof fsImpl.statSync === 'function' && fsImpl.existsSync(quarantinePath)) {
          try {
            const srcSt = fsImpl.statSync(resolved);
            const qSt = fsImpl.statSync(quarantinePath);
            if (srcSt && qSt && srcSt.size === qSt.size && Number(qSt.mtimeMs) >= Number(srcSt.mtimeMs)) {
              shouldCopy = false;
            }
          } catch {}
        }
        if (shouldCopy) {
          fsImpl.copyFileSync(resolved, quarantinePath);
        }
      } catch {}
    }`;

  norm = replaceUniqueAnchor(norm, oldQuarantine, newQuarantine, 'meter-storage:bounded-quarantine');
  return Buffer.from(norm.replace(/\n/g, newline), 'utf8');
}

function patchContextModulesConfig(raw) {
  const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  let norm = text.replace(/\r\n/g, '\n');

  const oldCorruptBak = 'const bakPath = `${cfgPath}.corrupt.${Date.now()}.bak`;';
  if (countOccurrences(norm, oldCorruptBak) !== 2) {
    throw new Error(`Anchor modules-config:corrupt-bak expected 2 matches, found ${countOccurrences(norm, oldCorruptBak)}`);
  }
  norm = norm.replaceAll(oldCorruptBak, 'const bakPath = `${cfgPath}.corrupt.bak`;');
  return Buffer.from(norm.replace(/\n/g, newline), 'utf8');
}

function patchContextMeterCollector(raw) {
  const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  let norm = text.replace(/\r\n/g, '\n');

  norm = replaceUniqueAnchor(
    norm,
    "const { normalizeLoopbackOrigin } = require('./local-api');\n",
    "const { normalizeLoopbackOrigin, resolveOriginCsrfToken } = require('./local-api');\n",
    'meter-collector:import-resolveOriginCsrfToken',
  );

  const oldCollectAuth = `      let token = !options.force ? csrfTokenByOrigin.get(origin) : null;
      if (!token) {
        const html = await request(origin, null, null, null, signal);
        if (isSuperseded()) return { version: PROJECT_VERSION, conversation: id, abortedStale: true, scannedAt: Date.now(), errors: [] };
        token = JSON.parse(html.match(/window.__APP_CONFIG__ = (.*?);/)[1]).csrfToken;
        csrfTokenByOrigin.set(origin, token);
      }
      const call = async (method, body) => {
        try {
          return await request(origin, method, body, token, signal);
        } catch (err) {
          if (err && /HTTP 40[13]/.test(String(err.message || '')) && !signal?.aborted) {
            csrfTokenByOrigin.delete(origin);
            const html = await request(origin, null, null, null, signal);
            token = JSON.parse(html.match(/window.__APP_CONFIG__ = (.*?);/)[1]).csrfToken;
            csrfTokenByOrigin.set(origin, token);
            return await request(origin, method, body, token, signal);
          }
          throw err;
        }
      };`;

  const newCollectAuth = `      const resolveToken = async () => {
        const resolved = await resolveOriginCsrfToken(origin, {
          fetchHtml: () => request(origin, null, null, null, signal),
          ...(options.authBootstrap !== undefined ? { authBootstrap: options.authBootstrap } : {}),
          ...(options.daemonDir !== undefined ? { daemonDir: options.daemonDir } : {}),
          ...(options.homeDir !== undefined ? { homeDir: options.homeDir } : {}),
          ...(options.isPidAlive !== undefined ? { isPidAlive: options.isPidAlive } : {})
        });
        return resolved.token;
      };
      let token = !options.force ? csrfTokenByOrigin.get(origin) : null;
      if (!token) {
        token = await resolveToken();
        if (isSuperseded()) return { version: PROJECT_VERSION, conversation: id, abortedStale: true, scannedAt: Date.now(), errors: [] };
        csrfTokenByOrigin.set(origin, token);
      }
      const call = async (method, body) => {
        try {
          return await request(origin, method, body, token, signal);
        } catch (err) {
          if (err && /HTTP 40[13]/.test(String(err.message || '')) && !signal?.aborted) {
            csrfTokenByOrigin.delete(origin);
            token = await resolveToken();
            csrfTokenByOrigin.set(origin, token);
            return await request(origin, method, body, token, signal);
          }
          throw err;
        }
      };`;

  norm = replaceUniqueAnchor(norm, oldCollectAuth, newCollectAuth, 'meter-collector:collect-auth');

  norm = replaceUniqueAnchor(
    norm,
    "        const connector = typeof options.connect === 'function' ? options.connect : require('./local-api').connect;\n        const api = await connector(options.origin ? { origin: options.origin } : undefined);\n",
    "        const connector = typeof options.connect === 'function' ? options.connect : require('./local-api').connect;\n        const connectOpts = {\n          ...(options.origin ? { origin: options.origin } : {}),\n          ...(options.authBootstrap !== undefined ? { authBootstrap: options.authBootstrap } : {}),\n          ...(options.daemonDir !== undefined ? { daemonDir: options.daemonDir } : {}),\n          ...(options.homeDir !== undefined ? { homeDir: options.homeDir } : {}),\n          ...(options.isPidAlive !== undefined ? { isPidAlive: options.isPidAlive } : {})\n        };\n        const api = await connector(Object.keys(connectOpts).length ? connectOpts : undefined);\n",
    'meter-collector:quota-connect',
  );

  norm = replaceUniqueAnchor(
    norm,
    "    const { connect } = require('./local-api');\n    const api = await connect(options.origin ? { origin: options.origin } : undefined);\n",
    "    const { connect } = require('./local-api');\n    const connectOpts = {\n      ...(options.origin ? { origin: options.origin } : {}),\n      ...(options.authBootstrap !== undefined ? { authBootstrap: options.authBootstrap } : {}),\n      ...(options.daemonDir !== undefined ? { daemonDir: options.daemonDir } : {}),\n      ...(options.homeDir !== undefined ? { homeDir: options.homeDir } : {}),\n      ...(options.isPidAlive !== undefined ? { isPidAlive: options.isPidAlive } : {})\n    };\n    const api = await connectorOrConnect(connect, connectOpts);\n".replace(
      'const api = await connectorOrConnect(connect, connectOpts);',
      'const api = await connect(Object.keys(connectOpts).length ? connectOpts : undefined);',
    ),
    'meter-collector:status-connect',
  );

  const oldLedgerPathFn = `function getPricingLedgerPath(overridePathOrDir) {
  if (overridePathOrDir) {
    if (overridePathOrDir.endsWith('.json')) return overridePathOrDir;
    return path.join(overridePathOrDir, 'pricing_ledger_v1.json');
  }
  if (process.env.AG_DIR) {
    return path.join(process.env.AG_DIR, 'pricing_ledger_v1.json');
  }
  const home = process.env.USERPROFILE || os.homedir();
  return path.join(home, '.gemini', 'antigravity', 'pricing_ledger_v1.json');
}`;

  const newLedgerPathFn = `function resolveMeterAddonDataDir(overridePathOrDir) {
  if (overridePathOrDir && String(overridePathOrDir).endsWith('.json')) {
    return overridePathOrDir;
  }
  const home = process.env.USERPROFILE || os.homedir();
  const defaultAgDir = path.join(home, '.gemini', 'antigravity');
  if (overridePathOrDir) {
    const normOverride = path.resolve(overridePathOrDir);
    const normDefault = path.resolve(defaultAgDir);
    const isDefaultHost = process.platform === 'win32'
      ? normOverride.toLowerCase() === normDefault.toLowerCase()
      : normOverride === normDefault;
    if (!isDefaultHost || process.env.AG_DIR) {
      return overridePathOrDir;
    }
  } else if (process.env.AG_DIR) {
    return process.env.AG_DIR;
  }
  if (process.platform === 'win32') {
    try {
      const { getStateDir } = require('./asar-engine');
      if (typeof getStateDir === 'function') {
        return getStateDir();
      }
    } catch {}
  }
  return defaultAgDir;
}

function getPricingLedgerPath(overridePathOrDir) {
  const target = resolveMeterAddonDataDir(overridePathOrDir);
  if (String(target).endsWith('.json')) return target;
  return path.join(target, 'pricing_ledger_v1.json');
}`;

  norm = replaceUniqueAnchor(norm, oldLedgerPathFn, newLedgerPathFn, 'meter-collector:ledger-state-dir');

  const oldRollingBak = `  // 正常落盘数据建立自动滚动备份，供损坏时恢复
  if (!readRes.corrupted) {
    try {
      if (!fsImpl.existsSync(bakPath) || Math.random() < 0.1) {
        fsImpl.copyFileSync(p, bakPath);
      }
    } catch { }
  }`;

  const newRollingBak = `  // 正常落盘数据建立自动滚动备份，供损坏时恢复（同目录临时文件 + rename 原子替换）
  if (!readRes.corrupted) {
    try {
      if (!fsImpl.existsSync(bakPath) || Math.random() < 0.1) {
        if (typeof fsImpl.renameSync === 'function') {
          const tmpBak = \`\${bakPath}.\${process.pid}.\${Date.now()}.tmp\`;
          try {
            fsImpl.copyFileSync(p, tmpBak);
            fsImpl.renameSync(tmpBak, bakPath);
          } catch (bakErr) {
            try { if (fsImpl.existsSync(tmpBak)) fsImpl.unlinkSync(tmpBak); } catch {}
            throw bakErr;
          }
        } else {
          fsImpl.copyFileSync(p, bakPath);
        }
      }
    } catch { }
  }`;

  norm = replaceUniqueAnchor(norm, oldRollingBak, newRollingBak, 'meter-collector:atomic-rolling-bak');

  const oldRepairKeepaliveEmail = `      // 显式保留用户/实验硬绑定的账号记录（keepalive / explicit email），其余均依据权威时间戳严格复核
      if (copy.isKeepalive && curScope && copy.accountAttributionConfidence === 'keepalive_bound') {
        copy.attributionRepairVersion = CURRENT_ATTRIBUTION_REPAIR_VERSION;
        nextCalls[k] = copy;
        continue;
      }
      if (copy.accountEmail && typeof copy.accountEmail === 'string' && copy.accountEmail.includes('@')) {
        copy.accountScopeKey = buildAccountScopeKey(copy.accountEmail);
        copy.accountAttributionConfidence = 'explicit_account_email';
        copy.accountAttributionEvidence = copy.accountAttributionEvidence || 'call_account_email';
        delete copy.unattributedReason;
        copy.attributionRepairVersion = CURRENT_ATTRIBUTION_REPAIR_VERSION;
        nextCalls[k] = copy;
        if (curScope !== copy.accountScopeKey) updatedCount++;
        continue;
      }`;

  const newRepairKeepaliveEmail = `      // 显式保留用户/实验硬绑定的账号记录（keepalive / explicit email），其余均依据权威时间戳严格复核
      if (copy.isKeepalive && curScope && copy.accountAttributionConfidence === 'keepalive_bound') {
        if (rec.attributionRepairVersion !== CURRENT_ATTRIBUTION_REPAIR_VERSION) updatedCount++;
        copy.attributionRepairVersion = CURRENT_ATTRIBUTION_REPAIR_VERSION;
        nextCalls[k] = copy;
        continue;
      }
      if (copy.accountEmail && typeof copy.accountEmail === 'string' && copy.accountEmail.includes('@')) {
        copy.accountScopeKey = buildAccountScopeKey(copy.accountEmail);
        copy.accountAttributionConfidence = 'explicit_account_email';
        copy.accountAttributionEvidence = copy.accountAttributionEvidence || 'call_account_email';
        delete copy.unattributedReason;
        if (curScope !== copy.accountScopeKey || rec.attributionRepairVersion !== CURRENT_ATTRIBUTION_REPAIR_VERSION) updatedCount++;
        copy.attributionRepairVersion = CURRENT_ATTRIBUTION_REPAIR_VERSION;
        nextCalls[k] = copy;
        continue;
      }`;

  norm = replaceUniqueAnchor(norm, oldRepairKeepaliveEmail, newRepairKeepaliveEmail, 'meter-collector:elv89-version-persist');

  const oldElv89Backup = `    const after = summarizeCounts(nextCalls);
    let backupPath = null;
    if (!dryRun && fs.existsSync(resolvedLedgerPath)) {
      const tsTag = backupSuffix || \`\${Date.now()}\`;
      backupPath = \`\${resolvedLedgerPath}.bak-pre-elv89-\${tsTag}\`;
      fs.copyFileSync(resolvedLedgerPath, backupPath);
    }

    if (!dryRun && (updatedCount > 0 || force)) {`;

  const newElv89Backup = `    const after = summarizeCounts(nextCalls);
    let backupPath = null;

    if (!dryRun && (updatedCount > 0 || force)) {
      if (fs.existsSync(resolvedLedgerPath)) {
        backupPath = backupSuffix
          ? \`\${resolvedLedgerPath}.bak-pre-elv89-\${backupSuffix}\`
          : \`\${resolvedLedgerPath}.bak-pre-elv89.json\`;
        const tmpElvBak = \`\${backupPath}.\${process.pid}.\${Date.now()}.tmp\`;
        try {
          fs.copyFileSync(resolvedLedgerPath, tmpElvBak);
          fs.renameSync(tmpElvBak, backupPath);
        } catch {
          try { if (fs.existsSync(tmpElvBak)) fs.unlinkSync(tmpElvBak); } catch {}
          fs.copyFileSync(resolvedLedgerPath, backupPath);
        }
      }`;

  norm = replaceUniqueAnchor(norm, oldElv89Backup, newElv89Backup, 'meter-collector:elv89-bounded-backup');

  const oldCustomPlanPath = `function getCustomPlanPath(overridePathOrDir) {
  if (overridePathOrDir) {
    if (overridePathOrDir.endsWith('.json')) return overridePathOrDir;
    return path.join(overridePathOrDir, 'custom_plan_v1.json');
  }
  if (process.env.AG_DIR) {
    return path.join(process.env.AG_DIR, 'custom_plan_v1.json');
  }
  const home = process.env.USERPROFILE || os.homedir();
  return path.join(home, '.gemini', 'antigravity', 'custom_plan_v1.json');
}`;

  const newCustomPlanPath = `function getCustomPlanPath(overridePathOrDir) {
  const target = resolveMeterAddonDataDir(overridePathOrDir);
  if (String(target).endsWith('.json')) return target;
  return path.join(target, 'custom_plan_v1.json');
}`;

  norm = replaceUniqueAnchor(norm, oldCustomPlanPath, newCustomPlanPath, 'meter-collector:custom-plan-state-dir');

  norm = replaceUniqueAnchor(
    norm,
    "    const home = process.env.USERPROFILE || os.homedir();\n    const agDir = targetDir && !targetDir.endsWith('.json') ? targetDir : (process.env.AG_DIR || path.join(home, '.gemini', 'antigravity'));\n    const archivePathV2 = path.join(agDir, 'token_usage_archive_v2.json');\n",
    "    const archiveDir = resolveMeterAddonDataDir(targetDir && !targetDir.endsWith('.json') ? targetDir : null);\n    const archivePathV2 = path.join(archiveDir, 'token_usage_archive_v2.json');\n",
    'meter-collector:custom-plan-archive-dir',
  );

  norm = replaceUniqueAnchor(
    norm,
    "  const archivePathV1 = path.join(agDir, 'token_usage_archive_v1.json');\n  const archivePathV2 = path.join(agDir, 'token_usage_archive_v2.json');\n",
    "  const archiveDir = options.agDir ? agDir : resolveMeterAddonDataDir(agDir);\n  const archivePathV1 = path.join(archiveDir, 'token_usage_archive_v1.json');\n  const archivePathV2 = path.join(archiveDir, 'token_usage_archive_v2.json');\n",
    'meter-collector:history-archive-dir',
  );

  norm = replaceUniqueAnchor(
    norm,
    "  const bakPathV1 = path.join(agDir, 'token_usage_archive_v1.bak.json');\n",
    "  const bakPathV1 = path.join(archiveDir, 'token_usage_archive_v1.bak.json');\n",
    'meter-collector:history-archive-bak-v1',
  );

  norm = replaceUniqueAnchor(
    norm,
    "  const bakPathV2 = path.join(agDir, 'token_usage_archive_v2.bak.json');\n",
    "  const bakPathV2 = path.join(archiveDir, 'token_usage_archive_v2.bak.json');\n",
    'meter-collector:history-archive-bak-v2',
  );

  const oldNeedsRepair = `      const preRepairCalls = (loadPricingLedger(agDir).calls || {});
      const needsAttributionRepair = Object.values(preRepairCalls).some(rec =>
        rec &&
        typeof rec === 'object' &&
        rec.attributionRepairVersion !== CURRENT_ATTRIBUTION_REPAIR_VERSION &&
        isValidAccountScopeKey(rec.accountScopeKey) &&
        rec.accountAttributionConfidence !== 'unattributed'
      );`;

  const newNeedsRepair = `      const preRepairCalls = (loadPricingLedger(agDir).calls || {});
      const nowRepairCheckMs = Date.now();
      const needsAttributionRepair = Object.values(preRepairCalls).some(rec => {
        if (!rec || typeof rec !== 'object') return false;
        if (rec.attributionRepairVersion === CURRENT_ATTRIBUTION_REPAIR_VERSION) return false;
        if (!isValidAccountScopeKey(rec.accountScopeKey) || rec.accountAttributionConfidence === 'unattributed') return false;
        if (rec.accountAttributionConfidence === 'live_confirmed_account') {
          const obsMs = Number(rec.liveObservedAtMs) || (rec.updatedAt ? Date.parse(rec.updatedAt) : NaN) || Number(rec.timestamp);
          if (Number.isFinite(obsMs) && (nowRepairCheckMs - obsMs) >= 0 && (nowRepairCheckMs - obsMs) < 180000) {
            return false;
          }
        }
        return true;
      });`;

  norm = replaceUniqueAnchor(norm, oldNeedsRepair, newNeedsRepair, 'meter-collector:skip-live-window-repair-check');

  return Buffer.from(norm.replace(/\n/g, newline), 'utf8');
}

function patchContextMeterRenderer(raw) {
  const text = Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  let norm = text.replace(/\r\n/g, '\n');

  norm = replaceUniqueAnchor(
    norm,
    "      const csrf = window.__APP_CONFIG__?.csrfToken; if (!csrf) throw new Error('后台尚未就绪');\n",
    "      let csrf = window.__APP_CONFIG__?.csrfToken || ''; if (!csrf) { try { csrf = window.localStorage?.getItem('agy_session_csrf_token') || ''; } catch {} } if (!csrf) throw new Error('后台尚未就绪');\n",
    'meter-renderer:requestPoll-csrf',
  );

  norm = replaceUniqueAnchor(
    norm,
    "    const csrf = typeof window !== 'undefined' ? window.__APP_CONFIG__?.csrfToken : null;\n",
    "    let csrf = typeof window !== 'undefined' ? (window.__APP_CONFIG__?.csrfToken || '') : '';\n    if (!csrf && typeof window !== 'undefined') { try { csrf = window.localStorage?.getItem('agy_session_csrf_token') || ''; } catch {} }\n",
    'meter-renderer:fetchAvailableModels-csrf',
  );

  return Buffer.from(norm.replace(/\n/g, newline), 'utf8');
}

function detectHubLoadAnchor(utilsSource) {
  const explicitCandidates = [
    '    void loadHubWindowUrl(win, url, { skipBootstrapMint });',
    '    void win.loadURL(url);',
  ];
  for (const cand of explicitCandidates) {
    if (countOccurrences(utilsSource, cand) === 1) return cand;
  }
  const regex = /^    void (?:loadHubWindowUrl\(win,\s*url[^;\r\n]*\)|win\.loadURL\(url\));$/gm;
  const matches = utilsSource.match(regex) || [];
  if (matches.length === 1) return matches[0];
  return null;
}

async function applyContextViewerLayer({ hostVersion, origUtils, origPreload, stateRoot, stageDir }) {
  const installer = require(path.join(CONTEXT_DIR, 'modular-installer.js'));
  const currentAnchor = detectHubLoadAnchor(origUtils);
  if (!currentAnchor) {
    return { status: 'skipped', reason: 'Unable to find a unique hub window navigation anchor in dist/utils.js' };
  }

  const meter = installer.generateMeterUtilsCode();
  const edits = [
    ['"use strict";', '"use strict";\n' + meter.headerProxyHook],
    ['function setupNodeWrapper(env) {', 'function setupNodeWrapper(env) {' + meter.nodeWrapperHook],
    ["titleBarStyle: 'hidden',", "titleBarStyle: 'hidden'," + meter.menuBarOption],
    [currentAnchor, meter.windowLoadHook + currentAnchor],
    ['function createWindow(url, storageManager, options) {', 'function createWindow(url, storageManager, options) {' + meter.storageFallback],
    ['wins[0].focus();', 'wins[0].focus();' + meter.focusHook],
    ['createWindow(`${constants_1.WINDOW_ORIGIN}:${port}/`);', 'const _mWin = createWindow(`${constants_1.WINDOW_ORIGIN}:${port}/`);' + meter.createHook],
  ];

  let patchedUtils = origUtils;
  for (const [anchor, replacement] of edits) {
    if (countOccurrences(patchedUtils, anchor) !== 1) {
      return { status: 'skipped', reason: `Anchor not unique in dist/utils.js: ${anchor}` };
    }
    patchedUtils = patchedUtils.replace(anchor, () => replacement);
  }
  if (patchedUtils.includes(installer.TAGS.PROXY_START)) {
    throw new Error('Unexpected ProxyNoTun injection present in meter-only utils.js');
  }
  verifyNodeSyntax(patchedUtils, stageDir, 'dist/utils.js');

  const preloadSnippet = installer.generateMeterPreloadCode();
  if (preloadSnippet.includes(installer.TAGS.CHINESE_START)) {
    throw new Error('Unexpected Chinese injection in meter-only preload snippet');
  }
  verifyNodeSyntax(origPreload + preloadSnippet, stageDir, 'dist/preload-context.js');

  // Offline preload fixture
  const exposed = new Map();
  const invoked = [];
  const decorator = [];
  vm.runInNewContext(preloadSnippet, {
    electron_1: {
      contextBridge: { exposeInMainWorld: (n, api) => exposed.set(n, api) },
      ipcRenderer: { invoke: (...a) => invoked.push(a) },
      webFrame: { executeJavaScript: (c) => { decorator.push(c); return Promise.resolve(); } },
    },
  });
  const api = exposed.get('contextMeterAPI');
  if (!api || typeof api.scan !== 'function') throw new Error('contextMeterAPI.scan missing in preload fixture');
  api.scan('fixture-conv', true);
  if (invoked.length !== 1 || invoked[0][0] !== 'context-meter:scan') throw new Error('contextMeterAPI.scan IPC mismatch');
  if (decorator.length !== 1 || !decorator[0].includes('__JETSKI_LS_CLIENT_DECORATOR__')) {
    throw new Error('Main-world decorator bootstrap missing');
  }

  // Build 21 overlay files purely from D:\Codex\tools\antigravity-addons\context-viewer-v0.8.8
  const contextStateWin = path.win32.normalize(path.join(stateRoot, 'context'));
  const oldStateLine = "  const dir = path.join(base, 'AntigravityContextMeter');";
  const newStateLine = `  const dir = process.platform === 'win32' ? ${JSON.stringify(contextStateWin)} : path.join(base, 'AntigravityContextMeter');`;
  const oldVendorAnchor = '    void win.loadURL(url);';

  const additions = new Map();
  for (const rel of CONTEXT_VENDOR_FILES) {
    let raw = await fsp.readFile(path.join(CONTEXT_DIR, rel));
    if (rel === 'asar-engine.js') {
      const txt = raw.toString('utf8');
      if (countOccurrences(txt, oldStateLine) !== 1) throw new Error('Unexpected asar-engine.js state line');
      raw = Buffer.from(txt.replace(oldStateLine, () => newStateLine), 'utf8');
    } else if (rel === 'modular-installer.js') {
      const txt = raw.toString('utf8');
      if (countOccurrences(txt, oldVendorAnchor) === 1) {
        raw = Buffer.from(txt.replace(oldVendorAnchor, () => currentAnchor), 'utf8');
      }
    } else if (rel === 'install.js') {
      const txt = raw.toString('utf8');
      if (countOccurrences(txt, oldVendorAnchor) === 2) {
        raw = Buffer.from(txt.replaceAll(oldVendorAnchor, () => currentAnchor), 'utf8');
      }
    } else if (rel === 'local-api.js') {
      raw = patchContextLocalApi(raw);
      verifyNodeSyntax(raw.toString('utf8'), stageDir, 'dist/local-api.js');
    } else if (rel === 'meter-storage.js') {
      raw = patchContextMeterStorage(raw);
      verifyNodeSyntax(raw.toString('utf8'), stageDir, 'dist/meter-storage.js');
    } else if (rel === 'modules-config.js') {
      raw = patchContextModulesConfig(raw);
      verifyNodeSyntax(raw.toString('utf8'), stageDir, 'dist/modules-config.js');
    } else if (rel === 'meter-collector.js') {
      raw = patchContextMeterCollector(raw);
      verifyNodeSyntax(raw.toString('utf8'), stageDir, 'dist/meter-collector.js');
    } else if (rel === 'meter-renderer.js') {
      raw = patchContextMeterRenderer(raw);
      verifyNodeSyntax(raw.toString('utf8'), stageDir, 'dist/meter-renderer.js');
    }
    additions.set(`dist/${rel}`, raw);
  }
  const manifestJson = JSON.stringify({
    version: '0.8.8',
    hostVersion,
    updatedAt: new Date().toISOString(),
  }, null, 2);
  additions.set('dist/meter-manifest.json', Buffer.from(manifestJson, 'utf8'));

  // Offline mount behavioral fixture (BrowserWindow + BaseWindow)
  const meterMain = additions.get('dist/meter-main.js').toString('utf8');
  const sliceBetween = (src, a, b) => {
    const i = src.indexOf(a);
    const j = src.indexOf(b, i + a.length);
    if (i < 0 || j <= i) throw new Error(`Fixture slice missing: ${a}`);
    return src.slice(i, j);
  };
  const mountStart = '    (0, previewViewers_1.registerPreviewViewer)(hubContents);';
  if (countOccurrences(patchedUtils, mountStart) === 1) {
    const mount = sliceBetween(patchedUtils, mountStart, '\n    return win;');
    const fn1 = sliceBetween(meterMain, 'function getWindowWebContents(win) {', '\n/**');
    const fn2 = sliceBetween(meterMain, 'async function ensureMeterInjected(win, options = {}) {', '\nexports.ensureMeterInjected');
    const fn3 = sliceBetween(meterMain, 'exports.installContextMeter = function (win) {', '\n\ntry {');
    for (const baseWindow of [true, false]) {
      const events = [];
      const handlers = {};
      const winHandlers = {};
      const hubContents = {
        on: (n, fn) => { handlers[n] = fn; },
        getURL: () => 'https://127.0.0.1:19999/',
        executeJavaScript: async (v) => { events.push(['inject', v]); },
      };
      const win = {
        on: (n, fn) => { winHandlers[n] = fn; },
        loadURL: (u) => { events.push(['navigate', u]); },
      };
      if (baseWindow) Object.defineProperty(win, 'webContents', { get: () => hubContents });
      else win.webContents = hubContents;
      const sandbox = {
        exports: {}, process: { platform: 'win32' }, win, hubContents, options: {}, url: 'https://127.0.0.1:19999/',
        boundWindows: new WeakSet(), boundWebContents: new WeakSet(),
        registerIpcOnce: () => { events.push(['register-ipc']); },
        syncWindowOverlayHeight: () => {}, getMeterSource: () => 'fixture-meter-source',
        previewViewers_1: { registerPreviewViewer: () => { events.push(['preview']); } },
        loadHubWindowUrl: (_w, u) => { events.push(['navigate', u]); },
        require: (n) => { if (n !== './meter-main') throw new Error(n); return sandbox.exports; },
      };
      vm.runInNewContext([fn1, fn2, fn3, mount].join('\n'), sandbox);
      handlers['did-finish-load']();
      await Promise.resolve();
      if (!events.some((e) => e[0] === 'register-ipc') || !events.some((e) => e[0] === 'inject' && e[1] === 'fixture-meter-source')) {
        throw new Error(`Context mount fixture failed (baseWindow=${baseWindow})`);
      }
    }
  }

  return {
    status: 'applied',
    version: '0.8.8',
    anchor: currentAnchor.trim(),
    csrfPatched: true,
    utils: patchedUtils,
    preloadSnippet,
    additions,
  };
}

// ---------------------------------------------------------------------------
// Layer 5: updater relaunch hand-off (dist/updater.js)
// ---------------------------------------------------------------------------

function applyUpdaterLayer(origSource, postQuitHookPath, launcherPath, stageDir) {
  if (!postQuitHookPath || !launcherPath) {
    return { status: 'skipped', reason: 'postQuitHookPath or launcherPath missing' };
  }
  const newline = origSource.includes('\r\n') ? '\r\n' : '\n';
  const norm = origSource.replace(/\r\n/g, '\n');
  const anchor = [
    '            await killLanguageServer();',
    '            electron_updater_1.autoUpdater.quitAndInstall(isSilent, true);',
    '            launched = Boolean(updater.quitAndInstallCalled);',
  ].join('\n');

  if (countOccurrences(norm, anchor) !== 1) {
    return { status: 'skipped', reason: 'Upstream dist/updater.js quitAndInstall anchor changed' };
  }

  const hookLiteral = JSON.stringify(toPosix(postQuitHookPath));
  const launcherLiteral = JSON.stringify(toPosix(launcherPath));
  const replacement = [
    '            await killLanguageServer();',
    '            let __agyDelegatedHookVbs = null;',
    '            const __agyPrevAutoRun = updater.autoRunAppAfterInstall;',
    '            try {',
    "                const fs = require('fs');",
    `                const hookFile = ${hookLiteral};`,
    `                const launcherExe = ${launcherLiteral};`,
    '                if (hookFile && launcherExe && fs.existsSync(hookFile) && fs.existsSync(launcherExe)) {',
    "                    const hook = JSON.parse(fs.readFileSync(hookFile, 'utf8'));",
    "                    if (hook && typeof hook.vbsPath === 'string' && hook.vbsPath && fs.existsSync(hook.vbsPath)) {",
    '                        __agyDelegatedHookVbs = hook.vbsPath;',
    '                        updater.autoRunAppAfterInstall = false;',
    '                    }',
    '                }',
    '            }',
    '            catch (_agyHookReadErr) {',
    '                __agyDelegatedHookVbs = null;',
    '            }',
    '            electron_updater_1.autoUpdater.quitAndInstall(isSilent, __agyDelegatedHookVbs === null);',
    '            launched = Boolean(updater.quitAndInstallCalled);',
    '            if (launched && __agyDelegatedHookVbs !== null) {',
    '                try {',
    "                    const child = (0, child_process_1.spawn)('wscript.exe', ['//B', '//NoLogo', __agyDelegatedHookVbs, '--relaunch'], {",
    '                        detached: true,',
    "                        stdio: 'ignore',",
    '                        windowsHide: true,',
    '                    });',
    '                    child.unref();',
    '                    if (electron_1.app) {',
    '                        electron_1.app.__zhcnUpdaterRelaunchHandedOff = true;',
    '                    }',
    '                }',
    '                catch (_agyHookSpawnErr) {',
    '                    updater.autoRunAppAfterInstall = __agyPrevAutoRun;',
    '                }',
    '            }',
    '            else if (!launched && __agyDelegatedHookVbs !== null) {',
    '                updater.autoRunAppAfterInstall = __agyPrevAutoRun;',
    '            }',
  ].join('\n');

  const patched = norm.replace(anchor, () => replacement).replace(/\n/g, newline);
  verifyNodeSyntax(patched, stageDir, 'dist/updater.js');

  const runFixture = async ({ filesPresent, installSucceeds }) => {
    const spawns = [];
    const quitCalls = [];
    const appObj = { isPackaged: true, getVersion: () => '2.35.0', quit: () => {} };
    const autoUpdater = {
      installerPath: 'C:\\updater\\Antigravity-x64.exe',
      autoRunAppAfterInstall: true,
      quitAndInstallCalled: false,
      on: () => {},
      quitAndInstall(isSilent, isForceRunAfter) {
        quitCalls.push([isSilent, isForceRunAfter, this.autoRunAppAfterInstall]);
        this.quitAndInstallCalled = installSucceeds;
      },
    };
    const existing = new Set(
      filesPresent
        ? [toPosix(postQuitHookPath), toPosix(launcherPath), 'D:/tools/post-quit-reconcile.vbs']
        : [],
    );
    const exp = {};
    const deps = {
      'electron-updater': { autoUpdater },
      electron: { app: appObj, Menu: { getApplicationMenu: () => null }, dialog: {} },
      path,
      './types': { UpdateState: { Idle: 'idle', CheckingForUpdates: 'checking', AvailableForDownload: 'avail', Downloading: 'dl', Ready: 'ready' } },
      child_process: {
        spawn(cmd, args, opts) {
          spawns.push([cmd, args, opts]);
          return { unref() {} };
        },
      },
      './services/settingsService': { SettingKey: {} },
      './utils': { getHubWindows: () => [], getHubWebContents: () => null, getFocusedHubWindow: () => null },
      './languageServer': { killLanguageServer: async () => {} },
      fs: {
        existsSync: (p) => existing.has(toPosix(String(p))),
        readFileSync: () => JSON.stringify({ vbsPath: 'D:/tools/post-quit-reconcile.vbs' }),
      },
    };
    vm.runInNewContext(patched, {
      exports: exp,
      require: (name) => {
        if (!Object.hasOwn(deps, name)) throw new Error(`Unexpected updater require: ${name}`);
        return deps[name];
      },
      process: { platform: 'win32', arch: 'x64', pid: 1234, env: {} },
      console: { log() {}, warn() {}, error() {} },
      setTimeout,
      clearInterval,
      setInterval,
    }, { filename: 'dist/updater.js' });
    await exp.quitAndInstall(false);
    return { spawns, quitCalls, appObj, autoUpdater };
  };

  return {
    status: 'ready',
    source: patched,
    verifyAsync: async () => {
      const delegated = await runFixture({ filesPresent: true, installSucceeds: true });
      if (
        delegated.quitCalls.length !== 1 ||
        delegated.quitCalls[0][1] !== false ||
        delegated.quitCalls[0][2] !== false ||
        delegated.spawns.length !== 1 ||
        delegated.spawns[0][0] !== 'wscript.exe' ||
        !delegated.spawns[0][1].includes('--relaunch') ||
        delegated.appObj.__zhcnUpdaterRelaunchHandedOff !== true
      ) {
        throw new Error('Updater delegated relaunch behavioral gate failed');
      }

      const fallback = await runFixture({ filesPresent: false, installSucceeds: true });
      if (
        fallback.quitCalls.length !== 1 ||
        fallback.quitCalls[0][1] !== true ||
        fallback.quitCalls[0][2] !== true ||
        fallback.spawns.length !== 0 ||
        Boolean(fallback.appObj.__zhcnUpdaterRelaunchHandedOff)
      ) {
        throw new Error('Updater missing-hook fallback behavioral gate failed');
      }

      const aborted = await runFixture({ filesPresent: true, installSucceeds: false });
      if (
        aborted.spawns.length !== 0 ||
        aborted.autoUpdater.autoRunAppAfterInstall !== true ||
        Boolean(aborted.appObj.__zhcnUpdaterRelaunchHandedOff)
      ) {
        throw new Error('Updater aborted-install rollback behavioral gate failed');
      }
    },
  };
}

// ---------------------------------------------------------------------------
// File helpers & atomic swap
// ---------------------------------------------------------------------------

async function writeFileAtomic(targetPath, content) {
  await fsp.mkdir(path.dirname(targetPath), { recursive: true });
  const tmp = `${targetPath}.${process.pid}.${Date.now()}.tmp`;
  await fsp.writeFile(tmp, content);
  try {
    await fsp.rename(tmp, targetPath);
  } catch (err) {
    await fsp.rm(tmp, { force: true }).catch(() => {});
    throw err;
  }
}

async function swapAsarAtomically(targetAsar, candidateBuffer, expectedOriginalSha, expectedCandidateSha) {
  const currentSha = await sha256File(targetAsar);
  if (currentSha !== expectedOriginalSha) {
    throw new Error(`Target app.asar changed during build: expected ${expectedOriginalSha}, found ${currentSha}`);
  }
  const dir = path.dirname(targetAsar);
  const token = `${process.pid}-${Date.now()}`;
  const staged = path.join(dir, `.app.asar.reconcile-new-${token}.tmp`);
  const displaced = path.join(dir, `.app.asar.reconcile-old-${token}.tmp`);

  await fsp.writeFile(staged, candidateBuffer);
  if (await sha256File(staged) !== expectedCandidateSha) {
    await fsp.rm(staged, { force: true }).catch(() => {});
    throw new Error('Staged app.asar SHA-256 mismatch before swap');
  }

  try {
    await fsp.rename(targetAsar, displaced);
  } catch (err) {
    await fsp.rm(staged, { force: true }).catch(() => {});
    err.isLockError = ['EBUSY', 'EPERM', 'EACCES'].includes(err.code);
    throw err;
  }

  try {
    await fsp.rename(staged, targetAsar);
    if (await sha256File(targetAsar) !== expectedCandidateSha) {
      throw new Error('Installed app.asar SHA-256 verification failed');
    }
  } catch (err) {
    await fsp.rm(targetAsar, { force: true }).catch(() => {});
    await fsp.rename(displaced, targetAsar).catch(() => {});
    await fsp.rm(staged, { force: true }).catch(() => {});
    throw err;
  }

  await fsp.rm(displaced, { force: true }).catch(() => {});
}

function detectAddonMarkers(entries, body) {
  const markers = [];
  const check = (rel, needle, tag) => {
    const e = entries.get(rel);
    if (e && !e.unpacked && e.offset !== undefined) {
      if (getAsarMember(body, e).includes(Buffer.from(needle, 'utf8'))) markers.push(tag);
    }
  };
  check('dist/customScheme.js', 'agy-zhcn://bundle/main.js', 'desktop-zhcn');
  check('dist/preload.js', 'AGY_CONTEXT_CAPSULE_START', 'pulse');
  check('dist/preload.js', 'Antigravity Context Meter preload Injection Start', 'context-viewer-preload');
  check('dist/utils.js', 'Antigravity Context Meter utils Injection Start', 'context-viewer-utils');
  check('dist/updater.js', '__zhcnUpdaterRelaunchHandedOff', 'updater-relaunch');
  check('dist/wsl.js', 'HKCU\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Lxss', 'wsl');
  return markers;
}

async function readJsonSafe(filePath) {
  try {
    return JSON.parse(await fsp.readFile(filePath, 'utf8'));
  } catch {
    return null;
  }
}

function parseArgs(argv) {
  const opts = {
    command: argv[0] || 'status',
    appDir: DEFAULT_APP_DIR,
    backupDir: DEFAULT_BACKUP_DIR,
    stateRoot: DEFAULT_STATE_ROOT,
    evidenceRoot: DEFAULT_EVIDENCE_ROOT,
    apply: false,
    stageOnly: false,
    dryRun: false,
    fromBackup: false,
    officialSha256: null,
  };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--app-dir') opts.appDir = argv[++i];
    else if (a === '--backup-dir') opts.backupDir = argv[++i];
    else if (a === '--state-root') opts.stateRoot = argv[++i];
    else if (a === '--evidence-root') opts.evidenceRoot = argv[++i];
    else if (a === '--apply') opts.apply = true;
    else if (a === '--stage-only') opts.stageOnly = true;
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--from-backup') opts.fromBackup = true;
    else if (a === '--official-sha256') opts.officialSha256 = argv[++i];
    else throw new Error(`Unknown argument: ${a}`);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Main commands
// ---------------------------------------------------------------------------

async function inspectLive(opts) {
  const reconcilerSha256 = await sha256File(RECONCILER_FILE);
  const appAsarPath = path.join(opts.appDir, 'resources/app.asar');
  const lsPath = path.join(opts.appDir, 'resources/bin/language_server.exe');
  const asarBuf = await fsp.readFile(appAsarPath);
  const currentAsarSha = sha256(asarBuf);
  const lsSha = fs.existsSync(lsPath) ? await sha256File(lsPath) : null;
  const { header, body } = unpackAsar(asarBuf);
  const entries = walkAsar(header);
  const pkg = JSON.parse(getAsarMember(body, entries.get('package.json')).toString('utf8'));
  const markers = detectAddonMarkers(entries, body);
  const active = await readJsonSafe(path.join(opts.stateRoot, 'active-build.json'));
  const pending = await readJsonSafe(path.join(opts.stateRoot, 'pending-apply.json'));
  const pendingAsarExists = fs.existsSync(path.join(opts.stateRoot, 'pending-app.asar'));

  const langUiPath = path.join(opts.stateRoot, `language-${pkg.version}`, 'agy_zhcn_ui_main.js');
  const langUiExists = fs.existsSync(langUiPath);

  let state = 'needs-reconcile';
  const pendingTargetSha = pending ? (pending.replaceTargetSha256 || pending.officialSha256) : null;
  if (
    pending &&
    pendingAsarExists &&
    pendingTargetSha === currentAsarSha &&
    pending.languageServerSha256 === lsSha &&
    pending.reconcilerSha256 === reconcilerSha256
  ) {
    state = 'pending-ready';
  } else if (active && active.combinedSha256 === currentAsarSha && active.languageServerSha256 === lsSha && (!markers.includes('desktop-zhcn') || langUiExists)) {
    state = 'up-to-date';
  } else if (markers.length > 0) {
    state = 'already-patched-untracked';
  }

  return {
    state,
    version: pkg.version,
    reconcilerSha256,
    appAsarPath,
    currentAsarSha,
    languageServerSha256: lsSha,
    markers,
    langUiExists,
    activeBuild: active,
    pendingApply: pending && pendingAsarExists ? pending : null,
    asarBuf,
    header,
    body,
    entries,
  };
}

async function cmdAdopt(opts) {
  const info = await inspectLive(opts);
  const record = {
    schemaVersion: 1,
    version: info.version,
    reconcilerSha256: info.reconcilerSha256,
    officialSha256: opts.officialSha256 || null,
    combinedSha256: info.currentAsarSha,
    languageServerSha256: info.languageServerSha256,
    appliedLayers: info.markers,
    skippedLayers: [],
    adoptedAt: new Date().toISOString(),
  };
  await writeFileAtomic(path.join(opts.stateRoot, 'active-build.json'), JSON.stringify(record, null, 2) + '\n');
  return { status: 'adopted', activeBuild: record };
}

async function cmdReconcile(opts) {
  const info = await inspectLive(opts);
  if (!opts.fromBackup) {
    if (info.state === 'up-to-date') {
      return { status: 'up-to-date', version: info.version, combinedSha256: info.currentAsarSha, markers: info.markers };
    }
    if (info.state === 'pending-ready' && opts.apply && !opts.stageOnly && !opts.dryRun) {
      const pendingPath = path.join(opts.stateRoot, 'pending-app.asar');
      const pendingMeta = info.pendingApply;
      try {
        const pendingBuf = await fsp.readFile(pendingPath);
        if (sha256(pendingBuf) === pendingMeta.combinedSha256) {
          await swapAsarAtomically(info.appAsarPath, pendingBuf, info.currentAsarSha, pendingMeta.combinedSha256);
          const promoted = { ...pendingMeta, promotedAt: new Date().toISOString() };
          await writeFileAtomic(path.join(opts.stateRoot, 'active-build.json'), JSON.stringify(promoted, null, 2) + '\n');
          await fsp.rm(pendingPath, { force: true }).catch(() => {});
          await fsp.rm(path.join(opts.stateRoot, 'pending-apply.json'), { force: true }).catch(() => {});
          return { status: 'applied-from-pending', ...promoted };
        }
      } catch (err) {
        if (err.isLockError) {
          return { status: 'pending-still-locked', version: info.version, combinedSha256: pendingMeta.combinedSha256 };
        }
        // Corrupt/mismatched pending artifact falls through to fresh rebuild
      }
    }
    if (info.state === 'already-patched-untracked') {
      return { status: 'refused-already-patched', version: info.version, currentAsarSha: info.currentAsarSha, markers: info.markers };
    }
  }

  let sourceBuf = info.asarBuf;
  let sourceHeader = info.header;
  let sourceBody = info.body;
  let sourceEntries = info.entries;
  let officialSha = info.currentAsarSha;
  let backupPath = path.join(opts.backupDir, `app.asar.${info.version}.original`);

  if (opts.fromBackup) {
    if (!fs.existsSync(backupPath)) {
      throw new Error(`Official backup not found for --from-backup: ${backupPath}`);
    }
    sourceBuf = await fsp.readFile(backupPath);
    officialSha = sha256(sourceBuf);
    const unpacked = unpackAsar(sourceBuf);
    sourceHeader = unpacked.header;
    sourceBody = unpacked.body;
    sourceEntries = walkAsar(sourceHeader);
    const backupMarkers = detectAddonMarkers(sourceEntries, sourceBody);
    if (backupMarkers.length > 0) {
      throw new Error(`Backup archive already contains addon markers: ${backupMarkers.join(', ')}`);
    }
  }

  const runStamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const stageDir = path.join(opts.evidenceRoot, `sync-${runStamp}-v${info.version}`);
  const workDir = path.join(stageDir, '.work');
  await fsp.mkdir(workDir, { recursive: true });
  try {
    return await executeReconcile({ opts, info, sourceBuf, sourceBody, sourceEntries, officialSha, backupPath, stageDir, workDir });
  } finally {
    await fsp.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

async function executeReconcile({ opts, info, sourceBuf, sourceBody, sourceEntries, officialSha, backupPath, stageDir, workDir }) {

  // Immutable official backup (never overwrite existing version backup)
  if (!opts.dryRun && !opts.fromBackup) {
    await fsp.mkdir(opts.backupDir, { recursive: true });
    if (!fs.existsSync(backupPath)) {
      await fsp.writeFile(backupPath, sourceBuf, { flag: 'wx' });
    }
  } else if (opts.dryRun && !opts.fromBackup) {
    backupPath = null;
  }

  const readTextMember = (rel) => {
    const e = sourceEntries.get(rel);
    return e && !e.unpacked ? getAsarMember(sourceBody, e).toString('utf8') : null;
  };

  const replacements = new Map();
  const additions = new Map();
  const layers = {};

  // Layer 1: WSL guard
  try {
    const origWsl = readTextMember('dist/wsl.js');
    if (!origWsl) {
      layers.wsl = { status: 'skipped', reason: 'dist/wsl.js absent' };
    } else {
      const res = applyWslLayer(origWsl, workDir);
      if (res.status === 'ready') {
        await res.verifyAsync();
        replacements.set('dist/wsl.js', Buffer.from(res.source, 'utf8'));
        layers.wsl = { status: 'applied', sha256: sha256(Buffer.from(res.source, 'utf8')) };
      } else {
        layers.wsl = res;
      }
    }
  } catch (err) {
    layers.wsl = { status: 'skipped', reason: `WSL gate error: ${err.message}` };
  }

  // Layer 2: desktop-zhcn
  let langResult = null;
  const postQuitHookPath = path.join(opts.stateRoot, 'post-quit-hook.json');
  try {
    const origScheme = readTextMember('dist/customScheme.js');
    const origOverlay = readTextMember('dist/loadingOverlay.js');
    if (!origScheme) {
      layers.language = { status: 'skipped', reason: 'dist/customScheme.js absent' };
    } else {
      langResult = await applyLanguageLayer({
        appAsarPath: info.appAsarPath,
        hostVersion: info.version,
        origCustomScheme: origScheme,
        origLoadingOverlay: origOverlay,
        stateRoot: opts.stateRoot,
        postQuitHookPath,
        stageDir: workDir,
      });
      if (langResult.status === 'applied') {
        replacements.set('dist/customScheme.js', Buffer.from(langResult.customScheme, 'utf8'));
        if (langResult.loadingOverlay !== null) {
          replacements.set('dist/loadingOverlay.js', Buffer.from(langResult.loadingOverlay, 'utf8'));
        }
        layers.language = {
          status: 'applied',
          version: langResult.version,
          stateDir: langResult.stateDir,
          uiSha256: langResult.uiSha256,
          embeddedUiSha256: langResult.embeddedUiSha256,
        };
      } else {
        layers.language = langResult;
      }
    }
  } catch (err) {
    layers.language = { status: 'skipped', reason: `Language gate error: ${err.message}` };
  }

  // Layer 3: pulse
  const origPreload = readTextMember('dist/preload.js');
  let pulseSnippet = '';
  try {
    if (!origPreload) {
      layers.pulse = { status: 'skipped', reason: 'dist/preload.js absent' };
    } else {
      const res = applyPulseLayer(sourceBuf, origPreload, workDir);
      if (res.status === 'applied') {
        pulseSnippet = res.snippet;
        layers.pulse = { status: 'applied', version: res.version, payloadSha256: res.payloadSha256 };
      } else {
        layers.pulse = res;
      }
    }
  } catch (err) {
    layers.pulse = { status: 'skipped', reason: `Pulse gate error: ${err.message}` };
  }

  // Layer 4: context-viewer (meter-only)
  let contextPreloadSnippet = '';
  try {
    const origUtils = readTextMember('dist/utils.js');
    if (!origUtils || !origPreload) {
      layers.contextViewer = { status: 'skipped', reason: 'dist/utils.js or dist/preload.js absent' };
    } else {
      const res = await applyContextViewerLayer({
        hostVersion: info.version,
        origUtils,
        origPreload,
        stateRoot: opts.stateRoot,
        stageDir: workDir,
      });
      if (res.status === 'applied') {
        replacements.set('dist/utils.js', Buffer.from(res.utils, 'utf8'));
        contextPreloadSnippet = res.preloadSnippet;
        for (const [k, v] of res.additions.entries()) additions.set(k, v);
        layers.contextViewer = {
          status: 'applied',
          version: res.version,
          anchor: res.anchor,
          addedFiles: res.additions.size,
        };
      } else {
        layers.contextViewer = res;
      }
    }
  } catch (err) {
    layers.contextViewer = { status: 'skipped', reason: `ContextViewer gate error: ${err.message}` };
  }

  // Combine dist/preload.js in canonical order: official + context + pulse
  if (origPreload && (contextPreloadSnippet || pulseSnippet)) {
    const combinedPreload = origPreload + contextPreloadSnippet + pulseSnippet;
    verifyNodeSyntax(combinedPreload, workDir, 'dist/preload.js');
    replacements.set('dist/preload.js', Buffer.from(combinedPreload, 'utf8'));
  }

  // Layer 5: updater relaunch hand-off
  const launcherPath = path.join(opts.backupDir, 'LaunchAntigravity.exe');
  try {
    const origUpdater = readTextMember('dist/updater.js');
    if (!origUpdater) {
      layers.updater = { status: 'skipped', reason: 'dist/updater.js absent' };
    } else {
      const res = applyUpdaterLayer(origUpdater, postQuitHookPath, launcherPath, workDir);
      if (res.status === 'ready') {
        await res.verifyAsync();
        replacements.set('dist/updater.js', Buffer.from(res.source, 'utf8'));
        layers.updater = { status: 'applied', sha256: sha256(Buffer.from(res.source, 'utf8')) };
      } else {
        layers.updater = res;
      }
    }
  } catch (err) {
    layers.updater = { status: 'skipped', reason: `Updater gate error: ${err.message}` };
  }

  const appliedLayers = Object.entries(layers).filter(([, v]) => v.status === 'applied').map(([k]) => k);
  const skippedLayers = Object.entries(layers).filter(([, v]) => v.status !== 'applied').map(([k, v]) => ({ layer: k, reason: v.reason }));

  if (appliedLayers.length === 0) {
    const abortReceipt = {
      status: 'aborted-no-layers',
      version: info.version,
      officialSha256: officialSha,
      layers,
      stageDir,
    };
    await writeFileAtomic(path.join(stageDir, 'result.json'), JSON.stringify(abortReceipt, null, 2) + '\n');
    return abortReceipt;
  }

  const { buffer: combinedBuffer, unchangedCount } = packAsarWithOverlay(sourceBuf, replacements, additions);
  const combinedSha = sha256(combinedBuffer);

  // Persist runtime state files (only when not dry-run)
  if (!opts.dryRun) {
    if (langResult && langResult.status === 'applied') {
      const langDir = path.join(opts.stateRoot, `language-${info.version}`);
      await writeFileAtomic(path.join(langDir, 'agy_zhcn_ui_main.js'), langResult.uiBuffer);
      const langSettingsPath = path.join(langDir, 'settings.json');
      if (!fs.existsSync(langSettingsPath)) {
        await writeFileAtomic(langSettingsPath, JSON.stringify({
          schemaVersion: 1,
          autoFollow: 'off',
          onlineTranslate: false,
          titleWriteBack: false,
        }) + '\n');
      }
    }
    if (layers.contextViewer?.status === 'applied') {
      const ctxSettingsPath = path.join(opts.stateRoot, 'context/modules.json');
      if (!fs.existsSync(ctxSettingsPath)) {
        await writeFileAtomic(ctxSettingsPath, JSON.stringify(DEFAULT_CONTEXT_MODULES, null, 2) + '\n');
      }
    }
  }

  const buildRecord = {
    schemaVersion: 1,
    version: info.version,
    reconcilerSha256: info.reconcilerSha256,
    officialSha256: officialSha,
    replaceTargetSha256: info.currentAsarSha,
    combinedSha256: combinedSha,
    languageServerSha256: info.languageServerSha256,
    appliedLayers,
    skippedLayers,
    layers,
    unchangedPackedMembers: unchangedCount,
    backupPath,
    stageDir,
    builtAt: new Date().toISOString(),
  };

  let finalStatus = 'dry-run-verified';
  if (!opts.dryRun) {
    if (opts.stageOnly) {
      await writeFileAtomic(path.join(opts.stateRoot, 'pending-app.asar'), combinedBuffer);
      await writeFileAtomic(path.join(opts.stateRoot, 'pending-apply.json'), JSON.stringify(buildRecord, null, 2) + '\n');
      finalStatus = 'staged-pending';
    } else if (opts.apply) {
      try {
        await swapAsarAtomically(info.appAsarPath, combinedBuffer, info.currentAsarSha, combinedSha);
        await writeFileAtomic(path.join(opts.stateRoot, 'active-build.json'), JSON.stringify(buildRecord, null, 2) + '\n');
        await fsp.rm(path.join(opts.stateRoot, 'pending-app.asar'), { force: true }).catch(() => {});
        await fsp.rm(path.join(opts.stateRoot, 'pending-apply.json'), { force: true }).catch(() => {});
        finalStatus = 'applied';
      } catch (err) {
        if (err.isLockError) {
          await writeFileAtomic(path.join(opts.stateRoot, 'pending-app.asar'), combinedBuffer);
          await writeFileAtomic(path.join(opts.stateRoot, 'pending-apply.json'), JSON.stringify(buildRecord, null, 2) + '\n');
          finalStatus = 'staged-pending-locked';
        } else {
          throw err;
        }
      }
    }
  }

  const receipt = { status: finalStatus, ...buildRecord };
  await writeFileAtomic(path.join(stageDir, 'result.json'), JSON.stringify(receipt, null, 2) + '\n');
  return receipt;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  let result;
  if (opts.command === 'status') {
    const info = await inspectLive(opts);
    result = {
      status: info.state,
      version: info.version,
      currentAsarSha: info.currentAsarSha,
      languageServerSha256: info.languageServerSha256,
      markers: info.markers,
      langUiExists: info.langUiExists,
      hasPending: Boolean(info.pendingApply),
    };
  } else if (opts.command === 'adopt') {
    result = await cmdAdopt(opts);
  } else if (opts.command === 'reconcile') {
    result = await cmdReconcile(opts);
  } else {
    throw new Error(`Unknown command: ${opts.command}`);
  }
  console.log(JSON.stringify(result));
}

export {
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
};

const isMainModule = Boolean(process.argv[1]) && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMainModule) {
  main().catch((err) => {
    console.error(err.stack || err.message || String(err));
    process.exitCode = 1;
  });
}
