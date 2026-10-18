'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const projectRoot = path.resolve(__dirname, '..');
const reportsRoot = path.join(projectRoot, 'reports');
const menuScript = path.join(projectRoot, 'scripts', 'retired-skill-menu-surface.cjs');
const menu = require(menuScript);

const LARGE_MANIFEST_ENTRY_COUNT = 384;
const LARGE_MANIFEST_FILE_CONTENT = 'fixture large manifest payload\n';
const LARGE_MANIFEST_FILE_SUFFIX = '-abcdefghijklmnopqrstuvwxyz0123456789.bin';
const RETIRED_SOURCE_REPO = 'https://example.test/retired-source';

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

// The fixture mirrors the live layout: <parent>\.codex is the Codex root,
// <parent>\skills-manager\skills is the physical active root, and
// <parent>\.codex\skills is a junction alias of it.
function activeRootOf(root) {
  return path.join(path.dirname(root), 'skills-manager', 'skills');
}

function aliasOf(root) {
  return path.join(root, 'skills');
}

function createFixture() {
  const parent = path.join(reportsRoot, `${menu.FIXTURE_PREFIX}${crypto.randomBytes(16).toString('hex')}`);
  const root = path.join(parent, '.codex');
  const activeRoot = activeRootOf(root);
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, menu.FIXTURE_MARKER), menu.FIXTURE_MARKER_VALUE, 'utf8');
  fs.mkdirSync(activeRoot, { recursive: true });
  fs.writeFileSync(path.join(activeRoot, '.downloaded-skills-source-state.json'), JSON.stringify({
    sources: [{
      id: 'fixture-retired-plugin',
      repo: 'https://example.test/retired-source.git',
      status: 'deleted-by-user',
      deleted_skills: [{ name: 'fixture-retired-skill', status: 'deleted-by-user' }],
    }],
    deleted: [{ name: 'fixture-retired-skill', source: 'fixture-retired-plugin', status: 'deleted-by-user' }],
  }, null, 2), 'utf8');
  fs.symlinkSync(activeRoot, aliasOf(root), 'junction');
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

// Junctions are unlinked first so the recursive teardown never follows one.
function unlinkJunctions(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const candidate = path.join(directory, entry.name);
    const stats = fs.lstatSync(candidate);
    if (stats.isSymbolicLink()) fs.unlinkSync(candidate);
    else if (stats.isDirectory()) unlinkJunctions(candidate);
  }
}

function removeFixture(root) {
  const parent = path.dirname(root);
  assert.ok(menu.isInside(parent, reportsRoot), 'fixture 清理不得越出 reports');
  assert.ok(path.basename(parent).startsWith(menu.FIXTURE_PREFIX), 'fixture 清理前缀不匹配');
  unlinkJunctions(parent);
  fs.rmSync(parent, { recursive: true, force: true, maxRetries: 3 });
}

