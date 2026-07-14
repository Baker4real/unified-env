'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const codexRoot = path.resolve(
  process.env.CODEX_ROOT || 'D:/Codex/.codex',
);
const activeRoot = path.join(codexRoot, 'skills');
const ledgerPath = path.join(activeRoot, '.downloaded-skills-source-state.json');
const menuScript = fs.readFileSync(
  path.join(codexRoot, 'scripts', 'retired-skill-menu-surface.cjs'),
  'utf8',
);
assert.doesNotMatch(menuScript, /backupAndRemove|backupPathFor|cpSync|copyFileSync/);
const retiredNames = [
  'brainstorming',
  'finishing-a-development-branch',
  'subagent-driven-development',
  'systematic-debugging',
  'test-driven-development',
  'verification-before-completion',
  'writing-plans',
];

const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
const sourceGroup = ledger.sources.find((source) => source.id === 'obra-superpowers');
assert.ok(sourceGroup, '缺少 obra-superpowers source group');
assert.equal(sourceGroup.status, 'deleted-by-user');
assert.deepEqual(sourceGroup.skills, []);
const sourceDeleted = new Map((sourceGroup.deleted_skills || []).map((row) => [row.name, row]));

const deleted = retiredNames.map((name) => {
  const activePath = path.join(activeRoot, name);
  assert.equal(fs.existsSync(activePath), false, name + ' 仍在 active root');

  const entry = ledger.deleted.find((row) => row.name === name);
  assert.ok(entry, '账本缺少 ' + name + ' 的 deleted 记录');
  assert.equal(entry.source, 'obra-superpowers');
  assert.equal(entry.status, 'deleted-by-user');
  assert.equal(entry.backup_path, null, name + ' 不应保留本机备份路径');
  assert.equal(entry.backup_status, 'purged-by-user-rule');

  const sourceEntry = sourceDeleted.get(name);
  assert.ok(sourceEntry, 'source group 账本缺少 ' + name + ' 的 deleted_skills 记录');
  assert.equal(sourceEntry.backup_path, null, name + ' source 记录不应保留本机备份路径');
  assert.equal(sourceEntry.backup_status, 'purged-by-user-rule');
  return name;
});

assert.equal(new Set(deleted).size, retiredNames.length);
console.log('Superpowers skill retirement: PASS (' + deleted.length + ' skills)');
