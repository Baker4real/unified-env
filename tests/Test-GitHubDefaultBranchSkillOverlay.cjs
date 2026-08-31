'use strict';

const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..');
const overlayPath = path.join(repoRoot, 'scripts', 'Apply-GitHubDefaultBranchSkillOverlay.cjs');
const catalogPath = path.join(repoRoot, 'scripts', 'github-default-branch-skill-overlay-catalog.json');

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex').toUpperCase();
}

function assertFileExists(filePath, label) {
  assert.equal(
    fs.existsSync(filePath),
    true,
    `缺少 ${label}：Apply-GitHubDefaultBranchSkillOverlay.cjs 和 github-default-branch-skill-overlay-catalog.json 必须先实现`,
  );
}

assertFileExists(overlayPath, '覆盖器');
assertFileExists(catalogPath, 'catalog');

const overlay = require(overlayPath);
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));

assert.equal(catalog.policy, 'main-only-publish-v2');
assert.equal(catalog.marker, '<!-- codex-github-main-only-overlay: v2 -->');

assert.equal(typeof overlay.discoverTargets, 'function');
assert.equal(typeof overlay.buildChangePlan, 'function');
assert.equal(typeof overlay.applyChangePlan, 'function');
assert.equal(typeof overlay.rollbackManifest, 'function');
assert.equal(typeof overlay.parseCliArgs, 'function');

const codexRoot = 'D:\\Codex\\.codex';
const evidenceRoot = path.join(
  'D:\\agents\\run-evidence',
  'github-default-branch-skill-policy',
  'overlay-test',
);
const fixtureRoot = path.join(evidenceRoot, 'fixture-codex-root');

const parsedNamedArgs = overlay.parseCliArgs([
  '--codex-root', codexRoot,
  '--evidence-root', 'D:\\agents\\run-evidence\\github-default-branch-skill-policy',
  '--catalog-path', catalogPath,
  '--dry-run',
  '--json',
]);
assert.equal(parsedNamedArgs.ok, true);
assert.equal(parsedNamedArgs.options.codexRoot, codexRoot);
assert.equal(parsedNamedArgs.options.evidenceRoot, 'D:\\agents\\run-evidence\\github-default-branch-skill-policy');
assert.equal(parsedNamedArgs.options.catalogPath, catalogPath);
assert.equal(parsedNamedArgs.options.dryRun, true);
assert.equal(parsedNamedArgs.options.json, true);
assert.deepEqual(overlay.parseCliArgs([codexRoot, catalogPath, '--dry-run']).options, {
  codexRoot,
  evidenceRoot: 'D:\\agents\\run-evidence\\github-default-branch-skill-policy',
  catalogPath,
  dryRun: true,
  json: false,
});
assert.equal(overlay.parseCliArgs(['--unknown-flag']).ok, false);
assert.equal(overlay.parseCliArgs(['--codex-root']).ok, false);
assert.equal(overlay.parseCliArgs(['--json', '--json']).ok, false);
const unknownCli = childProcess.spawnSync(
  process.execPath,
  [overlayPath, '--unknown-flag', '--json'],
  { encoding: 'utf8', windowsHide: true },
);
assert.notEqual(unknownCli.status, 0);
assert.equal(JSON.parse(unknownCli.stdout).blocked, true);

