'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const projectRoot = path.resolve(__dirname, '..');
const scriptPath = 'D:/Codex/.codex/scripts/purge-explicit-retired-artifacts.cjs';
const purge = require(scriptPath);

const targetById = new Map(purge.TARGET_DEFINITIONS.map((entry) => [entry.id, entry]));
const GSD_ID = 'historical-gsd-replicator-archive';
const RESIDUE_ID = 'backup-retention-test-residue';
const SOURCE_ID = 'open-design-historical-source-staging';
const SIDEBAR_RECOVERY_ID = 'retired-sidebar-recovery-bundle';
const CCSWITCH_BACKUP_ID = 'ccswitch-wss-retired-backup';
const AMBIENT_CACHE_ID = 'retired-project-ambient-suggestion-cache';
const AUDIT_CLONE_ID = 'open-design-retired-source-clone-audit-20260705';
const WORKTREE_ID = 'open-design-retired-source-worktree-20260713';
const BASE_CLONE_ID = 'open-design-retired-source-base-20260713';
const HEYGEN_PLUGIN_CACHE_ID = 'retired-heygen-plugin-cache';
const HYPERFRAMES_PLUGIN_CACHE_ID = 'retired-hyperframes-plugin-cache';
const DISABLED_REMOTE_GSD_BACKUP_ID = 'retired-disabled-remote-gsd-active-surface-backup';
const EMPTY_GSD_FIXTURE_IDS = [
  'retired-phase8-missing-baseline-empty-gsd-fixture',
  'retired-phase8-new-managed-create-empty-gsd-fixture',
  'retired-phase8-race-after-backup-empty-gsd-fixture',
  'retired-phase8-safe-overwrite-empty-gsd-fixture',
  'retired-phase8-target-local-deletion-parent-empty-gsd-fixture',
  'retired-phase8-target-local-deletion-empty-gsd-fixture',
];
const ALL_IDS = [
  GSD_ID,
  RESIDUE_ID,
  SOURCE_ID,
  AUDIT_CLONE_ID,
  WORKTREE_ID,
  BASE_CLONE_ID,
  SIDEBAR_RECOVERY_ID,
  CCSWITCH_BACKUP_ID,
  AMBIENT_CACHE_ID,
  HEYGEN_PLUGIN_CACHE_ID,
  HYPERFRAMES_PLUGIN_CACHE_ID,
  DISABLED_REMOTE_GSD_BACKUP_ID,
  ...EMPTY_GSD_FIXTURE_IDS,
];
const EXACT_NEW_TARGET_PARTS = new Map([
  [
    HEYGEN_PLUGIN_CACHE_ID,
    ['.codex', 'plugins', 'cache', 'openai-curated-remote', 'heygen'],
  ],
  [
    HYPERFRAMES_PLUGIN_CACHE_ID,
    ['.codex', 'plugins', 'cache', 'openai-curated-remote', 'hyperframes'],
  ],
  [
    DISABLED_REMOTE_GSD_BACKUP_ID,
    [
      '.codex',
      'run-evidence',
      'replicator',
      'runtime-constraints-sync-20260707T231344',
      'backup',
      'disabled-remote-gsd-active-surface',
    ],
  ],
  ...[
    ['retired-phase8-missing-baseline-empty-gsd-fixture', 'phase8-missing-baseline'],
    ['retired-phase8-new-managed-create-empty-gsd-fixture', 'phase8-new-managed-create'],
    ['retired-phase8-race-after-backup-empty-gsd-fixture', 'phase8-race-after-backup'],
    ['retired-phase8-safe-overwrite-empty-gsd-fixture', 'phase8-safe-overwrite'],
    ['retired-phase8-target-local-deletion-parent-empty-gsd-fixture', 'phase8-target-local-deletion-parent'],
    ['retired-phase8-target-local-deletion-empty-gsd-fixture', 'phase8-target-local-deletion'],
  ].map(([id, phase]) => [
    id,
    ['.codex', 'run-evidence', 'replicator', phase, 'fixture-target', 'gsd'],
  ]),
]);
const createdLinks = new Set();
const cleanupRoots = new Set();
const LARGE_MANIFEST_ENTRY_COUNT = 384;
const LARGE_MANIFEST_FILE_CONTENT = 'fixture large manifest payload\n';
const LARGE_MANIFEST_FILE_SUFFIX = '-abcdefghijklmnopqrstuvwxyz0123456789.bin';

