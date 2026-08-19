'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const OUT_DIR = __dirname;
const REPO = path.resolve(__dirname, '..', '..');
const PWSH = process.env.PWSH_PATH || 'D:\\Codex\\tools\\PowerShell\\7.6.4\\pwsh.exe';
const TEST = path.join(REPO, 'tests', 'Test-CodexSafeTreeDeleteProductionSmoke.ps1');
const SMOKE_DIR = path.join(OUT_DIR, 'production-smoke');
const FROZEN_LEAF = path.join(
  REPO,
  'reports',
  'safe-tree-delete-issue55-20260816',
  'leaf-delete-failed.json'
);

function sha256File(filePath) {
  if (!fs.existsSync(filePath)) return null;
  const crypto = require('node:crypto');
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function tailText(text, lineCount) {
  const normalized = String(text || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  if (!normalized) return '';
  const lines = normalized.split('\n');
  return lines.slice(Math.max(0, lines.length - lineCount)).join('\n');
}

function main() {
  fs.mkdirSync(SMOKE_DIR, { recursive: true });
  const stdoutPath = path.join(OUT_DIR, 'Test-CodexSafeTreeDeleteProductionSmoke.ps1.stdout.txt');
  const stderrPath = path.join(OUT_DIR, 'Test-CodexSafeTreeDeleteProductionSmoke.ps1.stderr.txt');
  const frozenShaStart = sha256File(FROZEN_LEAF);
  const startedMs = Date.now();
  const startedAtUtc = new Date(startedMs).toISOString();
  const outFd = fs.openSync(stdoutPath, 'w');
  const errFd = fs.openSync(stderrPath, 'w');
  let result;
  try {
    result = spawnSync(PWSH, ['-NoProfile', '-NonInteractive', '-File', TEST], {
      cwd: REPO,
      windowsHide: true,
      stdio: ['ignore', outFd, errFd],
      env: {
        ...process.env,
        SAFE_TREE_DELETE_SMOKE_EVIDENCE_ROOT: SMOKE_DIR,
      },
    });
  } finally {
    fs.closeSync(outFd);
    fs.closeSync(errFd);
  }
  const endedMs = Date.now();
  const stdout = fs.readFileSync(stdoutPath, 'utf8');
  const stderr = fs.readFileSync(stderrPath, 'utf8');
  const exit = result.status ?? (result.error ? -1 : 0);
  const record = {
    artifactType: 'env-governance.codex-safe-tree-delete-issue21-production-smoke',
    issue: 21,
    name: 'tests/Test-CodexSafeTreeDeleteProductionSmoke.ps1',
    exit,
    elapsedMs: endedMs - startedMs,
    startedAtUtc,
    endedAtUtc: new Date(endedMs).toISOString(),
    pwsh: PWSH,
    harnessEvidenceRoot: SMOKE_DIR,
    frozenLeafDeleteFailedPath: FROZEN_LEAF,
    frozenLeafDeleteFailedSha256AtStart: frozenShaStart,
    frozenLeafDeleteFailedSha256AtEnd: sha256File(FROZEN_LEAF),
    stdoutPath,
    stderrPath,
    stderrTail: tailText(stderr, 40),
    stdoutTail: tailText(stdout, 40),
    spawnError: result.error ? String(result.error.message || result.error) : null,
  };
  record.frozenSnapshotsUntouched =
    record.frozenLeafDeleteFailedSha256AtStart != null &&
    record.frozenLeafDeleteFailedSha256AtStart === record.frozenLeafDeleteFailedSha256AtEnd;
  fs.writeFileSync(
    path.join(OUT_DIR, 'production-smoke-result.json'),
    `${JSON.stringify(record, null, 2)}\n`,
    'utf8'
  );
  console.log(`SMOKE_DONE exit=${exit} elapsedMs=${record.elapsedMs}`);
  if (exit !== 0) {
    console.log(record.stderrTail || record.stdoutTail);
  }
  process.exitCode = exit === 0 ? 0 : 1;
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exitCode = 1;
}
