'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

// This cleanup entry point intentionally has no CODEX_ROOT/CODEX_PARENT
// override. Production is anchored to fixed host roots. A test may use a
// separately gated fixture root, but cannot redirect a production invocation.
const PRODUCTION_CODEX_ROOT = path.resolve('D:\\Codex\\.codex');
// The retirement ledger lives in the unified physical skills root; the
// Codex-side skills junction is never traversed.
const PRODUCTION_ACTIVE_SKILLS_ROOT = path.resolve('D:\\agents\\skills-manager\\skills');
const FIXTURE_PARENT = path.resolve('D:\\agents\\projects\\统一环境');
const FIXTURE_PREFIX = '.tmp-retired-skill-backup-fixture-';
const FIXTURE_MARKER_NAME = '.retired-skill-backup-fixture.json';
const FIXTURE_MARKER = Object.freeze({
  kind: 'retired-skill-backup-purger-fixture',
  version: 1,
});

// Production targets are deliberately empty. The former broad backup scan was
// removed: a real retired payload must first be added here as an exact,
// reviewed, version-controlled target with a matching marker contract.
const RETIRED_PAYLOAD_TARGET_MANIFEST = Object.freeze({
  version: 1,
  targets: Object.freeze([]),
});

// This separate, fixed fixture manifest exercises the same exact-target path
// without granting tests any way to nominate an arbitrary directory.
const FIXTURE_PAYLOAD_TARGET_MANIFEST = Object.freeze({
  version: 1,
  targets: Object.freeze([
    Object.freeze({
      id: 'fixture-retired-hyperframes-backup',
      relativePath: 'payload/retired-hyperframes-backup',
      markerName: '.retired-skill-backup-payload.json',
      marker: Object.freeze({
        kind: 'retired-skill-backup-payload',
        version: 1,
        targetId: 'fixture-retired-hyperframes-backup',
      }),
    }),
  ]),
});