const GSD_ARCHIVE_README = [
  '# Replicator 历史运行证据',
  '',
  '本目录保存 `codex-gsd-codex-c-skill` 项目在历史 GSD 流程中产生的 replicator 运行证据、测试夹具、调试输出和阶段验证产物。',
  '',
  '这些文件于 2026-06-26 从旧位置迁入：',
  '',
  '`D:\\Codex\\.gsd\\tmp\\replicator`',
  '',
  '迁入原因：',
  '',
  '- `D:\\Codex\\.gsd\\` 只服务 GSD 本体、GSD 项目、GSD 状态和 GSD 知识。',
  '- 本项目已迁为普通 Codex 项目，历史 GSD 材料统一归档在 `docs\\gsd-archive\\`。',
  '- 这些 replicator 证据属于本项目历史流程，不应继续留在全局 `.gsd\\tmp` 中。',
  '',
  '查阅原则：',
  '',
  '- 本目录是历史证据归档，不代表当前活跃 GSD 状态。',
  '- 当前项目工作流以根目录 `AGENTS.md` 中的 normal repository workflow 为准。',
  '- 新的非 GSD 远端运行原始证据应写入 `D:\\Codex\\.codex\\run-evidence\\replicator\\<run-id>\\`。',
  '- 原夹具中的 `gsd-link` junction 已转换为 `gsd-link.junction.json`，避免在归档目录里保留断开的 reparse point。',
  '',
].join('\r\n');

function targetFor(root, id) {
  const definition = targetById.get(id);
  assert.ok(definition, '未知固定目标：' + id);
  return path.join(root, ...definition.relativeParts);
}

function fixtureRoot(label) {
  const root = fs.mkdtempSync(path.join(projectRoot, purge.FIXTURE_PREFIX + label + '-'));
  cleanupRoots.add(root);
  fs.writeFileSync(path.join(root, purge.FIXTURE_MARKER), purge.FIXTURE_MARKER_CONTENT, 'utf8');
  return root;
}

function writeText(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, 'utf8');
}

function makeJunction(target, link) {
  fs.mkdirSync(path.dirname(link), { recursive: true });
  fs.symlinkSync(target, link, process.platform === 'win32' ? 'junction' : 'dir');
  createdLinks.add(link);
}

function writeGsdArchive(target) {
  fs.mkdirSync(target, { recursive: true });
  fs.writeFileSync(path.join(target, 'README.md'), GSD_ARCHIVE_README, 'utf8');
}

function writeBackupRetentionResidue(target) {
  const directories = [
    '.codex/backups_state/.codex-global-state.json-20260701T010102Z',
    '.codex/backups_state/provider-sync/20260701T000002Z',
    '.codex/backups_state/provider-sync/20260701T000003Z',
    '.codex/backups_state/provider-sync/20260701T000004Z',
    '.codex/backups_state/provider-sync/20260701T000005Z',
    '.codex/backups_state/provider-sync/20260701T000006Z',
    '.codex/backups_state/provider-sync/20260701T000007Z',
    '.codex/backups_state/provider-sync/unknown-directory',
    'ads-scope/.codex/backups_state/provider-sync/20260701T000001Z',
    'ads-scope/.codex/backups_state/provider-sync/20260701T000002Z',
    'ads-scope/.codex/backups_state/provider-sync/20260701T000003Z',
    'ads-scope/.codex/backups_state/provider-sync/20260701T000004Z',
    'ads-scope/.codex/backups_state/provider-sync/20260701T000005Z',
    'ads-scope/.codex/backups_state/provider-sync/20260701T000006Z',
    'apps/codex_switch',
    'late-scope/.codex/backups_state/provider-sync/20260701T000001Z',
    'late-scope/.codex/backups_state/provider-sync/20260701T000002Z',
    'late-scope/.codex/backups_state/provider-sync/20260701T000003Z',
    'late-scope/.codex/backups_state/provider-sync/20260701T000004Z',
    'late-scope/.codex/backups_state/provider-sync/20260701T000005Z',
    'late-scope/.codex/backups_state/provider-sync/20260701T000006Z',
    'reparse-parent',
    'reparse-target',
    '.codex/skills',
    'skills-junction-target',
    'tree-digest-fixture/empty-a',
    'tree-digest-fixture/empty-b',
    'tree-digest-junction-target',
  ];
  fs.mkdirSync(target, { recursive: true });
  for (const relative of directories) fs.mkdirSync(path.join(target, ...relative.split('/')), { recursive: true });

  const files = new Map([
    ['.codex/backups_state/config.toml_20260701T010106Z', 'invalid sidecar\r\n'],
    ['.codex/backups_state/config.toml-20260701T010101Z', 'valid sidecar\r\n'],
    ['.codex/backups_state/config.toml-20260701T010104Z-junk', 'invalid sidecar\r\n'],
    ['.codex/backups_state/config.tomlx-20260701T010103Z', 'invalid sidecar\r\n'],
    ['.codex/backups_state/junk-config.toml-20260701T010105Z', 'invalid sidecar\r\n'],
    ['.codex/backups_state/provider-sync/hidden-unknown.bin', 'hidden unknown\r\n'],
    ['.codex/backups_state/provider-sync/unknown-file.bin', 'unknown\r\n'],
    ['ads-scope/.codex/backups_state/provider-sync/20260701T000001Z/state.bin', 'AAAA'],
    ['apps/codex_switch/backups', 'not a directory\r\n'],
    ['tree-digest-fixture/a.bin', 'AAAA'],
    ['tree-digest-fixture/b.bin', 'BBBB'],
  ]);
  for (const [relative, content] of files) writeText(path.join(target, ...relative.split('/')), content);

}

