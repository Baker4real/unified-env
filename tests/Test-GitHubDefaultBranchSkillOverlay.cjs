'use strict';

const assert = require('node:assert/strict');
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

assert.equal(typeof overlay.discoverTargets, 'function');
assert.equal(typeof overlay.buildChangePlan, 'function');
assert.equal(typeof overlay.applyChangePlan, 'function');
assert.equal(typeof overlay.rollbackManifest, 'function');

const codexRoot = 'D:\\Codex\\.codex';
const evidenceRoot = path.join(
  codexRoot,
  'run-evidence',
  'github-default-branch-skill-overlay-test',
);
const fixtureRoot = path.join(evidenceRoot, 'fixture-codex-root');

function removeTree(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function catalogEntries(role) {
  const entries = Array.isArray(catalog) ? catalog : catalog.roles?.[role];
  assert.ok(Array.isArray(entries), `catalog 缺少 role=${role}`);
  return entries;
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
const fixtureCatalog = JSON.parse(JSON.stringify(catalog));
for (const role of ['yeet', 'github']) {
  fixtureCatalog.roles[role][0].upstreamSha256 = sha256(fixtureUpstream[role].local);
  fixtureCatalog.roles[role][1].upstreamSha256 = sha256(fixtureUpstream[role].remote);
}
overlay.loadCatalog(fixtureCatalog);

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
  { root: 'plugins/cache/openai-curated-remote/github/0.1.8-2841cf9749ae', variant: 'remote' },
];

removeTree(evidenceRoot);
fs.mkdirSync(fixtureRoot, { recursive: true });

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
assert.equal(targets.length, 6);

const plan = overlay.buildChangePlan(discovered, fixtureCatalog);
assert.equal(plan.errors.length, 0);
assert.equal(plan.changes.length, 6);

const dryRun = overlay.applyChangePlan(plan, { dryRun: true, evidenceRoot });
assert.equal(dryRun.changed, 0);
assert.equal(dryRun.failed, 0);
assert.equal(dryRun.skipped, 0);

const applied = overlay.applyChangePlan(plan, { dryRun: false, evidenceRoot });
assert.equal(applied.changed, 6);
assert.equal(applied.failed, 0);
assert.ok(applied.evidencePaths?.length >= 6);

const secondPlan = overlay.buildChangePlan(
  overlay.discoverTargets(fixtureRoot),
  fixtureCatalog,
);
assert.equal(secondPlan.errors.length, 0);
assert.equal(secondPlan.changes.length, 0);
const idempotent = overlay.applyChangePlan(secondPlan, { dryRun: false, evidenceRoot });
assert.equal(idempotent.changed, 0);
assert.equal(idempotent.failed, 0);
assert.equal(idempotent.skipped, 6);

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
let unknownPlan = overlay.buildChangePlan(unknownDiscovery, fixtureCatalog);
assert.ok(unknownPlan.errors.some((error) => error.reason === 'unknown-input-fingerprint'));
const unknownSnapshot = snapshotFiles();
const unknownApply = overlay.applyChangePlan(unknownPlan, { dryRun: false, evidenceRoot });
assert.equal(unknownApply.changed, 0);
assert.equal(unknownApply.failed, 0);
assertUnchanged(unknownSnapshot);
fs.writeFileSync(unknownTarget, patchedDocuments[unknownTarget], 'utf8');

// A stable marker alone is not proof that the file is one of our patched documents.
fs.writeFileSync(unknownTarget, '<!-- codex-github-default-branch-overlay: v1 -->\nforged\n', 'utf8');
let forgedPlan = overlay.buildChangePlan(overlay.discoverTargets(fixtureRoot), fixtureCatalog);
assert.ok(forgedPlan.errors.some((error) => error.reason === 'unknown-input-fingerprint'));
const forgedSnapshot = snapshotFiles();
const forgedApply = overlay.applyChangePlan(forgedPlan, { dryRun: false, evidenceRoot });
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
const missingPlan = overlay.buildChangePlan(missingDiscovery, fixtureCatalog);
assert.ok(
  (missingDiscovery.errors ?? []).some((error) => error.reason === 'missing-paired-skill')
    || missingPlan.errors.some((error) => error.reason === 'missing-paired-skill'),
  '缺少 github/yeet 配对 skill 时必须失败关闭',
);
const missingSnapshot = snapshotFiles();
const missingApply = overlay.applyChangePlan(missingPlan, { dryRun: false, evidenceRoot });
assert.equal(missingApply.changed, 0);
assert.equal(missingApply.failed, 0);
assertUnchanged(missingSnapshot);

// The fixture was deliberately changed in the negative cases; all other files remain intact.
fs.writeFileSync(missingPair.path, patchedDocuments[missingPair.path], 'utf8');

console.log(JSON.stringify({ ok: true, changed: applied.changed, idempotent: idempotent.skipped, evidenceRoot }));