function fail(message) {
  throw new Error(message);
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeComparablePath(value) {
  let normalized = path.normalize(value);
  if (normalized.startsWith('\\\\?\\')) normalized = normalized.slice(4);
  normalized = normalized.replace(/[\\/]+$/, '');
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized;
}

function isInside(child, parent) {
  const relative = path.relative(normalizeComparablePath(parent), normalizeComparablePath(child));
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function isReparsePoint(stat) {
  // Node reports Windows junctions and symbolic links as symbolic links via
  // lstat. Every checked path is also realpath-contained below, so a future
  // platform-specific reparse representation still fails closed on escape.
  return stat.isSymbolicLink();
}

function lstatOrNull(target) {
  try {
    return fs.lstatSync(target);
  } catch (error) {
    if (error && (error.code === 'ENOENT' || error.code === 'ENOTDIR')) return null;
    throw error;
  }
}

function lstatRequired(target, label) {
  const stat = lstatOrNull(target);
  if (!stat) fail(`${label} is missing: ${target}`);
  if (isReparsePoint(stat)) fail(`${label} is a reparse point: ${target}`);
  return stat;
}

function realpathRequired(target, label) {
  try {
    return fs.realpathSync.native(target);
  } catch (error) {
    fail(`${label} cannot be resolved safely: ${target} (${error.code || error.message})`);
  }
}

function statSignature(stat) {
  return [stat.dev, stat.ino, stat.mode, stat.size, stat.mtimeMs, stat.ctimeMs].join(':');
}

function assertPhysicalPathWithin(root, target, expectedType, label) {
  const rootPath = path.resolve(root);
  const targetPath = path.resolve(target);
  if (!isInside(targetPath, rootPath)) fail(`${label} escapes approved root: ${targetPath}`);

  const rootStat = lstatRequired(rootPath, 'approved root');
  if (!rootStat.isDirectory()) fail(`approved root is not a directory: ${rootPath}`);
  const canonicalRoot = realpathRequired(rootPath, 'approved root');
  const parts = path.relative(rootPath, targetPath).split(/[\\/]+/).filter(Boolean);
  let current = rootPath;

  if (!isInside(canonicalRoot, canonicalRoot)) fail(`approved root cannot be contained: ${rootPath}`);
  if (parts.length === 0) {
    if (expectedType === 'directory' && !rootStat.isDirectory()) fail(`${label} is not a directory: ${targetPath}`);
    if (expectedType === 'file' && !rootStat.isFile()) fail(`${label} is not a regular file: ${targetPath}`);
    return { path: targetPath, stat: rootStat, realpath: canonicalRoot };
  }

  for (let index = 0; index < parts.length; index += 1) {
    current = path.join(current, parts[index]);
    const stat = lstatRequired(current, label);
    const canonicalCurrent = realpathRequired(current, label);
    if (!isInside(canonicalCurrent, canonicalRoot)) {
      fail(`${label} resolves outside approved root: ${current}`);
    }
    if (index < parts.length - 1 && !stat.isDirectory()) {
      fail(`${label} has a non-directory ancestor: ${current}`);
    }
    if (index === parts.length - 1) {
      if (expectedType === 'directory' && !stat.isDirectory()) fail(`${label} is not a directory: ${current}`);
      if (expectedType === 'file' && !stat.isFile()) fail(`${label} is not a regular file: ${current}`);
      return { path: targetPath, stat, realpath: canonicalCurrent };
    }
  }

  fail(`${label} path traversal failed: ${targetPath}`);
}

function assertPhysicalTreeWithin(root, directory, label) {
  assertPhysicalPathWithin(root, directory, 'directory', label);
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  for (const entry of entries) {
    const child = path.join(directory, entry.name);
    const childInfo = assertPhysicalPathWithin(root, child, null, label);
    if (childInfo.stat.isDirectory()) assertPhysicalTreeWithin(root, child, label);
    else if (!childInfo.stat.isFile()) fail(`${label} contains an unsupported filesystem entry: ${child}`);
  }
}

function readPhysicalFile(root, target, label) {
  const before = assertPhysicalPathWithin(root, target, 'file', label);
  const raw = fs.readFileSync(before.path, 'utf8');
  const after = assertPhysicalPathWithin(root, target, 'file', label);
  if (statSignature(before.stat) !== statSignature(after.stat)) {
    fail(`${label} changed while being read: ${target}`);
  }
  return {
    path: after.path,
    raw,
    sha256: crypto.createHash('sha256').update(raw, 'utf8').digest('hex'),
  };
}

function readPhysicalJson(root, target, label) {
  const file = readPhysicalFile(root, target, label);
  try {
    return { ...file, value: JSON.parse(file.raw) };
  } catch (error) {
    fail(`${label} is not valid JSON: ${target} (${error.message})`);
  }
}

function parseArgs(argv) {
  let applyMode = false;
  let dryRun = false;
  let fixtureRoot = null;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--apply') {
      applyMode = true;
    } else if (arg === '--dry-run') {
      dryRun = true;
    } else if (arg === '--fixture-root') {
      if (fixtureRoot !== null || index + 1 >= argv.length) fail('--fixture-root requires exactly one path');
      fixtureRoot = argv[index + 1];
      index += 1;
    } else {
      fail(`unsupported argument: ${arg}`);
    }
  }
  return { applyMode, dryRun: !applyMode || dryRun, fixtureRoot };
}

function sameJsonShape(actual, expected) {
  return JSON.stringify(actual) === JSON.stringify(expected);
}

