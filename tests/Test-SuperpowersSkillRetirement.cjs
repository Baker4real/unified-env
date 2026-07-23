'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const projectRoot = path.resolve(__dirname, '..');
const reportsRoot = path.join(projectRoot, 'reports');
const codexRoot = path.resolve(process.env.CODEX_ROOT || 'D:/Codex/.codex');
const activeRoot = path.join(codexRoot, 'skills');
const ledgerPath = path.join(activeRoot, '.downloaded-skills-source-state.json');
const menuScript = path.join(codexRoot, 'scripts', 'retired-skill-menu-surface.cjs');
const backupScript = path.join(codexRoot, 'scripts', 'purge-retired-skill-backups.cjs');
const menu = require(menuScript);

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
const LARGE_MANIFEST_ENTRY_COUNT = 384;
const LARGE_MANIFEST_FILE_CONTENT = 'fixture large manifest payload\n';
const LARGE_MANIFEST_FILE_SUFFIX = '-abcdefghijklmnopqrstuvwxyz0123456789.bin';

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

function createFixture() {
  const parent = path.join(reportsRoot, `${menu.FIXTURE_PREFIX}${crypto.randomBytes(16).toString('hex')}`);
  const root = path.join(parent, '.codex');
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, menu.FIXTURE_MARKER), menu.FIXTURE_MARKER_VALUE, 'utf8');
  fs.mkdirSync(path.join(root, 'skills'), { recursive: true });
  fs.writeFileSync(path.join(root, 'skills', '.downloaded-skills-source-state.json'), JSON.stringify({
    sources: [{
      id: 'fixture-retired-plugin',
      repo: 'https://example.test/retired-source.git',
      status: 'deleted-by-user',
      deleted_skills: [{ name: 'fixture-retired-skill', status: 'deleted-by-user' }],
    }],
    deleted: [{ name: 'fixture-retired-skill', source: 'fixture-retired-plugin', status: 'deleted-by-user' }],
  }, null, 2), 'utf8');
  return root;
}

function fixtureEnv(extraEnvironment = {}) {
  return { ...process.env, [menu.FIXTURE_ENV]: '1', ...extraEnvironment };
}

function runMenu(root, args = [], expectedStatus = 0, extraEnvironment = {}) {
  return runJsonScript(menuScript, ['--fixture-root', root, ...args], fixtureEnv(extraEnvironment), expectedStatus);
}

function writeSkill(directory, name, sourceRepo) {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'SKILL.md'), `---\nname: ${name}\n---\nfixture\n`, 'utf8');
  if (sourceRepo) fs.writeFileSync(path.join(directory, 'SOURCE.md'), `Source repository: ${sourceRepo}\n`, 'utf8');
}

function writeText(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, 'utf8');
}

function largeManifestRelativePath(index) {
  return '!bulk/manifest-entry-' + String(index).padStart(4, '0') + LARGE_MANIFEST_FILE_SUFFIX;
}

function largeManifestSerializedLowerBoundBytes() {
  // The policy emits these fields in this order and uses fixed-width identity
  // values.  The generated entries are a strict subset of the real manifest,
  // proving that Apply must pass it over stdin instead of a command line.
  const entries = Array.from({ length: LARGE_MANIFEST_ENTRY_COUNT }, (_, index) => ({
    relativePath: largeManifestRelativePath(index),
    kind: 'file',
    sha256: '0'.repeat(64),
    identity: ['00000000', '0000000000000000'],
  }));
  return Buffer.byteLength(JSON.stringify({
    schemaVersion: 1,
    rootIdentity: ['00000000', '0000000000000000'],
    entries,
  }), 'utf8');
}

function removeFixture(root) {
  const parent = path.dirname(root);
  assert.ok(menu.isInside(parent, reportsRoot), 'fixture 清理不得越出 reports');
  assert.ok(path.basename(parent).startsWith(menu.FIXTURE_PREFIX), 'fixture 清理前缀不匹配');
  for (const entry of fs.readdirSync(parent, { withFileTypes: true })) {
    const candidate = path.join(parent, entry.name);
    if (fs.lstatSync(candidate).isSymbolicLink()) fs.unlinkSync(candidate);
  }
  fs.rmSync(parent, { recursive: true, force: true, maxRetries: 3 });
}

