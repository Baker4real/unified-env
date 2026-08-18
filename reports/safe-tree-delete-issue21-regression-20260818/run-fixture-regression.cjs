'use strict';

const { spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const REPO = path.resolve(__dirname, '..', '..');
const OUT_DIR = __dirname;
const PWSH = process.env.PWSH_PATH || 'D:\\Codex\\tools\\PowerShell\\7.6.4\\pwsh.exe';
const MANIFEST_PATH = path.join(REPO, 'modules', 'manifest.json');
const LEFTOVER_TX =
  'D:\\Codex\\.codex\\run-evidence\\safe-tree-delete\\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\\transaction.json';
const LEFTOVER_Q = path.join(
  REPO,
  'reports',
  '.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine'
);
const TAIL_LINES = 40;
const FILESYSTEM_TEST = 'tests/Test-CodexSafeTreeDeleteFileSystem.ps1';

function sha256File(filePath) {
  if (!fs.existsSync(filePath)) return null;
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function tailText(text, lineCount) {
  const normalized = String(text || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  if (!normalized) return '';
  const lines = normalized.split('\n');
  return lines.slice(Math.max(0, lines.length - lineCount)).join('\n');
}

function probePwsh() {
  const result = spawnSync(
    PWSH,
    ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSEdition + " " + $PSVersionTable.PSVersion.ToString()'],
    { cwd: REPO, encoding: 'utf8', windowsHide: true }
  );
  if (result.status !== 0) {
    throw new Error(`pwsh probe failed: ${(result.stderr || result.stdout || result.status)}`);
  }
  return String(result.stdout || '').trim();
}

function loadFixtureList() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
  const owner = manifest.modules.find((entry) => entry.id === 'host-safety');
  if (!owner) throw new Error('host-safety module missing from manifest');
  const tests = owner.tests?.fixture?.powershell;
  if (!Array.isArray(tests) || tests.length === 0) {
    throw new Error('host-safety.tests.fixture.powershell missing or empty');
  }
  return tests;
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function buildSummary(state) {
  const failed = state.tests.filter((t) => t.exit !== 0);
  const waived = failed.filter((t) => t.name.replace(/\\/g, '/') === FILESYSTEM_TEST);
  const unexpected = failed.filter((t) => t.name.replace(/\\/g, '/') !== FILESYSTEM_TEST);
  return {
    artifactType: 'env-governance.codex-safe-tree-delete-issue21-fixture-regression',
    issue: 21,
    acceptanceCriterion: '既有全部 safe-tree-delete 测试保持通过',
    module: 'host-safety',
    profile: 'fixture',
    source: 'modules/manifest.json host-safety.tests.fixture.powershell',
    pwsh: PWSH,
    pwshVersion: state.pwshVersion,
    repo: REPO,
    startedAtUtc: state.startedAtUtc,
    generatedAtUtc: new Date().toISOString(),
    incomplete: state.incomplete,
    manifestCount: state.manifestTests.length,
    completedCount: state.tests.length,
    passCount: state.tests.filter((t) => t.exit === 0).length,
    failCount: failed.length,
    unexpectedFailCount: unexpected.length,
    leftoverTransactionSha256AtStart: state.leftoverTransactionSha256AtStart,
    leftoverTransactionSha256AtEnd: state.leftoverTransactionSha256AtEnd,
    leftoverQuarantineExistsAtStart: state.leftoverQuarantineExistsAtStart,
    leftoverQuarantineExistsAtEnd: state.leftoverQuarantineExistsAtEnd,
    leftoverUntouched:
      state.leftoverTransactionSha256AtStart != null &&
      state.leftoverTransactionSha256AtEnd != null &&
      state.leftoverTransactionSha256AtStart === state.leftoverTransactionSha256AtEnd,
    knownWaivers: [
      {
        name: FILESYSTEM_TEST,
        reason: 'FAT32/网络实卷 e2e 维护者 waiver（GitHub #35）。未提权 diskpart/VHD；红不改 DetectFileSystem。',
      },
    ],
    tests: state.tests,
  };
}

function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const manifestTests = loadFixtureList();
  const state = {
    pwshVersion: probePwsh(),
    startedAtUtc: new Date().toISOString(),
    incomplete: true,
    manifestTests,
    leftoverTransactionSha256AtStart: sha256File(LEFTOVER_TX),
    leftoverQuarantineExistsAtStart: fs.existsSync(LEFTOVER_Q),
    leftoverTransactionSha256AtEnd: null,
    leftoverQuarantineExistsAtEnd: null,
    tests: [],
  };

  writeJson(path.join(OUT_DIR, 'summary.json'), buildSummary(state));
  console.log(`RUNNER_START count=${manifestTests.length} pwsh=${state.pwshVersion}`);

  for (const rel of manifestTests) {
    const abs = path.resolve(REPO, rel);
    const base = path.basename(rel);
    const stdoutPath = path.join(OUT_DIR, `${base}.stdout.txt`);
    const stderrPath = path.join(OUT_DIR, `${base}.stderr.txt`);
    console.log(`START ${rel}`);
    const startedMs = Date.now();
    const startedAtUtc = new Date(startedMs).toISOString();
    const outFd = fs.openSync(stdoutPath, 'w');
    const errFd = fs.openSync(stderrPath, 'w');
    let spawnError = null;
    let result;
    try {
      result = spawnSync(PWSH, ['-NoProfile', '-NonInteractive', '-File', abs], {
        cwd: REPO,
        windowsHide: true,
        stdio: ['ignore', outFd, errFd],
      });
    } catch (error) {
      spawnError = error;
      result = { status: -1, error };
    } finally {
      fs.closeSync(outFd);
      fs.closeSync(errFd);
    }
    const endedMs = Date.now();
    const stdout = fs.readFileSync(stdoutPath, 'utf8');
    const stderr = fs.readFileSync(stderrPath, 'utf8');
    const exit = spawnError ? -1 : (result.status ?? (result.error ? -1 : 0));
    const entry = {
      name: rel.replace(/\\/g, '/'),
      exit,
      elapsedMs: endedMs - startedMs,
      startedAtUtc,
      endedAtUtc: new Date(endedMs).toISOString(),
      stderrTail: tailText(stderr, TAIL_LINES),
      stdoutTail: exit === 0 ? '' : tailText(stdout, TAIL_LINES),
      stdoutPath,
      stderrPath,
    };
    if (spawnError) entry.spawnError = String(spawnError.message || spawnError);
    if (result.error && !spawnError) entry.spawnError = String(result.error.message || result.error);
    if (entry.name === FILESYSTEM_TEST && exit !== 0) {
      entry.waiver = 'github-35-fat32-network-live-volume';
    }
    state.tests.push(entry);
    writeJson(path.join(OUT_DIR, 'summary.json'), buildSummary(state));
    console.log(`COMPLETED ${rel} exit=${exit} elapsedMs=${entry.elapsedMs}`);
  }

  state.incomplete = false;
  state.leftoverTransactionSha256AtEnd = sha256File(LEFTOVER_TX);
  state.leftoverQuarantineExistsAtEnd = fs.existsSync(LEFTOVER_Q);
  writeJson(path.join(OUT_DIR, 'summary.json'), buildSummary(state));
  console.log('RUNNER_DONE');
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exitCode = 1;
}