function validateTargetManifest(manifest, label) {
  if (!manifest || manifest.version !== 1 || !Array.isArray(manifest.targets)) {
    fail(`${label} is not a supported target manifest`);
  }
  const ids = new Set();
  for (const target of manifest.targets) {
    if (!target || typeof target.id !== 'string' || !target.id || ids.has(target.id)) {
      fail(`${label} has a missing or duplicate target id`);
    }
    ids.add(target.id);
    if (typeof target.relativePath !== 'string' || !target.relativePath || path.isAbsolute(target.relativePath)) {
      fail(`${label} target ${target.id} has an unsafe relative path`);
    }
    const segments = target.relativePath.split(/[\\/]+/);
    if (segments.some((segment) => !segment || segment === '.' || segment === '..')) {
      fail(`${label} target ${target.id} has an unsafe relative path`);
    }
    if (typeof target.markerName !== 'string' || path.basename(target.markerName) !== target.markerName) {
      fail(`${label} target ${target.id} has an unsafe marker name`);
    }
    if (!target.marker || typeof target.marker !== 'object' || Array.isArray(target.marker)) {
      fail(`${label} target ${target.id} has no marker contract`);
    }
  }
}

function assertPhysicalRoot(root, label) {
  assertPhysicalPathWithin(root, root, 'directory', label);
  if (normalizeComparablePath(realpathRequired(root, label)) !== normalizeComparablePath(root)) {
    fail(`${label} resolves through a reparse point: ${root}`);
  }
  return root;
}

function resolveContext(args) {
  validateTargetManifest(RETIRED_PAYLOAD_TARGET_MANIFEST, 'production target manifest');
  validateTargetManifest(FIXTURE_PAYLOAD_TARGET_MANIFEST, 'fixture target manifest');

  if (args.fixtureRoot === null) {
    assertPhysicalPathWithin(PRODUCTION_CODEX_ROOT, PRODUCTION_CODEX_ROOT, 'directory', 'production Codex root');
    return {
      kind: 'production',
      root: PRODUCTION_CODEX_ROOT,
      activeSkillsRoot: assertPhysicalRoot(PRODUCTION_ACTIVE_SKILLS_ROOT, 'production active skills root'),
      payloadTargetManifest: RETIRED_PAYLOAD_TARGET_MANIFEST,
    };
  }

  if (process.env.TEST_MODE !== '1') fail('fixture mode requires TEST_MODE=1');
  if (!path.isAbsolute(args.fixtureRoot)) fail('fixture root must be an absolute path');
  const root = path.resolve(args.fixtureRoot);
  if (path.dirname(root).toLowerCase() !== FIXTURE_PARENT.toLowerCase()) {
    fail(`fixture root must be a direct child of ${FIXTURE_PARENT}`);
  }
  if (!path.basename(root).startsWith(FIXTURE_PREFIX)) {
    fail(`fixture root must start with ${FIXTURE_PREFIX}`);
  }
  assertPhysicalPathWithin(FIXTURE_PARENT, FIXTURE_PARENT, 'directory', 'fixture parent');
  assertPhysicalPathWithin(FIXTURE_PARENT, root, 'directory', 'fixture root');
  const markerPath = path.join(root, FIXTURE_MARKER_NAME);
  const marker = readPhysicalJson(root, markerPath, 'fixture marker').value;
  if (!sameJsonShape(marker, FIXTURE_MARKER)) fail(`fixture marker does not match ${FIXTURE_MARKER_NAME}`);
  return {
    kind: 'fixture',
    root,
    activeSkillsRoot: assertPhysicalRoot(path.join(root, 'skills-manager', 'skills'), 'fixture active skills root'),
    payloadTargetManifest: FIXTURE_PAYLOAD_TARGET_MANIFEST,
  };
}

function ledgerPathFor(context) {
  return path.join(context.activeSkillsRoot, '.downloaded-skills-source-state.json');
}

function readLedger(context) {
  const file = readPhysicalJson(context.activeSkillsRoot, ledgerPathFor(context), 'retired skill ledger');
  return { ...file, ledger: file.value };
}

function isUserRetired(record) {
  return Boolean(record && record.status === 'deleted-by-user');
}