function writeOpenDesignSnapshot(target) {
  const origin = purge.OPEN_DESIGN_IDENTITY.origin;
  const head = purge.OPEN_DESIGN_IDENTITY.head;
  writeText(path.join(target, '.git', 'config'), `[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = ${origin}\n`);
  writeText(path.join(target, '.git', 'HEAD'), 'ref: refs/heads/main\n');
  writeText(path.join(target, '.git', 'refs', 'heads', 'main'), head + '\n');
  for (const name of ['frontend-design', 'video-hyperframes', 'remotion']) {
    writeText(path.join(target, 'skills', name, 'SKILL.md'), `---\nname: ${name}\n---\nfixture\n`);
  }
}

function writeRetiredOpenDesignClone(target, identity) {
  writeText(
    path.join(target, '.git', 'config'),
    `[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = ${identity.origin}\n`,
  );
  writeText(path.join(target, '.git', 'HEAD'), 'ref: refs/heads/main\n');
  writeText(path.join(target, '.git', 'refs', 'heads', 'main'), identity.head + '\n');
  for (const marker of identity.markers) {
    writeText(
      path.join(target, ...marker.relativePath.split('/')),
      `---\nname: ${marker.name}\n---\nfixture\n`,
    );
  }
}

function writeRetiredOpenDesignWorktree(target, identity, metadataTarget) {
  for (const marker of identity.markers) {
    writeText(
      path.join(target, ...marker.relativePath.split('/')),
      `---\nname: ${marker.name}\n---\nfixture\n`,
    );
  }
  const targetGitFile = path.join(target, '.git');
  writeText(targetGitFile, 'gitdir: ../../open-design/.git/worktrees/open-design\n');
  writeText(path.join(metadataTarget, 'commondir'), '../..\n');
  writeText(path.join(metadataTarget, 'gitdir'), '../../../../bases/open-design/.git\n');
  writeText(path.join(metadataTarget, 'HEAD'), identity.head + '\n');
  writeText(path.join(metadataTarget, 'ORIG_HEAD'), identity.head + '\n');
  writeText(path.join(metadataTarget, 'index'), 'fixture worktree index\n');
  writeText(path.join(metadataTarget, 'logs', 'HEAD'), 'fixture worktree reflog\n');
  fs.mkdirSync(path.join(metadataTarget, 'refs'), { recursive: true });
}

function worktreeMetadataTarget(root) {
  return path.join(targetFor(root, BASE_CLONE_ID), '.git', 'worktrees', 'open-design');
}

function writeSidebarRecoveryBundle(target) {
  writeText(path.join(target, 'global-state.json'), '{"kind":"retired-sidebar-recovery"}\n');
  writeText(path.join(target, 'state_5.sqlite'), 'fixture sqlite state\n');
}

function writeCcSwitchBackup(target) {
  writeText(path.join(target, 'cc-switch.db'), 'fixture cc-switch backup\n');
  writeText(path.join(target, 'cc-switch.db-wal'), 'fixture cc-switch wal\n');
}

function writeRetiredAmbientSuggestionCache(target) {
  writeText(
    path.join(target, 'ambient-suggestions.json'),
    JSON.stringify({ projectRoot: 'D:\\Codex\\projects\\codex-gsd-codex-c-skill' }) + '\n',
  );
}

function largeManifestRelativePath(index) {
  return '!bulk/manifest-entry-' + String(index).padStart(4, '0') + LARGE_MANIFEST_FILE_SUFFIX;
}

