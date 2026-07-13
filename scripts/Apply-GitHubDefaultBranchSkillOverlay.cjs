'use strict';

/**
 * Versioned, fail-closed overlay for the two GitHub skills whose publisher
 * workflow is being governed by the default-branch policy.  The overlay is
 * deliberately content-addressed: paths identify candidates, but a SHA-256
 * fingerprint is the only authority that permits a write.
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const EXPECTED_ROLES = Object.freeze(['github', 'yeet']);
const STABLE_MARKER = '<!-- codex-github-default-branch-overlay: v1 -->';
const DEFAULT_EVIDENCE_ROOT = 'D:\\Codex\\.codex\\run-evidence\\github-default-branch-skill-policy';
const CATALOG_VERSION = 1;

class CatalogValidationError extends Error {
  constructor(errors) {
    super(`invalid GitHub default-branch overlay catalog: ${errors.map((item) => item.message || item.reason).join('; ')}`);
    this.name = 'CatalogValidationError';
    this.errors = errors;
  }
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex').toUpperCase();
}

function sha256File(filePath) {
  return sha256(fs.readFileSync(filePath));
}

function resolveAbsolute(filePath) {
  return path.resolve(String(filePath));
}

function isWithin(root, candidate) {
  const rootPath = resolveAbsolute(root);
  const candidatePath = resolveAbsolute(candidate);
  const relative = path.relative(rootPath, candidatePath);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

function isDDrivePath(filePath) {
  const resolved = resolveAbsolute(filePath);
  return /^D:[\\/]/i.test(resolved);
}

function assertDDrivePath(filePath, label) {
  if (!isDDrivePath(filePath)) {
    throw new Error(`${label} must stay on the D: drive: ${filePath}`);
  }
}

function unique(items) {
  return [...new Set(items)];
}

function readJson(catalogOrPath) {
  if (typeof catalogOrPath === 'string') {
    return JSON.parse(fs.readFileSync(catalogOrPath, 'utf8'));
  }
  return catalogOrPath;
}

function roleEntries(catalog, role) {
  if (Array.isArray(catalog)) {
    return catalog.filter((entry) => entry && entry.role === role);
  }
  if (catalog && catalog.roles && Array.isArray(catalog.roles[role])) {
    return catalog.roles[role];
  }
  if (catalog && Array.isArray(catalog[role])) {
    return catalog[role];
  }
  return [];
}

function validateCatalog(catalogOrPath) {
  let catalog;
  try {
    catalog = readJson(catalogOrPath);
  } catch (error) {
    throw new CatalogValidationError([{ reason: 'catalog-read-failed', message: error.message }]);
  }

  const errors = [];
  if (!catalog || typeof catalog !== 'object') {
    errors.push({ reason: 'catalog-not-object', message: 'catalog must be a JSON object' });
  }
  if (catalog && catalog.version !== CATALOG_VERSION) {
    errors.push({ reason: 'unsupported-catalog-version', message: `expected catalog version ${CATALOG_VERSION}` });
  }
  if (catalog && catalog.marker !== STABLE_MARKER) {
    errors.push({ reason: 'catalog-marker-mismatch', message: 'catalog marker does not match the overlay marker' });
  }

  const roles = {};
  for (const role of EXPECTED_ROLES) {
    const entries = roleEntries(catalog, role);
    if (entries.length === 0) {
      errors.push({ role, reason: 'missing-role', message: `catalog has no entries for role ${role}` });
      roles[role] = [];
      continue;
    }
    roles[role] = [];
    const seenUpstream = new Set();
    for (const [index, entry] of entries.entries()) {
      const prefix = `roles.${role}[${index}]`;
      if (!entry || typeof entry !== 'object') {
        errors.push({ role, reason: 'invalid-entry', message: `${prefix} must be an object` });
        continue;
      }
      const upstreamSha256 = String(entry.upstreamSha256 || '').toUpperCase();
      const patchedSha256 = String(entry.patchedSha256 || '').toUpperCase();
      if (!/^[A-F0-9]{64}$/.test(upstreamSha256)) {
        errors.push({ role, reason: 'invalid-upstream-sha256', message: `${prefix}.upstreamSha256 is not a SHA-256` });
      }
      if (!/^[A-F0-9]{64}$/.test(patchedSha256)) {
        errors.push({ role, reason: 'invalid-patched-sha256', message: `${prefix}.patchedSha256 is not a SHA-256` });
      }
      if (seenUpstream.has(upstreamSha256)) {
        errors.push({ role, reason: 'duplicate-upstream-sha256', message: `${prefix}.upstreamSha256 is duplicated` });
      }
      seenUpstream.add(upstreamSha256);

      const patchedDocument = typeof entry.patchedDocument === 'string' ? entry.patchedDocument : '';
      if (!patchedDocument) {
        errors.push({ role, reason: 'missing-patched-document', message: `${prefix}.patchedDocument is empty` });
      }
      if (sha256(patchedDocument) !== patchedSha256) {
        errors.push({ role, reason: 'patched-fingerprint-mismatch', message: `${prefix}.patchedDocument does not match patchedSha256` });
      }
      if (!patchedDocument.includes(STABLE_MARKER)) {
        errors.push({ role, reason: 'missing-stable-marker', message: `${prefix}.patchedDocument has no stable marker` });
      }
      const namePattern = new RegExp(`^name:\\s*["']?${role}(?:["']?|\\s*)$`, 'mi');
      if (!namePattern.test(patchedDocument)) {
        errors.push({ role, reason: 'yaml-name-mismatch', message: `${prefix}.patchedDocument does not preserve YAML name ${role}` });
      }
      const forbidden = [
        /git\s+push[^\r\n]*patch-stack/i,
        /git\s+(?:merge-base|merge|rebase)[^\r\n]*(?:\bmain\b|\bmaster\b)/i,
        /git\s+push[^\r\n]*(?:--force|-f)(?:\s|$)/i,
        /(?:^|\s)--draft(?:\s|$)/i,
      ];
      for (const pattern of forbidden) {
        if (pattern.test(patchedDocument)) {
          errors.push({ role, reason: 'forbidden-publish-pattern', message: `${prefix}.patchedDocument contains ${pattern}` });
        }
      }
      roles[role].push({
        ...entry,
        role,
        upstreamSha256,
        patchedSha256,
        patchedDocument,
      });
    }
  }

  if (errors.length > 0) throw new CatalogValidationError(errors);
  return { ...catalog, roles };
}

function walkFiles(root, output = []) {
  if (!fs.existsSync(root)) return output;
  const stat = fs.statSync(root);
  if (!stat.isDirectory()) return output;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const candidate = path.join(root, entry.name);
    if (entry.isDirectory()) walkFiles(candidate, output);
    else if (entry.isFile() && entry.name.toLowerCase() === 'skill.md') output.push(candidate);
  }
  return output;
}

function discoverTargets(codexRoot) {
  const root = resolveAbsolute(codexRoot);
  assertDDrivePath(root, 'codexRoot');
  const roots = [
    path.join(root, '.tmp', 'plugins', 'plugins', 'github'),
    path.join(root, 'plugins', 'cache', 'openai-curated', 'github'),
    path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'github'),
  ];
  const groups = new Map();
  const errors = [];
  let foundAnySurface = false;

  for (const searchRoot of roots) {
    for (const filePath of walkFiles(searchRoot)) {
      const roleDirectory = path.basename(path.dirname(filePath));
      if (!EXPECTED_ROLES.includes(roleDirectory)) continue;
      const skillsDirectory = path.dirname(path.dirname(filePath));
      const surfaceDirectory = path.dirname(skillsDirectory);
      if (!isWithin(root, filePath)) {
        errors.push({ path: filePath, reason: 'target-outside-codex-root' });
        continue;
      }
      foundAnySurface = true;
      const key = surfaceDirectory.toLowerCase();
      if (!groups.has(key)) groups.set(key, { surfaceDirectory, roles: new Map() });
      const group = groups.get(key);
      if (group.roles.has(roleDirectory)) {
        errors.push({ path: filePath, reason: 'duplicate-role-surface' });
      } else {
        group.roles.set(roleDirectory, { path: filePath, role: roleDirectory, surfaceDirectory });
      }
    }
  }

  if (!foundAnySurface) {
    errors.push({ reason: 'no-github-skill-surfaces', message: 'no supported GitHub plugin surface was found' });
  }

  const targets = [];
  for (const group of groups.values()) {
    for (const role of EXPECTED_ROLES) {
      if (!group.roles.has(role)) {
        errors.push({
          path: path.join(group.surfaceDirectory, 'skills', role, 'SKILL.md'),
          reason: 'missing-paired-skill',
          surfaceDirectory: group.surfaceDirectory,
          role,
        });
      }
    }
    for (const target of group.roles.values()) targets.push(target);
  }

  targets.sort((left, right) => left.path.localeCompare(right.path));
  return { targets, errors };
}

function normaliseTargets(input) {
  if (Array.isArray(input)) return { targets: input, errors: [] };
  if (input && Array.isArray(input.targets)) return { targets: input.targets, errors: Array.isArray(input.errors) ? input.errors : [] };
  return { targets: [], errors: [{ reason: 'invalid-target-list', message: 'targets must be an array or discoverTargets result' }] };
}

function buildChangePlan(targetInput, catalogOrPath) {
  const discovered = normaliseTargets(targetInput);
  const errors = [...discovered.errors];
  const changes = [];
  const skipped = [];
  let catalog;
  try {
    catalog = validateCatalog(catalogOrPath);
  } catch (error) {
    const catalogErrors = error instanceof CatalogValidationError ? error.errors : [{ reason: 'catalog-invalid', message: error.message }];
    return { changes: [], skipped: [], errors: [...errors, ...catalogErrors], catalogError: true };
  }

  const seenPaths = new Set();
  for (const target of discovered.targets) {
    if (!target || typeof target.path !== 'string' || !EXPECTED_ROLES.includes(target.role)) {
      errors.push({ path: target?.path, reason: 'invalid-target', message: 'target must include a supported role and path' });
      continue;
    }
    let filePath;
    try {
      filePath = resolveAbsolute(target.path);
      assertDDrivePath(filePath, 'target path');
    } catch (error) {
      errors.push({ path: target.path, reason: 'unsafe-target-path', message: error.message });
      continue;
    }
    if (seenPaths.has(filePath.toLowerCase())) {
      errors.push({ path: filePath, reason: 'duplicate-target' });
      continue;
    }
    seenPaths.add(filePath.toLowerCase());
    if (!fs.existsSync(filePath)) {
      errors.push({ path: filePath, reason: 'missing-target' });
      continue;
    }
    const originalBytes = fs.readFileSync(filePath);
    const original = originalBytes.toString('utf8');
    const currentSha256 = sha256(originalBytes);
    const entry = catalog.roles[target.role].find((candidate) => (
      candidate.upstreamSha256 === currentSha256 || candidate.patchedSha256 === currentSha256
    ));
    if (!entry) {
      errors.push({ path: filePath, role: target.role, currentSha256, reason: 'unknown-input-fingerprint' });
      continue;
    }
    if (entry.patchedSha256 === currentSha256) {
      skipped.push({ path: filePath, role: target.role, sha256: currentSha256, reason: 'already-patched' });
      continue;
    }
    changes.push({
      ...target,
      path: filePath,
      role: target.role,
      original,
      originalBytes,
      originalSha256: currentSha256,
      replacement: entry.patchedDocument,
      replacementSha256: entry.patchedSha256,
      catalogEntry: entry,
    });
  }

  return { changes, skipped, errors };
}

function ensureDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true });
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function writeAtomic(filePath, contents) {
  const directory = path.dirname(filePath);
  ensureDirectory(directory);
  const token = `${process.pid}-${Date.now()}-${crypto.randomBytes(6).toString('hex')}`;
  const temporaryPath = path.join(directory, `.${path.basename(filePath)}.${token}.tmp`);
  let handle;
  try {
    handle = fs.openSync(temporaryPath, 'wx');
    const buffer = Buffer.isBuffer(contents) ? contents : Buffer.from(contents, 'utf8');
    fs.writeFileSync(handle, buffer);
    fs.fsyncSync(handle);
    fs.closeSync(handle);
    handle = undefined;
    fs.renameSync(temporaryPath, filePath);
  } finally {
    if (handle !== undefined) {
      try { fs.closeSync(handle); } catch { /* preserve original error */ }
    }
    if (fs.existsSync(temporaryPath)) {
      try { fs.unlinkSync(temporaryPath); } catch { /* evidence will show the failed cleanup */ }
    }
  }
}