function collectRetiredRecords(ledger) {
  const retiredSourceIds = new Set(
    asArray(ledger.sources)
      .filter((source) => isUserRetired(source) && typeof source.id === 'string')
      .map((source) => source.id),
  );
  const records = [];
  const add = (record, scope, source) => {
    if (!record || typeof record !== 'object') return;
    records.push({ record, scope, source, name: typeof record.name === 'string' ? record.name : null });
  };

  for (const source of asArray(ledger.sources)) {
    if (!source || typeof source !== 'object') continue;
    const sourceId = typeof source.id === 'string' ? source.id : null;
    const sourceRetired = isUserRetired(source);
    if (sourceRetired) add(source, 'source', sourceId);
    for (const row of asArray(source.deleted_skills)) {
      if (sourceRetired || isUserRetired(row)) add(row, 'deleted_skills', sourceId);
    }
  }
  for (const row of asArray(ledger.deleted)) {
    if (isUserRetired(row) || (row && retiredSourceIds.has(row.source))) {
      add(row, 'deleted', typeof row.source === 'string' ? row.source : null);
    }
  }
  return records;
}

function entryExistsWithoutFollowingLeaf(value) {
  if (typeof value !== 'string' || !value.trim()) return false;
  return lstatOrNull(value.trim()) !== null;
}

function isStaleBackupCleanupManifest(value) {
  return value !== null && value !== undefined && !entryExistsWithoutFollowingLeaf(value);
}

function manifestFinding(reference) {
  return {
    scope: reference.scope,
    source: reference.source,
    name: reference.name,
    manifest: reference.record.backup_cleanup_manifest,
  };
}

function collectStaleBackupCleanupManifests(retiredRecords) {
  return retiredRecords
    .filter((reference) => isStaleBackupCleanupManifest(reference.record.backup_cleanup_manifest))
    .map(manifestFinding);
}

function clearStaleBackupCleanupManifests(retiredRecords) {
  const cleared = [];
  for (const reference of retiredRecords) {
    if (!isStaleBackupCleanupManifest(reference.record.backup_cleanup_manifest)) continue;
    const manifest = reference.record.backup_cleanup_manifest;
    // Do not mutate any provenance/reason/back-up fields. This script's only
    // ledger write is to clear a stale cleanup-manifest reference on a retired row.
    reference.record.backup_cleanup_manifest = null;
    cleared.push({ ...manifestFinding(reference), manifest });
  }
  return cleared;
}

function targetPathFor(context, target) {
  const targetPath = path.resolve(context.root, target.relativePath);
  if (!isInside(targetPath, context.root)) fail(`target manifest escapes cleanup root: ${target.id}`);
  return targetPath;
}

function verifyPayloadTarget(context, target, targetPath = targetPathFor(context, target)) {
  assertPhysicalPathWithin(context.root, targetPath, 'directory', `payload target ${target.id}`);
  const markerPath = path.join(targetPath, target.markerName);
  const marker = readPhysicalJson(context.root, markerPath, `payload target marker ${target.id}`).value;
  if (!sameJsonShape(marker, target.marker)) fail(`payload target marker does not match allowlist contract: ${target.id}`);
  assertPhysicalTreeWithin(context.root, targetPath, `payload target ${target.id}`);
  return targetPath;
}

function quarantinePrefixFor(targetPath) {
  return `.${path.basename(targetPath)}.retired-skill-purge-`;
}

function collectResidualQuarantines(context, target, targetPath) {
  const parent = path.dirname(targetPath);
  if (!lstatOrNull(parent)) return [];
  const prefix = quarantinePrefixFor(targetPath);
  try {
    assertPhysicalPathWithin(context.root, parent, 'directory', `payload target parent ${target.id}`);
    return fs.readdirSync(parent, { withFileTypes: true })
      .filter((entry) => entry.name.startsWith(prefix))
      .map((entry) => {
        const directory = path.join(parent, entry.name);
        try {
          assertPhysicalPathWithin(context.root, directory, null, `residual payload quarantine ${target.id}`);
          return {
            id: target.id,
            directory,
            reason: 'a prior exact-target purge quarantine remains; inspect it before retrying cleanup',
          };
        } catch (error) {
          return {
            id: target.id,
            directory,
            reason: `residual payload quarantine is unsafe: ${error.message}`,
          };
        }
      });
  } catch (error) {
    return [{
      id: target.id,
      directory: parent,
      reason: `cannot inspect residual payload quarantine safely: ${error.message}`,
    }];
  }
}

