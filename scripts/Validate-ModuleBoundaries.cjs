'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const DEFAULT_MANIFEST_PATH = path.join(PROJECT_ROOT, 'modules', 'manifest.json');
const TEST_KINDS = Object.freeze(['powershell', 'python', 'node']);
const CODE_FILE_PATTERN = /\.(?:cjs|cmd|cs|js|mjs|ps1|py)$/i;

function normalizeRepositoryPath(value, label = 'path') {
  const normalized = String(value).replace(/\\/g, '/').replace(/^\.\//, '');
  if (
    normalized.length === 0
    || normalized.startsWith('/')
    || /^[A-Za-z]:/.test(normalized)
    || normalized.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error(`${label} must be a normalized repository-relative path: ${value}`);
  }
  return normalized;
}

function collectRepositoryFiles(projectRoot = PROJECT_ROOT) {
  const result = spawnSync('git', [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '-z',
  ], {
    cwd: projectRoot,
    encoding: 'utf8',
    windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`git ls-files failed: ${String(result.stderr || result.stdout || '').trim()}`);
  }

  return String(result.stdout || '')
    .split('\0')
    .filter(Boolean)
    .map((entry) => normalizeRepositoryPath(entry, 'repository file'))
    .filter((entry) => fs.existsSync(path.join(projectRoot, ...entry.split('/'))))
    .sort((left, right) => left.localeCompare(right));
}

function testPaths(owner) {
  const profiles = owner.tests || {};
  return Object.values(profiles).flatMap((profile) => TEST_KINDS.flatMap(
    (kind) => (profile && Array.isArray(profile[kind]) ? profile[kind] : []),
  ));
}

function exactPaths(owner) {
  const ownership = owner.ownership || {};
  return new Set([
    ...(owner.context ? [owner.context] : []),
    ...(Array.isArray(owner.interfaces) ? owner.interfaces : []),
    ...(Array.isArray(ownership.files) ? ownership.files : []),
    ...testPaths(owner),
  ].map((entry) => normalizeRepositoryPath(entry, `${owner.id || 'shared'} owned file`)));
}

function prefixes(owner) {
  const ownership = owner.ownership || {};
  return (Array.isArray(ownership.prefixes) ? ownership.prefixes : []).map((entry) => {
    const normalized = normalizeRepositoryPath(entry.replace(/\/$/, ''), `${owner.id || 'shared'} owned prefix`);
    return `${normalized}/`;
  });
}

function ownersForPath(manifest, repositoryPath) {
  const normalized = normalizeRepositoryPath(repositoryPath, 'repository file');
  const owners = [
    ...(Array.isArray(manifest.modules) ? manifest.modules : []),
    ...(manifest.shared ? [{ id: 'shared', ...manifest.shared }] : []),
  ];

  return owners
    .filter((owner) => exactPaths(owner).has(normalized)
      || prefixes(owner).some((prefix) => normalized.startsWith(prefix)))
    .map((owner) => owner.id);
}

function validateOwnership(manifest, repositoryFiles) {
  const errors = [];
  for (const repositoryPath of repositoryFiles) {
    const owners = ownersForPath(manifest, repositoryPath);
    if (owners.length === 0) {
      errors.push(`${repositoryPath}: no owner`);
    } else if (owners.length > 1) {
      errors.push(`${repositoryPath}: multiple owners (${owners.join(', ')})`);
    }
  }
  return errors;
}

function validateCrossModuleCodeReferences(manifest, repositoryFiles, projectRoot = PROJECT_ROOT) {
  const errors = [];
  const modules = new Map(manifest.modules.map((module) => [module.id, module]));
  const codeFiles = repositoryFiles
    .filter((repositoryPath) => CODE_FILE_PATTERN.test(repositoryPath))
    .map((repositoryPath) => ({
      repositoryPath,
      owners: ownersForPath(manifest, repositoryPath),
    }))
    .filter(({ owners }) => owners.length === 1 && modules.has(owners[0]));
  const targetsByBasename = new Map();

  for (const target of codeFiles) {
    const basename = path.posix.basename(target.repositoryPath).toLowerCase();
    if (!targetsByBasename.has(basename)) targetsByBasename.set(basename, []);
    targetsByBasename.get(basename).push(target);
  }

  for (const source of codeFiles) {
    if (!/^(?:managed|modules|scripts)\//.test(source.repositoryPath)) continue;
    const consumer = modules.get(source.owners[0]);
    const sourceText = fs.readFileSync(
      path.join(projectRoot, ...source.repositoryPath.split('/')),
      'utf8',
    ).toLowerCase();

    for (const [basename, targets] of targetsByBasename) {
      if (!sourceText.includes(basename)) continue;
      const providerIds = new Set(
        targets
          .map((target) => target.owners[0])
          .filter((providerId) => providerId !== consumer.id),
      );
      for (const providerId of providerIds) {
        const provider = modules.get(providerId);
        if (!consumer.dependsOn.includes(providerId)) {
          errors.push(`${source.repositoryPath} references ${basename} without dependency ${consumer.id} -> ${providerId}`);
        }
        if (!provider.interfaces.some((interfacePath) => path.posix.basename(interfacePath).toLowerCase() === basename)) {
          errors.push(`${source.repositoryPath} references undeclared ${providerId} interface: ${basename}`);
        }
      }
    }
  }

  return errors;
}

function validateOwnedPath(projectRoot, owner, repositoryPath, role, errors) {
  let normalized;
  try {
    normalized = normalizeRepositoryPath(repositoryPath, `${owner.id} ${role}`);
  } catch (error) {
    errors.push(error.message);
    return;
  }
  if (!fs.existsSync(path.join(projectRoot, ...normalized.split('/')))) {
    errors.push(`${owner.id} ${role} does not exist: ${normalized}`);
  }
}

function validateDependencyGraph(modules, errors) {
  const ids = new Set(modules.map((entry) => entry.id));
  const graph = new Map();

  for (const module of modules) {
    const dependencies = Array.isArray(module.dependsOn) ? module.dependsOn : [];
    graph.set(module.id, dependencies);
    for (const dependency of dependencies) {
      if (!ids.has(dependency)) errors.push(`${module.id} depends on unknown module: ${dependency}`);
      if (dependency === module.id) errors.push(`${module.id} cannot depend on itself`);
    }
    for (const coupling of Array.isArray(module.transitionalDependencies) ? module.transitionalDependencies : []) {
      if (!coupling || !ids.has(coupling.module)) {
        errors.push(`${module.id} has an unknown transitional dependency`);
      }
      if (!coupling || typeof coupling.reason !== 'string' || coupling.reason.trim() === '') {
        errors.push(`${module.id} transitional dependency must explain its removal gate`);
      }
    }
  }

  const visiting = new Set();
  const visited = new Set();
  function visit(id) {
    if (visiting.has(id)) {
      errors.push(`module dependency cycle includes: ${id}`);
      return;
    }
    if (visited.has(id)) return;
    visiting.add(id);
    for (const dependency of graph.get(id) || []) {
      if (graph.has(dependency)) visit(dependency);
    }
    visiting.delete(id);
    visited.add(id);
  }
  for (const id of graph.keys()) visit(id);
}

function validateManifest(manifest, projectRoot = PROJECT_ROOT) {
  const errors = [];
  if (!manifest || manifest.schemaVersion !== 1) {
    return ['manifest schemaVersion must be 1'];
  }
  if (!Array.isArray(manifest.modules) || manifest.modules.length === 0) {
    return ['manifest modules must be a non-empty array'];
  }
  if (!manifest.shared || typeof manifest.shared !== 'object') {
    errors.push('manifest shared ownership is required');
  }

  const moduleIds = new Set();
  for (const module of manifest.modules) {
    if (!module || typeof module.id !== 'string' || !/^[a-z][a-z0-9-]*$/.test(module.id)) {
      errors.push('module id must use lower-case kebab-case');
      continue;
    }
    if (moduleIds.has(module.id)) errors.push(`duplicate module id: ${module.id}`);
    moduleIds.add(module.id);
    if (typeof module.summary !== 'string' || module.summary.trim() === '') {
      errors.push(`${module.id} summary is required`);
    }
    if (!Array.isArray(module.interfaces) || module.interfaces.length === 0) {
      errors.push(`${module.id} must expose at least one interface`);
    }
    validateOwnedPath(projectRoot, module, module.context, 'context', errors);
    for (const interfacePath of module.interfaces || []) {
      validateOwnedPath(projectRoot, module, interfacePath, 'interface', errors);
    }
    for (const testPath of testPaths(module)) {
      validateOwnedPath(projectRoot, module, testPath, 'test', errors);
    }
    if (!module.tests || !module.tests.fixture) {
      errors.push(`${module.id} must define a fixture test profile`);
    }
    for (const [profileName, profile] of Object.entries(module.tests || {})) {
      if (!/^[a-z][a-z0-9-]*$/.test(profileName)) {
        errors.push(`${module.id} test profile must use lower-case kebab-case: ${profileName}`);
      }
      for (const kind of TEST_KINDS) {
        if (!profile || !Array.isArray(profile[kind])) {
          errors.push(`${module.id} ${profileName} test profile must define ${kind}`);
        }
      }
    }
  }

  for (const owner of [...manifest.modules, { id: 'shared', ...manifest.shared }]) {
    for (const ownedPath of owner.ownership?.files || []) {
      validateOwnedPath(projectRoot, owner, ownedPath, 'owned file', errors);
    }
    for (const ownedPrefix of owner.ownership?.prefixes || []) {
      const normalized = normalizeRepositoryPath(
        String(ownedPrefix).replace(/\/$/, ''),
        `${owner.id} owned prefix`,
      );
      if (!fs.existsSync(path.join(projectRoot, ...normalized.split('/')))) {
        errors.push(`${owner.id} owned prefix does not exist: ${normalized}/`);
      }
    }
  }

  validateDependencyGraph(manifest.modules, errors);
  return errors;
}

function parseArguments(args) {
  let json = false;
  let manifestPath = DEFAULT_MANIFEST_PATH;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--json') {
      json = true;
    } else if (argument === '--manifest') {
      index += 1;
      if (index >= args.length) throw new Error('--manifest requires a path');
      manifestPath = path.resolve(args[index]);
    } else {
      throw new Error('Usage: node scripts/Validate-ModuleBoundaries.cjs [--json] [--manifest <path>]');
    }
  }
  return { json, manifestPath };
}

function main(args) {
  const options = parseArguments(args);
  const manifest = JSON.parse(fs.readFileSync(options.manifestPath, 'utf8'));
  const repositoryFiles = collectRepositoryFiles(PROJECT_ROOT);
  const errors = [
    ...validateManifest(manifest, PROJECT_ROOT),
    ...validateOwnership(manifest, repositoryFiles),
    ...validateCrossModuleCodeReferences(manifest, repositoryFiles, PROJECT_ROOT),
  ];
  const result = {
    ok: errors.length === 0,
    files: repositoryFiles.length,
    modules: manifest.modules.length,
    errors,
  };

  if (options.json) {
    console.log(JSON.stringify(result));
  } else if (result.ok) {
    console.log(`PASS Validate-ModuleBoundaries files=${result.files} modules=${result.modules}`);
  } else {
    for (const error of errors) console.error(error);
  }
  if (!result.ok) process.exitCode = 1;
}

module.exports = {
  collectRepositoryFiles,
  ownersForPath,
  validateCrossModuleCodeReferences,
  validateManifest,
  validateOwnership,
};

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
