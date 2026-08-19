'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const OUT_DIR = __dirname;
const REPO = path.resolve(__dirname, '..', '..');
const PWSH = 'D:\\Codex\\tools\\PowerShell\\7.6.4\\pwsh.exe';
const TESTS = [
  'tests/Test-CodexSafeTreeDelete.ps1',
  'tests/Test-CodexSafeTreeDeletePhase3Integration.ps1',
];

function tailText(text, lineCount) {
  const normalized = String(text || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  if (!normalized) return '';
  const lines = normalized.split('\n');
  return lines.slice(Math.max(0, lines.length - lineCount)).join('\n');
}

function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const results = [];
  console.log(`DIAG_START repo=${REPO}`);
  for (const rel of TESTS) {
    const abs = path.resolve(REPO, rel);
    const base = path.basename(rel);
    const stdoutPath = path.join(OUT_DIR, `diag-${base}.stdout.txt`);
    const stderrPath = path.join(OUT_DIR, `diag-${base}.stderr.txt`);
    console.log(`START ${rel}`);
    const startedMs = Date.now();
    const outFd = fs.openSync(stdoutPath, 'w');
    const errFd = fs.openSync(stderrPath, 'w');
    let result;
    try {
      result = spawnSync(PWSH, ['-NoProfile', '-NonInteractive', '-File', abs], {
        cwd: REPO,
        windowsHide: true,
        stdio: ['ignore', outFd, errFd],
      });
    } finally {
      fs.closeSync(outFd);
      fs.closeSync(errFd);
    }
    const elapsedMs = Date.now() - startedMs;
    const stdout = fs.readFileSync(stdoutPath, 'utf8');
    const stderr = fs.readFileSync(stderrPath, 'utf8');
    const exit = result.status ?? (result.error ? -1 : 0);
    const entry = {
      name: rel,
      exit,
      elapsedMs,
      stderrTail: tailText(stderr, 40),
      stdoutTail: tailText(stdout, 20),
    };
    results.push(entry);
    console.log(`COMPLETED ${rel} exit=${exit} elapsedMs=${elapsedMs}`);
    if (exit !== 0) {
      console.log('--- stderr ---');
      console.log(entry.stderrTail);
      console.log('--- stdout ---');
      console.log(entry.stdoutTail);
    }
  }
  fs.writeFileSync(
    path.join(OUT_DIR, 'diag-two.json'),
    `${JSON.stringify({ generatedAtUtc: new Date().toISOString(), results }, null, 2)}\n`,
    'utf8'
  );
  console.log('DIAG_DONE');
  const failed = results.filter((row) => row.exit !== 0);
  process.exitCode = failed.length === 0 ? 0 : 1;
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exitCode = 1;
}