function runProvenanceAndContainerFixture() {
  const root = createFixture();
  try {
    const plugin = path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'fixture-retired-plugin');
    writeSkill(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
    const active = path.join(root, 'skills', 'fixture-retired-skill');
    writeSkill(active, 'fixture-retired-skill', 'https://example.test/retired-source');
    const audit = runMenu(root, [], 1);
    assert.equal(audit.findingCount, 2, '精确 plugin 容器和来源匹配 active skill 都必须被发现');
    const applied = runMenu(root, ['--apply']);
    assert.equal(applied.ok, true, 'Apply 后菜单表面必须归零');
    assert.equal(fs.existsSync(plugin), false, '退休插件容器未删除');
    assert.equal(fs.existsSync(active), false, '来源匹配的退休 active skill 未删除');
    assert.ok(applied.result.removedDirectories.length === 2, 'Apply 未报告两个精确目录删除');
  } finally {
    removeFixture(root);
  }
}

function runNameCollisionFixture() {
  const root = createFixture();
  try {
    const active = path.join(root, 'skills', 'same-name-active-source');
    writeSkill(active, 'fixture-retired-skill', 'https://example.test/active-source');
    const audit = runMenu(root);
    assert.equal(audit.ok, true, '来源不匹配的同名 active skill 不得成为删除候选');
    assert.equal(fs.existsSync(active), true, '同名 active skill 被误删');
  } finally {
    removeFixture(root);
  }
}

function runReparseFixture() {
  const root = createFixture();
  const outside = path.join(reportsRoot, `${menu.FIXTURE_PREFIX}${crypto.randomBytes(16).toString('hex')}-outside`);
  try {
    const pluginParent = path.join(root, 'plugins', 'cache', 'openai-curated-remote');
    const junction = path.join(pluginParent, 'fixture-retired-plugin');
    fs.mkdirSync(pluginParent, { recursive: true });
    fs.mkdirSync(outside, { recursive: true });
    const sentinel = path.join(outside, 'sentinel.txt');
    fs.writeFileSync(sentinel, 'must survive', 'utf8');
    fs.symlinkSync(outside, junction, process.platform === 'win32' ? 'junction' : 'dir');
    const audit = runMenu(root);
    assert.equal(audit.ok, true, 'junction 不能被枚举为可删除退休插件');
    runMenu(root, ['--apply']);
    assert.equal(fs.lstatSync(junction).isSymbolicLink(), true, 'Apply 不得删除 junction');
    assert.equal(fs.readFileSync(sentinel, 'utf8'), 'must survive', 'junction 外 sentinel 被误伤');
  } finally {
    try {
      const junction = path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'fixture-retired-plugin');
      if (fs.existsSync(junction) && fs.lstatSync(junction).isSymbolicLink()) fs.unlinkSync(junction);
    } catch {}
    removeFixture(root);
    fs.rmSync(outside, { recursive: true, force: true, maxRetries: 3 });
  }
}

function runRootSwapFixture() {
  const root = createFixture();
  try {
    const plugin = path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'fixture-retired-plugin');
    writeSkill(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
    const result = runMenu(
      root,
      ['--apply'],
      1,
      { [menu.FIXTURE_SWAP_TARGET_ENV]: 'fixture-retired-plugin' },
    );
    assert.equal(result.ok, false, 'preflight 后目录替换必须失败关闭');
    assert.equal(result.error.code, 'target-changed-before-delete', '目录替换必须归类为删除前漂移');
    const parked = plugin + '.fixture-predelete-parked';
    assert.equal(fs.existsSync(parked), true, '原已审计插件树必须保留');
    assert.equal(fs.existsSync(path.join(parked, '1.0.0', 'skills', 'fixture-retired-skill', 'SKILL.md')), true, '原已审计 payload 不得被删除');
    assert.equal(fs.existsSync(plugin), true, '新建替换目录必须保留');
    assert.equal(
      fs.readFileSync(path.join(plugin, '.fixture-predelete-sentinel'), 'utf8'),
      'must survive handle-bound root identity refusal\n',
      '替换目录 sentinel 不得被删除',
    );
  } finally {
    removeFixture(root);
  }
}

