import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  applyWslLayer,
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
    console.log('ALL 5 UNIT TESTS PASSED');
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
    console.log('E2E PASS 1: full 4-layer reconcile on official 2.34.0');

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