function createEvidenceDirectory(evidenceRoot) {
  const root = resolveAbsolute(evidenceRoot || DEFAULT_EVIDENCE_ROOT);
  assertDDrivePath(root, 'evidenceRoot');
  ensureDirectory(root);
  const directory = path.join(root, `run-${new Date().toISOString().replace(/[:.]/g, '-')}-${process.pid}-${crypto.randomBytes(4).toString('hex')}`);
  ensureDirectory(directory);
  return directory;
}

function updateManifest(manifestPath, manifest) {
  writeAtomic(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

function rollbackManifest(manifestPath, options = {}) {
  const resolvedManifest = resolveAbsolute(manifestPath);
  assertDDrivePath(resolvedManifest, 'manifestPath');
  const manifest = JSON.parse(fs.readFileSync(resolvedManifest, 'utf8'));
  const errors = [];
  let restored = 0;
  let skipped = 0;
  const entries = Array.isArray(manifest.entries) ? manifest.entries : [];

  for (const entry of entries) {
    if (entry.status !== 'committed') {
      skipped += 1;
      continue;
    }
    try {
      const currentBytes = fs.readFileSync(entry.path);
      const currentSha256 = sha256(currentBytes);
      if (currentSha256 === entry.originalSha256) {
        entry.status = 'restored';
        skipped += 1;
        continue;
      }
      if (currentSha256 !== entry.replacementSha256) {
        throw new Error(`compare-and-swap conflict at ${entry.path}: expected ${entry.replacementSha256}, got ${currentSha256}`);
      }
      const backupBytes = fs.readFileSync(entry.backupPath);
      if (sha256(backupBytes) !== entry.originalSha256) {
        throw new Error(`backup fingerprint mismatch at ${entry.backupPath}`);
      }
      writeAtomic(entry.path, backupBytes);
      if (sha256File(entry.path) !== entry.originalSha256) {
        throw new Error(`restored fingerprint mismatch at ${entry.path}`);
      }
      entry.status = 'restored';
      restored += 1;
    } catch (error) {
      entry.status = 'rollback-failed';
      entry.rollbackError = error.message;
      errors.push({ path: entry.path, reason: 'rollback-failed', message: error.message });
    }
  }

  manifest.status = errors.length > 0 ? 'unsafe-partial' : 'rolled-back';
  manifest.rollback = {
    at: new Date().toISOString(),
    restored,
    skipped,
    errors,
    reason: options.reason || undefined,
  };
  try {
    updateManifest(resolvedManifest, manifest);
  } catch (error) {
    errors.push({ reason: 'manifest-update-failed', message: error.message });
    manifest.status = 'unsafe-partial';
  }
  return {
    ok: errors.length === 0,
    status: manifest.status,
    restored,
    skipped,
    failed: errors.length,
    errors,
    manifestPath: resolvedManifest,
  };
}

function applyChangePlan(plan, options = {}) {
  const safePlan = plan && typeof plan === 'object' ? plan : { changes: [], skipped: [], errors: [{ reason: 'invalid-plan' }] };
  const errors = Array.isArray(safePlan.errors) ? safePlan.errors : [];
  const planned = Array.isArray(safePlan.changes) ? safePlan.changes : [];
  const alreadySkipped = Array.isArray(safePlan.skipped) ? safePlan.skipped.length : 0;
  if (errors.length > 0) {
    return {
      ok: false,
      blocked: true,
      changed: 0,
      skipped: 0,
      failed: 0,
      errors,
      evidencePaths: [],
    };
  }
  if (options.dryRun) {
    return {
      ok: true,
      dryRun: true,
      changed: 0,
      skipped: alreadySkipped,
      planned: planned.length,
      failed: 0,
      errors: [],
      evidencePaths: [],
    };
  }
  if (planned.length === 0) {
    return { ok: true, changed: 0, skipped: alreadySkipped, failed: 0, errors: [], evidencePaths: [] };
  }

  const evidenceDirectory = createEvidenceDirectory(options.evidenceRoot || DEFAULT_EVIDENCE_ROOT);
  const manifestPath = path.join(evidenceDirectory, 'manifest.json');
  const manifest = {
    version: 1,
    status: 'prepared',
    createdAt: new Date().toISOString(),
    evidenceDirectory,
    entries: [],
  };

  try {
    // The complete backup set is committed before any target is changed.
    for (const [index, change] of planned.entries()) {
      assertDDrivePath(change.path, 'target path');
      const currentBytes = fs.readFileSync(change.path);
      const currentSha256 = sha256(currentBytes);
      if (currentSha256 !== change.originalSha256) {
        throw new Error(`compare-and-swap conflict before backup at ${change.path}`);
      }
      const backupPath = path.join(evidenceDirectory, `backup-${String(index + 1).padStart(2, '0')}-${path.basename(change.path)}`);
      fs.writeFileSync(backupPath, currentBytes);
      manifest.entries.push({
        path: change.path,
        role: change.role,
        originalSha256: change.originalSha256,
        replacementSha256: change.replacementSha256,
        backupPath,
        status: 'prepared',
      });
    }
    updateManifest(manifestPath, manifest);
    manifest.status = 'applying';
    updateManifest(manifestPath, manifest);

    let changed = 0;
    for (const [index, change] of planned.entries()) {
      const entry = manifest.entries[index];
      const currentBytes = fs.readFileSync(change.path);
      if (sha256(currentBytes) !== change.originalSha256) {
        throw new Error(`compare-and-swap conflict while applying at ${change.path}`);
      }
      if (typeof options.onBeforeWrite === 'function') options.onBeforeWrite(change, index);
      if (Number.isInteger(options.failAfter) && changed >= options.failAfter) {
        throw new Error(`injected failure after ${changed} writes`);
      }
      writeAtomic(change.path, Buffer.from(change.replacement, 'utf8'));
      if (sha256File(change.path) !== change.replacementSha256) {
        throw new Error(`replacement fingerprint mismatch at ${change.path}`);
      }
      entry.status = 'committed';
      entry.committedAt = new Date().toISOString();
      changed += 1;
      updateManifest(manifestPath, manifest);
    }
    manifest.status = 'succeeded';
    manifest.completedAt = new Date().toISOString();
    updateManifest(manifestPath, manifest);
    return {
      ok: true,
      changed,
      skipped: alreadySkipped,
      failed: 0,
      errors: [],
      manifestPath,
      evidencePaths: [manifestPath, ...manifest.entries.map((entry) => entry.backupPath)],
    };
  } catch (error) {
    manifest.status = 'apply-failed';
    manifest.error = error.message;
    try { updateManifest(manifestPath, manifest); } catch { /* rollback result remains authoritative */ }
    let rollback = {
      status: 'unsafe-partial',
      errors: [{ reason: 'manifest-unavailable', message: 'rollback manifest was not created before the failure' }],
    };
    if (fs.existsSync(manifestPath)) {
      rollback = rollbackManifest(manifestPath, { reason: error.message });
    } else if (manifest.entries.length === 0) {
      rollback = { status: 'rolled-back', errors: [] };
    }
    return {
      ok: false,
      status: rollback.status,
      changed: 0,
      skipped: alreadySkipped,
      failed: 1,
      errors: [{ reason: 'apply-failed', message: error.message }, ...rollback.errors],
      manifestPath,
      evidencePaths: [manifestPath, ...manifest.entries.map((entry) => entry.backupPath)],
    };
  }
}

function loadCatalog(catalogOrPath) {
  return validateCatalog(catalogOrPath);
}

module.exports = {
  STABLE_MARKER,
  DEFAULT_EVIDENCE_ROOT,
  sha256,
  loadCatalog,
  discoverTargets,
  buildChangePlan,
  applyChangePlan,
  rollbackManifest,
};

if (require.main === module) {
  const codexRoot = process.argv[2] || 'D:\\Codex\\.codex';
  const catalogPath = process.argv[3] || path.join(__dirname, 'github-default-branch-skill-overlay-catalog.json');
  const discovered = discoverTargets(codexRoot);
  const plan = buildChangePlan(discovered, catalogPath);
  const report = applyChangePlan(plan, { dryRun: process.argv.includes('--dry-run') });
  console.log(JSON.stringify({ discovered, plan: { changes: plan.changes.length, skipped: plan.skipped.length, errors: plan.errors }, report }, null, 2));
  process.exitCode = report.ok ? 0 : 1;
}
