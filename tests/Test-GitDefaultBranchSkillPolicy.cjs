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

function readPluginSkill(surface, role) {
  const file = path.join(codexRoot, ...surface.split('/'), 'skills', role, 'SKILL.md');
  return { file, text: fs.readFileSync(file, 'utf8') };
}

const privateStack = readSkill('private-patch-stack');
const neatFreak = readSkill('neat-freak');
const closeoutReference = readSkill('neat-freak', 'references/repo-clean-closeout.md');
const repoCloseout = readSkill('repo-clean-closeout');
const handoff = readSkill('handoff');
const sourceLedger = JSON.parse(
  fs.readFileSync(path.join(codexRoot, 'skills', '.downloaded-skills-source-state.json'), 'utf8'),
);
const retiredFinishingPath = path.join(codexRoot, 'skills', 'finishing-a-development-branch');
const githubPluginSurfaces = [
  '.tmp/plugins/plugins/github',
  'plugins/cache/openai-curated/github/27126220',
  'plugins/cache/openai-curated-remote/github/0.1.8-2841cf9749ae',
];

const failures = [];
function check(name, callback) {
  try {
    callback();
  } catch (error) {
    failures.push(`${name}: ${error.message}`);
  }
}

check('obra/superpowers finishing skill must be retired from active root', () => {
  assert.equal(fs.existsSync(retiredFinishingPath), false, 'finishing-a-development-branch 仍在 active root');
  const deleted = sourceLedger.deleted.find((entry) => entry.name === 'finishing-a-development-branch');
  assert.ok(deleted, '账本缺少 finishing-a-development-branch 的退役记录');
  assert.equal(deleted.source, 'obra-superpowers');
  assert.equal(deleted.status, 'deleted-by-user');
});

check('neat-freak delivery mode must publish only authorized scope and prove clean parity', () => {
  assert.match(neatFreak.text, /本机 Git 交付 overlay[\s\S]*默认还要完成受管交付[\s\S]*用户拥有远端[\s\S]*main/i);
  assert.match(neatFreak.text, /只读、只整理或不发布/);
  assert.match(closeoutReference.text, /delivery mode/i);
  assert.match(closeoutReference.text, /all read-only publication preflights[\s\S]*before the first commit or push/i);
  assert.match(closeoutReference.text, /git status --porcelain=v1 -uall --branch/i);
  assert.match(closeoutReference.text, /remote is not ahead or diverged/i);
  assert.match(closeoutReference.text, /git push <user-owned-remote> HEAD:main/i);
  assert.match(closeoutReference.text, /empty porcelain output/i);
  assert.match(closeoutReference.text, /unrelated work/i);
  assert.match(closeoutReference.text, /never bypass it with `--no-verify`/i);
  assert.match(closeoutReference.text, /Never use destructive commands such as `git reset --hard`, `git clean -fd`/i);
});

check('private-patch-stack must be private-default compatibility protection', () => {
  assert.match(privateStack.text, /user-owned remote|用户拥有/i);
  assert.match(privateStack.text, /third-party upstream|public fork|vendor|非用户/i);
  assert.doesNotMatch(privateStack.text, /refs\/heads\/patch-stack/i);
  const englishContract = /do not create, update, or push a patch stack/i.test(privateStack.text);
  const chineseContract =
    /不再创建 patch-stack 分支/i.test(privateStack.text) &&
    /不拆分、不推送、不追踪 patch-stack 分支/i.test(privateStack.text);
  assert.ok(englishContract || chineseContract, '缺少禁止创建、更新或推送 patch-stack 的完整契约');
  assert.doesNotMatch(privateStack.text, /允许(?:创建|更新|推送)[^。\n]{0,40}patch-stack/i);
  assert.doesNotMatch(privateStack.text, /^\s*git\s+(?:branch|switch|checkout|push)\b[^\n]*patch-stack/im);
  assert.doesNotMatch(privateStack.text, /patch-stack\/NN-|patch-stack\/\d{2}-/i);
  assert.match(privateStack.text, /temporary branch|临时分支/i);
});

check('neat-freak must route to the canonical closeout reference', () => {
  assert.match(neatFreak.text, /references[\\/]repo-clean-closeout\.md/);
  assert.match(closeoutReference.text, /target `main`|目标.*main|remote\/main/i);
  assert.match(closeoutReference.text, /patch-stack/i);
  assert.match(closeoutReference.text, /报告|report/i);
  assert.match(closeoutReference.text, /explicit authorization for that exact action/i);
});

check('compatibility wrappers must remain thin', () => {
  assert.match(repoCloseout.text, /neat-freak[\\/].*repo-clean-closeout\.md/i);
  assert.doesNotMatch(repoCloseout.text, /merge-base\s+HEAD\s+(?:main|master)/i);
});

check('handoff must use D-hosted point-in-time paths and stay observational', () => {
  assert.match(handoff.text, /D:\\Codex\\\.codex\\handoffs\\projectless/i);
  assert.doesNotMatch(handoff.text, /temporary directory of the user's OS/i);
  assert.match(handoff.text, /point[- ]in[- ]time|时间点/i);
  assert.doesNotMatch(handoff.text, /^\s*git\s+(?:push|branch|worktree)\b/im);
});

check('all GitHub plugin surfaces must preserve hybrid capabilities behind main-only authorization', () => {
  for (const surface of githubPluginSurfaces) {
    const github = readPluginSkill(surface, 'github');
    const yeet = readPluginSkill(surface, 'yeet');
    for (const skill of [github, yeet]) {
      assert.match(skill.text, /<!-- codex-github-main-only-overlay: v2 -->/, skill.file);
      assert.match(skill.text, /当前任务[\s\S]{0,100}明确授权[\s\S]{0,100}(?:commit|push|发布)/i, skill.file);
      assert.match(skill.text, /用户拥有[\s\S]{0,80}(?:remote|远端)/i, skill.file);
      assert.match(skill.text, /git\s+push\s+<targetRemote>\s+HEAD:main/i, skill.file);
      assert.match(skill.text, /本地\s+HEAD[\s\S]{0,180}<targetRemote>\/main[\s\S]{0,100}(?:tracking|一致)/i, skill.file);
      assert.doesNotMatch(skill.text, /agent\/\{description\}/i, skill.file);
    }
    assert.match(github.text, /GitHub app/i, github.file);
    assert.match(github.text, /connector first|connector-first|优先使用 connector/i, github.file);
    assert.match(github.text, /current-branch PR discovery|当前分支[\s\S]{0,80}PR/i, github.file);
    assert.match(github.text, /GitHub Actions logs|GitHub Actions 日志/i, github.file);
    assert.match(github.text, /`gh`[\s\S]{0,80}(?:fallback|兜底)/i, github.file);
    assert.match(yeet.text, /PR creation|创建 PR/i, yeet.file);
    assert.match(yeet.text, /GitHub app/i, yeet.file);
    assert.match(yeet.text, /`gh`[\s\S]{0,80}(?:fallback|兜底)/i, yeet.file);
    assert.match(yeet.text, /发布前门禁[\s\S]{0,700}git\s+fetch\s+--prune\s+<targetRemote>[\s\S]{0,300}(?:ahead|diverged)/i, yeet.file);
    assert.match(yeet.text, /只有[\s\S]{0,180}用户确认[\s\S]{0,180}git\s+push\s+--set-upstream\s+<targetRemote>\s+<temporaryBranch>/i, yeet.file);
  }
});

if (failures.length > 0) {
  console.error(`Git default-branch skill policy: FAIL (${failures.length} checks)`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log('Git default-branch skill policy: PASS');
}