function removeTree(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function catalogEntries(role) {
  const entries = Array.isArray(catalog) ? catalog : catalog.roles?.[role];
  if (Array.isArray(entries)) return entries;
  assert.ok(Array.isArray(entries?.knownInputSha256), `catalog 缺少 role=${role}`);
  return entries.knownInputSha256.map((upstreamSha256) => ({
    upstreamSha256,
    patchedSha256: entries.patchedSha256,
    patchedDocument: entries.patchedDocument,
  }));
}

const fixtureUpstream = {
  yeet: {
    local: '---\nname: "yeet"\ndescription: "fixture local publisher"\n---\n\n# Fixture yeet local\n',
    remote: '---\nname: "yeet"\ndescription: "fixture remote publisher"\n---\n\n# Fixture yeet remote\n',
  },
  github: {
    local: '---\nname: github\ndescription: fixture local router\n---\n\n# Fixture github local\n',
    remote: '---\nname: github\ndescription: fixture remote router\n---\n\n# Fixture github remote\n',
  },
};

// Keep the fixture independent of mutable global plugin files. Task 3 will
// replace those files, while the real catalog itself is still validated here.
overlay.loadCatalog(catalog);
const expectedInputs = {
  github: [
    '380D663305EB74B44858F58D76BDB21173A4D4C63D5885299AD6005D6FFC80B9',
    '81DBDD90934FE86A79DDC4790FD211E5FCA866302A74090AD153395F56F2BD42',
    '1A45C26345139509A3E7B759E688C3948C8A381143D8A2BD01C5D6F43CC38366',
    '2107A6AA76F24B544D2F296C09B155FCEE1A936101364C38730335FE0D385FEE',
  ],
  yeet: [
    '9D70C68282ACBC7FBEE678F142ADBF84B4F1091890D6CB93B3106E5E629FC0CB',
    'E93C6EA769BA673D30749A981CD8AD75B687F454E3C8E2E45E7CFCBD412DF12C',
    '036578CBD8FC6855B49156D3B1E585C128481B289DE660939F4F0305C699EB9F',
    '4AE826B1F9EA1543AC582791DADE5D15A8B4A8E6B9211BC5B3A30B9B01D4E9C1',
    '9E58C2B95136F8F5EE39A14340FDCC6B1E30B7AF37273B2C3D8CABA777B11901',
  ],
};
for (const role of ['github', 'yeet']) {
  const inputs = new Set(catalogEntries(role).map((entry) => entry.upstreamSha256));
  for (const expected of expectedInputs[role]) {
    assert.ok(inputs.has(expected), `${role} catalog 未识别现役输入 ${expected}`);
  }
  assert.equal(
    new Set(catalogEntries(role).map((entry) => entry.patchedSha256)).size,
    1,
    `${role} 的所有已知输入必须收敛到同一现役 overlay`,
  );
}
const fixtureCatalog = JSON.parse(JSON.stringify(overlay.loadCatalog(catalog)));
for (const role of ['yeet', 'github']) {
  fixtureCatalog.roles[role][0].upstreamSha256 = sha256(fixtureUpstream[role].local);
  fixtureCatalog.roles[role][1].upstreamSha256 = sha256(fixtureUpstream[role].remote);
}
overlay.loadCatalog(fixtureCatalog);

const sharedPolicyPatterns = [
  /当前任务[\s\S]{0,100}明确授权[\s\S]{0,100}(?:commit|push|发布)/i,
  /用户拥有[\s\S]{0,80}(?:remote|远端)/i,
  /git\s+push\s+<targetRemote>\s+HEAD:main/i,
  /git\s+fetch\s+--prune\s+<targetRemote>/i,
  /本地\s+HEAD[\s\S]{0,180}<targetRemote>\/main[\s\S]{0,100}(?:tracking|一致)/i,
];
for (const role of ['github', 'yeet']) {
  for (const entry of fixtureCatalog.roles[role]) {
    for (const pattern of sharedPolicyPatterns) {
      assert.match(entry.patchedDocument, pattern, `${role} patchedDocument 缺少可验证发布契约 ${pattern}`);
    }
    assert.doesNotMatch(entry.patchedDocument, /agent\/\{description\}/i);
    assert.match(entry.patchedDocument, /创建 PR 不是默认|不默认创建 draft PR|does not default to a draft PR/i);
  }
}

const githubDocument = fixtureCatalog.roles.github[0].patchedDocument;
for (const pattern of [
  /GitHub app/i,
  /connector first|connector-first|优先使用 connector/i,
  /current-branch PR discovery|当前分支[\s\S]{0,80}PR/i,
  /GitHub Actions logs|GitHub Actions 日志/i,
  /PR creation|创建 PR/i,
  /`gh`[\s\S]{0,80}(?:fallback|兜底)/i,
  /\.\.\/yeet\/SKILL\.md/i,
]) {
  assert.match(githubDocument, pattern, `github overlay 丢失新版 upstream 能力 ${pattern}`);
}

const yeetDocument = fixtureCatalog.roles.yeet[0].patchedDocument;
for (const pattern of [
  /GitHub app/i,
  /PR creation|创建 PR/i,
  /`gh`[\s\S]{0,80}(?:fallback|兜底)/i,
  /发布前门禁[\s\S]{0,700}git\s+fetch\s+--prune\s+<targetRemote>[\s\S]{0,300}(?:ahead|diverged)/i,
  /只有[\s\S]{0,180}用户确认[\s\S]{0,180}git\s+push\s+--set-upstream\s+<targetRemote>\s+<temporaryBranch>/i,
  /git\s+push\s+--delete\s+<targetRemote>\s+<temporaryBranch>/i,
  /git\s+worktree\s+remove\s+<temporaryWorktree>/i,
  /git\s+branch\s+--delete\s+<temporaryBranch>/i,
  /ownedByThisWorkflow/i,
  /远端删除失败[\s\S]{0,180}(?:保留|停止)/i,
]) {
  assert.match(yeetDocument, pattern, `yeet overlay 缺少发布或例外边界 ${pattern}`);
}
{
    const cleanupCommands = [
      'git push --delete <targetRemote> <temporaryBranch>',
      'git worktree remove <temporaryWorktree>',
      'git branch --delete <temporaryBranch>',
      'git fetch --prune <targetRemote>',
    ];
  const cleanupIndexes = cleanupCommands.map((command) => yeetDocument.lastIndexOf(command));
  assert.ok(cleanupIndexes.every((index) => index >= 0), 'yeet patchedDocument 缺少 cleanup 命令');
  assert.ok(cleanupIndexes.every((index, indexInOrder) => indexInOrder === 0 || index > cleanupIndexes[indexInOrder - 1]), 'yeet patchedDocument cleanup 顺序错误');
}
const missingSemanticCatalog = JSON.parse(JSON.stringify(fixtureCatalog));
missingSemanticCatalog.roles.yeet[0].patchedDocument = missingSemanticCatalog.roles.yeet[0].patchedDocument
  .replaceAll('`git push <targetRemote> HEAD:main`', '`git push <targetRemote> HEAD:<branch>`');
assert.throws(
  () => overlay.loadCatalog(missingSemanticCatalog),
  (error) => error?.errors?.some((item) => item.reason === 'missing-main-push'),
  'catalog 缺少 main-only push 证据时必须失败关闭',
);
const misorderedCleanupCatalog = JSON.parse(JSON.stringify(fixtureCatalog));
misorderedCleanupCatalog.roles.yeet[0].patchedDocument = misorderedCleanupCatalog.roles.yeet[0].patchedDocument
  .replace(
    '3. `git branch --delete <temporaryBranch>`\n4. `git fetch --prune <targetRemote>`',
    '3. `git fetch --prune <targetRemote>`\n4. `git branch --delete <temporaryBranch>`',
  );
assert.throws(
  () => overlay.loadCatalog(misorderedCleanupCatalog),
  (error) => error?.errors?.some((item) => item.reason === 'cleanup-order-mismatch'),
  'cleanup 顺序不满足远端→worktree→本地分支→fetch 时必须失败关闭',
);

function entryFor(role, document, fixture = fixtureCatalog) {
  const current = sha256(document);
  const entry = fixture.roles[role].find((candidate) => candidate.upstreamSha256 === current);
  assert.ok(entry, `catalog 未接受 role=${role} 的 fixture 指纹 ${current}`);
  return entry;
}

function fixturePath(surface, role) {
  return path.join(fixtureRoot, surface, 'skills', role, 'SKILL.md');
}

const surfaces = [
  { root: '.tmp/plugins/plugins/github', variant: 'local' },
  { root: 'plugins/cache/openai-curated/github/27126220', variant: 'local' },
  // 远端 curated surface 自 0.1.12 起不再落盘 SKILL.md，已从现役合同移除；
  // 见 scripts/Apply-GitHubDefaultBranchSkillOverlay.cjs 的 EXPECTED_SURFACE_RELATIVES。
];

removeTree(evidenceRoot);
fs.mkdirSync(fixtureRoot, { recursive: true });
const fixtureCatalogPath = path.join(evidenceRoot, 'fixture-catalog.json');
fs.writeFileSync(fixtureCatalogPath, `${JSON.stringify(fixtureCatalog, null, 2)}\n`, 'utf8');
const fixtureApplyOptions = (overrides = {}) => ({
  evidenceRoot,
  allowTestCatalog: true,
  testOnlyCatalogPath: fixtureCatalogPath,
  testOnlyCatalog: fixtureCatalog,
  ...overrides,
});

for (const surface of surfaces) {
  for (const role of ['yeet', 'github']) {
    const document = fixtureUpstream[role][surface.variant];
    const target = fixturePath(surface.root, role);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, document, 'utf8');
    assert.ok(entryFor(role, document));
  }
}

