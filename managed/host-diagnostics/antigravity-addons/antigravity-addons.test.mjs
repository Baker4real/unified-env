import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const res = spawnSync(process.execPath, [path.join(dir, 'test-reconcile-addons.mjs'), '--unit'], {
  stdio: 'inherit',
  timeout: 30000,
});
if (res.status !== 0) process.exit(res.status ?? 1);
if (process.platform === 'win32') {
  const registry = spawnSync('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', path.join(dir, 'Test-AntigravityUpdateTarget.ps1')], {
    stdio: 'inherit',
    timeout: 30000,
  });
  process.exit(registry.status ?? 1);
}