function writeRetiredPluginCache(target, options = {}) {
  const manifest = '{"fixture":"retired-plugin-cache"}\n';
  writeText(path.join(target, '.codex-remote-plugin-install.json'), manifest);
  writeText(path.join(target, '3.0.0', '.codex-plugin', 'plugin.json'), manifest);
  writeText(
    path.join(target, '3.0.0', 'skills', 'retired-plugin', 'SKILL.md'),
    '---\nname: retired-plugin\n---\nfixture\n',
  );
  if (options.largeManifest === true) {
    for (let index = 0; index < LARGE_MANIFEST_ENTRY_COUNT; index += 1) {
      writeText(path.join(target, ...largeManifestRelativePath(index).split('/')), LARGE_MANIFEST_FILE_CONTENT);
    }
  }
}

function writeDisabledRemoteGsdActiveSurface(target) {
  writeText(path.join(target, 'hooks', 'gsd-check-update.cmd'), '@echo fixture\r\n');
  writeText(path.join(target, 'hooks', 'gsd-check-update.js'), 'console.log("fixture");\n');
  fs.mkdirSync(path.join(target, 'skills'), { recursive: true });
}

function writeEmptyGsdFixture(target) {
  fs.mkdirSync(target, { recursive: true });
}

function makeCompleteFixture(label, options = {}) {
  const root = fixtureRoot(label);
  writeGsdArchive(targetFor(root, GSD_ID));
  writeBackupRetentionResidue(targetFor(root, RESIDUE_ID));
  writeOpenDesignSnapshot(targetFor(root, SOURCE_ID));
  writeRetiredOpenDesignClone(
    targetFor(root, AUDIT_CLONE_ID),
    purge.FIXTURE_OPEN_DESIGN_AUDIT_CLONE_IDENTITY,
  );
  writeRetiredOpenDesignClone(
    targetFor(root, BASE_CLONE_ID),
    purge.FIXTURE_OPEN_DESIGN_20260713_BASE_IDENTITY,
  );
  writeRetiredOpenDesignWorktree(
    targetFor(root, WORKTREE_ID),
    purge.FIXTURE_OPEN_DESIGN_20260713_WORKTREE_IDENTITY,
    worktreeMetadataTarget(root),
  );
  writeSidebarRecoveryBundle(targetFor(root, SIDEBAR_RECOVERY_ID));
  writeCcSwitchBackup(targetFor(root, CCSWITCH_BACKUP_ID));
  writeRetiredAmbientSuggestionCache(targetFor(root, AMBIENT_CACHE_ID));
  writeRetiredPluginCache(targetFor(root, HEYGEN_PLUGIN_CACHE_ID), {
    largeManifest: options.largeManifest === true,
  });
  writeRetiredPluginCache(targetFor(root, HYPERFRAMES_PLUGIN_CACHE_ID));
  writeDisabledRemoteGsdActiveSurface(targetFor(root, DISABLED_REMOTE_GSD_BACKUP_ID));
  for (const id of EMPTY_GSD_FIXTURE_IDS) writeEmptyGsdFixture(targetFor(root, id));
  writeText(
    path.join(root, 'active', 'skills', 'frontend-design', 'SOURCE.md'),
    'Source repository: https://github.com/nexu-io/open-design\nCommit: d954bee805b4f1bdf8767cc9aa3da95c1d097e36\n',
  );
  return root;
}

function runPurge(root, argumentsList = [], expectedStatus = 0, extraEnvironment = {}) {
  const result = spawnSync(process.execPath, [scriptPath, '--fixture-root', root, ...argumentsList], {
    encoding: 'utf8',
    env: { ...process.env, [purge.FIXTURE_ENV]: '1', ...extraEnvironment },
    windowsHide: true,
  });
  assert.equal(result.status, expectedStatus, 'purger 退出码异常：' + (result.stderr || result.stdout));
  assert.equal(result.stderr, '', 'purger 不应向 stderr 写非 JSON：' + result.stderr);
  assert.notEqual(result.stdout.trim(), '', 'purger 必须输出 JSON 摘要');
  return JSON.parse(result.stdout);
}