const discovered = overlay.discoverTargets(fixtureRoot);
assert.equal(discovered.errors?.length ?? 0, 0);
const targets = discovered.targets ?? discovered;
assert.equal(targets.length, 4);

const plan = overlay.buildChangePlan(discovered, fixtureCatalog);
assert.equal(plan.errors.length, 0);
assert.equal(plan.changes.length, 4);

const dryRun = overlay.applyChangePlan(plan, fixtureApplyOptions({ dryRun: true }));
assert.equal(dryRun.changed, 0);
assert.equal(dryRun.failed, 0);
assert.equal(dryRun.skipped, 0);

const applied = overlay.applyChangePlan(plan, fixtureApplyOptions({ dryRun: false }));
assert.equal(applied.changed, 4);
assert.equal(applied.failed, 0);
assert.ok(applied.evidencePaths?.length >= 4);
const appliedManifest = JSON.parse(fs.readFileSync(applied.manifestPath, 'utf8'));
assert.equal(appliedManifest.catalogPath, fixtureCatalogPath);
assert.equal(appliedManifest.catalogSha256, sha256(fs.readFileSync(fixtureCatalogPath)));
assert.equal(
  sha256(fs.readFileSync(appliedManifest.catalogBackupPath)),
  appliedManifest.catalogSha256,
);
assert.equal(appliedManifest.inventory.digest, plan.inventory.digest);
assert.equal(appliedManifest.inventory.targets.length, 4);
assert.equal(appliedManifest.sourceInputs.catalog.path, fixtureCatalogPath);
assert.equal(appliedManifest.sourceInputs.catalog.sha256, appliedManifest.catalogSha256);
assert.equal(appliedManifest.sourceInputs.targets.length, 4);
assert.equal(appliedManifest.sourceInputs.changes.length, 4);
assert.equal(appliedManifest.sourceInputs.skipped.length, 0);

