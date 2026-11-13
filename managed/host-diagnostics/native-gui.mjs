import { execFile } from 'node:child_process';
import path from 'node:path';
import { createNativeSession } from './gui-session.mjs';

// The Python executable and exact window identity come from current host discovery.
// This adapter has no automatic activation, global keyboard shortcut or input retry.
export function createWindowsGuiSession({ python, pid, title, evidenceRoot, signal }) {
  if (!path.win32.isAbsolute(python || '') || !Number.isInteger(pid) || pid < 1 || typeof title !== 'string' || !title ||
      !/^D:[\\/]/i.test(evidenceRoot || '') || path.win32.parse(evidenceRoot).root === evidenceRoot) throw new Error('Provide absolute Python, observed PID/title and a D drive evidence directory');
  const script = path.join(import.meta.dirname, 'native-gui.py');
  const call = (action, fields = {}) => new Promise((resolve, reject) => {
    execFile(python, ['-I', script, action, JSON.stringify({ pid, title, evidenceRoot, ...fields })], { windowsHide: true, timeout: 5000, maxBuffer: 8192, signal }, (error, stdout) => {
      let result;
      try { result = JSON.parse(stdout); } catch { return reject(new Error('Native GUI transport failed without a valid bounded result')); }
      if (error || result.error) return reject(new Error(result.error || 'Native GUI operation failed'));
      resolve(result);
    });
  });
  return createNativeSession({
    observe: window => call('observe', { window }), verify: window => call('verify', { window }),
    click: args => call('click', args), activate: () => call('activate'),
  }, { signal });
}
