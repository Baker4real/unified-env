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
const CODEX_ROOT = 'D:\\Codex\\.codex';
const CONTROLLED_EVIDENCE_ROOT = DEFAULT_EVIDENCE_ROOT;
const CATALOG_VERSION = 1;
const EXPECTED_SURFACE_RELATIVES = Object.freeze([
  '.tmp/plugins/plugins/github',
  'plugins/cache/openai-curated/github/27126220',
  'plugins/cache/openai-curated-remote/github/0.1.8-2841cf9749ae',
]);
const EXPECTED_SURFACE_COUNT = EXPECTED_SURFACE_RELATIVES.length;
const EXPECTED_TARGET_COUNT = EXPECTED_SURFACE_COUNT * EXPECTED_ROLES.length;

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

function mtimeFingerprint(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.trunc(number) : Number.NaN;
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

function isControlledEvidencePath(filePath) {
  return isWithin(CONTROLLED_EVIDENCE_ROOT, filePath);
}

function assertControlledEvidencePath(filePath, label) {
  assertDDrivePath(filePath, label);
  if (!isControlledEvidencePath(filePath)) {
    throw new Error(`${label} must stay under ${CONTROLLED_EVIDENCE_ROOT}: ${filePath}`);
  }
}

function normaliseRelativePath(relativePath) {
  return String(relativePath).replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/+$/, '').toLowerCase();
}

function expectedSurfaceRelative(codexRoot, surfaceDirectory) {
  const relative = path.relative(resolveAbsolute(codexRoot), resolveAbsolute(surfaceDirectory));
  const normalised = normaliseRelativePath(relative);
  return EXPECTED_SURFACE_RELATIVES.find((candidate) => normaliseRelativePath(candidate) === normalised) || null;
}

function expectedSurfaceDirectories(codexRoot) {
  const root = resolveAbsolute(codexRoot);
  return EXPECTED_SURFACE_RELATIVES.map((relative) => ({
    relative,
    directory: path.join(root, ...relative.split('/')),
  }));
}

