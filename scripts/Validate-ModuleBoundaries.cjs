'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const TEST_KINDS = Object.freeze(['powershell', 'python', 'node']);
const CODE_FILE_PATTERN = /\.(?:cjs|cmd|cs|js|mjs|ps1|py)$/i;
const OWNED_TEST_FILE_PATTERN = /(?:^|\/)tests\/Test-[^/]+\.(?:ps1|cjs|py)$/i;

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

function runGit(projectRoot, args, options = {}) {
  const result = spawnSync('git', args, {
    cwd: projectRoot,
    windowsHide: true,
    // Default 1MiB maxBuffer truncates git ls-files (--others includes every
    // untracked evidence/fixture path) and fails the gate with ENOBUFS.
    maxBuffer: 256 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`git ${args[0]} failed: ${String(result.stderr || result.stdout || '').trim()}`);
  }
  return result.stdout;
}

function collectRepositoryFiles(projectRoot = PROJECT_ROOT) {
  return String(runGit(projectRoot, [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '-z',
  ], { encoding: 'utf8' }))
    .split('\0')
    .filter(Boolean)
    .map((entry) => normalizeRepositoryPath(entry, 'repository file'))
    .filter((entry) => fs.existsSync(path.join(projectRoot, ...entry.split('/'))))
    .sort((left, right) => left.localeCompare(right));
}

// A tree is what the validator checks: its files, whether a file or directory
// exists, and the text of a list of files.  The work tree is the default;
// --rev checks a commit (or tree) without exporting it.
function workTree(projectRoot = PROJECT_ROOT) {
  const fullPath = (repositoryPath) => path.join(projectRoot, ...repositoryPath.split('/'));
  return {
    files: collectRepositoryFiles(projectRoot),
    exists: (repositoryPath) => fs.existsSync(fullPath(repositoryPath)),
    readTexts: (repositoryPaths) => repositoryPaths.map((entry) => fs.readFileSync(fullPath(entry), 'utf8')),
  };
}