function writeNestedMutationPlugin(root) {
  const plugin = path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'fixture-retired-plugin');
  writeSkill(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
  writeText(path.join(plugin, '!nested', 'original.txt'), 'must survive nested manifest refusal\n');
  return plugin;
}

function runNestedChildReplaceFixture() {
  const root = createFixture();
  try {
    const plugin = writeNestedMutationPlugin(root);
    const result = runMenu(
      root,
      ['--apply'],
      1,
      { [menu.FIXTURE_NESTED_CHILD_REPLACE_TARGET_ENV]: 'fixture-retired-plugin' },
    );
    assert.equal(result.ok, false, 'manifest 快照后的 nested 目录替换必须失败关闭');
    assert.equal(result.error.code, 'target-changed-before-delete', 'nested 目录替换必须归类为删除前漂移');
    const parked = plugin + '.fixture-nested-predelete-parked';
    assert.equal(
      fs.readFileSync(path.join(parked, 'original.txt'), 'utf8'),
      'must survive nested manifest refusal\n',
      '原 nested payload 不得被删除',
    );
    assert.equal(
      fs.readFileSync(path.join(plugin, '!nested', '.fixture-nested-replacement-sentinel'), 'utf8'),
      'must survive nested identity refusal\n',
      'nested 替换 sentinel 不得被删除',
    );
    assert.equal(fs.existsSync(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill', 'SKILL.md')), true, '同级退休 payload 不得被误删');
  } finally {
    removeFixture(root);
  }
}

function runNestedChildAdditionFixture() {
  const root = createFixture();
  try {
    const plugin = writeNestedMutationPlugin(root);
    const result = runMenu(
      root,
      ['--apply'],
      1,
      { [menu.FIXTURE_NESTED_CHILD_ADD_TARGET_ENV]: 'fixture-retired-plugin' },
    );
    assert.equal(result.ok, false, 'manifest 快照后的 nested 新增必须失败关闭');
    assert.equal(result.error.code, 'target-changed-before-delete', 'nested 新增必须归类为删除前漂移');
    assert.equal(
      fs.readFileSync(path.join(plugin, '!nested', 'original.txt'), 'utf8'),
      'must survive nested manifest refusal\n',
      'nested 新增拒绝时原 payload 不得被删除',
    );
    assert.equal(
      fs.readFileSync(path.join(plugin, '!nested', '.fixture-nested-added-sentinel'), 'utf8'),
      'must survive manifest membership refusal\n',
      'nested 新增 sentinel 不得被删除',
    );
    assert.equal(fs.existsSync(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill', 'SKILL.md')), true, 'nested 新增不得误删同级退休 payload');
  } finally {
    removeFixture(root);
  }
}

function runLargeDirectoryManifestFixture() {
  const root = createFixture();
  try {
    const plugin = path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'fixture-retired-plugin');
    writeSkill(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
    for (let index = 0; index < LARGE_MANIFEST_ENTRY_COUNT; index += 1) {
      writeText(path.join(plugin, ...largeManifestRelativePath(index).split('/')), LARGE_MANIFEST_FILE_CONTENT);
    }
    const safeSibling = path.join(path.dirname(plugin), 'unrelated-plugin-sentinel.txt');
    fs.writeFileSync(safeSibling, 'must survive large directory manifest apply\n', 'utf8');
    assert.ok(
      largeManifestSerializedLowerBoundBytes() > 32 * 1024,
      'fixture serialized manifest 必须超过 Windows 命令行安全长度',
    );
    const applied = runMenu(root, ['--apply']);
    assert.equal(applied.ok, true, '大型目录 manifest Apply 不得回退到命令行传输');
    assert.equal(fs.existsSync(plugin), false, '大型 manifest 精确退休插件目录必须删除');
    assert.equal(
      fs.readFileSync(safeSibling, 'utf8'),
      'must survive large directory manifest apply\n',
      '大型 manifest Apply 不得删除同级安全项',
    );
  } finally {
    removeFixture(root);
  }
}

function writeCatalog(root, content) {
  const file = path.join(root, 'cache', 'remote_plugin_catalog', 'catalog.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(content, null, 2) + '\n', 'utf8');
  return file;
}

function runCatalogFixture() {
  const root = createFixture();
  try {
    const file = writeCatalog(root, { plugins: [{ name: 'fixture-retired-plugin' }, { name: 'active-plugin' }] });
    const ignoredByDefault = runMenu(root);
    assert.equal(ignoredByDefault.ok, true, '远程 AVAILABLE catalog 不应伪装成已安装 payload');
    const catalogAudit = runMenu(root, ['--include-remote-catalog'], 1);
    assert.equal(catalogAudit.findingCount, 1, '显式 catalog hygiene 必须发现退休插件条目');
    const applied = runMenu(root, ['--include-remote-catalog', '--apply']);
    assert.equal(applied.ok, true, 'catalog Apply 后必须归零');
    assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).plugins.map((entry) => entry.name), ['active-plugin']);
  } finally {
    removeFixture(root);
  }
}

function runLargeCatalogFixture() {
  const root = createFixture();
  try {
    const description = 'x'.repeat(64 * 1024);
    const active = { name: 'active-plugin-large-payload', description };
    const file = writeCatalog(root, {
      plugins: [{ name: 'fixture-retired-plugin' }, active],
    });
    assert.ok(fs.statSync(file).size > 32 * 1024, 'fixture 必须超过 Windows 命令行安全长度');
    const applied = runMenu(root, ['--include-remote-catalog', '--apply']);
    assert.equal(applied.ok, true, '大型 catalog Apply 不得受命令行长度限制');
    const after = JSON.parse(fs.readFileSync(file, 'utf8')).plugins;
    assert.deepEqual(after, [active], '大型 catalog 必须原样保留非退休条目');
  } finally {
    removeFixture(root);
  }
}

function runCatalogHardlinkFixture() {
  const root = createFixture();
  const outside = path.join(reportsRoot, `${menu.FIXTURE_PREFIX}${crypto.randomBytes(16).toString('hex')}-catalog-outside`);
  try {
    const file = writeCatalog(root, { plugins: [{ name: 'fixture-retired-plugin' }] });
    fs.mkdirSync(outside, { recursive: true });
    const sentinel = path.join(outside, 'sentinel.json');
    fs.copyFileSync(file, sentinel);
    fs.unlinkSync(file);
    fs.linkSync(sentinel, file);
    const result = runMenu(root, ['--include-remote-catalog', '--apply'], 1);
    assert.equal(result.ok, false, 'hard link catalog 必须失败关闭');
    assert.ok(result.blocked.some((entry) => /hard link/i.test(entry.detail)), 'hard link 拒绝必须可诊断');
    assert.equal(fs.readFileSync(sentinel, 'utf8').includes('fixture-retired-plugin'), true, '外部 hard-link sentinel 被误改');
  } finally {
    removeFixture(root);
    fs.rmSync(outside, { recursive: true, force: true, maxRetries: 3 });
  }
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

assert.equal(fs.existsSync(path.join(codexRoot, '.tmp', 'plugins', 'plugins', 'superpowers')), false, 'Superpowers marketplace payload 仍存在');
const menuAudit = runJsonScript(menuScript);
assert.equal(menuAudit.ok, true, '仍有已安装退休菜单或插件 payload');
const backupAudit = runJsonScript(backupScript);
assert.equal(backupAudit.candidateCount, 0, '仍有退役 skill 或插件备份');
assert.equal(backupAudit.staleBackupCleanupManifestCount, 0, '退役 ledger 仍保留失效 cleanup manifest');

runProvenanceAndContainerFixture();
runNameCollisionFixture();
runReparseFixture();
runRootSwapFixture();
runNestedChildReplaceFixture();
runNestedChildAdditionFixture();
runLargeDirectoryManifestFixture();
runCatalogFixture();
runLargeCatalogFixture();
runCatalogHardlinkFixture();

console.log(`Superpowers full retirement: PASS (${retiredNames.length} skills; provenance, reparse, manifest, catalog and hard-link guards)`);
