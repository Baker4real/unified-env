#!/usr/bin/env node

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function argumentValue(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const codexRoot = path.resolve(
  argumentValue('--codex-root', process.env.CODEX_ROOT || 'D:/Codex/.codex'),
);

function readSkill(skill, relativePath = 'SKILL.md') {
  const file = path.join(codexRoot, 'skills', skill, relativePath);
  return { file, text: fs.readFileSync(file, 'utf8') };
}

const finishing = readSkill('finishing-a-development-branch');
const privateStack = readSkill('private-patch-stack');
const neatFreak = readSkill('neat-freak');
const closeoutReference = readSkill('neat-freak', 'references/repo-clean-closeout.md');
const repoCloseout = readSkill('repo-clean-closeout');
const cleanWorktree = readSkill('clean-git-worktree');
const handoff = readSkill('handoff');

const failures = [];
function check(name, callback) {
  try {
    callback();
  } catch (error) {
    failures.push(`${name}: ${error.message}`);
  }
}

check('finishing must resolve the default branch instead of guessing main/master', () => {
  assert.doesNotMatch(finishing.text, /merge-base\s+HEAD\s+(?:main|master)/i);
  assert.match(finishing.text, /ls-remote\s+--symref[\s\S]*\bHEAD\b/i);
  assert.match(finishing.text, /defaultBranchRef/i);
});

check('finishing must publish and reconcile temporary branches explicitly', () => {
  assert.match(finishing.text, /git\s+push[\s\S]*--delete/i);
  assert.match(finishing.text, /fetch\s+--prune/i);
  assert.match(finishing.text, /local[\s\S]*remote|remote[\s\S]*local/i);
  assert.doesNotMatch(finishing.text, /create (?:a )?pull request by default|default pull request|Keep the branch as-is/i);
});

check('private-patch-stack must be private-default compatibility protection', () => {
  assert.match(privateStack.text, /private[\s-]+(?:upstream|default branch)|private repository/i);
  assert.match(privateStack.text, /source remote[\s\S]*(?:push|禁推)|push[\s\S]*(?:disabled|禁用)/i);
  assert.doesNotMatch(privateStack.text, /refs\/heads\/patch-stack/i);
  assert.doesNotMatch(privateStack.text, /git\s+push[^\n]*patch-stack/i);
  assert.doesNotMatch(privateStack.text, /patch-stack\/NN-|patch-stack\/\d{2}-/i);
  assert.match(privateStack.text, /git revert|提交历史|controlled temporary branch|受控临时分支/i);
});

check('neat-freak must route to the canonical closeout reference', () => {
  assert.match(neatFreak.text, /references[\\/]repo-clean-closeout\.md/);
  assert.match(closeoutReference.text, /default branch|默认分支/i);
  assert.match(closeoutReference.text, /patch-stack/i);
  assert.match(closeoutReference.text, /报告|report/i);
  assert.match(closeoutReference.text, /单独.*授权|separate.*authori[sz]ation|等待.*授权/i);
});

check('compatibility wrappers must remain thin', () => {
  assert.match(repoCloseout.text, /neat-freak[\\/].*repo-clean-closeout\.md/i);
  assert.match(cleanWorktree.text, /Repository Clean Gate/);
  assert.doesNotMatch(repoCloseout.text, /merge-base\s+HEAD\s+(?:main|master)/i);
  assert.doesNotMatch(cleanWorktree.text, /merge-base\s+HEAD\s+(?:main|master)/i);
});

check('handoff must use D-hosted point-in-time paths and stay observational', () => {
  assert.match(handoff.text, /D:\\Codex\\\.codex\\handoffs\\projectless/i);
  assert.doesNotMatch(handoff.text, /temporary directory of the user's OS/i);
  assert.match(handoff.text, /point[- ]in[- ]time|时间点/i);
  assert.doesNotMatch(handoff.text, /^\s*git\s+(?:push|branch|worktree)\b/im);
});

if (failures.length > 0) {
  console.error(`Git default-branch skill policy: FAIL (${failures.length} checks)`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log('Git default-branch skill policy: PASS');
}