function supportedPluginSurface(filePath, codexRoot = CODEX_ROOT) {
  const resolved = resolveAbsolute(filePath);
  const rootBase = resolveAbsolute(codexRoot);
  const roots = expectedSurfaceDirectories(rootBase).map(({ directory }) => ({
    root: directory,
    relativePattern: /^skills\\(github|yeet)\\SKILL\.md$/i,
  }));
  for (const descriptor of roots) {
    if (!isWithin(descriptor.root, resolved)) continue;
    const relative = path.relative(descriptor.root, resolved).replace(/\//g, '\\');
    const match = relative.match(descriptor.relativePattern);
    if (match && expectedSurfaceRelative(rootBase, descriptor.root)) {
      const role = match[1].toLowerCase();
      return {
        root: descriptor.root,
        role,
        surfaceDirectory: path.dirname(path.dirname(path.dirname(resolved))),
      };
    }
  }
  return null;
}

function isAllowedCodexRoot(codexRoot) {
  const resolved = resolveAbsolute(codexRoot);
  return resolved.toLowerCase() === CODEX_ROOT.toLowerCase()
    || isWithin(CONTROLLED_EVIDENCE_ROOT, resolved);
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
        /git\s+push[^\r\n]*(?:--force(?:-[A-Za-z0-9-]+)?|-f)(?:\s|=|$)/i,
        /git\s+branch[^\r\n]*patch-stack\b/i,
        /git\s+(?:switch|checkout)\s+(?:-(?:b|c)|--create|--branch)\s+patch-stack\b/i,
        /git\s+worktree\s+add[^\r\n]*patch-stack\b/i,
        /refs\/heads\/patch-stack\b/i,
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

function normalizedCatalogPayload(catalog) {
  const metadata = {};
  for (const key of Object.keys(catalog).filter((key) => key !== 'roles').sort()) {
    metadata[key] = catalog[key];
  }
  return {
    ...metadata,
    roles: Object.fromEntries(EXPECTED_ROLES.map((role) => [
      role,
      catalog.roles[role].map((entry) => ({
        upstreamSha256: entry.upstreamSha256,
        patchedSha256: entry.patchedSha256,
        patchedDocument: entry.patchedDocument,
      })),
    ])),
  };
}

function normalizedCatalogDigest(catalog) {
  return sha256(JSON.stringify(normalizedCatalogPayload(catalog)));
}

function catalogReference(catalogOrPath, validatedCatalog) {
  if (typeof catalogOrPath === 'string') {
    const catalogPath = resolveAbsolute(catalogOrPath);
    const rawSha256 = sha256(fs.readFileSync(catalogPath));
    return {
      path: catalogPath,
      rawSha256,
      normalizedSha256: normalizedCatalogDigest(validatedCatalog),
      sha256: rawSha256,
    };
  }
  return {
    path: null,
    rawSha256: null,
    normalizedSha256: normalizedCatalogDigest(validatedCatalog),
    sha256: normalizedCatalogDigest(validatedCatalog),
  };
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

function discoverSurfaceCandidates(codexRoot) {
  const root = resolveAbsolute(codexRoot);
  const candidates = expectedSurfaceDirectories(root).map((descriptor) => ({
    directory: descriptor.directory,
    relative: descriptor.relative,
    expected: true,
  }));
  const parentDescriptors = [
    { parent: path.join(root, '.tmp', 'plugins', 'plugins'), includeChildren: true },
    { parent: path.join(root, 'plugins', 'cache', 'openai-curated', 'github'), includeChildren: true },
    { parent: path.join(root, 'plugins', 'cache', 'openai-curated-remote', 'github'), includeChildren: true },
  ];
  for (const descriptor of parentDescriptors) {
    if (!fs.existsSync(descriptor.parent) || !fs.statSync(descriptor.parent).isDirectory()) continue;
    for (const entry of fs.readdirSync(descriptor.parent, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const directory = path.join(descriptor.parent, entry.name);
      const githubSkill = path.join(directory, 'skills', 'github', 'SKILL.md');
      const yeetSkill = path.join(directory, 'skills', 'yeet', 'SKILL.md');
      if (!fs.existsSync(githubSkill) && !fs.existsSync(yeetSkill)) continue;
      const relative = path.relative(root, directory).replace(/\\/g, '/');
      candidates.push({
        directory,
        relative,
        expected: Boolean(expectedSurfaceRelative(root, directory)),
      });
    }
  }
  const seen = new Set();
  return candidates.filter((candidate) => {
    const key = candidate.directory.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function discoverTargets(codexRoot) {
  const root = resolveAbsolute(codexRoot);
  assertDDrivePath(root, 'codexRoot');
  const groups = new Map();
  const errors = [];
  let foundAnySurface = false;
  const surfaceCandidates = discoverSurfaceCandidates(root);

  for (const candidate of surfaceCandidates) {
    const surfaceDirectory = candidate.directory;
    const expected = candidate.expected;
    const existingRoles = EXPECTED_ROLES.filter((role) => (
      fs.existsSync(path.join(surfaceDirectory, 'skills', role, 'SKILL.md'))
    ));
    if (!expected) {
      errors.push({
        path: surfaceDirectory,
        relative: candidate.relative,
        reason: 'unexpected-plugin-surface',
        message: `surface is not in the exact catalog: ${candidate.relative}`,
      });
      continue;
    }
    if (!fs.existsSync(surfaceDirectory) || !fs.statSync(surfaceDirectory).isDirectory()) {
      errors.push({
        path: surfaceDirectory,
        relative: candidate.relative,
        reason: 'missing-plugin-surface',
        message: `expected GitHub plugin surface is missing: ${candidate.relative}`,
      });
      continue;
    }
    if (existingRoles.length > 0) foundAnySurface = true;
    const key = surfaceDirectory.toLowerCase();
    if (!groups.has(key)) groups.set(key, { surfaceDirectory, roles: new Map() });
    const group = groups.get(key);
    for (const role of existingRoles) {
      const filePath = path.join(surfaceDirectory, 'skills', role, 'SKILL.md');
      if (!isWithin(root, filePath)) {
        errors.push({ path: filePath, reason: 'target-outside-codex-root' });
      } else if (group.roles.has(role)) {
        errors.push({ path: filePath, reason: 'duplicate-role-surface' });
      } else {
        group.roles.set(role, { path: filePath, role, surfaceDirectory, codexRoot: root });
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

  if (surfaceCandidates.length !== EXPECTED_SURFACE_COUNT || groups.size !== EXPECTED_SURFACE_COUNT) {
    errors.push({
      reason: 'unexpected-surface-count',
      expected: EXPECTED_SURFACE_COUNT,
      actual: surfaceCandidates.length,
      grouped: groups.size,
      message: `expected exactly ${EXPECTED_SURFACE_COUNT} GitHub plugin surfaces, found ${surfaceCandidates.length}`,
    });
  }
  if (targets.length !== EXPECTED_TARGET_COUNT) {
    errors.push({
      reason: 'unexpected-target-count',
      expected: EXPECTED_TARGET_COUNT,
      actual: targets.length,
      message: `expected exactly ${EXPECTED_TARGET_COUNT} GitHub plugin targets, found ${targets.length}`,
    });
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
  if (discovered.targets.length !== EXPECTED_TARGET_COUNT
    && !errors.some((error) => error.reason === 'unexpected-target-count')) {
    errors.push({
      reason: 'unexpected-target-count',
      expected: EXPECTED_TARGET_COUNT,
      actual: discovered.targets.length,
      message: `expected exactly ${EXPECTED_TARGET_COUNT} GitHub plugin targets, found ${discovered.targets.length}`,
    });
  }
  let catalog;
  try {
    catalog = validateCatalog(catalogOrPath);
  } catch (error) {
    const catalogErrors = error instanceof CatalogValidationError ? error.errors : [{ reason: 'catalog-invalid', message: error.message }];
    return { changes: [], skipped: [], errors: [...errors, ...catalogErrors], catalogError: true };
  }
  const catalogRef = catalogReference(catalogOrPath, catalog);

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
    const surface = supportedPluginSurface(filePath, target.codexRoot || CODEX_ROOT);
    if (!surface || surface.role !== target.role) {
      errors.push({ path: filePath, role: target.role, reason: 'unsupported-plugin-surface' });
      continue;
    }
    const pairedRole = target.role === 'yeet' ? 'github' : 'yeet';
    const pairedPath = path.join(surface.surfaceDirectory, 'skills', pairedRole, 'SKILL.md');
    if (!fs.existsSync(pairedPath)) {
      errors.push({ path: pairedPath, role: pairedRole, reason: 'missing-paired-skill' });
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
    const originalStat = fs.statSync(filePath);
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
      originalMtimeMs: mtimeFingerprint(originalStat.mtimeMs),
      replacement: entry.patchedDocument,
      replacementSha256: entry.patchedSha256,
      catalogEntry: entry,
    });
  }

  return { changes, skipped, errors, catalogRef };
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
  assertControlledEvidencePath(root, 'evidenceRoot');
  ensureDirectory(root);
  const directory = path.join(root, `run-${new Date().toISOString().replace(/[:.]/g, '-')}-${process.pid}-${crypto.randomBytes(4).toString('hex')}`);
  ensureDirectory(directory);
  return directory;
}

function updateManifest(manifestPath, manifest) {
  writeAtomic(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

function validateRollbackManifest(resolvedManifest, manifest) {
  assertControlledEvidencePath(resolvedManifest, 'manifestPath');
  const evidenceDirectory = resolveAbsolute(manifest.evidenceDirectory || path.dirname(resolvedManifest));
  assertControlledEvidencePath(evidenceDirectory, 'manifest evidenceDirectory');
  if (!isWithin(evidenceDirectory, resolvedManifest)) {
    throw new Error(`manifestPath must stay inside its evidenceDirectory: ${resolvedManifest}`);
  }
  const entries = Array.isArray(manifest.entries) ? manifest.entries : [];
  for (const entry of entries) {
    if (!entry || typeof entry.path !== 'string' || typeof entry.backupPath !== 'string' || typeof entry.codexRoot !== 'string') {
      throw new Error('manifest entry must include D: path, backupPath, and codexRoot');
    }
    const target = resolveAbsolute(entry.path);
    const backup = resolveAbsolute(entry.backupPath);
    const entryCodexRoot = resolveAbsolute(entry.codexRoot);
    assertDDrivePath(target, 'manifest entry.path');
    assertDDrivePath(backup, 'manifest entry.backupPath');
    assertDDrivePath(entryCodexRoot, 'manifest entry.codexRoot');
    if (!isAllowedCodexRoot(entryCodexRoot)) {
      throw new Error(`manifest codexRoot is outside the allowed roots: ${entryCodexRoot}`);
    }
    if (!supportedPluginSurface(target, entryCodexRoot)) {
      throw new Error(`manifest target is outside a supported GitHub plugin surface: ${target}`);
    }
    if (!isWithin(evidenceDirectory, backup)) {
      throw new Error(`manifest backupPath is outside its evidenceDirectory: ${backup}`);
    }
    if (entry.originalMtimeMs !== undefined && !Number.isFinite(Number(entry.originalMtimeMs))) {
      throw new Error(`manifest originalMtimeMs is invalid: ${entry.path}`);
    }
    if (entry.replacementMtimeMs !== undefined && !Number.isFinite(Number(entry.replacementMtimeMs))) {
      throw new Error(`manifest replacementMtimeMs is invalid: ${entry.path}`);
    }
    entry.path = target;
    entry.backupPath = backup;
    entry.codexRoot = entryCodexRoot;
    entry.evidenceDirectory = evidenceDirectory;
  }
}

function rollbackManifest(manifestPath, options = {}) {
  const resolvedManifest = resolveAbsolute(manifestPath);
  const manifest = options.manifest || JSON.parse(fs.readFileSync(resolvedManifest, 'utf8'));
  validateRollbackManifest(resolvedManifest, manifest);
  const errors = [];
  let restored = 0;
  let skipped = 0;
  const entries = Array.isArray(manifest.entries) ? manifest.entries : [];

  for (const entry of entries) {
    if (!['write-attempted', 'committed'].includes(entry.status)) {
      skipped += 1;
      continue;
    }
    try {
      const currentBytes = fs.readFileSync(entry.path);
      const currentSha256 = sha256(currentBytes);
      if (currentSha256 === entry.originalSha256) {
        if (entry.originalMtimeMs !== undefined) {
          const currentMtimeMs = mtimeFingerprint(fs.statSync(entry.path).mtimeMs);
          if (currentMtimeMs !== Number(entry.originalMtimeMs)) {
            const message = `compare-and-swap rollback mtime conflict at ${entry.path}: expected ${entry.originalMtimeMs}, got ${currentMtimeMs}`;
            entry.status = 'rollback-failed';
            entry.rollbackError = message;
            errors.push({
              path: entry.path,
              reason: 'rollback-mtime-cas-conflict',
              message,
              expectedMtimeMs: Number(entry.originalMtimeMs),
              currentMtimeMs,
            });
            continue;
          }
        }
        entry.status = 'restored';
        skipped += 1;
        continue;
      }
      if (currentSha256 !== entry.replacementSha256) {
        throw new Error(`compare-and-swap conflict at ${entry.path}: expected ${entry.replacementSha256}, got ${currentSha256}`);
      }
      if (entry.replacementMtimeMs !== undefined) {
        const currentMtimeMs = mtimeFingerprint(fs.statSync(entry.path).mtimeMs);
        if (currentMtimeMs !== Number(entry.replacementMtimeMs)) {
          throw new Error(`compare-and-swap mtime conflict at ${entry.path}: expected ${entry.replacementMtimeMs}, got ${currentMtimeMs}`);
        }
      }
      const backupBytes = fs.readFileSync(entry.backupPath);
      if (sha256(backupBytes) !== entry.originalSha256) {
        throw new Error(`backup fingerprint mismatch at ${entry.backupPath}`);
      }
      writeAtomic(entry.path, backupBytes);
      if (entry.originalMtimeMs !== undefined) {
        const originalMtimeMs = Number(entry.originalMtimeMs);
        fs.utimesSync(entry.path, new Date(originalMtimeMs), new Date(originalMtimeMs));
      }
      if (sha256File(entry.path) !== entry.originalSha256) {
        throw new Error(`restored fingerprint mismatch at ${entry.path}`);
      }
      if (entry.originalMtimeMs !== undefined
        && mtimeFingerprint(fs.statSync(entry.path).mtimeMs) !== Number(entry.originalMtimeMs)) {
        throw new Error(`restored mtime fingerprint mismatch at ${entry.path}`);
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

function resolveCanonicalCatalog(plan, options = {}) {
  const defaultCatalogPath = resolveAbsolute(path.join(__dirname, 'github-default-branch-skill-overlay-catalog.json'));
  const hasTestCatalog = options.allowTestCatalog === true
    && (typeof options.testOnlyCatalogPath === 'string' || options.testOnlyCatalog !== undefined);
  if (hasTestCatalog) {
    let testCatalog;
    let testCatalogPath = null;
    let rawSha256 = null;
    if (typeof options.testOnlyCatalogPath === 'string') {
      testCatalogPath = resolveAbsolute(options.testOnlyCatalogPath);
      assertControlledEvidencePath(testCatalogPath, 'testOnlyCatalogPath');
      const bytes = fs.readFileSync(testCatalogPath);
      rawSha256 = sha256(bytes);
      testCatalog = validateCatalog(testCatalogPath);
    } else {
      testCatalog = validateCatalog(options.testOnlyCatalog);
    }
    const normalizedSha256 = normalizedCatalogDigest(testCatalog);
    if (plan.catalogRef?.normalizedSha256
      && normalizedSha256 !== String(plan.catalogRef.normalizedSha256).toUpperCase()) {
      throw new Error(`test-only catalog normalized fingerprint drift: expected ${plan.catalogRef.normalizedSha256}, got ${normalizedSha256}`);
    }
    return { path: testCatalogPath, rawSha256, normalizedSha256, catalog: testCatalog };
  }

  if (options.testOnlyCatalogPath !== undefined || options.testOnlyCatalog !== undefined) {
    throw new Error('test-only catalog injection requires allowTestCatalog=true');
  }
  if (plan.catalogRef && Object.prototype.hasOwnProperty.call(plan.catalogRef, 'path')
    && plan.catalogRef.path === null) {
    throw new Error('production canonical catalog requires a file-backed catalog path; inline catalog objects are test-only');
  }
  if (plan.catalogRef?.path && resolveAbsolute(plan.catalogRef.path).toLowerCase() !== defaultCatalogPath.toLowerCase()) {
    throw new Error(`production canonical catalog must be the script-local file: ${plan.catalogRef.path}`);
  }
  const catalogBytes = fs.readFileSync(defaultCatalogPath);
  const rawSha256 = sha256(catalogBytes);
  const canonicalCatalog = validateCatalog(defaultCatalogPath);
  const normalizedSha256 = normalizedCatalogDigest(canonicalCatalog);
  if (plan.catalogRef?.rawSha256 && rawSha256 !== String(plan.catalogRef.rawSha256).toUpperCase()) {
    throw new Error(`canonical catalog byte fingerprint drift: expected ${plan.catalogRef.rawSha256}, got ${rawSha256}`);
  }
  if (plan.catalogRef?.normalizedSha256
    && normalizedSha256 !== String(plan.catalogRef.normalizedSha256).toUpperCase()) {
    throw new Error(`canonical catalog normalized fingerprint drift: expected ${plan.catalogRef.normalizedSha256}, got ${normalizedSha256}`);
  }
  return {
    path: defaultCatalogPath,
    rawSha256,
    normalizedSha256,
    catalog: canonicalCatalog,
  };
}

function validateApplyChangePlan(plan, canonicalCatalog) {
  const errors = [];
  const seenPaths = new Set();
  const changes = Array.isArray(plan.changes) ? plan.changes : [];
  if (changes.length !== EXPECTED_TARGET_COUNT) {
    errors.push({
      reason: 'unexpected-change-count',
      expected: EXPECTED_TARGET_COUNT,
      actual: changes.length,
      message: `apply requires exactly ${EXPECTED_TARGET_COUNT} target changes`,
    });
  }
  for (const [index, change] of (Array.isArray(plan.changes) ? plan.changes : []).entries()) {
    const prefix = `changes[${index}]`;
    if (!change || typeof change.path !== 'string' || !EXPECTED_ROLES.includes(change.role)) {
      errors.push({ reason: 'invalid-change', message: `${prefix} must include a supported role and path` });
      continue;
    }
    let filePath;
    try {
      filePath = resolveAbsolute(change.path);
      assertDDrivePath(filePath, 'change path');
    } catch (error) {
      errors.push({ path: change.path, reason: 'unsafe-change-path', message: error.message });
      continue;
    }
    const codexRoot = change.codexRoot || CODEX_ROOT;
    if (!isAllowedCodexRoot(codexRoot)) {
      errors.push({ path: filePath, reason: 'unsafe-codex-root', message: `codexRoot is outside the allowed roots: ${codexRoot}` });
      continue;
    }
    const surface = supportedPluginSurface(filePath, codexRoot);
    if (!surface || surface.role !== change.role) {
      errors.push({ path: filePath, role: change.role, reason: 'unsupported-plugin-surface' });
      continue;
    }
    const lowerPath = filePath.toLowerCase();
    if (seenPaths.has(lowerPath)) {
      errors.push({ path: filePath, reason: 'duplicate-change-path' });
      continue;
    }
    seenPaths.add(lowerPath);
    const pairedRole = change.role === 'yeet' ? 'github' : 'yeet';
    const pairedPath = path.join(surface.surfaceDirectory, 'skills', pairedRole, 'SKILL.md');
    if (!fs.existsSync(pairedPath)) {
      errors.push({ path: pairedPath, role: pairedRole, reason: 'missing-paired-skill' });
      continue;
    }
    if (!fs.existsSync(filePath)) {
      errors.push({ path: filePath, reason: 'missing-change-target' });
      continue;
    }
    const currentSha256 = sha256File(filePath);
    if (!/^[A-F0-9]{64}$/.test(String(change.originalSha256 || '').toUpperCase())) {
      errors.push({ path: filePath, reason: 'invalid-original-sha256' });
    } else if (currentSha256 !== String(change.originalSha256).toUpperCase()) {
      errors.push({ path: filePath, reason: 'original-cas-conflict', currentSha256, expectedSha256: change.originalSha256 });
    }
    const currentMtimeMs = mtimeFingerprint(fs.statSync(filePath).mtimeMs);
    if (!Number.isFinite(Number(change.originalMtimeMs))) {
      errors.push({ path: filePath, reason: 'invalid-original-mtime-ms' });
    } else if (currentMtimeMs !== Number(change.originalMtimeMs)) {
      errors.push({
        path: filePath,
        reason: 'original-mtime-cas-conflict',
        currentMtimeMs,
        expectedMtimeMs: Number(change.originalMtimeMs),
      });
    }
    if (typeof change.original === 'string' && sha256(change.original) !== String(change.originalSha256).toUpperCase()) {
      errors.push({ path: filePath, reason: 'original-plan-fingerprint-mismatch' });
    }
    const canonicalEntry = canonicalCatalog.roles[change.role].find((entry) => (
      entry.upstreamSha256 === String(change.originalSha256).toUpperCase()
    ));
    if (!canonicalEntry) {
      errors.push({ path: filePath, role: change.role, reason: 'canonical-target-fingerprint-mismatch' });
    }
    if (typeof change.replacement !== 'string') {
      errors.push({ path: filePath, reason: 'missing-replacement-document' });
    } else {
      const replacementSha256 = sha256(change.replacement);
      if (replacementSha256 !== String(change.replacementSha256 || '').toUpperCase()) {
        errors.push({ path: filePath, reason: 'replacement-plan-fingerprint-mismatch' });
      }
      if (!change.replacement.includes(STABLE_MARKER)) {
        errors.push({ path: filePath, reason: 'replacement-marker-mismatch' });
      }
      if (canonicalEntry && (canonicalEntry.patchedSha256 !== String(change.replacementSha256).toUpperCase()
        || canonicalEntry.patchedDocument !== change.replacement)) {
        errors.push({ path: filePath, reason: 'canonical-replacement-mismatch' });
      }
    }
    const pairBytes = fs.readFileSync(pairedPath);
    const pairSha256 = sha256(pairBytes);
    if (!canonicalCatalog.roles[pairedRole].some((entry) => (
      entry.upstreamSha256 === pairSha256 || entry.patchedSha256 === pairSha256
    ))) {
      errors.push({ path: pairedPath, role: pairedRole, reason: 'canonical-pair-fingerprint-mismatch' });
    }
  }
  return errors;
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
  if (planned.length === 0) {
    return { ok: true, changed: 0, skipped: alreadySkipped, failed: 0, errors: [], evidencePaths: [] };
  }

  let canonicalCatalog;
  try {
    canonicalCatalog = resolveCanonicalCatalog(safePlan, options).catalog;
    assertControlledEvidencePath(options.evidenceRoot || DEFAULT_EVIDENCE_ROOT, 'evidenceRoot');
  } catch (error) {
    return {
      ok: false,
      blocked: true,
      changed: 0,
      skipped: 0,
      failed: 0,
      errors: [{ reason: 'canonical-validation-failed', message: error.message }],
      evidencePaths: [],
    };
  }
  const boundaryErrors = validateApplyChangePlan(safePlan, canonicalCatalog);
  if (boundaryErrors.length > 0) {
    return {
      ok: false,
      blocked: true,
      changed: 0,
      skipped: 0,
      failed: 0,
      errors: boundaryErrors,
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

  const evidenceDirectory = createEvidenceDirectory(options.evidenceRoot || DEFAULT_EVIDENCE_ROOT);
  const manifestPath = path.join(evidenceDirectory, 'manifest.json');
  const manifest = {
    version: 1,
    status: 'prepared',
    createdAt: new Date().toISOString(),
    evidenceDirectory,
    entries: [],
  };

  let manifestWrites = 0;
  const persistManifest = () => {
    manifestWrites += 1;
    if (Number.isInteger(options.failManifestUpdateAt) && manifestWrites === options.failManifestUpdateAt) {
      throw new Error(`injected manifest update failure at write ${manifestWrites}`);
    }
    updateManifest(manifestPath, manifest);
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
      const currentMtimeMs = mtimeFingerprint(fs.statSync(change.path).mtimeMs);
      if (currentMtimeMs !== Number(change.originalMtimeMs)) {
        throw new Error(`compare-and-swap mtime conflict before backup at ${change.path}`);
      }
      const backupPath = path.join(evidenceDirectory, `backup-${String(index + 1).padStart(2, '0')}-${path.basename(change.path)}`);
      fs.writeFileSync(backupPath, currentBytes);
      manifest.entries.push({
        path: change.path,
        role: change.role,
        codexRoot: change.codexRoot || CODEX_ROOT,
        originalSha256: change.originalSha256,
        originalMtimeMs: change.originalMtimeMs,
        replacementSha256: change.replacementSha256,
        backupPath,
        status: 'prepared',
      });
    }
    persistManifest();
    manifest.status = 'applying';
    persistManifest();

    let changed = 0;
    for (const [index, change] of planned.entries()) {
      const entry = manifest.entries[index];
      const currentBytes = fs.readFileSync(change.path);
      if (sha256(currentBytes) !== change.originalSha256) {
        throw new Error(`compare-and-swap conflict while applying at ${change.path}`);
      }
      const currentMtimeMs = mtimeFingerprint(fs.statSync(change.path).mtimeMs);
      if (currentMtimeMs !== Number(change.originalMtimeMs)) {
        throw new Error(`compare-and-swap mtime conflict while applying at ${change.path}`);
      }
      if (typeof options.onBeforeWrite === 'function') options.onBeforeWrite(change, index);
      if (Number.isInteger(options.failAfter) && changed >= options.failAfter) {
        throw new Error(`injected failure after ${changed} writes`);
      }
      entry.status = 'write-attempted';
      entry.writeStartedAt = new Date().toISOString();
      writeAtomic(change.path, Buffer.from(change.replacement, 'utf8'));
      entry.status = 'committed';
      entry.committedAt = new Date().toISOString();
      entry.replacementMtimeMs = mtimeFingerprint(fs.statSync(change.path).mtimeMs);
      if (typeof options.onAfterWrite === 'function') options.onAfterWrite(change, index);
      if (sha256File(change.path) !== change.replacementSha256) {
        throw new Error(`replacement fingerprint mismatch at ${change.path}`);
      }
      changed += 1;
      persistManifest();
    }
    manifest.status = 'succeeded';
    manifest.completedAt = new Date().toISOString();
    persistManifest();
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
    try { updateManifest(manifestPath, manifest); } catch { /* rollback uses the in-memory manifest */ }
    let rollback = {
      status: 'unsafe-partial',
      errors: [{ reason: 'manifest-unavailable', message: 'rollback manifest was not created before the failure' }],
    };
    try {
      rollback = rollbackManifest(manifestPath, { reason: error.message, manifest });
    } catch (rollbackError) {
      rollback = {
        status: 'unsafe-partial',
        errors: [{ reason: 'rollback-validation-failed', message: rollbackError.message }],
      };
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

function parseCliArgs(argv) {
  const options = {
    codexRoot: CODEX_ROOT,
    evidenceRoot: DEFAULT_EVIDENCE_ROOT,
    catalogPath: path.join(__dirname, 'github-default-branch-skill-overlay-catalog.json'),
    dryRun: false,
    json: false,
  };
  const errors = [];
  const positional = [];
  const explicit = new Set();
  const valueFlags = new Map([
    ['--codex-root', 'codexRoot'],
    ['--evidence-root', 'evidenceRoot'],
    ['--catalog-path', 'catalogPath'],
  ]);
  const booleanFlags = new Map([
    ['--dry-run', 'dryRun'],
    ['--json', 'json'],
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('-')) {
      positional.push(token);
      continue;
    }
    if (valueFlags.has(token)) {
      const key = valueFlags.get(token);
      if (explicit.has(key)) {
        errors.push({ reason: 'duplicate-cli-option', option: token });
        continue;
      }
      const value = argv[index + 1];
      if (!value || value.startsWith('-')) {
        errors.push({ reason: 'missing-cli-value', option: token });
        continue;
      }
      explicit.add(key);
      options[key] = value;
      index += 1;
      continue;
    }
    if (booleanFlags.has(token)) {
      const key = booleanFlags.get(token);
      if (explicit.has(key)) errors.push({ reason: 'duplicate-cli-option', option: token });
      explicit.add(key);
      options[key] = true;
      continue;
    }
    errors.push({ reason: 'unknown-cli-option', option: token });
  }

  if (positional.length > 2) {
    errors.push({ reason: 'too-many-positional-arguments', count: positional.length });
  }
  if (positional[0] !== undefined) {
    if (explicit.has('codexRoot')) errors.push({ reason: 'duplicate-cli-option', option: '--codex-root' });
    else options.codexRoot = positional[0];
  }
  if (positional[1] !== undefined) {
    if (explicit.has('catalogPath')) errors.push({ reason: 'duplicate-cli-option', option: '--catalog-path' });
    else options.catalogPath = positional[1];
  }

  return { ok: errors.length === 0, options, errors };
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
  parseCliArgs,
};

if (require.main === module) {
  const parsed = parseCliArgs(process.argv.slice(2));
  if (!parsed.ok) {
    const failure = { ok: false, blocked: true, errors: parsed.errors };
    if (parsed.options.json) console.log(JSON.stringify(failure, null, 2));
    else console.error(`GitHub default-branch overlay CLI 参数错误：${parsed.errors.map((error) => error.option || error.reason).join('; ')}`);
    process.exitCode = 2;
  } else {
    const { codexRoot, catalogPath, evidenceRoot, dryRun, json } = parsed.options;
    const discovered = discoverTargets(codexRoot);
    const plan = buildChangePlan(discovered, catalogPath);
    const report = applyChangePlan(plan, { dryRun, evidenceRoot });
    const result = {
      discovered,
      plan: { changes: plan.changes.length, skipped: plan.skipped.length, errors: plan.errors },
      report,
    };
    if (json) console.log(JSON.stringify(result, null, 2));
    else console.log(`GitHub default-branch overlay: planned=${plan.changes.length}, skipped=${plan.skipped.length}, changed=${report.changed}, errors=${report.errors?.length ?? 0}`);
    process.exitCode = report.ok ? 0 : 1;
  }
}