function collectPayloadCandidates(context) {
  const candidates = [];
  const blocked = [];
  for (const target of context.payloadTargetManifest.targets) {
    const targetPath = targetPathFor(context, target);
    blocked.push(...collectResidualQuarantines(context, target, targetPath));
    if (!lstatOrNull(targetPath)) continue;
    try {
      verifyPayloadTarget(context, target, targetPath);
      candidates.push({
        id: target.id,
        directory: targetPath,
        type: 'exact-retired-payload-target',
      });
    } catch (error) {
      blocked.push({
        id: target.id,
        directory: targetPath,
        reason: error.message,
      });
    }
  }
  return { candidates, blocked };
}

function nextQuarantinePath(parent, baseName) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const suffix = crypto.randomBytes(10).toString('hex');
    const candidate = path.join(parent, `${quarantinePrefixFor(path.join(parent, baseName))}${process.pid}-${suffix}`);
    if (!lstatOrNull(candidate)) return candidate;
  }
  fail(`unable to reserve a cleanup quarantine path under ${parent}`);
}

function removePayloadCandidate(context, candidate) {
  const target = context.payloadTargetManifest.targets.find((item) => item.id === candidate.id);
  if (!target) fail(`candidate is not in the exact payload allowlist: ${candidate.id}`);

  // Re-validate the full physical tree immediately before moving it out of its
  // live location. A replacement at the original path after this rename is not
  // followed by the purge operation.
  const targetPath = verifyPayloadTarget(context, target, candidate.directory);
  const parent = path.dirname(targetPath);
  assertPhysicalPathWithin(context.root, parent, 'directory', `payload target parent ${target.id}`);
  const quarantine = nextQuarantinePath(parent, path.basename(targetPath));
  fs.renameSync(targetPath, quarantine);
  try {
    // Re-check after the atomic same-volume move before recursively removing.
    verifyPayloadTarget(context, target, quarantine);
    fs.rmSync(quarantine, { recursive: true, force: false, maxRetries: 3 });
  } catch (error) {
    // Never continue to ledger mutation after a failed payload purge. Any
    // unsafe or partially deleted quarantine remains an explicit blocked audit
    // finding rather than silently becoming an untracked backup; do not race
    // to move it back over a path that may have been recreated concurrently.
    throw error;
  }
  if (lstatOrNull(quarantine)) fail(`payload quarantine remains after deletion: ${quarantine}`);
  return { ...candidate, directory: targetPath };
}

function serializeLedger(ledger, originalRaw) {
  const eol = originalRaw.includes('\r\n') ? '\r\n' : '\n';
  return `${JSON.stringify(ledger, null, 2)}\n`.replace(/\n/g, eol);
}

