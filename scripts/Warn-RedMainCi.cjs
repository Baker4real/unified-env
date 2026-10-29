'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');

// .githooks/pre-push runs this. When a push updates main on GitHub, it looks up the latest completed run of
// ci.yml on main and warns, with the run link, if that run did not pass. It only warns: the push goes on, and a
// lookup that fails or hangs is reported in one line instead of guessed.
const CI_WORKFLOW = 'ci.yml';
const GH_TIMEOUT_MS = 10000;
const PASSING_CONCLUSIONS = new Set(['success', 'neutral', 'skipped']);

// Same pattern as githubSlug in managed/claude-hooks/claude-public-push-guard.mjs.
function githubSlug(url) {
  const match = String(url).match(/^(?:https?:\/\/(?:[^@/]+@)?github\.com\/|ssh:\/\/git@github\.com\/|git@github\.com:)([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/i);
  return match ? `${match[1]}/${match[2]}` : null;
}

// Each stdin line is "<local ref> <local oid> <remote ref> <remote oid>"; an all-zero local oid deletes the ref.
function pushesMain(refLines) {
  return String(refLines).split(/\r?\n/).some((line) => {
    const [, localOid = '', remoteRef] = line.trim().split(/\s+/);
    return remoteRef === 'refs/heads/main' && /^[0-9a-f]+$/i.test(localOid) && !/^0+$/.test(localOid);
  });
}

function runGh(args, { command = 'gh', timeoutMs = GH_TIMEOUT_MS } = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    timeout: timeoutMs,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error?.code === 'ETIMEDOUT') return { ok: false, reason: `gh 在 ${timeoutMs / 1000} 秒内没有返回` };
  if (result.error) return { ok: false, reason: `gh 无法启动：${result.error.code || result.error.message}` };
  if (result.status !== 0) {
    const detail = String(result.stderr).trim().split(/\r?\n/)[0];
    return { ok: false, reason: `gh 退出码 ${result.status}${detail ? `：${detail}` : ''}` };
  }
  return { ok: true, stdout: result.stdout };
}

// The text to print for this push, or null when there is nothing to say.
function mainCiWarning(remoteUrl, refLines, gh = runGh) {
  const slug = githubSlug(remoteUrl);
  if (!slug || !pushesMain(refLines)) return null;
  const listed = gh(['run', 'list', '--repo', slug, '--workflow', CI_WORKFLOW, '--branch', 'main',
    '--status', 'completed', '--limit', '1', '--json', 'conclusion,headSha,displayTitle,url']);
  if (!listed.ok) return `pre-push：没查到 main 的 CI 状态（${listed.reason}），这次不提醒。`;
  let latest;
  try {
    [latest] = JSON.parse(listed.stdout);
  } catch {
    return 'pre-push：gh 返回的不是 JSON，没查到 main 的 CI 状态，这次不提醒。';
  }
  if (!latest || PASSING_CONCLUSIONS.has(latest.conclusion)) return null;
  return [
    `pre-push 警告：main 最近一次跑完的 CI 没通过（${latest.conclusion}）：${String(latest.headSha).slice(0, 7)} ${latest.displayTitle}`,
    `  ${latest.url}`,
    '  推送照常进行。这次推送如果不是在修它，先查清 main 为什么红，别在红的 main 上继续叠提交。',
  ].join('\n');
}

function main(args) {
  let refLines = '';
  try {
    refLines = fs.readFileSync(0, 'utf8');
  } catch {
    // No readable stdin (the hook run by hand): nothing says main is being pushed.
  }
  const warning = mainCiWarning(args[1] || '', refLines);
  if (warning) console.error(warning);
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`pre-push：检查 main 的 CI 状态时出错（${error.message}），这次不提醒。`);
  }
}

module.exports = {
  githubSlug,
  mainCiWarning,
  pushesMain,
  runGh,
};
