'use strict';
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const OUT_DIR = __dirname;
const REPO = path.resolve(__dirname, '..', '..');
const PWSH = 'D:\\Codex\\tools\\PowerShell\\7.6.4\\pwsh.exe';
const rel = 'tests/Test-CodexSafeTreeDeleteControlPlane.ps1';
const stdoutPath = path.join(OUT_DIR, 'verify-ControlPlane.stdout.txt');
const stderrPath = path.join(OUT_DIR, 'verify-ControlPlane.stderr.txt');
const outFd = fs.openSync(stdoutPath, 'w');
const errFd = fs.openSync(stderrPath, 'w');
const started = Date.now();
let result;
try {
  result = spawnSync(PWSH, ['-NoProfile', '-NonInteractive', '-File', path.join(REPO, rel)], {
    cwd: REPO,
    windowsHide: true,
    stdio: ['ignore', outFd, errFd],
  });
} finally {
  fs.closeSync(outFd);
  fs.closeSync(errFd);
}
const exit = result.status ?? (result.error ? -1 : 0);
console.log(`ControlPlane exit=${exit} elapsedMs=${Date.now() - started}`);
if (exit !== 0) {
  console.log(fs.readFileSync(stderrPath, 'utf8').slice(-2000));
}
process.exitCode = exit === 0 ? 0 : 1;