function writeLedgerAtomically(context, original, ledger) {
  const ledgerPath = ledgerPathFor(context);
  const parent = path.dirname(ledgerPath);
  assertPhysicalPathWithin(context.activeSkillsRoot, parent, 'directory', 'retired skill ledger parent');
  const content = serializeLedger(ledger, original.raw);
  const tempPath = path.join(parent, `.${path.basename(ledgerPath)}.retired-skill-purge-${process.pid}-${crypto.randomBytes(10).toString('hex')}.tmp`);
  let tempCreated = false;
  try {
    // Compare-and-swap protection: no stale snapshot may overwrite a concurrent
    // ledger update, and each read/write boundary rechecks physical containment.
    const current = readPhysicalFile(context.activeSkillsRoot, ledgerPath, 'retired skill ledger');
    if (current.sha256 !== original.sha256) fail('retired skill ledger changed before cleanup apply');
    const fd = fs.openSync(tempPath, 'wx', 0o600);
    tempCreated = true;
    try {
      fs.writeFileSync(fd, content, 'utf8');
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    assertPhysicalPathWithin(context.activeSkillsRoot, tempPath, 'file', 'retired skill ledger temporary file');
    const beforeReplace = readPhysicalFile(context.activeSkillsRoot, ledgerPath, 'retired skill ledger');
    if (beforeReplace.sha256 !== original.sha256) fail('retired skill ledger changed before atomic replacement');
    fs.renameSync(tempPath, ledgerPath);
    tempCreated = false;
    const written = readPhysicalFile(context.activeSkillsRoot, ledgerPath, 'retired skill ledger');
    if (written.sha256 !== crypto.createHash('sha256').update(content, 'utf8').digest('hex')) {
      fail('retired skill ledger atomic replacement did not preserve expected content');
    }
  } finally {
    if (tempCreated && lstatOrNull(tempPath)) {
      const tempInfo = assertPhysicalPathWithin(context.activeSkillsRoot, tempPath, 'file', 'retired skill ledger temporary file');
      if (tempInfo.stat.isFile()) fs.unlinkSync(tempPath);
    }
  }
}

function run(args) {
  const context = resolveContext(args);
  const initialLedger = readLedger(context);
  const retiredRecords = collectRetiredRecords(initialLedger.ledger);
  const staleBackupCleanupManifests = collectStaleBackupCleanupManifests(retiredRecords);
  const payloadScan = collectPayloadCandidates(context);
  let removed = [];
  let clearedBackupCleanupManifests = [];
  let remainingStaleBackupCleanupManifests = staleBackupCleanupManifests;

  if (args.applyMode && !args.dryRun && payloadScan.blocked.length === 0) {
    removed = payloadScan.candidates.map((candidate) => removePayloadCandidate(context, candidate));

    // Re-read after payload work and only then mutate the exact stale fields.
    const currentLedger = readLedger(context);
    const currentRetiredRecords = collectRetiredRecords(currentLedger.ledger);
    clearedBackupCleanupManifests = clearStaleBackupCleanupManifests(currentRetiredRecords);
    if (clearedBackupCleanupManifests.length > 0) {
      writeLedgerAtomically(context, currentLedger, currentLedger.ledger);
    }
    const finalLedger = readLedger(context);
    remainingStaleBackupCleanupManifests = collectStaleBackupCleanupManifests(
      collectRetiredRecords(finalLedger.ledger),
    );
  }

  return {
    mode: args.applyMode ? 'apply' : 'audit',
    dryRun: args.dryRun,
    executionRoot: context.kind,
    backupPolicy: 'no-local-retired-skill-backups',
    payloadTargetManifestVersion: context.payloadTargetManifest.version,
    payloadTargetManifestCount: context.payloadTargetManifest.targets.length,
    retiredRecordCount: retiredRecords.length,
    candidateCount: payloadScan.candidates.length,
    candidates: payloadScan.candidates,
    blockedPayloadTargetCount: payloadScan.blocked.length,
    blockedPayloadTargets: payloadScan.blocked,
    removed,
    staleBackupCleanupManifestCount: staleBackupCleanupManifests.length,
    staleBackupCleanupManifests,
    clearedBackupCleanupManifestCount: clearedBackupCleanupManifests.length,
    clearedBackupCleanupManifests,
    remainingStaleBackupCleanupManifestCount: remainingStaleBackupCleanupManifests.length,
    remainingStaleBackupCleanupManifests,
  };
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    const result = run(args);
    console.log(JSON.stringify(result, null, 2));
    if (
      result.blockedPayloadTargetCount > 0
      || result.remainingStaleBackupCleanupManifestCount > 0
      || (result.dryRun && result.candidateCount > 0)
    ) {
      process.exitCode = 1;
    }
  } catch (error) {
    console.log(JSON.stringify({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }, null, 2));
    process.exitCode = 1;
  }
}

if (require.main === module) main();
