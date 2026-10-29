'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const { githubSlug, mainCiWarning, runGh } = require(path.join(PROJECT_ROOT, 'scripts', 'Warn-RedMainCi.cjs'));

const REMOTE = 'https://github.com/o/r.git';
const PUSHED_OID = 'a'.repeat(40);
const ZERO_OID = '0'.repeat(40);
const refLine = (remoteRef, localOid = PUSHED_OID) => `refs/heads/topic ${localOid} ${remoteRef} ${ZERO_OID}\n`;
const MAIN_PUSH = refLine('refs/heads/main');
const RUN_LIST = ['run', 'list', '--repo', 'o/r', '--workflow', 'ci.yml', '--branch', 'main',
  '--status', 'completed', '--limit', '1', '--json', 'conclusion,headSha,displayTitle,url'];

function fakeGh(result) {
  const calls = [];
  return { calls, gh: (args) => { calls.push(args); return result; } };
}
const listed = (...runs) => ({ ok: true, stdout: JSON.stringify(runs) });
const ciRun = (conclusion) => ({
  conclusion, headSha: 'abcdef1234567890', displayTitle: 'docs: probe', url: 'https://github.com/o/r/actions/runs/1',
});

// The latest completed run on main did not pass: warn with its conclusion, short SHA, title and link.
for (const conclusion of ['failure', 'cancelled', 'timed_out', 'startup_failure']) {
  const { calls, gh } = fakeGh(listed(ciRun(conclusion)));
  const warning = mainCiWarning(REMOTE, MAIN_PUSH, gh);
  assert.ok(warning?.includes(`没通过（${conclusion}）：abcdef1 docs: probe`), `${conclusion}: ${warning}`);
  assert.ok(warning.includes('https://github.com/o/r/actions/runs/1'), warning);
  assert.deepEqual(calls, [RUN_LIST]);
}
assert.ok(mainCiWarning(REMOTE, refLine('refs/heads/topic') + MAIN_PUSH, fakeGh(listed(ciRun('failure'))).gh),
  'main pushed together with another ref');

// Passed, or no completed run yet: nothing to say.
for (const result of [listed(ciRun('success')), listed(ciRun('skipped')), listed()]) {
  assert.equal(mainCiWarning(REMOTE, MAIN_PUSH, fakeGh(result).gh), null, result.stdout);
}

// A push that does not update main on GitHub never asks gh.
for (const [remote, refLines] of [
  [REMOTE, refLine('refs/heads/topic')],
  [REMOTE, refLine('refs/heads/main', ZERO_OID)],
  [REMOTE, ''],
  ['D:/bare/r.git', MAIN_PUSH],
  ['https://gitlab.com/o/r.git', MAIN_PUSH],
]) {
  const { calls, gh } = fakeGh(listed(ciRun('failure')));
  assert.equal(mainCiWarning(remote, refLines, gh), null, `${remote} ${refLines}`);
  assert.equal(calls.length, 0, `${remote} ${refLines}`);
}
assert.equal(githubSlug('git@github.com:Baker4real/unified-env.git'), 'Baker4real/unified-env');

// A lookup that fails says why in one line instead of guessing.
assert.equal(mainCiWarning(REMOTE, MAIN_PUSH, fakeGh({ ok: false, reason: 'gh 退出码 4' }).gh),
  'pre-push：没查到 main 的 CI 状态（gh 退出码 4），这次不提醒。');
assert.match(mainCiWarning(REMOTE, MAIN_PUSH, fakeGh({ ok: true, stdout: 'not json' }).gh), /不是 JSON/);

// runGh against real processes: a hung gh is cut off at the limit, a failing one reports its exit code and the
// first stderr line, a missing one reports that it could not start.
const started = Date.now();
assert.deepEqual(runGh(['-e', 'setTimeout(() => {}, 60000)'], { command: process.execPath, timeoutMs: 1000 }),
  { ok: false, reason: 'gh 在 1 秒内没有返回' });
assert.ok(Date.now() - started < 15000, `timeout took ${Date.now() - started} ms`);
assert.deepEqual(
  runGh(['-e', 'process.stderr.write("not logged in\\nsecond line\\n"); process.exit(4)'], { command: process.execPath }),
  { ok: false, reason: 'gh 退出码 4：not logged in' });
assert.match(runGh([], { command: path.join(PROJECT_ROOT, 'no-such-gh.exe') }).reason, /^gh 无法启动：ENOENT/);

// Wiring: git runs .githooks/pre-push with the remote and the pushed refs on stdin. gh has no login here
// (empty GH_CONFIG_DIR, no token), so the hook must report that it could not look, and still exit 0.
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'warn-red-main-ci-'));
try {
  const repo = path.join(root, 'repo');
  const refsPath = path.join(root, 'refs.txt');
  fs.writeFileSync(refsPath, MAIN_PUSH);
  assert.equal(spawnSync('git', ['init', '-q', repo], { windowsHide: true }).status, 0);
  const env = { ...process.env, GH_CONFIG_DIR: path.join(root, 'gh-config') };
  for (const name of ['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN']) delete env[name];
  const hook = spawnSync('git', ['-C', repo, '-c', `core.hooksPath=${path.join(PROJECT_ROOT, '.githooks')}`,
    'hook', 'run', `--to-stdin=${refsPath}`, 'pre-push', '--', 'origin', REMOTE], { encoding: 'utf8', env, windowsHide: true });
  assert.equal(hook.status, 0, hook.stderr);
  assert.match(hook.stderr, /pre-push：没查到 main 的 CI 状态（gh /, hook.stderr);
} finally {
  fs.rmSync(root, { recursive: true, force: true, maxRetries: 3 });
}

console.log('PASS Test-WarnRedMainCi');
