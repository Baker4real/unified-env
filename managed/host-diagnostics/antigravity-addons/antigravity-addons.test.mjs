import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const res = spawnSync(process.execPath, [path.join(dir, 'test-reconcile-addons.mjs'), '--unit'], {
  stdio: 'inherit',
  timeout: 30000,
});
process.exit(res.status ?? 1);