function revisionTree(projectRoot, revision) {
  const blobs = new Map();
  const directories = new Set();
  for (const entry of String(runGit(projectRoot, ['ls-tree', '-r', '-z', revision], { encoding: 'utf8' })).split('\0')) {
    if (!entry) continue;
    const tab = entry.indexOf('\t');
    const repositoryPath = normalizeRepositoryPath(entry.slice(tab + 1), 'repository file');
    blobs.set(repositoryPath, entry.slice(0, tab).split(' ')[2]);
    for (let slash = repositoryPath.indexOf('/'); slash !== -1; slash = repositoryPath.indexOf('/', slash + 1)) {
      directories.add(repositoryPath.slice(0, slash));
    }
  }

  function readTexts(repositoryPaths) {
    const objects = repositoryPaths.map((repositoryPath) => {
      if (!blobs.has(repositoryPath)) throw new Error(`${repositoryPath} is not in ${revision}`);
      return blobs.get(repositoryPath);
    });
    if (objects.length === 0) return [];
    const output = runGit(projectRoot, ['cat-file', '--batch'], { input: `${objects.join('\n')}\n` });
    let offset = 0;
    return objects.map((object) => {
      const headerEnd = output.indexOf(0x0a, offset);
      const [, type, size] = output.toString('utf8', offset, headerEnd).split(' ');
      if (type !== 'blob') throw new Error(`git cat-file: ${object} is ${type}`);
      const start = headerEnd + 1;
      offset = start + Number(size) + 1;
      return output.toString('utf8', start, start + Number(size));
    });
  }

  return {
    files: [...blobs.keys()].sort((left, right) => left.localeCompare(right)),
    exists: (repositoryPath) => blobs.has(repositoryPath) || directories.has(repositoryPath),
    readTexts,
  };
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

// A path argument as a repository path, or null when it lies outside the repository.
function toRepositoryPath(argument, projectRoot = PROJECT_ROOT) {
  const relative = path.relative(projectRoot, path.resolve(argument));
  if (relative === '' || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return null;
  return normalizeRepositoryPath(relative);
}

// Each path's owners with the test profiles they define, as --owners reports them.
function describeOwners(manifest, entries) {
  const ownersById = new Map([
    ...(Array.isArray(manifest.modules) ? manifest.modules : []).map((module) => [module.id, module]),
    ['shared', { id: 'shared', ...manifest.shared }],
  ]);
  return entries.map(({ argument, repositoryPath }) => ({
    argument,
    path: repositoryPath,
    owners: repositoryPath === null ? [] : ownersForPath(manifest, repositoryPath).map((id) => ({
      id,
      profiles: Object.keys(ownersById.get(id).tests || {}),
    })),
  }));
}

function formatOwners(entry) {
  if (entry.path === null) return `${entry.argument}: outside the repository`;
  if (entry.owners.length === 0) return `${entry.path}: no owner`;
  if (entry.owners.length > 1) return `${entry.path}: multiple owners (${entry.owners.map((owner) => owner.id).join(', ')})`;
  const [owner] = entry.owners;
  return `${entry.path}: ${owner.id} (test profiles: ${owner.profiles.join(', ') || 'none'})`;
}

const COMMIT_SCOPE_PATTERN = /^[A-Za-z]+\(([^)]*)\)!?:/;

// The subject is the first line that is neither blank nor a git comment.
function commitSubject(message) {
  return String(message).split(/\r?\n/).find((line) => line.trim() !== '' && !line.startsWith('#')) || '';
}

// A conventional-commit scope that names a module or shared must own one of the staged files. A scope that is
// not a module id, a subject without a scope and a commit with nothing staged pass.
function checkCommitScope(manifest, message, stagedFiles) {
  const match = COMMIT_SCOPE_PATTERN.exec(commitSubject(message));
  if (!match || stagedFiles.length === 0) return [];
  const moduleIds = new Set([...manifest.modules.map((module) => module.id), 'shared']);
  const stagedOwners = [...new Set(stagedFiles.flatMap((file) => ownersForPath(manifest, file)))].sort();
  return match[1].split(',')
    .map((scope) => scope.trim())
    .filter((scope) => moduleIds.has(scope) && !stagedOwners.includes(scope))
    .map((scope) => `commit scope "${scope}" names a module that owns none of the staged files (their owners: ${
      stagedOwners.join(', ') || 'no module'}); use an owning module or a scope that is not a module id`);
}

// The commit-msg hook: the manifest and the staged files come from the index being committed, which a tool may
// have pointed elsewhere with GIT_INDEX_FILE. A subject without a scope needs neither, and a repository whose
// index has no manifest (a test fixture that borrows these hooks) has no modules to check.
function checkCommitMessageFile(messagePath) {
  const message = fs.readFileSync(path.resolve(messagePath), 'utf8');
  if (!COMMIT_SCOPE_PATTERN.test(commitSubject(message))) return [];
  const repositoryRoot = String(runGit(process.cwd(), ['rev-parse', '--show-toplevel'], { encoding: 'utf8' })).trim();
  if (String(runGit(repositoryRoot, ['ls-files', '-z', '--', 'modules/manifest.json'], { encoding: 'utf8' })) === '') return [];
  const manifest = JSON.parse(String(runGit(repositoryRoot, ['show', ':modules/manifest.json'], { encoding: 'utf8' })));
  const stagedFiles = String(runGit(repositoryRoot, ['diff', '--cached', '--name-only', '--no-renames', '-z'], { encoding: 'utf8' }))
    .split('\0')
    .filter(Boolean);
  return checkCommitScope(manifest, message, stagedFiles);
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

function validateCrossModuleCodeReferences(manifest, repositoryFiles, tree) {
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

  const sources = codeFiles.filter(({ repositoryPath }) => /^(?:managed|modules|scripts)\//.test(repositoryPath));
  const sourceTexts = tree.readTexts(sources.map(({ repositoryPath }) => repositoryPath));
  for (const [index, source] of sources.entries()) {
    const consumer = modules.get(source.owners[0]);
    const sourceText = sourceTexts[index].toLowerCase();

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

function validateOwnedPath(tree, owner, repositoryPath, role, errors) {
  let normalized;
  try {
    normalized = normalizeRepositoryPath(repositoryPath, `${owner.id} ${role}`);
  } catch (error) {
    errors.push(error.message);
    return;
  }
  if (!tree.exists(normalized)) {
    errors.push(`${owner.id} ${role} does not exist: ${normalized}`);
  }
}

// An owned `tests/Test-*` file that no profile lists never runs in standard
// regression or CI: registration in ownership alone is invisible to runners.
function validateOwnedTestsInProfiles(owner, errors) {
  const profileTests = new Set(testPaths(owner));
  for (const ownedPath of owner.ownership?.files || []) {
    let normalized;
    try {
      normalized = normalizeRepositoryPath(ownedPath, `${owner.id} owned file`);
    } catch {
      continue;
    }
    if (!OWNED_TEST_FILE_PATTERN.test(normalized)) continue;
    if (!profileTests.has(normalized)) {
      errors.push(`${owner.id} owned test file is not in any test profile: ${normalized}`);
    }
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

function validateManifest(manifest, tree) {
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
    validateOwnedPath(tree, module, module.context, 'context', errors);
    for (const interfacePath of module.interfaces || []) {
      validateOwnedPath(tree, module, interfacePath, 'interface', errors);
    }
    for (const testPath of testPaths(module)) {
      validateOwnedPath(tree, module, testPath, 'test', errors);
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
      validateOwnedPath(tree, owner, ownedPath, 'owned file', errors);
    }
    validateOwnedTestsInProfiles(owner, errors);
    for (const ownedPrefix of owner.ownership?.prefixes || []) {
      const normalized = normalizeRepositoryPath(
        String(ownedPrefix).replace(/\/$/, ''),
        `${owner.id} owned prefix`,
      );
      if (!tree.exists(normalized)) {
        errors.push(`${owner.id} owned prefix does not exist: ${normalized}/`);
      }
    }
  }

  validateDependencyGraph(manifest.modules, errors);
  return errors;
}

// The manifest comes from the checked tree unless --manifest names a file.
function validateRepository(projectRoot, { revision, manifestPath } = {}) {
  const tree = revision ? revisionTree(projectRoot, revision) : workTree(projectRoot);
  const manifest = JSON.parse(manifestPath
    ? fs.readFileSync(manifestPath, 'utf8')
    : tree.readTexts(['modules/manifest.json'])[0]);
  const errors = [
    ...validateManifest(manifest, tree),
    ...validateOwnership(manifest, tree.files),
    ...validateCrossModuleCodeReferences(manifest, tree.files, tree),
  ];
  return {
    ok: errors.length === 0,
    files: tree.files.length,
    modules: manifest.modules.length,
    errors,
  };
}

function parseArguments(args) {
  let json = false;
  let manifestPath;
  let revision;
  let ownerPaths;
  let commitMessagePath;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--json') {
      json = true;
    } else if (argument === '--manifest') {
      index += 1;
      if (index >= args.length) throw new Error('--manifest requires a path');
      manifestPath = path.resolve(args[index]);
    } else if (argument === '--rev') {
      index += 1;
      if (index >= args.length || args[index].startsWith('-')) throw new Error('--rev requires a commit or tree');
      revision = args[index];
    } else if (argument === '--owners') {
      ownerPaths = [];
      while (index + 1 < args.length && !args[index + 1].startsWith('--')) {
        index += 1;
        ownerPaths.push(args[index]);
      }
      if (ownerPaths.length === 0) throw new Error('--owners requires at least one path');
    } else if (argument === '--commit-msg') {
      index += 1;
      if (index >= args.length || args[index].startsWith('--')) throw new Error('--commit-msg requires the message file');
      commitMessagePath = args[index];
    } else {
      throw new Error('Usage: node scripts/Validate-ModuleBoundaries.cjs [--json] [--manifest <path>] [--rev <commit-or-tree>]'
        + ' | --owners <path>... [--json] [--manifest <path>] | --commit-msg <message-file>');
    }
  }
  if ((ownerPaths || commitMessagePath) && revision) throw new Error('--rev only applies to the boundary check');
  if (ownerPaths && commitMessagePath) throw new Error('--owners and --commit-msg are separate modes');
  return { json, manifestPath, revision, ownerPaths, commitMessagePath };
}

function main(args) {
  const options = parseArguments(args);
  if (options.commitMessagePath) {
    const errors = checkCommitMessageFile(options.commitMessagePath);
    for (const error of errors) console.error(error);
    if (errors.length > 0) process.exitCode = 1;
    return;
  }
  if (options.ownerPaths) {
    const manifest = JSON.parse(fs.readFileSync(options.manifestPath || path.join(PROJECT_ROOT, 'modules', 'manifest.json'), 'utf8'));
    const report = describeOwners(manifest, options.ownerPaths.map((argument) => ({ argument, repositoryPath: toRepositoryPath(argument) })));
    if (options.json) {
      console.log(JSON.stringify(report));
    } else {
      for (const entry of report) console.log(formatOwners(entry));
    }
    if (report.some((entry) => entry.owners.length !== 1)) process.exitCode = 1;
    return;
  }
  const result = validateRepository(PROJECT_ROOT, options);

  if (options.json) {
    console.log(JSON.stringify(result));
  } else if (result.ok) {
    console.log(`PASS Validate-ModuleBoundaries files=${result.files} modules=${result.modules}`);
  } else {
    for (const error of result.errors) console.error(error);
  }
  if (!result.ok) process.exitCode = 1;
}

module.exports = {
  checkCommitScope,
  describeOwners,
  ownersForPath,
  validateCrossModuleCodeReferences,
  validateManifest,
  validateOwnedTestsInProfiles,
  validateOwnership,
  validateRepository,
  workTree,
};

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