const secondPlan = overlay.buildChangePlan(
  overlay.discoverTargets(fixtureRoot),
  fixtureCatalogPath,
);
assert.equal(secondPlan.errors.length, 0);
assert.equal(secondPlan.changes.length, 0);
const idempotent = overlay.applyChangePlan(secondPlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(idempotent.changed, 0);
assert.equal(idempotent.failed, 0);
assert.equal(idempotent.skipped, 4);

// Mixed state is valid: three targets are already patched and one target is
// upstream. The complete inventory is still four, so apply changes only one.
const mixedTarget = targets[0];
fs.writeFileSync(mixedTarget.path, fixtureUpstream[mixedTarget.role].local, 'utf8');
const mixedDiscovery = overlay.discoverTargets(fixtureRoot);
const mixedPlan = overlay.buildChangePlan(mixedDiscovery, fixtureCatalogPath);
assert.equal(mixedPlan.changes.length, 1);
assert.equal(mixedPlan.skipped.length, 3);
const mixedApply = overlay.applyChangePlan(mixedPlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(mixedApply.changed, 1);
assert.equal(mixedApply.failed, 0);
const mixedManifest = JSON.parse(fs.readFileSync(mixedApply.manifestPath, 'utf8'));
assert.equal(mixedManifest.inventory.digest, mixedPlan.inventory.digest);
assert.equal(mixedManifest.sourceInputs.targets.length, 4);
assert.equal(mixedManifest.sourceInputs.changes.length, 1);
assert.equal(mixedManifest.sourceInputs.skipped.length, 3);

// A skipped entry is not trusted merely because it is marked skipped.
const forgedSkippedPlan = JSON.parse(JSON.stringify(secondPlan));
forgedSkippedPlan.skipped[0].patchedSha256 = '0'.repeat(64);
const forgedSkippedResult = overlay.applyChangePlan(forgedSkippedPlan, fixtureApplyOptions({ dryRun: true }));
assert.equal(forgedSkippedResult.blocked, true);
assert.ok(forgedSkippedResult.errors.some((error) => error.reason === 'skipped-plan-fingerprint-mismatch'));

// A partial/hand-built plan without the discovery inventory is never allowed.
const missingInventoryPartial = overlay.applyChangePlan(
  { changes: [mixedPlan.changes[0]], skipped: [], errors: [], catalogRef: mixedPlan.catalogRef },
  fixtureApplyOptions({ dryRun: true }),
);
assert.equal(missingInventoryPartial.blocked, true);
assert.ok(missingInventoryPartial.errors.some((error) => error.reason === 'missing-or-invalid-inventory'));

// Any new version or sibling surface is an inventory drift, even when both
// files carry a catalog-known upstream fingerprint. The entire operation must
// block before writing the six expected targets.
const extraSurfaceRoots = [
  path.join(fixtureRoot, 'plugins', 'cache', 'openai-curated', 'github', '27126220-extra'),
  path.join(fixtureRoot, '.tmp', 'plugins', 'plugins', 'github-extra'),
];
for (const extraRoot of extraSurfaceRoots) {
  for (const role of ['yeet', 'github']) {
    fs.mkdirSync(path.join(extraRoot, 'skills', role), { recursive: true });
    fs.writeFileSync(
      path.join(extraRoot, 'skills', role, 'SKILL.md'),
      fixtureUpstream[role].local,
      'utf8',
    );
  }
}
const extraBefore = {};
for (const target of overlay.discoverTargets(fixtureRoot).targets) {
  extraBefore[target.path] = sha256(fs.readFileSync(target.path));
}
const extraDiscovery = overlay.discoverTargets(fixtureRoot);
assert.ok(extraDiscovery.errors.some((error) => error.reason === 'unexpected-plugin-surface'));
assert.ok(extraDiscovery.errors.some((error) => error.reason === 'unexpected-surface-count'));
const extraPlan = overlay.buildChangePlan(extraDiscovery, fixtureCatalogPath);
assert.ok(extraPlan.errors.some((error) => error.reason === 'unexpected-plugin-surface'));
const extraDryRun = overlay.applyChangePlan(extraPlan, fixtureApplyOptions({ dryRun: true }));
assert.equal(extraDryRun.blocked, true);
const extraApply = overlay.applyChangePlan(extraPlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(extraApply.blocked, true);
assert.equal(extraApply.changed, 0);
for (const [filePath, expected] of Object.entries(extraBefore)) {
  assert.equal(sha256(fs.readFileSync(filePath)), expected, `extra surface drift must not write ${filePath}`);
}
for (const extraRoot of extraSurfaceRoots) fs.rmSync(extraRoot, { recursive: true, force: true });

// Removing an expected surface is also a hard inventory failure.
const missingSurfaceRoot = path.join(fixtureRoot, 'plugins', 'cache', 'openai-curated', 'github', '27126220');
const missingSurfaceBackup = path.join(evidenceRoot, 'missing-surface-backup');
fs.rmSync(missingSurfaceBackup, { recursive: true, force: true });
fs.renameSync(missingSurfaceRoot, missingSurfaceBackup);
const missingSurfaceDiscovery = overlay.discoverTargets(fixtureRoot);
assert.ok(missingSurfaceDiscovery.errors.some((error) => error.reason === 'missing-plugin-surface'));
assert.ok(missingSurfaceDiscovery.errors.some((error) => error.reason === 'unexpected-surface-count'));
assert.ok(missingSurfaceDiscovery.errors.some((error) => error.reason === 'unexpected-target-count'));
const missingSurfacePlan = overlay.buildChangePlan(missingSurfaceDiscovery, fixtureCatalogPath);
const missingSurfaceApply = overlay.applyChangePlan(missingSurfacePlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(missingSurfaceApply.blocked, true);
assert.equal(missingSurfaceApply.changed, 0);
fs.renameSync(missingSurfaceBackup, missingSurfaceRoot);

// Only the three supported plugin surfaces may be changed, even when an
// external D: file happens to carry a known upstream fingerprint.
const externalTarget = path.join(evidenceRoot, 'external', 'SKILL.md');
fs.mkdirSync(path.dirname(externalTarget), { recursive: true });
fs.writeFileSync(externalTarget, fixtureUpstream.yeet.local, 'utf8');
const externalPlan = overlay.buildChangePlan(
  [{ path: externalTarget, role: 'yeet' }],
  fixtureCatalog,
);
assert.ok(externalPlan.errors.some((error) => error.reason === 'unsupported-plugin-surface'));
assert.equal(overlay.applyChangePlan(externalPlan, fixtureApplyOptions({ dryRun: false })).changed, 0);
const forgedChange = JSON.parse(JSON.stringify(plan.changes[0]));
forgedChange.path = externalTarget;
forgedChange.codexRoot = codexRoot;
const forgedApplyPlan = overlay.applyChangePlan(
  { changes: [forgedChange], skipped: [], errors: [], inventory: plan.inventory },
  fixtureApplyOptions({ dryRun: true }),
);
assert.equal(forgedApplyPlan.changed, 0);
assert.equal(forgedApplyPlan.blocked, true);
assert.ok(forgedApplyPlan.errors.some((error) => error.reason === 'unsupported-plugin-surface'));
// A patched marker is not sufficient when the catalog document contains a
// forbidden force/patch-stack operation.
const forgedCatalog = JSON.parse(JSON.stringify(fixtureCatalog));
forgedCatalog.roles.yeet[0].patchedDocument += [
  '`git push --force-with-lease origin feature`',
  '`git push --force-with-lease=origin/feature origin feature`',
  '`git push -f origin feature`',
  '`git push -f=origin/feature origin feature`',
  '`git branch patch-stack`',
  '`git switch -c patch-stack`',
  '`git switch --create patch-stack`',
  '`git checkout -b patch-stack`',
  '`git worktree add D:\\tmp\\patch-stack patch-stack`',
  '`git update-ref refs/heads/patch-stack deadbeef`',
].join('\n');
const forgedCatalogPlan = overlay.buildChangePlan(
  overlay.discoverTargets(fixtureRoot),
  forgedCatalog,
);
const forbiddenErrors = forgedCatalogPlan.errors.filter((error) => error.reason === 'forbidden-publish-pattern');
assert.equal(forbiddenErrors.length, 5);
assert.ok(forbiddenErrors.some((error) => /force/.test(error.message)));
assert.ok(forbiddenErrors.some((error) => /branch/.test(error.message)));
assert.ok(forbiddenErrors.some((error) => /switch|checkout/.test(error.message)));
assert.ok(forbiddenErrors.some((error) => /worktree/.test(error.message)));
assert.ok(forbiddenErrors.some((error) => /refs/.test(error.message)));

// Rollback refuses a manifest that attempts to address a non-plugin path.
const maliciousManifestDirectory = path.join(evidenceRoot, 'malicious-manifest');
const maliciousManifestPath = path.join(maliciousManifestDirectory, 'manifest.json');
const maliciousBackupPath = path.join(maliciousManifestDirectory, 'backup-SKILL.md');
fs.mkdirSync(maliciousManifestDirectory, { recursive: true });
fs.writeFileSync(maliciousBackupPath, fixtureUpstream.yeet.local, 'utf8');
fs.writeFileSync(maliciousManifestPath, JSON.stringify({
  evidenceDirectory: maliciousManifestDirectory,
  entries: [{
    path: externalTarget,
    backupPath: maliciousBackupPath,
    status: 'committed',
    codexRoot: fixtureRoot,
    originalSha256: sha256(fixtureUpstream.yeet.local),
    replacementSha256: sha256(fixtureUpstream.yeet.local),
  }],
}), 'utf8');
assert.throws(
  () => overlay.rollbackManifest(maliciousManifestPath),
  /manifest target is outside a supported GitHub plugin surface/,
);
const maliciousBackupManifestPath = path.join(maliciousManifestDirectory, 'manifest-external-backup.json');
fs.writeFileSync(maliciousBackupManifestPath, JSON.stringify({
  evidenceDirectory: maliciousManifestDirectory,
  entries: [{
    path: targets[0].path,
    backupPath: 'D:\\Codex\\outside-overlay-backup.bin',
    status: 'committed',
    originalSha256: sha256(fixtureUpstream.yeet.local),
    replacementSha256: fixtureCatalog.roles[targets[0].role][0].patchedSha256,
    codexRoot: fixtureRoot,
  }],
}), 'utf8');
assert.throws(
  () => overlay.rollbackManifest(maliciousBackupManifestPath),
  /manifest backupPath is outside its evidenceDirectory/,
);
const cDriveManifestPath = path.join(maliciousManifestDirectory, 'manifest-c-drive.json');
fs.writeFileSync(cDriveManifestPath, JSON.stringify({
  evidenceDirectory: maliciousManifestDirectory,
  entries: [{
    path: 'C:\\outside-plugin\\skills\\yeet\\SKILL.md',
    backupPath: 'C:\\outside-evidence\\backup-SKILL.md',
    codexRoot: 'C:\\outside-plugin',
    status: 'committed',
    originalSha256: sha256(fixtureUpstream.yeet.local),
    replacementSha256: fixtureCatalog.roles.yeet[0].patchedSha256,
  }],
}), 'utf8');
assert.throws(
  () => overlay.rollbackManifest(cDriveManifestPath),
  /must stay on the D: drive/,
);

// A failure after the target rename must restore every already-written target.
const postWriteRoot = path.join(evidenceRoot, 'post-write-fixture');
fs.rmSync(postWriteRoot, { recursive: true, force: true });
for (const surface of surfaces) {
  for (const role of ['yeet', 'github']) {
    const document = fixtureUpstream[role][surface.variant];
    const independentTarget = path.join(postWriteRoot, surface.root, 'skills', role, 'SKILL.md');
    fs.mkdirSync(path.dirname(independentTarget), { recursive: true });
    fs.writeFileSync(independentTarget, document, 'utf8');
  }
}
const postWriteDiscovery = overlay.discoverTargets(postWriteRoot);
const postWritePlan = overlay.buildChangePlan(postWriteDiscovery, fixtureCatalogPath);
const objectProductionPlan = overlay.buildChangePlan(postWriteDiscovery, fixtureCatalog);
const objectProductionResult = overlay.applyChangePlan(objectProductionPlan, { dryRun: true, evidenceRoot });
assert.equal(objectProductionResult.blocked, true);
assert.ok(objectProductionResult.errors.some((error) => /inline catalog objects are test-only/.test(error.message)));
const canonicalCatalogObject = JSON.parse(fs.readFileSync(
  path.join(repoRoot, 'scripts', 'github-default-branch-skill-overlay-catalog.json'),
  'utf8',
));
const canonicalObjectRef = overlay.buildChangePlan([], canonicalCatalogObject).catalogRef;
const canonicalObjectNoFlag = overlay.applyChangePlan(
  { changes: postWritePlan.changes, skipped: [], errors: [], catalogRef: canonicalObjectRef, inventory: postWritePlan.inventory },
  { dryRun: true, evidenceRoot },
);
assert.equal(canonicalObjectNoFlag.blocked, true);
assert.ok(canonicalObjectNoFlag.errors.some((error) => /inline catalog objects are test-only/.test(error.message)));
const productionEvidenceCatalogResult = overlay.applyChangePlan(postWritePlan, {
  dryRun: true,
  evidenceRoot,
});
assert.equal(productionEvidenceCatalogResult.blocked, true);
assert.ok(productionEvidenceCatalogResult.errors.some((error) => /production canonical catalog/.test(error.message)));
const outsideEvidenceResult = overlay.applyChangePlan(postWritePlan, fixtureApplyOptions({
  dryRun: true,
  evidenceRoot: 'D:\\Codex\\.codex\\run-evidence-outside-policy',
}));
assert.equal(outsideEvidenceResult.blocked, true);
assert.ok(outsideEvidenceResult.errors.some((error) => /evidenceRoot must stay under/.test(error.message)));
const replacementTamper = JSON.parse(JSON.stringify(postWritePlan.changes[0]));
replacementTamper.replacement = 'tampered replacement';
const replacementTamperResult = overlay.applyChangePlan(
  { changes: [replacementTamper], skipped: [], errors: [], catalogRef: postWritePlan.catalogRef, inventory: postWritePlan.inventory },
  fixtureApplyOptions({ dryRun: false }),
);
assert.equal(replacementTamperResult.changed, 0);
assert.ok(replacementTamperResult.errors.some((error) => error.reason === 'replacement-plan-fingerprint-mismatch'));
const forgedCanonicalChange = JSON.parse(JSON.stringify(postWritePlan.changes[0]));
forgedCanonicalChange.replacement = `${forgedCanonicalChange.replacement}\n\`git push --force-with-lease=origin/patch-stack\`\n`;
forgedCanonicalChange.replacementSha256 = sha256(forgedCanonicalChange.replacement);
forgedCanonicalChange.catalogEntry = {
  role: forgedCanonicalChange.role,
  patchedDocument: forgedCanonicalChange.replacement,
  patchedSha256: forgedCanonicalChange.replacementSha256,
};
const forgedCanonicalResult = overlay.applyChangePlan(
  { changes: [forgedCanonicalChange], skipped: [], errors: [], catalogRef: postWritePlan.catalogRef, inventory: postWritePlan.inventory },
  fixtureApplyOptions({ dryRun: false }),
);
assert.equal(forgedCanonicalResult.changed, 0);
assert.ok(forgedCanonicalResult.errors.some((error) => error.reason === 'canonical-replacement-mismatch'));
const pairChange = postWritePlan.changes[0];
const pairRole = pairChange.role === 'yeet' ? 'github' : 'yeet';
const pairPath = path.join(pairChange.surfaceDirectory, 'skills', pairRole, 'SKILL.md');
const pairOriginal = fs.readFileSync(pairPath);
const pairOriginalMtimeMs = pairChange.originalMtimeMs;
fs.writeFileSync(pairPath, 'unknown pair fingerprint\n', 'utf8');
const pairFingerprintResult = overlay.applyChangePlan(
  { changes: [pairChange], skipped: [], errors: [], catalogRef: postWritePlan.catalogRef, inventory: postWritePlan.inventory },
  fixtureApplyOptions({ dryRun: false }),
);
assert.equal(pairFingerprintResult.changed, 0);
assert.ok(pairFingerprintResult.errors.some((error) => error.reason === 'canonical-pair-fingerprint-mismatch'));
fs.writeFileSync(pairPath, pairOriginal);
fs.utimesSync(pairPath, new Date(pairOriginalMtimeMs), new Date(pairOriginalMtimeMs));
assert.equal(fs.statSync(pairPath).mtimeMs, pairOriginalMtimeMs);
const casTarget = postWritePlan.changes[0].path;
fs.writeFileSync(casTarget, 'user changed before apply\n', 'utf8');
const casResult = overlay.applyChangePlan(
  { changes: [postWritePlan.changes[0]], skipped: [], errors: [], catalogRef: postWritePlan.catalogRef, inventory: postWritePlan.inventory },
  fixtureApplyOptions({ dryRun: false }),
);
assert.equal(casResult.changed, 0);
assert.ok(casResult.errors.some((error) => error.reason === 'original-cas-conflict'));
fs.writeFileSync(casTarget, postWritePlan.changes[0].original, 'utf8');
const originalMtimeMs = postWritePlan.changes[0].originalMtimeMs;
fs.utimesSync(casTarget, new Date(originalMtimeMs), new Date(originalMtimeMs));
assert.equal(fs.statSync(casTarget).mtimeMs, originalMtimeMs);
fs.utimesSync(casTarget, new Date(originalMtimeMs + 2000), new Date(originalMtimeMs + 2000));
const mtimeCasResult = overlay.applyChangePlan(postWritePlan, fixtureApplyOptions({ dryRun: true }));
assert.equal(mtimeCasResult.changed, 0);
assert.ok(mtimeCasResult.blocked);
assert.ok(mtimeCasResult.errors.some((error) => error.reason === 'original-mtime-cas-conflict'));
fs.utimesSync(casTarget, new Date(originalMtimeMs), new Date(originalMtimeMs));
assert.equal(fs.statSync(casTarget).mtimeMs, originalMtimeMs);
const postWriteFailure = overlay.applyChangePlan(postWritePlan, fixtureApplyOptions({
  dryRun: false,
  onAfterWrite: () => { throw new Error('injected post-write verification failure'); },
}));
assert.equal(postWriteFailure.status, 'rolled-back');
for (const target of postWriteDiscovery.targets) {
  assert.equal(
    sha256(fs.readFileSync(target.path)),
    sha256(fixtureUpstream[target.role].local),
    `post-write failure left a changed target: ${target.path}`,
  );
}
const manifestFailure = overlay.applyChangePlan(postWritePlan, fixtureApplyOptions({
  dryRun: false,
  failManifestUpdateAt: 3,
}));
assert.equal(manifestFailure.status, 'rolled-back');
for (const target of postWriteDiscovery.targets) {
  assert.equal(
    sha256(fs.readFileSync(target.path)),
    sha256(fixtureUpstream[target.role].local),
    `manifest failure left a changed target: ${target.path}`,
  );
}

// A concurrent actor may restore the original bytes but touch the mtime. It
// must not be treated as an already-restored entry during rollback.
const rollbackMtimeApply = overlay.applyChangePlan(postWritePlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(rollbackMtimeApply.changed, 4);
const rollbackMtimeManifest = JSON.parse(fs.readFileSync(rollbackMtimeApply.manifestPath, 'utf8'));
const rollbackMtimeEntry = rollbackMtimeManifest.entries[0];
const rollbackMtimeTarget = rollbackMtimeEntry.path;
fs.writeFileSync(rollbackMtimeTarget, postWritePlan.changes[0].original, 'utf8');
fs.utimesSync(
  rollbackMtimeTarget,
  new Date(Number(rollbackMtimeEntry.originalMtimeMs) + 2000),
  new Date(Number(rollbackMtimeEntry.originalMtimeMs) + 2000),
);
const rollbackMtimeResult = overlay.rollbackManifest(rollbackMtimeApply.manifestPath);
assert.equal(rollbackMtimeResult.status, 'unsafe-partial');
assert.ok(rollbackMtimeResult.errors.some((error) => error.reason === 'rollback-mtime-cas-conflict'));
assert.equal(
  sha256(fs.readFileSync(rollbackMtimeTarget)),
  sha256(Buffer.from(postWritePlan.changes[0].original, 'utf8')),
);
fs.utimesSync(
  rollbackMtimeTarget,
  new Date(Number(rollbackMtimeEntry.originalMtimeMs)),
  new Date(Number(rollbackMtimeEntry.originalMtimeMs)),
);
assert.equal(fs.statSync(rollbackMtimeTarget).mtimeMs, Number(rollbackMtimeEntry.originalMtimeMs));

function snapshotFiles() {
  return targets.reduce((snapshot, target) => {
    snapshot[target.path] = fs.existsSync(target.path)
      ? sha256(fs.readFileSync(target.path))
      : null;
    return snapshot;
  }, {});
}

const patchedDocuments = targets.reduce((documents, target) => {
  documents[target.path] = fs.readFileSync(target.path, 'utf8');
  return documents;
}, {});

function assertUnchanged(snapshot) {
  for (const [filePath, expected] of Object.entries(snapshot)) {
    const actual = fs.existsSync(filePath) ? sha256(fs.readFileSync(filePath)) : null;
    assert.equal(actual, expected, `失败计划不应写入 ${filePath}`);
  }
}

const unknownTarget = targets[0].path;
fs.writeFileSync(unknownTarget, 'unknown upstream content\n', 'utf8');
let unknownDiscovery = overlay.discoverTargets(fixtureRoot);
let unknownPlan = overlay.buildChangePlan(unknownDiscovery, fixtureCatalogPath);
assert.ok(unknownPlan.errors.some((error) => error.reason === 'unknown-input-fingerprint'));
const unknownSnapshot = snapshotFiles();
const unknownApply = overlay.applyChangePlan(unknownPlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(unknownApply.changed, 0);
assert.equal(unknownApply.failed, 0);
assertUnchanged(unknownSnapshot);
fs.writeFileSync(unknownTarget, patchedDocuments[unknownTarget], 'utf8');

// A stable marker alone is not proof that the file is one of our patched documents.
fs.writeFileSync(unknownTarget, '<!-- codex-github-default-branch-overlay: v1 -->\nforged\n', 'utf8');
let forgedPlan = overlay.buildChangePlan(overlay.discoverTargets(fixtureRoot), fixtureCatalogPath);
assert.ok(forgedPlan.errors.some((error) => error.reason === 'unknown-input-fingerprint'));
const forgedSnapshot = snapshotFiles();
const forgedApply = overlay.applyChangePlan(forgedPlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(forgedApply.changed, 0);
assert.equal(forgedApply.failed, 0);
assertUnchanged(forgedSnapshot);
fs.writeFileSync(unknownTarget, patchedDocuments[unknownTarget], 'utf8');

// Restore all files from the already-applied catalog documents before testing a missing pair.
for (const target of targets) {
  const role = target.role;
  const document = fs.readFileSync(target.path, 'utf8');
  const patched = fixtureCatalog.roles[role].find((entry) => entry.patchedSha256 === sha256(document));
  assert.ok(patched, `fixture 未处于可识别的 patched 状态：${target.path}`);
}

const missingPair = targets.find((target) => target.role === 'github');
fs.unlinkSync(missingPair.path);
const missingDiscovery = overlay.discoverTargets(fixtureRoot);
const missingPlan = overlay.buildChangePlan(missingDiscovery, fixtureCatalogPath);
assert.ok(
  (missingDiscovery.errors ?? []).some((error) => error.reason === 'missing-paired-skill')
    || missingPlan.errors.some((error) => error.reason === 'missing-paired-skill'),
  '缺少 github/yeet 配对 skill 时必须失败关闭',
);
const missingSnapshot = snapshotFiles();
const missingApply = overlay.applyChangePlan(missingPlan, fixtureApplyOptions({ dryRun: false }));
assert.equal(missingApply.changed, 0);
assert.equal(missingApply.failed, 0);
assertUnchanged(missingSnapshot);

// The fixture was deliberately changed in the negative cases; all other files remain intact.
fs.writeFileSync(missingPair.path, patchedDocuments[missingPair.path], 'utf8');

// The deployment script must roll back the first runtime file when the
// second file fails. This uses an isolated D: fixture, never the live runtime.
const deploymentFixtureRoot = path.join(evidenceRoot, 'deployment-fixture');
const deploymentSourceRoot = path.join(deploymentFixtureRoot, 'source');
const deploymentCodexRoot = path.join(deploymentFixtureRoot, 'codex');
const deploymentEvidenceRoot = path.join(evidenceRoot, 'deployment-evidence');
fs.rmSync(deploymentFixtureRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(deploymentSourceRoot, 'scripts'), { recursive: true });
fs.copyFileSync(
  path.join(repoRoot, 'scripts', 'Apply-GitHubDefaultBranchSkillOverlay.cjs'),
  path.join(deploymentSourceRoot, 'scripts', 'Apply-GitHubDefaultBranchSkillOverlay.cjs'),
);
fs.copyFileSync(
  path.join(repoRoot, 'scripts', 'github-default-branch-skill-overlay-catalog.json'),
  path.join(deploymentSourceRoot, 'scripts', 'github-default-branch-skill-overlay-catalog.json'),
);
const deploymentProcess = childProcess.spawnSync(
  'D:\\Codex\\tools\\PowerShell\\7.6.5\\pwsh.exe',
  [
    '-NoProfile',
    '-File',
    path.join(repoRoot, 'scripts', 'Deploy-GitHubDefaultBranchSkillOverlay.ps1'),
    '-SourceRoot', path.join(deploymentSourceRoot, 'scripts'),
    '-CodexRoot', deploymentCodexRoot,
    '-EvidenceRoot', deploymentEvidenceRoot,
    '-InjectFailureAfter', '1',
  ],
  { encoding: 'utf8', windowsHide: true },
);
assert.notEqual(deploymentProcess.status, 0, deploymentProcess.stdout || deploymentProcess.stderr);
const deploymentReport = JSON.parse(deploymentProcess.stdout.trim());
assert.equal(deploymentReport.status, 'rolled-back');
assert.equal(deploymentReport.rolledBack, true);
assert.ok(deploymentReport.manifestPath.startsWith(
  'D:\\agents\\run-evidence\\github-default-branch-skill-policy',
));
assert.equal(
  fs.existsSync(path.join(deploymentCodexRoot, 'scripts', 'Apply-GitHubDefaultBranchSkillOverlay.cjs')),
  false,
);
assert.equal(
  fs.existsSync(path.join(deploymentCodexRoot, 'scripts', 'github-default-branch-skill-overlay-catalog.json')),
  false,
);
const concurrentRollbackProcess = childProcess.spawnSync(
  'D:\\Codex\\tools\\PowerShell\\7.6.5\\pwsh.exe',
  [
    '-NoProfile',
    '-File',
    path.join(repoRoot, 'scripts', 'Deploy-GitHubDefaultBranchSkillOverlay.ps1'),
    '-SourceRoot', path.join(deploymentSourceRoot, 'scripts'),
    '-CodexRoot', deploymentCodexRoot,
    '-EvidenceRoot', path.join(evidenceRoot, 'concurrent-deployment-evidence'),
    '-InjectFailureAfter', '1',
    '-InjectConcurrentChangeBeforeRollback',
  ],
  { encoding: 'utf8', windowsHide: true },
);
assert.notEqual(concurrentRollbackProcess.status, 0, concurrentRollbackProcess.stdout || concurrentRollbackProcess.stderr);
const concurrentRollbackReport = JSON.parse(concurrentRollbackProcess.stdout.trim());
assert.equal(concurrentRollbackReport.status, 'unsafe-partial');
assert.equal(concurrentRollbackReport.rolledBack, false);
assert.match(
  fs.readFileSync(path.join(deploymentCodexRoot, 'scripts', 'Apply-GitHubDefaultBranchSkillOverlay.cjs'), 'utf8'),
  /concurrent change detected during rollback/,
);
const outsideDeployment = childProcess.spawnSync(
  'D:\\Codex\\tools\\PowerShell\\7.6.5\\pwsh.exe',
  [
    '-NoProfile',
    '-File',
    path.join(repoRoot, 'scripts', 'Deploy-GitHubDefaultBranchSkillOverlay.ps1'),
    '-SourceRoot', deploymentSourceRoot,
    '-CodexRoot', deploymentCodexRoot,
    '-EvidenceRoot', 'D:\\Codex\\.codex\\run-evidence-outside-policy',
  ],
  { encoding: 'utf8', windowsHide: true },
);
assert.notEqual(outsideDeployment.status, 0);
assert.match(outsideDeployment.stderr, /EvidenceRoot/);
assert.match(outsideDeployment.stderr, /run-evidence-outside-policy/);

console.log(JSON.stringify({ ok: true, changed: applied.changed, idempotent: idempotent.skipped, evidenceRoot }));
