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

const privateStack = readSkill('private-patch-stack');
const neatFreak = readSkill('neat-freak');
const closeoutReference = readSkill('neat-freak', 'references/repo-clean-closeout.md');
const repoCloseout = readSkill('repo-clean-closeout');
const cleanWorktree = readSkill('clean-git-worktree');
const handoff = readSkill('handoff');
const sourceLedger = JSON.parse(
  fs.readFileSync(path.join(codexRoot, 'skills', '.downloaded-skills-source-state.json'), 'utf8'),
);
const retiredFinishingPath = path.join(codexRoot, 'skills', 'finishing-a-development-branch');

const failures = [];
function check(name, callback) {
  try {
    callback();
  } catch (error) {
    failures.push(`${name}: ${error.message}`);
  }
}

function assertOrdered(text, patterns, label) {
  let cursor = -1;
  for (const pattern of patterns) {
    const match = pattern.exec(text);
    assert.ok(match, `${label}: missing ${pattern}`);
    assert.ok(match.index > cursor, `${label}: ${pattern} is out of order`);
    cursor = match.index;
  }
}

function sectionBetween(text, start, end) {
  const startIndex = text.search(start);
  assert.ok(startIndex >= 0, `missing section ${start}`);
  const endIndex = text.search(end);
  return text.slice(startIndex, endIndex >= 0 ? endIndex : text.length);
}

check('obra/superpowers finishing skill must be retired from active root', () => {
  assert.equal(fs.existsSync(retiredFinishingPath), false, 'finishing-a-development-branch 仍在 active root');
  const deleted = sourceLedger.deleted.find((entry) => entry.name === 'finishing-a-development-branch');
  assert.ok(deleted, '账本缺少 finishing-a-development-branch 的退役记录');
  assert.equal(deleted.source, 'obra-superpowers');
  assert.equal(deleted.status, 'deleted-by-user');
});

check('canonical flows must own worktrees and remove them in a safe order', () => {
  for (const [name, text] of [
    ['closeout reference', closeoutReference.text],
    ['private compatibility flow', privateStack.text],
  ]) {
    assert.match(text, /(?:workflow|流程).*(?:owned|ownership|所有权|创建并.*接管|明确接管)/is);
    assert.match(text, /(?:用户|user|未知|unknown).*(?:worktree).*(?:不.*删除|报告|停止|stop|保留)/is);
    assert.match(text, /(?:其他|other).*(?:worktree).*(?:报告|停止|stop|保留)/is);
    assert.match(text, /remote deletion failed|远端删除失败/i);
    assert.match(text, /(?:保留|preserve).*(?:local|本地).*(?:worktree|工作树)/is);
    const lifecycle = sectionBetween(text, /受控临时分支|历史引用和回滚/i, /完成门槛|阶段性完成证明/i);
    assertOrdered(
      lifecycle,
      [
        /git\s+push[^\n]*--delete/i,
        /git\s+worktree\s+remove/i,
        /git\s+branch\s+-d\b/i,
        /git\s+fetch\s+--prune/i,
      ],
      name,
    );
    const direct = sectionBetween(text, /直接 default branch 发布|默认发布路径/i, /受控临时分支|受控临时 worktree|临时分支生命周期|临时分支清理/i);
    assert.doesNotMatch(direct, /git\s+worktree\s+(?:add|remove)/i);
    const directPushIndex = direct.search(/git\s+push(?![^\n]*--delete)/i);
    const directFetchIndex = direct.search(/git\s+fetch\s+--prune/i);
    assert.ok(directPushIndex >= 0, `${name}: direct path must push default branch`);
    assert.ok(directFetchIndex > directPushIndex, `${name}: direct fetch --prune must follow push`);
    assert.match(direct, /git\s+rev-parse\s+HEAD/i);
    assert.match(direct, /git\s+rev-parse\s+(?:<targetRemote>|private)\/<defaultBranch>/i);
    assert.match(direct, /git\s+branch\s+-vv/i);
  }
});

check('canonical temporary branches must publish with tracking before confirmation cleanup', () => {
  for (const [name, text] of [
    ['closeout reference', closeoutReference.text],
    ['private compatibility flow', privateStack.text],
  ]) {
    const tracking = /git\s+push\s+--set-upstream\s+<targetRemote>\s+<temporaryBranch>/i;
    const remoteDelete = /git\s+push[^\n]*--delete/i;
    assert.match(text, tracking);
    const trackingIndex = text.search(tracking);
    const remoteDeleteIndex = text.search(remoteDelete);
    assert.ok(remoteDeleteIndex > trackingIndex, `${name}: remote cleanup must follow tracked temp publish`);
  }
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