function largeManifestSerializedLowerBoundBytes() {
  // The policy emits each entry in this field order and uses fixed-width
  // VolumeSerialNumber/FileIndex strings.  These file entries are a strict
  // subset of the actual manifest, so this proves the stdin payload itself is
  // larger than a Windows command line without relying on a private diagnostic.
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

function assertNoPayloadBackup(summary) {
  assert.equal(summary.payloadBackupCreated, false);
  assert.equal(summary.backupPath, null);
  assert.equal(summary.evidenceContainsPayload, false);
  assert.ok(summary.evidencePath, '每次审计/拒绝都必须留下无 payload evidence');
  assert.ok(fs.existsSync(summary.evidencePath), 'evidence summary 不存在');
  const evidence = JSON.parse(fs.readFileSync(summary.evidencePath, 'utf8'));
  assert.equal(evidence.payloadBackupCreated, false);
  assert.equal(evidence.backupPath, null);
  assert.equal(evidence.evidenceContainsPayload, false);
  assert.deepEqual(fs.readdirSync(path.dirname(summary.evidencePath)).sort(), ['summary.json']);
}

function assertFixtureTargetsExist(root) {
  for (const id of ALL_IDS) {
    assert.equal(fs.existsSync(targetFor(root, id)), true, id + ' 不应被误删');
  }
}

function unlinkIfLink(candidate) {
  try {
    if (fs.lstatSync(candidate).isSymbolicLink()) fs.unlinkSync(candidate);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

function cleanup() {
  for (const link of [...createdLinks].reverse()) unlinkIfLink(link);
  for (const root of [...cleanupRoots].reverse()) fs.rmSync(root, { recursive: true, force: true, maxRetries: 3 });
}

try {
  for (const [id, expectedParts] of EXACT_NEW_TARGET_PARTS) {
    const definition = targetById.get(id);
    assert.ok(definition, '缺少新增固定目标：' + id);
    assert.deepEqual(
      [...definition.relativeParts],
      expectedParts,
      id + ' 不得扩大为共同插件父目录或 evidence 父目录',
    );
    assert.equal(definition.identityKind, 'exact-tree', id + ' 必须保持 exact-tree');
  }
  assert.equal(
    'interruptedExpectedTree' in targetById.get(AUDIT_CLONE_ID),
    false,
    '成功续删后不得保留 partial-tree 例外',
  );

  const normal = makeCompleteFixture('normal');
  const audit = runPurge(normal);
  assert.equal(audit.ok, true);
  assert.equal(audit.mode, 'audit');
  assert.equal(audit.dryRun, true);
  assert.equal(audit.fixtureMode, true);
  assert.equal(audit.approvedTargets.length, ALL_IDS.length);
  assert.ok(audit.approvedTargets.every((entry) => entry.state === 'ready'));
  assert.ok(audit.approvedTargets.every((entry) => entry.action === 'audit-would-delete'));
  assertNoPayloadBackup(audit);
  assertFixtureTargetsExist(normal);

  const rootSwap = makeCompleteFixture('root-swap');
  const rootSwapTarget = targetFor(rootSwap, GSD_ID);
  const rootSwapResult = runPurge(
    rootSwap,
    ['--apply'],
    1,
    { [purge.FIXTURE_SWAP_TARGET_ID_ENV]: GSD_ID },
  );
  assert.equal(rootSwapResult.ok, false, 'preflight 后根目录替换必须失败关闭');
  assert.equal(rootSwapResult.error.code, 'target-changed-before-delete', '根目录替换必须归类为删除前漂移');
  const parkedRootSwapTarget = rootSwapTarget + '.fixture-predelete-parked';
  assert.equal(fs.existsSync(parkedRootSwapTarget), true, '原已审计树必须保留在 parked 目录');
  assert.equal(fs.existsSync(path.join(parkedRootSwapTarget, 'README.md')), true, '原已审计树内容不得被删除');
  assert.equal(fs.existsSync(rootSwapTarget), true, '新建替换目录必须保留');
  assert.equal(
    fs.readFileSync(path.join(rootSwapTarget, '.fixture-predelete-sentinel'), 'utf8'),
    'must survive handle-bound root identity refusal\n',
    '替换目录 sentinel 不得被删除',
  );
  assert.equal(fs.existsSync(targetFor(rootSwap, RESIDUE_ID)), true, '根目录替换拒绝后不得触碰后续目标');
  assertNoPayloadBackup(rootSwapResult);

  const nestedReplace = makeCompleteFixture('nested-child-replace');
  const nestedReplaceTarget = targetFor(nestedReplace, DISABLED_REMOTE_GSD_BACKUP_ID);
  const nestedReplaceOriginal = path.join(nestedReplaceTarget, 'hooks', 'gsd-check-update.cmd');
  const nestedReplaceResult = runPurge(
    nestedReplace,
    ['--apply'],
    1,
    { [purge.FIXTURE_NESTED_CHILD_REPLACE_TARGET_ID_ENV]: DISABLED_REMOTE_GSD_BACKUP_ID },
  );
  assert.equal(nestedReplaceResult.ok, false, 'manifest 快照后的 nested 目录替换必须失败关闭');
  assert.equal(nestedReplaceResult.error.code, 'target-changed-before-delete', 'nested 目录替换必须归类为删除前漂移');
  const parkedNestedReplace = nestedReplaceTarget + '.fixture-nested-predelete-parked';
  assert.equal(fs.existsSync(path.join(parkedNestedReplace, 'gsd-check-update.cmd')), true, '原 nested payload 不得被删除');
  assert.equal(fs.existsSync(nestedReplaceOriginal), false, '已替换的原 nested 位置不应伪装为原 payload');
  assert.equal(
    fs.readFileSync(path.join(nestedReplaceTarget, 'hooks', '.fixture-nested-replacement-sentinel'), 'utf8'),
    'must survive nested identity refusal\n',
    'nested 替换 sentinel 不得被删除',
  );
  assert.equal(fs.existsSync(path.join(nestedReplaceTarget, 'skills')), true, '同级已审计目录不得被误删');
  assertNoPayloadBackup(nestedReplaceResult);

  const nestedAdd = makeCompleteFixture('nested-child-add');
  const nestedAddTarget = targetFor(nestedAdd, DISABLED_REMOTE_GSD_BACKUP_ID);
  const nestedAddOriginal = path.join(nestedAddTarget, 'hooks', 'gsd-check-update.cmd');
  const nestedAddResult = runPurge(
    nestedAdd,
    ['--apply'],
    1,
    { [purge.FIXTURE_NESTED_CHILD_ADD_TARGET_ID_ENV]: DISABLED_REMOTE_GSD_BACKUP_ID },
  );
  assert.equal(nestedAddResult.ok, false, 'manifest 快照后的 nested 新增必须失败关闭');
  assert.equal(nestedAddResult.error.code, 'target-changed-before-delete', 'nested 新增必须归类为删除前漂移');
  assert.equal(fs.existsSync(nestedAddOriginal), true, 'nested 新增拒绝时原 payload 不得被删除');
  assert.equal(
    fs.readFileSync(path.join(nestedAddTarget, 'hooks', '.fixture-nested-added-sentinel'), 'utf8'),
    'must survive manifest membership refusal\n',
    'nested 新增 sentinel 不得被删除',
  );
  assert.equal(fs.existsSync(path.join(nestedAddTarget, 'skills')), true, 'nested 新增拒绝时同级目录不得被误删');
  assertNoPayloadBackup(nestedAddResult);

  const largeManifest = makeCompleteFixture('large-directory-manifest', { largeManifest: true });
  const largeManifestTarget = targetFor(largeManifest, HEYGEN_PLUGIN_CACHE_ID);
  const largeManifestSafeSibling = path.join(path.dirname(largeManifestTarget), 'unrelated-plugin-sentinel.txt');
  fs.writeFileSync(largeManifestSafeSibling, 'must survive large retired plugin deletion\n', 'utf8');
  assert.ok(
    largeManifestSerializedLowerBoundBytes() > 32 * 1024,
    'fixture serialized manifest 必须超过 Windows 命令行安全长度',
  );
  const largeManifestResult = runPurge(
    largeManifest,
    ['--apply'],
    0,
    { [purge.FIXTURE_LARGE_MANIFEST_TARGET_ID_ENV]: HEYGEN_PLUGIN_CACHE_ID },
  );
  assert.equal(largeManifestResult.ok, true, '大型目录 manifest Apply 不得回退到命令行传输');
  assert.equal(fs.existsSync(largeManifestTarget), false, '大型 manifest 的精确退休插件目标必须删除');
  assert.equal(
    fs.readFileSync(largeManifestSafeSibling, 'utf8'),
    'must survive large retired plugin deletion\n',
    '大型 manifest Apply 不得删除同级安全项',
  );
  assertNoPayloadBackup(largeManifestResult);

  const readOnlyFile = makeCompleteFixture('read-only-file');
  const readOnlyTarget = path.join(
    targetFor(readOnlyFile, HEYGEN_PLUGIN_CACHE_ID),
    '3.0.0',
    'skills',
    'retired-plugin',
    'SKILL.md',
  );
  fs.chmodSync(readOnlyTarget, 0o444);
  assert.equal(
    fs.statSync(readOnlyTarget).mode & 0o200,
    0,
    'fixture 普通文件必须实际处于只读状态',
  );
  const readOnlyAudit = runPurge(readOnlyFile);
  assert.equal(readOnlyAudit.ok, true);
  assertNoPayloadBackup(readOnlyAudit);
  const readOnlyApplied = runPurge(readOnlyFile, ['--apply']);
  assert.equal(readOnlyApplied.ok, true);
  assert.deepEqual([...readOnlyApplied.deletedTargetIds].sort(), [...ALL_IDS].sort());
  assertNoPayloadBackup(readOnlyApplied);
  for (const id of ALL_IDS) {
    assert.equal(fs.existsSync(targetFor(readOnlyFile, id)), false, id + ' readonly fixture apply 未删除');
  }

  const applied = runPurge(normal, ['--apply']);
  assert.equal(applied.ok, true);
  assert.equal(applied.mode, 'apply');
  assert.equal(applied.dryRun, false);
  assert.deepEqual([...applied.deletedTargetIds].sort(), [...ALL_IDS].sort());
  assert.ok(applied.approvedTargets.every((entry) => entry.state === 'removed'));
  assertNoPayloadBackup(applied);
  for (const id of ALL_IDS) {
    assert.equal(fs.existsSync(targetFor(normal, id)), false, id + ' fixture apply 未删除');
  }
  assert.equal(fs.existsSync(worktreeMetadataTarget(normal)), false, 'detached worktree metadata 必须随 apply 安全注销');

  const absentAudit = runPurge(normal);
  assert.equal(absentAudit.ok, true);
  assert.ok(absentAudit.approvedTargets.every((entry) => entry.state === 'absent'));
  assert.ok(absentAudit.approvedTargets.every((entry) => entry.action === 'already-absent'));
  assertNoPayloadBackup(absentAudit);

  const mismatch = makeCompleteFixture('content-mismatch');
  writeText(path.join(targetFor(mismatch, GSD_ID), 'unexpected.txt'), 'must refuse\n');
  const mismatchResult = runPurge(mismatch, ['--apply'], 1);
  assert.equal(mismatchResult.ok, false);
  assert.equal(mismatchResult.error.code, 'identity-fingerprint-mismatch');
  assertNoPayloadBackup(mismatchResult);
  assertFixtureTargetsExist(mismatch);

  const pluginMismatch = makeCompleteFixture('plugin-cache-mismatch');
  writeText(
    path.join(targetFor(pluginMismatch, HEYGEN_PLUGIN_CACHE_ID), 'unexpected.txt'),
    'must refuse\n',
  );
  const pluginMismatchResult = runPurge(pluginMismatch, ['--apply'], 1);
  assert.equal(pluginMismatchResult.ok, false);
  assert.equal(pluginMismatchResult.error.code, 'identity-fingerprint-mismatch');
  assertNoPayloadBackup(pluginMismatchResult);
  assertFixtureTargetsExist(pluginMismatch);

  const staleProvenance = makeCompleteFixture('stale-provenance');
  writeText(
    path.join(staleProvenance, 'active', 'skills', 'frontend-design', 'SOURCE.md'),
    'Retrieval: ' + targetFor(staleProvenance, SOURCE_ID) + '\n',
  );
  const staleProvenanceResult = runPurge(staleProvenance, ['--apply'], 1);
  assert.equal(staleProvenanceResult.ok, false);
  assert.equal(staleProvenanceResult.error.code, 'active-source-provenance-reference');
  assertNoPayloadBackup(staleProvenanceResult);
  assertFixtureTargetsExist(staleProvenance);

  const worktreeGitdirMismatch = makeCompleteFixture('worktree-gitdir-mismatch');
  writeText(path.join(targetFor(worktreeGitdirMismatch, WORKTREE_ID), '.git'), 'gitdir: D:/outside/unsafe\n');
  const worktreeGitdirMismatchResult = runPurge(worktreeGitdirMismatch, ['--apply'], 1);
  assert.equal(worktreeGitdirMismatchResult.ok, false);
  assert.equal(worktreeGitdirMismatchResult.error.code, 'identity-fingerprint-mismatch');
  assertNoPayloadBackup(worktreeGitdirMismatchResult);
  assertFixtureTargetsExist(worktreeGitdirMismatch);
  assert.equal(fs.existsSync(worktreeMetadataTarget(worktreeGitdirMismatch)), true, 'gitfile 拒绝时 metadata 不得删除');

  const worktreeMetadataMismatch = makeCompleteFixture('worktree-metadata-mismatch');
  writeText(path.join(worktreeMetadataTarget(worktreeMetadataMismatch), 'gitdir'), 'D:/outside/unsafe/.git\n');
  const worktreeMetadataMismatchResult = runPurge(worktreeMetadataMismatch, ['--apply'], 1);
  assert.equal(worktreeMetadataMismatchResult.ok, false);
  assert.equal(worktreeMetadataMismatchResult.error.code, 'identity-fingerprint-mismatch');
  assertNoPayloadBackup(worktreeMetadataMismatchResult);
  assertFixtureTargetsExist(worktreeMetadataMismatch);
  assert.equal(fs.existsSync(worktreeMetadataTarget(worktreeMetadataMismatch)), true, 'metadata 拒绝时不得注销 worktree');

  const unsupported = makeCompleteFixture('unsupported-argument');
  const unsupportedResult = runPurge(unsupported, ['not-an-approved-target'], 1);
  assert.equal(unsupportedResult.ok, false);
  assert.equal(unsupportedResult.error.code, 'unsupported-argument');
  assertNoPayloadBackup(unsupportedResult);
  assertFixtureTargetsExist(unsupported);

  const targetJunction = makeCompleteFixture('target-junction');
  const targetJunctionOutside = fixtureRoot('target-junction-outside');
  const targetJunctionSentinel = path.join(targetJunctionOutside, 'external-sentinel.txt');
  fs.writeFileSync(targetJunctionSentinel, 'must survive target junction refusal', 'utf8');
  const gsdTarget = targetFor(targetJunction, GSD_ID);
  fs.rmSync(gsdTarget, { recursive: true, force: true });
  const externalArchive = path.join(targetJunctionOutside, 'external-archive');
  writeGsdArchive(externalArchive);
  makeJunction(externalArchive, gsdTarget);
  const targetJunctionResult = runPurge(targetJunction, ['--apply'], 1);
  assert.equal(targetJunctionResult.ok, false);
  assert.equal(targetJunctionResult.error.code, 'reparse-point');
  assertNoPayloadBackup(targetJunctionResult);
  assert.equal(fs.lstatSync(gsdTarget).isSymbolicLink(), true, 'target junction 不得删除');
  assert.equal(fs.existsSync(externalArchive), true, '不得删除 junction 外的 archive');
  assert.equal(fs.existsSync(targetJunctionSentinel), true, '外部 sentinel 必须存活');
  assert.equal(fs.existsSync(targetFor(targetJunction, RESIDUE_ID)), true, '批量 preflight 失败时不得触碰后续目标');

  const ancestorJunction = makeCompleteFixture('ancestor-junction');
  const ancestorOutside = fixtureRoot('ancestor-junction-outside');
  const ancestorSentinel = path.join(ancestorOutside, 'external-sentinel.txt');
  fs.writeFileSync(ancestorSentinel, 'must survive ancestor junction refusal', 'utf8');
  const reportsPath = path.join(ancestorJunction, 'projects', '统一环境', 'reports');
  fs.rmSync(reportsPath, { recursive: true, force: true });
  const externalReports = path.join(ancestorOutside, 'reports');
  writeBackupRetentionResidue(path.join(externalReports, path.basename(targetFor(ancestorJunction, RESIDUE_ID))));
  makeJunction(externalReports, reportsPath);
  const ancestorResult = runPurge(ancestorJunction, ['--apply'], 1);
  assert.equal(ancestorResult.ok, false);
  assert.equal(ancestorResult.error.code, 'reparse-point');
  assertNoPayloadBackup(ancestorResult);
  assert.equal(fs.lstatSync(reportsPath).isSymbolicLink(), true, 'ancestor junction 不得删除');
  assert.equal(fs.existsSync(externalReports), true, '不得删除 junction 外的 reports');
  assert.equal(fs.existsSync(ancestorSentinel), true, 'ancestor 外部 sentinel 必须存活');
  assert.equal(fs.existsSync(targetFor(ancestorJunction, GSD_ID)), true, 'preflight 失败不得删除先前普通目标');

  const nestedJunction = makeCompleteFixture('nested-junction');
  const nestedOutside = fixtureRoot('nested-junction-outside');
  const nestedSentinel = path.join(nestedOutside, 'external-sentinel.txt');
  fs.writeFileSync(nestedSentinel, 'must survive nested junction refusal', 'utf8');
  const nestedResidue = targetFor(nestedJunction, RESIDUE_ID);
  const nestedLink = path.join(nestedResidue, 'reparse-parent');
  fs.rmdirSync(nestedLink);
  makeJunction(nestedOutside, nestedLink);
  const nestedResult = runPurge(nestedJunction, ['--apply'], 1);
  assert.equal(nestedResult.ok, false);
  assert.equal(nestedResult.error.code, 'nested-reparse-escape');
  assertNoPayloadBackup(nestedResult);
  assert.equal(fs.lstatSync(nestedLink).isSymbolicLink(), true, 'nested junction 不得删除');
  assert.equal(fs.existsSync(nestedSentinel), true, 'nested 外部 sentinel 必须存活');
  assert.equal(fs.existsSync(targetFor(nestedJunction, GSD_ID)), true, 'preflight 失败不得删除正常 archive');

  console.log('Explicit retired artifact purge: PASS (fixed allowlist, plugin/GSD payloads, fingerprints, audit/apply fixtures, target/ancestor/nested junction refusal)');
} finally {
  cleanup();
}