function runProvenanceAndContainerFixture() {
  const root = createFixture();
  try {
    const plugin = path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'fixture-retired-plugin');
    writeSkill(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
    const active = path.join(activeRootOf(root), 'fixture-retired-skill');
    writeSkill(active, 'fixture-retired-skill', RETIRED_SOURCE_REPO);
    const audit = runMenu(root, [], 1);
    assert.equal(audit.findingCount, 2, '精确 plugin 容器和来源匹配 active skill 都必须被发现');
    assert.ok(
      audit.findings.some((finding) => finding.type === 'retired-active-skill' && finding.target === active),
      'active skill 必须在实体根下审计，而不是经 Codex junction',
    );
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
    const active = path.join(activeRootOf(root), 'same-name-active-source');
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

function runInstalledPluginCacheFixture() {
  const root = createFixture();
  try {
    // Every marketplace container under each plugins\cache holds installed
    // payload, including a marketplace the audit has never seen.
    const plugins = [
      path.join(root, 'plugins', 'cache', 'openai-curated', 'fixture-retired-plugin'),
      path.join(root, 'plugins', 'cache', 'future-marketplace', 'fixture-retired-plugin'),
      path.join(root, 'account_backup', 'windows', 'refresh_runtime', 'plugins', 'cache', 'openai-bundled', 'fixture-retired-plugin'),
    ];
    for (const plugin of plugins) writeSkill(path.join(plugin, '1.0.0', 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
    const audit = runMenu(root, [], 1);
    assert.equal(audit.installedFindingCount, plugins.length, '每个 marketplace 容器里的退休插件都必须被发现');
    assert.deepEqual(
      audit.findings.map((finding) => [finding.type, finding.target]).sort(),
      plugins.map((plugin) => ['retired-plugin-directory', plugin]).sort(),
    );
    const applied = runMenu(root, ['--apply']);
    assert.equal(applied.ok, true, 'Apply 后已安装面必须归零');
    for (const plugin of plugins) assert.equal(fs.existsSync(plugin), false, `退休插件容器未删除：${plugin}`);
  } finally {
    removeFixture(root);
  }
}

function runPluginCacheContainerReparseFixture() {
  const root = createFixture();
  const outside = path.join(reportsRoot, `${menu.FIXTURE_PREFIX}${crypto.randomBytes(16).toString('hex')}-cache-outside`);
  try {
    const container = path.join(root, 'plugins', 'cache', 'linked-marketplace');
    const outsidePlugin = path.join(outside, 'fixture-retired-plugin');
    writeSkill(path.join(outsidePlugin, '1.0.0', 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
    fs.mkdirSync(path.dirname(container), { recursive: true });
    fs.symlinkSync(outside, container, 'junction');
    const result = runMenu(root, ['--apply'], 1);
    assert.equal(result.error.code, 'blocked-menu-surface', 'junction marketplace 容器必须失败关闭');
    assert.ok(
      result.blocked.some((entry) => entry.type === 'plugin-parent-blocked' && entry.target === container),
      'junction marketplace 容器必须可诊断',
    );
    assert.equal(fs.existsSync(path.join(outsidePlugin, '1.0.0', 'skills', 'fixture-retired-skill', 'SKILL.md')), true, 'junction 外的插件被误删');
  } finally {
    removeFixture(root);
    fs.rmSync(outside, { recursive: true, force: true, maxRetries: 3 });
  }
}

function runLocalMarketplaceFixture() {
  const root = createFixture();
  try {
    // The Codex app re-syncs this copy, where plugins are only listed as available.
    const plugin = path.join(root, '.tmp', 'plugins', 'plugins', 'fixture-retired-plugin');
    writeSkill(path.join(plugin, 'skills', 'fixture-retired-skill'), 'fixture-retired-skill');
    const catalog = path.join(root, '.tmp', 'plugins', '.agents', 'plugins', 'marketplace.json');
    writeText(catalog, JSON.stringify({ plugins: [{ name: 'fixture-retired-plugin' }, { name: 'active-plugin' }] }, null, 2) + '\n');
    const byDefault = runMenu(root, ['--apply']);
    assert.equal(byDefault.findingCount, 0, '本地 marketplace 副本不得算作已安装 payload');
    assert.equal(fs.existsSync(plugin), true, '默认 Apply 不得删除本地 marketplace 副本');
    assert.match(fs.readFileSync(catalog, 'utf8'), /fixture-retired-plugin/, '默认 Apply 不得改写本地 catalog');
    const audit = runMenu(root, ['--include-local-marketplace'], 1);
    assert.equal(audit.includeLocalMarketplace, true);
    assert.equal(audit.installedFindingCount, 0);
    assert.equal(audit.localMarketplaceFindingCount, 2, '显式 hygiene 必须发现副本目录和本地 catalog 条目');
    assert.deepEqual(audit.findings.map((finding) => finding.type).sort(), ['retired-local-catalog-entry', 'retired-local-marketplace-directory']);
    const applied = runMenu(root, ['--include-local-marketplace', '--apply']);
    assert.equal(applied.ok, true, '本地 marketplace Apply 后必须归零');
    assert.equal(fs.existsSync(plugin), false, '本地 marketplace 副本里的退休插件目录未删除');
    assert.deepEqual(JSON.parse(fs.readFileSync(catalog, 'utf8')).plugins.map((entry) => entry.name), ['active-plugin']);
  } finally {
    removeFixture(root);
  }
}

function runAliasTargetsOtherDirectoryFixture() {
  const root = createFixture();
  try {
    // Codex reads a different directory now, so the physical root no longer
    // stands for its menu.
    const other = path.join(path.dirname(root), 'other-skills');
    fs.mkdirSync(other);
    fs.copyFileSync(
      path.join(activeRootOf(root), '.downloaded-skills-source-state.json'),
      path.join(other, '.downloaded-skills-source-state.json'),
    );
    const stray = path.join(other, 'fixture-retired-skill');
    writeSkill(stray, 'fixture-retired-skill', RETIRED_SOURCE_REPO);
    const active = path.join(activeRootOf(root), 'fixture-retired-skill');
    writeSkill(active, 'fixture-retired-skill', RETIRED_SOURCE_REPO);
    fs.unlinkSync(aliasOf(root));
    fs.symlinkSync(other, aliasOf(root), 'junction');
    const result = runMenu(root, ['--apply'], 1);
    assert.equal(result.error.code, 'skills-alias-mismatch', '指向别处的 Codex skills junction 必须失败关闭');
    assert.equal(fs.existsSync(path.join(active, 'SKILL.md')), true, '别名不匹配时不得删除实体根里的 skill');
    assert.equal(fs.existsSync(path.join(stray, 'SKILL.md')), true, '别名不匹配时不得删除别名目标里的 skill');
  } finally {
    removeFixture(root);
  }
}

function runAliasIsPhysicalDirectoryFixture() {
  const root = createFixture();
  try {
    // The pre-unification layout: Codex reads its own physical skills directory.
    fs.unlinkSync(aliasOf(root));
    const legacy = path.join(aliasOf(root), 'fixture-retired-skill');
    writeSkill(legacy, 'fixture-retired-skill', RETIRED_SOURCE_REPO);
    const active = path.join(activeRootOf(root), 'fixture-retired-skill');
    writeSkill(active, 'fixture-retired-skill', RETIRED_SOURCE_REPO);
    const result = runMenu(root, ['--apply'], 1);
    assert.equal(result.error.code, 'skills-alias-mismatch', '变回实体目录的 Codex skills 必须失败关闭');
    assert.equal(fs.existsSync(path.join(legacy, 'SKILL.md')), true, '别名不匹配时不得删除 Codex 目录里的 skill');
    assert.equal(fs.existsSync(path.join(active, 'SKILL.md')), true, '别名不匹配时不得删除实体根里的 skill');
  } finally {
    removeFixture(root);
  }
}

function runActiveRootReparseFixture() {
  // leaf: the physical root itself is a junction; ancestor: a directory above
  // it is, while the root resolves to a real directory.
  for (const variant of ['leaf', 'ancestor']) {
    const root = createFixture();
    try {
      const activeRoot = activeRootOf(root);
      const linkPath = variant === 'leaf' ? activeRoot : path.dirname(activeRoot);
      const realPath = path.join(path.dirname(root), `${variant}-real`);
      fs.renameSync(linkPath, realPath);
      fs.symlinkSync(realPath, linkPath, 'junction');
      const survivor = path.join(activeRoot, 'fixture-retired-skill');
      writeSkill(survivor, 'fixture-retired-skill', RETIRED_SOURCE_REPO);
      const result = runMenu(root, ['--apply'], 1);
      assert.equal(result.error.code, 'reparse-point', `实体根的 ${variant} 是 junction 时必须失败关闭`);
      assert.equal(fs.existsSync(path.join(survivor, 'SKILL.md')), true, `实体根的 ${variant} 是 junction 时不得删除 skill`);
    } finally {
      removeFixture(root);
    }
  }
}

function runLedgerHardLinkFixture() {
  const root = createFixture();
  try {
    const ledger = path.join(activeRootOf(root), '.downloaded-skills-source-state.json');
    const outside = path.join(path.dirname(root), 'ledger-outside.json');
    fs.copyFileSync(ledger, outside);
    fs.unlinkSync(ledger);
    fs.linkSync(outside, ledger);
    const result = runMenu(root, [], 1);
    assert.equal(result.error.code, 'hard-link', 'hard link 账本必须失败关闭');
  } finally {
    removeFixture(root);
  }
}

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
runInstalledPluginCacheFixture();
runPluginCacheContainerReparseFixture();
runLocalMarketplaceFixture();
runAliasTargetsOtherDirectoryFixture();
runAliasIsPhysicalDirectoryFixture();
runActiveRootReparseFixture();
runLedgerHardLinkFixture();

console.log('Retired skill menu surface: PASS (unified root alias, provenance, reparse, manifest, catalog, plugin cache, local marketplace and hard-link guards)');
