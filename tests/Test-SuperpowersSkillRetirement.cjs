'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Live host check only; the scripts' fixture coverage is in
// Test-RetiredSkillMenuSurface.cjs and Test-RetiredSkillBackupManifestPurger.cjs.
const projectRoot = path.resolve(__dirname, '..');
const codexRoot = path.resolve(process.env.CODEX_ROOT || 'D:/Codex/.codex');
const activeRoot = path.join(codexRoot, 'skills');
const ledgerPath = path.join(activeRoot, '.downloaded-skills-source-state.json');
const menuScript = path.join(codexRoot, 'scripts', 'retired-skill-menu-surface.cjs');
const backupScript = path.join(codexRoot, 'scripts', 'purge-retired-skill-backups.cjs');

const retiredNames = [
  'brainstorming',
  'dispatching-parallel-agents',
  'executing-plans',
  'finishing-a-development-branch',
  'receiving-code-review',
  'requesting-code-review',
  'subagent-driven-development',
  'systematic-debugging',
  'test-driven-development',
  'using-git-worktrees',
  'using-superpowers',
  'verification-before-completion',
  'writing-plans',
  'writing-skills',
];

// config.toml enables a plugin with `enabled = true` in its
// [plugins."<name>@<marketplace>"] table.
function enabledPlugins(config) {
  const enabled = [];
  let plugin = null;
  for (const line of config.split(/\r?\n/)) {
    const header = line.match(/^\s*\[(.*)\]\s*$/);
    if (header) {
      const match = header[1].match(/^plugins\."([^"@]+)@[^"]*"$/);
      plugin = match ? match[1].toLowerCase() : null;
    } else if (plugin && /^\s*enabled\s*=\s*true\s*(#.*)?$/.test(line)) {
      enabled.push(plugin);
    }
  }
  return enabled;
}

function runJsonScript(script, args = [], env = process.env, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [script, ...args], {
    encoding: 'utf8',
    env,
    windowsHide: true,
  });
  assert.equal(result.status, expectedStatus, `${path.basename(script)} 未通过：${result.stderr || result.stdout}`);
  assert.equal(result.stderr, '', `${path.basename(script)} 不应向 stderr 输出：${result.stderr}`);
  assert.notEqual(result.stdout.trim(), '', `${path.basename(script)} 必须输出 JSON`);
  return JSON.parse(result.stdout);
}

const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
const sourceGroup = ledger.sources.find((source) => source.id === 'obra-superpowers');
assert.ok(sourceGroup, '缺少 obra-superpowers source group');
assert.equal(sourceGroup.status, 'deleted-by-user');
assert.deepEqual(sourceGroup.skills, []);
assert.deepEqual([...sourceGroup.retirement_scope].sort(), [...retiredNames].sort());
assert.equal(sourceGroup.backup_path, null);
assert.equal(sourceGroup.backup_status, 'purged-by-user-rule');
const sourceDeleted = new Map((sourceGroup.deleted_skills || []).map((row) => [row.name, row]));
for (const name of retiredNames) {
  assert.equal(fs.existsSync(path.join(activeRoot, name)), false, `${name} 仍在 active root`);
  const entry = ledger.deleted.find((row) => row.name === name);
  assert.ok(entry, `账本缺少 ${name} 的 deleted 记录`);
  assert.equal(entry.source, 'obra-superpowers');
  assert.equal(entry.status, 'deleted-by-user');
  assert.equal(entry.backup_path, null);
  assert.equal(entry.backup_status, 'purged-by-user-rule');
  const sourceEntry = sourceDeleted.get(name);
  assert.ok(sourceEntry, `source group 缺少 ${name}`);
  assert.equal(sourceEntry.backup_path, null);
  assert.equal(sourceEntry.backup_status, 'purged-by-user-rule');
}

// Retired means not active, not installed and not enabled.  The local
// marketplace copy under .tmp is re-synced by the Codex app and may still list
// Superpowers as available, so it is not asserted here.
const pluginCacheRoots = [
  path.join(codexRoot, 'plugins', 'cache'),
  path.join(codexRoot, 'account_backup', 'windows', 'login_runtime', 'plugins', 'cache'),
  path.join(codexRoot, 'account_backup', 'windows', 'refresh_runtime', 'plugins', 'cache'),
];
for (const cacheRoot of pluginCacheRoots.filter((root) => fs.existsSync(root))) {
  for (const marketplace of fs.readdirSync(cacheRoot)) {
    const installed = path.join(cacheRoot, marketplace, 'superpowers');
    assert.equal(fs.existsSync(installed), false, `Superpowers 仍安装在 ${installed}`);
  }
}
const config = fs.readFileSync(path.join(codexRoot, 'config.toml'), 'utf8');
assert.equal(enabledPlugins(config).includes('superpowers'), false, 'config.toml 仍启用 Superpowers 插件');

// The live audits run the deployed copies, which must be the repository source.
for (const script of [menuScript, backupScript]) {
  assert.ok(
    fs.readFileSync(script).equals(fs.readFileSync(path.join(projectRoot, 'scripts', path.basename(script)))),
    `${script} 与仓库源码不一致，先用 scripts/Deploy-RetiredSkillCleanup.ps1 部署`,
  );
}

const menuAudit = runJsonScript(menuScript);
assert.equal(menuAudit.ok, true, '仍有已安装退休菜单或插件 payload');
const backupAudit = runJsonScript(backupScript);
assert.equal(backupAudit.candidateCount, 0, '仍有退役 skill 或插件备份');
assert.equal(backupAudit.staleBackupCleanupManifestCount, 0, '退役 ledger 仍保留失效 cleanup manifest');

console.log(`Superpowers full retirement: PASS (${retiredNames.length} skills; ledger, not installed or enabled, deployed script parity, live menu and backup audits)`);
