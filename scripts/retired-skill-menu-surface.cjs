'use strict';

// This is a retirement auditor, not a generic skill-name deleter.  It only
// removes exact user-retired plugin containers or active skills whose SOURCE.md
// proves the same retired source repository.  The default audit covers what is
// installed: active skills and every marketplace container under plugins\cache.
// Remote suggested-plugin catalog entries and the local marketplace copy under
// .tmp (plugin directories and catalogs) are vendor-available listings, not
// installed payload; each is an explicit one-shot hygiene surface because the
// Codex app re-fetches or re-syncs them.

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const LIVE_CODEX_ROOT = 'D:\\Codex\\.codex';
// Active skills and the retirement ledger live in the unified physical root.
// LIVE_CODEX_ROOT\skills is only a junction alias of it, checked on every scan.
const LIVE_ACTIVE_SKILLS_ROOT = 'D:\\agents\\skills-manager\\skills';
const PROJECT_ROOT = 'D:\\agents\\projects\\统一环境';
const POLICY_PATH = path.join(PROJECT_ROOT, 'scripts', 'lib', 'CodexHostSafety.ps1');
const PWSH_PATH = 'D:\\Codex\\tools\\PowerShell\\7.6.5\\pwsh.exe';
const FIXTURE_ENV = 'RETIRED_SKILL_MENU_SURFACE_TEST_MODE';
const FIXTURE_SWAP_TARGET_ENV = 'RETIRED_SKILL_MENU_SURFACE_TEST_SWAP_TARGET';
const FIXTURE_NESTED_CHILD_REPLACE_TARGET_ENV = 'RETIRED_SKILL_MENU_SURFACE_TEST_NESTED_CHILD_REPLACE_TARGET';
const FIXTURE_NESTED_CHILD_ADD_TARGET_ENV = 'RETIRED_SKILL_MENU_SURFACE_TEST_NESTED_CHILD_ADD_TARGET';
const FIXTURE_MARKER = '.retired-skill-menu-surface-fixture';
const FIXTURE_MARKER_VALUE = 'retired-skill-menu-surface-fixture-v1\n';
const FIXTURE_PREFIX = 'retired-skill-menu-surface-tests-';

// Aliases identify plugin containers only.  They are deliberately never
// expanded into global skill names: `gsap`, for example, may be a valid skill
// from an unrelated active source.
const SOURCE_PLUGIN_ALIASES = new Map([
  ['hyperframes', ['hyperframes']],
  ['remotion-skills', ['remotion']],
  ['obra-superpowers', ['superpowers']],
  ['heygen', ['heygen']],
]);

class SafetyError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'SafetyError';
    this.code = code;
  }
}

function fail(code, message) {
  throw new SafetyError(code, message);
}

function parseArguments(argv) {
  let apply = false;
  let dryRun = false;
  let includeRemoteCatalog = false;
  let includeLocalMarketplace = false;
  let fixtureRoot = null;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--apply') {
      if (apply) fail('duplicate-apply', '--apply 只能出现一次。');
      apply = true;
    } else if (argument === '--dry-run') {
      if (dryRun) fail('duplicate-dry-run', '--dry-run 只能出现一次。');
      dryRun = true;
    } else if (argument === '--include-remote-catalog') {
      if (includeRemoteCatalog) fail('duplicate-remote-catalog', '--include-remote-catalog 只能出现一次。');
      includeRemoteCatalog = true;
    } else if (argument === '--include-local-marketplace') {
      if (includeLocalMarketplace) fail('duplicate-local-marketplace', '--include-local-marketplace 只能出现一次。');
      includeLocalMarketplace = true;
    } else if (argument === '--fixture-root') {
      if (fixtureRoot !== null) fail('duplicate-fixture-root', '--fixture-root 只能出现一次。');
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) fail('missing-fixture-root', '--fixture-root 必须跟随绝对目录。');
      fixtureRoot = value;
      index += 1;
    } else {
      fail('unsupported-argument', `不支持的参数：${argument}`);
    }
  }
  return { apply, dryRun, includeRemoteCatalog, includeLocalMarketplace, fixtureRoot };
}

function lstatOrNull(target) {
  try {
    return fs.lstatSync(target);
  } catch (error) {
    if (error && (error.code === 'ENOENT' || error.code === 'ENOTDIR')) return null;
    throw error;
  }
}

function isReparse(stats) {
  return Boolean(stats && stats.isSymbolicLink());
}

function isInside(child, parent) {
  const relative = path.relative(path.resolve(parent), path.resolve(child));
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function assertPhysicalChain(target, boundary, label, requireLeaf = false) {
  const fullTarget = path.resolve(target);
  const fullBoundary = path.resolve(boundary);
  if (!isInside(fullTarget, fullBoundary)) fail('path-outside-root', `${label} 越出允许根：${fullTarget}`);
  let current = fullTarget;
  while (true) {
    const stats = lstatOrNull(current);
    if (!stats) {
      if (requireLeaf && current === fullTarget) fail('missing-path', `${label} 不存在：${current}`);
    } else if (isReparse(stats)) {
      fail('reparse-point', `${label} 穿过 reparse point：${current}`);
    }
    if (current.toLowerCase() === fullBoundary.toLowerCase()) break;
    const parent = path.dirname(current);
    if (parent === current || !isInside(parent, fullBoundary)) fail('path-outside-root', `${label} 越出允许根：${fullTarget}`);
    current = parent;
  }
  return fullTarget;
}

function assertPhysicalDirectory(target, boundary, label) {
  const full = assertPhysicalChain(target, boundary, label, true);
  const stats = lstatOrNull(full);
  if (!stats || !stats.isDirectory() || isReparse(stats)) fail('not-physical-directory', `${label} 不是普通目录：${full}`);
  return full;
}

function assertPhysicalFile(target, boundary, label) {
  const full = assertPhysicalChain(target, boundary, label, true);
  const stats = lstatOrNull(full);
  if (!stats || !stats.isFile() || isReparse(stats)) fail('not-physical-file', `${label} 不是普通文件：${full}`);
  if (stats.nlink !== 1) fail('hard-link', `${label} 是 hard link：${full}`);
  return full;
}

function safeWalk(root, boundary, files = []) {
  const fullRoot = assertPhysicalDirectory(root, boundary, '菜单扫描根');
  for (const entry of fs.readdirSync(fullRoot, { withFileTypes: true })) {
    const candidate = path.join(fullRoot, entry.name);
    const stats = lstatOrNull(candidate);
    if (!stats || isReparse(stats)) continue;
    if (stats.isDirectory()) {
      if (entry.name === '.git' || entry.name === 'node_modules') continue;
      safeWalk(candidate, boundary, files);
    } else if (stats.isFile()) {
      files.push(candidate);
    }
  }
  return files;
}

function sha256File(target) {
  return crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex');
}

function directoryNodeIdentity(target, label) {
  const stats = lstatOrNull(target);
  if (!stats || !stats.isDirectory() || isReparse(stats)) {
    fail('target-changed-before-delete', `${label} 在目录身份采集前不再是安全普通目录：${target}`);
  }
  return { dev: String(stats.dev), ino: String(stats.ino) };
}

function sameDirectoryNodeIdentity(left, right) {
  return left && right && left.dev === right.dev && left.ino === right.ino;
}

function inspectDirectoryDeletionTree(target, boundary, label) {
  const root = assertPhysicalDirectory(target, boundary, label);
  const nodeIdentity = directoryNodeIdentity(root, label);
  const rootRealPath = fs.realpathSync.native(root);
  const entries = [];
  const lines = [];

  function visit(candidate, relativePath) {
    const stats = lstatOrNull(candidate);
    if (!stats) fail('target-changed-before-delete', `${label} 审计期间条目消失：${candidate}`);
    if (isReparse(stats)) fail('reparse-point', `${label} 包含 reparse point：${candidate}`);
    const resolved = fs.realpathSync.native(candidate);
    if (!isInside(resolved, rootRealPath)) fail('realpath-escape', `${label} 的 realpath 越出根：${candidate}`);
    if (stats.isDirectory()) {
      entries.push({ relativePath, kind: 'directory', sha256: null });
      lines.push(`D:${relativePath}`);
      for (const name of fs.readdirSync(candidate).sort()) {
        visit(path.join(candidate, name), relativePath === '.' ? name : `${relativePath}/${name}`);
      }
      return;
    }
    if (!stats.isFile()) fail('unsupported-entry-type', `${label} 包含不支持的文件系统条目：${candidate}`);
    if (stats.nlink !== 1) fail('hard-link', `${label} 包含 hard link：${candidate}`);
    const sha256 = sha256File(candidate);
    entries.push({ relativePath, kind: 'file', sha256 });
    lines.push(`F:${relativePath}:${sha256}`);
  }

  visit(root, '.');
  if (!sameDirectoryNodeIdentity(nodeIdentity, directoryNodeIdentity(root, label))) {
    fail('target-changed-during-inspection', `${label} 整树审计期间目录身份漂移：${root}`);
  }
  return {
    digest: crypto.createHash('sha256').update(lines.join('\n') + '\n', 'utf8').digest('hex'),
    entries,
    nodeIdentity,
  };
}

function sameDirectoryDeletionTree(left, right) {
  return left && right && left.digest === right.digest &&
    sameDirectoryNodeIdentity(left.nodeIdentity, right.nodeIdentity);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeName(value) {
  return typeof value === 'string' && value.trim() ? value.trim().toLowerCase() : null;
}

function normalizeRepo(value) {
  if (typeof value !== 'string' || !value.trim()) return null;
  return value.trim().replace(/[\\/]$/, '').replace(/\.git$/i, '').toLowerCase();
}

function collectRetired(ledgerFile) {
  const ledger = readJson(ledgerFile);
  const groups = [];
  const byId = new Map();
  for (const source of asArray(ledger.sources)) {
    if (!source || source.status !== 'deleted-by-user' || typeof source.id !== 'string') continue;
    const group = {
      id: source.id,
      repo: normalizeRepo(source.repo),
      pluginIds: new Set([normalizeName(source.id), ...asArray(SOURCE_PLUGIN_ALIASES.get(source.id)).map(normalizeName)].filter(Boolean)),
      skillNames: new Set(),
    };
    for (const row of asArray(source.deleted_skills)) {
      if (row && row.status === 'deleted-by-user') {
        const name = normalizeName(row.name);
        if (name) group.skillNames.add(name);
      }
    }
    groups.push(group);
    byId.set(source.id, group);
  }
  for (const row of asArray(ledger.deleted)) {
    if (!row || row.status !== 'deleted-by-user' || typeof row.source !== 'string') continue;
    const group = byId.get(row.source);
    const name = normalizeName(row.name);
    if (group && name) group.skillNames.add(name);
  }
  const pluginIds = new Set(groups.flatMap((group) => [...group.pluginIds]));
  const groupsBySkill = new Map();
  for (const group of groups) {
    for (const name of group.skillNames) {
      if (!groupsBySkill.has(name)) groupsBySkill.set(name, []);
      groupsBySkill.get(name).push(group);
    }
  }
  return { groups, groupsBySkill, pluginIds };
}

function menuRoots(root, activeSkillsRoot) {
  const accountBackup = path.join(root, 'account_backup');
  return {
    ledger: path.join(activeSkillsRoot, '.downloaded-skills-source-state.json'),
    activeSkills: activeSkillsRoot,
    codexSkillsAlias: path.join(root, 'skills'),
    // Installed plugins live in <plugins\cache>\<marketplace>\<plugin>; every
    // marketplace container found there is audited.
    pluginCacheRoots: [
      path.join(root, 'plugins', 'cache'),
      path.join(accountBackup, 'windows', 'login_runtime', 'plugins', 'cache'),
      path.join(accountBackup, 'windows', 'refresh_runtime', 'plugins', 'cache'),
    ],
    localMarketplacePluginParents: [
      path.join(root, '.tmp', 'plugins', 'plugins'),
      path.join(root, '.tmp', 'bundled-marketplaces', 'plugins'),
    ],
    localCatalogFiles: [
      path.join(root, '.tmp', 'plugins', '.agents', 'plugins', 'marketplace.json'),
      path.join(root, '.tmp', 'plugins', '.agents', 'plugins', 'api_marketplace.json'),
    ],
    remoteCatalogRoots: [
      path.join(root, 'cache', 'remote_plugin_catalog'),
      path.join(accountBackup, 'windows', 'login_runtime', 'cache', 'remote_plugin_catalog'),
      path.join(accountBackup, 'windows', 'refresh_runtime', 'cache', 'remote_plugin_catalog'),
    ],
  };
}

// Auditing the physical root stands for Codex's skill menu only while the
// Codex skills directory is a reparse point resolving to that exact root.
function assertActiveSkillsRoot(roots) {
  const root = assertPhysicalDirectory(roots.activeSkills, roots.activeSkills, 'active skills 实体根');
  if (fs.realpathSync.native(root).toLowerCase() !== root.toLowerCase()) {
    fail('reparse-point', `active skills 实体根的祖先链穿过 reparse point：${root}`);
  }
  const alias = lstatOrNull(roots.codexSkillsAlias);
  let aliasTarget = null;
  if (alias && isReparse(alias)) {
    try {
      aliasTarget = fs.realpathSync.native(roots.codexSkillsAlias);
    } catch {
      aliasTarget = null;
    }
  }
  if (aliasTarget === null || aliasTarget.toLowerCase() !== root.toLowerCase()) {
    fail('skills-alias-mismatch', `Codex skills 目录必须是指向 active skills 实体根的 junction：${roots.codexSkillsAlias}`);
  }
}

function frontmatterName(content) {
  if (!content.startsWith('---')) return null;
  const end = content.indexOf('\n---', 3);
  if (end < 0) return null;
  const match = content.slice(3, end).match(/^\s*name\s*:\s*(.+?)\s*$/m);
  return match ? normalizeName(match[1].replace(/^['"]|['"]$/g, '')) : null;
}

function sourceRepos(skillDirectory, activeRoot) {
  const source = path.join(skillDirectory, 'SOURCE.md');
  const stats = lstatOrNull(source);
  if (!stats || !stats.isFile() || isReparse(stats) || stats.nlink !== 1) return [];
  assertPhysicalFile(source, activeRoot, 'active SOURCE.md');
  const content = fs.readFileSync(source, 'utf8');
  return [...content.matchAll(/https?:\/\/[^\s)'"<>]+/gi)]
    .map((match) => normalizeRepo(match[0]))
    .filter(Boolean);
}

function addFinding(findings, type, target, allowedRoot, name, detail, deletionInspection = null) {
  findings.push({ type, target, allowedRoot, name, detail, deletionInspection });
}

function scanActiveSkills(roots, retired, findings, blocked) {
  if (!lstatOrNull(roots.activeSkills)) return;
  let files;
  try {
    files = safeWalk(roots.activeSkills, roots.activeSkills);
  } catch (error) {
    blocked.push({ type: 'active-skill-root-blocked', target: roots.activeSkills, detail: error.message });
    return;
  }
  for (const file of files) {
    if (path.basename(file) !== 'SKILL.md') continue;
    const name = frontmatterName(fs.readFileSync(file, 'utf8'));
    const groups = name ? retired.groupsBySkill.get(name) : null;
    if (!groups || groups.length === 0) continue;
    const directory = path.dirname(file);
    const repos = sourceRepos(directory, roots.activeSkills);
    if (repos.length === 0) {
      blocked.push({ type: 'retired-active-skill-unprovenanced', target: directory, name, detail: '同名 active skill 缺少可验证 SOURCE.md，拒绝删除。' });
      continue;
    }
    const matching = groups.find((group) => group.repo && repos.includes(group.repo));
    if (matching) {
      try {
        const deletionInspection = inspectDirectoryDeletionTree(directory, roots.activeSkills, 'retired active skill');
        addFinding(findings, 'retired-active-skill', directory, roots.activeSkills, name, `SOURCE.md 匹配已退役 source ${matching.id}`, deletionInspection);
      } catch (error) {
        blocked.push({ type: 'retired-active-skill-blocked', target: directory, name, detail: error.message });
      }
    }
  }
}

// A marketplace container that is not a plain directory is still listed, so
// scanPluginParents blocks it instead of skipping it.
function installedPluginParents(roots, blocked) {
  const parents = [];
  for (const cacheRoot of roots.pluginCacheRoots) {
    if (!lstatOrNull(cacheRoot)) continue;
    try {
      assertPhysicalDirectory(cacheRoot, cacheRoot, '插件 cache 根');
      for (const entry of fs.readdirSync(cacheRoot, { withFileTypes: true })) {
        if (entry.isDirectory() || entry.isSymbolicLink()) parents.push(path.join(cacheRoot, entry.name));
      }
    } catch (error) {
      blocked.push({ type: 'plugin-cache-root-blocked', target: cacheRoot, detail: error.message });
    }
  }
  return parents;
}

function scanPluginParents(parents, findingType, findingDetail, retired, findings, blocked) {
  for (const parent of parents) {
    const stats = lstatOrNull(parent);
    if (!stats) continue;
    if (!stats.isDirectory() || isReparse(stats)) {
      blocked.push({ type: 'plugin-parent-blocked', target: parent, detail: '插件父目录不是安全普通目录。' });
      continue;
    }
    try {
      assertPhysicalDirectory(parent, parent, '插件父目录');
      for (const entry of fs.readdirSync(parent, { withFileTypes: true })) {
        const name = normalizeName(entry.name);
        const candidate = path.join(parent, entry.name);
        const child = lstatOrNull(candidate);
        if (!name || !child || !child.isDirectory() || isReparse(child)) continue;
        if (retired.pluginIds.has(name)) {
          try {
            const deletionInspection = inspectDirectoryDeletionTree(candidate, parent, 'retired plugin directory');
            addFinding(findings, findingType, candidate, parent, name, findingDetail, deletionInspection);
          } catch (error) {
            blocked.push({ type: 'retired-plugin-directory-blocked', target: candidate, name, detail: error.message });
          }
        }
      }
    } catch (error) {
      blocked.push({ type: 'plugin-parent-blocked', target: parent, detail: error.message });
    }
  }
}

function collectPluginCatalogEntries(value, retired, entries = []) {
  if (!value || typeof value !== 'object') return entries;
  if (Array.isArray(value)) {
    for (const child of value) collectPluginCatalogEntries(child, retired, entries);
    return entries;
  }
  for (const [key, child] of Object.entries(value)) {
    if (key === 'plugins' && Array.isArray(child)) {
      for (const entry of child) {
        const name = entry && typeof entry === 'object' ? normalizeName(entry.name) : null;
        if (name && retired.pluginIds.has(name)) entries.push(name);
      }
    }
    collectPluginCatalogEntries(child, retired, entries);
  }
  return entries;
}

function prunePluginCatalogEntries(value, retired, removed) {
  if (!value || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((child) => prunePluginCatalogEntries(child, retired, removed));
  for (const key of Object.keys(value)) {
    const child = value[key];
    if (key === 'plugins' && Array.isArray(child)) {
      value[key] = child
        .filter((entry) => {
          const name = entry && typeof entry === 'object' ? normalizeName(entry.name) : null;
          if (name && retired.pluginIds.has(name)) {
            removed.push(name);
            return false;
          }
          return true;
        })
        .map((entry) => prunePluginCatalogEntries(entry, retired, removed));
    } else {
      value[key] = prunePluginCatalogEntries(child, retired, removed);
    }
  }
  return value;
}

function scanCatalogFile(file, boundary, retired, kind, findings, blocked) {
  try {
    assertPhysicalFile(file, boundary, '插件 catalog');
    const data = readJson(file);
    const names = collectPluginCatalogEntries(data, retired);
    for (const name of names) addFinding(findings, kind, file, boundary, name, 'plugins[] 中的已退役插件条目');
  } catch (error) {
    blocked.push({ type: 'catalog-blocked', target: file, detail: error.message });
  }
}

function scanCatalogs(roots, retired, surfaces, findings, blocked) {
  if (surfaces.includeLocalMarketplace) {
    for (const file of roots.localCatalogFiles) {
      if (lstatOrNull(file)) scanCatalogFile(file, path.dirname(file), retired, 'retired-local-catalog-entry', findings, blocked);
    }
  }
  if (!surfaces.includeRemoteCatalog) return;
  for (const root of roots.remoteCatalogRoots) {
    if (!lstatOrNull(root)) continue;
    try {
      for (const file of safeWalk(root, root)) {
        if (path.extname(file).toLowerCase() === '.json') {
          scanCatalogFile(file, root, retired, 'retired-remote-catalog-entry', findings, blocked);
        }
      }
    } catch (error) {
      blocked.push({ type: 'remote-catalog-root-blocked', target: root, detail: error.message });
    }
  }
}

function scan(scope, surfaces) {
  const roots = menuRoots(scope.root, scope.activeSkillsRoot);
  assertActiveSkillsRoot(roots);
  assertPhysicalFile(roots.ledger, roots.activeSkills, 'retirement ledger');
  const retired = collectRetired(roots.ledger);
  const findings = [];
  const blocked = [];
  scanActiveSkills(roots, retired, findings, blocked);
  scanPluginParents(installedPluginParents(roots, blocked), 'retired-plugin-directory', '精确已退役插件容器', retired, findings, blocked);
  if (surfaces.includeLocalMarketplace) {
    scanPluginParents(roots.localMarketplacePluginParents, 'retired-local-marketplace-directory', '本地 marketplace 副本中的精确已退役插件目录', retired, findings, blocked);
  }
  scanCatalogs(roots, retired, surfaces, findings, blocked);
  findings.sort((left, right) => left.target.localeCompare(right.target) || left.name.localeCompare(right.name));
  blocked.sort((left, right) => left.target.localeCompare(right.target) || left.type.localeCompare(right.type));
  return { roots, retired, findings, blocked, fixture: scope.fixture === true };
}

function base64Utf8(value) {
  return Buffer.from(value, 'utf8').toString('base64');
}

function runPwsh(script, label, input) {
  assertPhysicalFile(PWSH_PATH, path.dirname(PWSH_PATH), '固定 PowerShell runtime');
  assertPhysicalFile(POLICY_PATH, PROJECT_ROOT, 'handle-bound policy');
  const encoded = Buffer.from(script, 'utf16le').toString('base64');
  const result = spawnSync(PWSH_PATH, ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], {
    encoding: 'utf8',
    input,
    windowsHide: true,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) fail('powershell-launch-failed', `${label} 启动失败：${result.error.message}`);
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    const code = /CODEX_HOOK_DIRECTORY_TREE_IDENTITY_DRIFT|身份漂移|树清单|已审计树清单|target-changed/i.test(detail)
      ? 'target-changed-before-delete'
      : 'handle-bound-operation-failed';
    fail(code, `${label} 失败：${detail}`);
  }
  return result.stdout.trim();
}

function handleBoundDirectoryTreeSnapshot(target, root) {
  const script = `
$ErrorActionPreference = 'Stop'
. ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(POLICY_PATH)}')))
$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(target)}'))
$root = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(root)}'))
$snapshot = Get-CodexHookCapabilityDirectoryTreeSnapshot -Path $path -CapabilityRoot $root -AllowedExactPaths @($path) -Name 'retired plugin or skill directory'
$snapshot | ConvertTo-Json -Compress -Depth 32
`;
  let snapshot;
  try {
    snapshot = JSON.parse(runPwsh(script, 'retired plugin or skill directory snapshot'));
  } catch (error) {
    if (error instanceof SafetyError) throw error;
    fail('directory-snapshot-invalid', '目录快照输出无效。');
  }
  return snapshot;
}

function buildDirectoryDeletionManifest(tree, snapshot, label) {
  if (!snapshot || (snapshot.schemaVersion !== 1 && snapshot.schemaVersion !== 2) ||
      !Array.isArray(snapshot.rootIdentity) ||
      snapshot.rootIdentity.length !== 2 || !Array.isArray(snapshot.entries)) {
    fail('directory-snapshot-invalid', `${label} 目录快照 schema 非法。`);
  }
  const actualByPath = new Map();
  for (const entry of snapshot.entries) {
    if (!entry || typeof entry.relativePath !== 'string' ||
        (entry.kind !== 'directory' && entry.kind !== 'file') ||
        !Array.isArray(entry.identity) || entry.identity.length !== 2 ||
        actualByPath.has(entry.relativePath.toLowerCase())) {
      fail('directory-snapshot-invalid', `${label} 目录快照条目非法。`);
    }
    if (entry.kind === 'directory' ? entry.sha256 !== null :
      typeof entry.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(entry.sha256)) {
      fail('directory-snapshot-invalid', `${label} 目录快照 hash 非法。`);
    }
    actualByPath.set(entry.relativePath.toLowerCase(), entry);
  }
  if (actualByPath.size !== tree.entries.length) {
    fail('target-changed-before-delete', `${label} handle-bound 快照与已审计树条目数量不一致。`);
  }
  const entries = [];
  for (const expected of tree.entries) {
    const actual = actualByPath.get(expected.relativePath.toLowerCase());
    if (!actual || actual.kind !== expected.kind || actual.sha256 !== expected.sha256) {
      fail('target-changed-before-delete', `${label} handle-bound 快照与已审计树不一致。`);
    }
    entries.push({
      relativePath: expected.relativePath,
      kind: expected.kind,
      sha256: expected.sha256,
      identity: actual.identity,
    });
  }
  const rootEntry = entries.find((entry) => entry.relativePath === '.');
  if (!rootEntry || rootEntry.kind !== 'directory' ||
      rootEntry.identity[0] !== snapshot.rootIdentity[0] || rootEntry.identity[1] !== snapshot.rootIdentity[1]) {
    fail('directory-snapshot-invalid', `${label} 根目录身份不一致。`);
  }
  return { schemaVersion: snapshot.schemaVersion, rootIdentity: snapshot.rootIdentity, entries };
}

function handleBoundSnapshot(file, root) {
  const script = `
$ErrorActionPreference = 'Stop'
. ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(POLICY_PATH)}')))
$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(file)}'))
$root = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(root)}'))
$snapshot = Get-CodexHookCapabilityFileSnapshot -Path $path -CapabilityRoot $root -AllowedExactPaths @($path) -Name 'retired plugin catalog'
[pscustomobject][ordered]@{ exists = [bool]$snapshot.exists; state = [string]$snapshot.state; sha256 = $snapshot.sha256; identity = @($snapshot.identity) } | ConvertTo-Json -Compress
`;
  let snapshot;
  try {
    snapshot = JSON.parse(runPwsh(script, 'catalog snapshot'));
  } catch (error) {
    if (error instanceof SafetyError) throw error;
    fail('catalog-snapshot-invalid', 'catalog snapshot 输出无效。');
  }
  if (!snapshot || snapshot.exists !== true || snapshot.state !== 'regular-file'
    || typeof snapshot.sha256 !== 'string' || !Array.isArray(snapshot.identity) || snapshot.identity.length !== 2) {
    fail('catalog-snapshot-invalid', 'catalog snapshot 未返回安全普通文件身份。');
  }
  return snapshot;
}

function writeCatalogAtomically(file, root, beforeText, afterText) {
  const sourceSha = crypto.createHash('sha256').update(beforeText, 'utf8').digest('hex');
  const afterBytes = Buffer.from(afterText, 'utf8');
  const afterSha = crypto.createHash('sha256').update(afterBytes).digest('hex');
  const snapshot = handleBoundSnapshot(file, root);
  if (snapshot.sha256.toLowerCase() !== sourceSha) fail('catalog-content-drift', `catalog 读取期间发生内容漂移：${file}`);
  const script = `
$ErrorActionPreference = 'Stop'
. ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(POLICY_PATH)}')))
$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(file)}'))
$root = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(root)}'))
$identityJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(JSON.stringify(snapshot.identity))}'))
$identity = @($identityJson | ConvertFrom-Json)
$payloadStream = [Console]::OpenStandardInput()
$payloadBuffer = [IO.MemoryStream]::new()
try {
  $payloadStream.CopyTo($payloadBuffer)
  [byte[]]$bytes = $payloadBuffer.ToArray()
} finally {
  $payloadBuffer.Dispose()
}
Set-CodexHookAtomicFileBytesWithCapability -Path $path -Bytes $bytes -ExpectedExists $true -ExpectedSha256 '${sourceSha}' -ExpectedIdentity $identity -AfterSha256 '${afterSha}' -CapabilityRoot $root -AllowedExactPaths @($path) -Scope 'retired plugin catalog'
`;
  runPwsh(script, 'catalog atomic rewrite', afterBytes);
}

function maybeMutateFixtureDirectory(target, fixtureMode) {
  if (!fixtureMode) return;
  const targetName = path.basename(target);
  const rootSwap = process.env[FIXTURE_SWAP_TARGET_ENV] === targetName;
  const nestedReplace = process.env[FIXTURE_NESTED_CHILD_REPLACE_TARGET_ENV] === targetName;
  const nestedAdd = process.env[FIXTURE_NESTED_CHILD_ADD_TARGET_ENV] === targetName;
  if ([rootSwap, nestedReplace, nestedAdd].filter(Boolean).length > 1) {
    fail('fixture-mutation-ambiguous', '同一 fixture 目录只能启用一种删除前变异。');
  }
  if (rootSwap) {
    const parked = target + '.fixture-predelete-parked';
    if (lstatOrNull(parked)) fail('fixture-swap-invalid', `fixture parked 目标已存在：${parked}`);
    fs.renameSync(target, parked);
    fs.mkdirSync(target);
    fs.writeFileSync(path.join(target, '.fixture-predelete-sentinel'), 'must survive handle-bound root identity refusal\n', 'utf8');
    return;
  }
  if (!nestedReplace && !nestedAdd) return;
  const nested = path.join(target, '!nested');
  const nestedStats = lstatOrNull(nested);
  if (!nestedStats || isReparse(nestedStats) || !nestedStats.isDirectory()) {
    fail('fixture-nested-mutation-invalid', `fixture !nested 目录不存在或不安全：${nested}`);
  }
  if (nestedReplace) {
    const parked = target + '.fixture-nested-predelete-parked';
    if (lstatOrNull(parked)) fail('fixture-nested-mutation-invalid', `fixture nested parked 目录已存在：${parked}`);
    fs.renameSync(nested, parked);
    fs.mkdirSync(nested);
    fs.writeFileSync(path.join(nested, '.fixture-nested-replacement-sentinel'), 'must survive nested identity refusal\n', 'utf8');
    return;
  }
  fs.writeFileSync(path.join(nested, '.fixture-nested-added-sentinel'), 'must survive manifest membership refusal\n', 'utf8');
}

function removeDirectoryHandleBound(target, root, manifest, fixtureMode) {
  maybeMutateFixtureDirectory(target, fixtureMode);
  const script = `
$ErrorActionPreference = 'Stop'
. ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(POLICY_PATH)}')))
$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(target)}'))
$root = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Utf8(root)}'))
$payloadStream = [Console]::OpenStandardInput()
$payloadBuffer = [IO.MemoryStream]::new()
try {
  $payloadStream.CopyTo($payloadBuffer)
  $manifest = ([Text.Encoding]::UTF8.GetString($payloadBuffer.ToArray()) | ConvertFrom-Json -Depth 64)
} finally {
  $payloadBuffer.Dispose()
}
Remove-CodexHookCapabilityDirectoryTree -Path $path -CapabilityRoot $root -AllowedExactPaths @($path) -ExpectedRootIdentity @($manifest.rootIdentity) -ExpectedTreeManifest $manifest -Scope 'retired plugin or skill directory'
`;
  runPwsh(script, 'retired plugin or skill directory deletion', Buffer.from(JSON.stringify(manifest), 'utf8'));
  if (lstatOrNull(target)) fail('delete-incomplete', `删除后目标仍存在：${target}`);
}

function apply(scanResult, dryRun) {
  const directoryFindings = new Map();
  const catalogFindings = new Map();
  for (const finding of scanResult.findings) {
    if (finding.type === 'retired-plugin-directory' || finding.type === 'retired-local-marketplace-directory' ||
        finding.type === 'retired-active-skill') {
      directoryFindings.set(finding.target.toLowerCase(), finding);
    } else if (finding.type.endsWith('catalog-entry')) {
      catalogFindings.set(finding.target.toLowerCase(), finding);
    }
  }

  // Validate all catalogs before deleting any installed payload.  A hard link,
  // reparse point, invalid JSON, or concurrent rewrite fails the full apply.
  const catalogPlans = [];
  for (const finding of catalogFindings.values()) {
    const file = assertPhysicalFile(finding.target, finding.allowedRoot, '插件 catalog');
    const before = fs.readFileSync(file, 'utf8');
    const data = JSON.parse(before);
    const removed = [];
    const next = prunePluginCatalogEntries(data, scanResult.retired, removed);
    const after = `${JSON.stringify(next, null, 2)}\n`;
    if (removed.length === 0 || after === before) fail('catalog-plan-drift', `catalog 计划与扫描结果不一致：${file}`);
    handleBoundSnapshot(file, finding.allowedRoot);
    catalogPlans.push({ file, root: finding.allowedRoot, before, after, removed: [...new Set(removed)].sort() });
  }

  const directoryPlans = [];
  for (const finding of directoryFindings.values()) {
    if (!finding.deletionInspection) {
      fail('invalid-directory-inspection', `退休目录缺少已审计树：${finding.target}`);
    }
    const current = inspectDirectoryDeletionTree(finding.target, finding.allowedRoot, 'retired plugin or skill directory');
    if (!sameDirectoryDeletionTree(current, finding.deletionInspection)) {
      fail('target-changed-before-delete', `退休目录在预检与删除清单之间发生漂移：${finding.target}`);
    }
    const snapshot = handleBoundDirectoryTreeSnapshot(finding.target, finding.allowedRoot);
    const afterSnapshotIdentity = directoryNodeIdentity(finding.target, 'retired plugin or skill directory');
    if (!sameDirectoryNodeIdentity(afterSnapshotIdentity, finding.deletionInspection.nodeIdentity)) {
      fail('target-changed-before-delete', `退休目录在 handle-bound 快照期间被替换：${finding.target}`);
    }
    const manifest = buildDirectoryDeletionManifest(current, snapshot, 'retired plugin or skill directory');
    directoryPlans.push({ finding, manifest });
  }

  if (dryRun) {
    return {
      removedDirectories: directoryPlans.map((plan) => plan.finding.target),
      modifiedCatalogs: catalogPlans.map((plan) => ({ file: plan.file, removedEntries: plan.removed })),
    };
  }

  const removedDirectories = [];
  for (const plan of directoryPlans) {
    removeDirectoryHandleBound(plan.finding.target, plan.finding.allowedRoot, plan.manifest, scanResult.fixture === true);
    removedDirectories.push(plan.finding.target);
  }
  const modifiedCatalogs = [];
  for (const plan of catalogPlans) {
    writeCatalogAtomically(plan.file, plan.root, plan.before, plan.after);
    modifiedCatalogs.push({ file: plan.file, removedEntries: plan.removed });
  }
  return { removedDirectories, modifiedCatalogs };
}

function assertFixtureRoot(raw) {
  if (process.env[FIXTURE_ENV] !== '1') fail('fixture-mode-disabled', '--fixture-root 仅允许受控测试进程使用。');
  if (!path.isAbsolute(raw)) fail('invalid-fixture-root', '--fixture-root 必须是绝对路径。');
  const root = path.resolve(raw);
  const reportsRoot = path.join(PROJECT_ROOT, 'reports');
  if (!isInside(root, reportsRoot) || path.basename(root).toLowerCase() !== '.codex') {
    fail('invalid-fixture-root', 'fixture root 必须位于项目 reports 的专用 .codex 子树。');
  }
  const parent = path.dirname(root);
  if (!path.basename(parent).startsWith(FIXTURE_PREFIX) || !/^[0-9a-f]{32}$/i.test(path.basename(parent).slice(FIXTURE_PREFIX.length))) {
    fail('invalid-fixture-root', 'fixture parent 必须使用固定随机前缀。');
  }
  assertPhysicalDirectory(root, reportsRoot, 'fixture root');
  const marker = assertPhysicalFile(path.join(root, FIXTURE_MARKER), root, 'fixture marker');
  if (fs.readFileSync(marker, 'utf8') !== FIXTURE_MARKER_VALUE) fail('invalid-fixture-marker', 'fixture marker 内容不匹配。');
  return root;
}

function resolveScope(fixtureRoot) {
  if (fixtureRoot !== null) {
    const root = assertFixtureRoot(fixtureRoot);
    // The fixture mirrors the live split: <parent>\.codex plus a physical
    // <parent>\skills-manager\skills that the caller cannot relocate.
    return { root, activeSkillsRoot: path.join(path.dirname(root), 'skills-manager', 'skills'), fixture: true };
  }
  return {
    root: assertPhysicalDirectory(LIVE_CODEX_ROOT, LIVE_CODEX_ROOT, 'live Codex root'),
    activeSkillsRoot: LIVE_ACTIVE_SKILLS_ROOT,
    fixture: false,
  };
}

function publicFinding(finding) {
  return { type: finding.type, target: finding.target, name: finding.name, detail: finding.detail };
}

// Opt-in surfaces are scanned only on request, so every finding is enforced.
function makePayload(options) {
  const installedFindings = options.findings.filter((finding) => (
    finding.type === 'retired-active-skill' || finding.type === 'retired-plugin-directory'));
  const catalogFindings = options.findings.filter((finding) => finding.type.includes('catalog'));
  return {
    schemaVersion: 3,
    ok: !options.error && options.findings.length === 0 && options.blocked.length === 0,
    mode: options.apply ? 'apply' : 'audit',
    dryRun: options.dryRun,
    fixture: options.fixture,
    includeLocalMarketplace: options.includeLocalMarketplace,
    includeRemoteCatalog: options.includeRemoteCatalog,
    retirementPolicy: 'no-local-retired-skill-or-plugin-payload-backups',
    retiredPluginIds: [...options.retired.pluginIds].sort(),
    findingCount: options.findings.length,
    installedFindingCount: installedFindings.length,
    localMarketplaceFindingCount: options.findings.filter((finding) => finding.type.startsWith('retired-local-')).length,
    remoteCatalogFindingCount: catalogFindings.filter((finding) => finding.type === 'retired-remote-catalog-entry').length,
    findings: options.findings.map(publicFinding),
    observedCatalogFindings: catalogFindings.map(publicFinding),
    blockedCount: options.blocked.length,
    blocked: options.blocked,
    result: options.result || null,
    error: options.error || null,
  };
}

function main() {
  let args = { apply: false, dryRun: false, includeRemoteCatalog: false, includeLocalMarketplace: false, fixtureRoot: null };
  let scope = { root: LIVE_CODEX_ROOT, fixture: false };
  let scanResult = { retired: { pluginIds: new Set() }, findings: [], blocked: [] };
  try {
    args = parseArguments(process.argv.slice(2));
    scope = resolveScope(args.fixtureRoot);
    scanResult = scan(scope, args);
    if (scanResult.blocked.length > 0) fail('blocked-menu-surface', '存在无法安全处理的退休菜单表面。');
    let result = null;
    if (args.apply) {
      result = apply(scanResult, args.dryRun);
      if (!args.dryRun) {
        scanResult = scan(scope, args);
        if (scanResult.blocked.length > 0 || scanResult.findings.length > 0) {
          fail('post-apply-not-clean', 'Apply 后仍有退休菜单、插件或 catalog 表面。');
        }
      }
    }
    const payload = makePayload({
      ...args,
      fixture: scope.fixture,
      retired: scanResult.retired,
      findings: scanResult.findings,
      blocked: scanResult.blocked,
      result,
      error: null,
    });
    console.log(JSON.stringify(payload, null, 2));
    if (!args.apply && !payload.ok) process.exitCode = 1;
  } catch (error) {
    const payload = makePayload({
      ...args,
      fixture: scope.fixture,
      retired: scanResult.retired,
      findings: scanResult.findings,
      blocked: scanResult.blocked,
      result: null,
      error: { code: error instanceof SafetyError ? error.code : 'unexpected-error', message: error instanceof Error ? error.message : String(error) },
    });
    console.log(JSON.stringify(payload, null, 2));
    process.exitCode = 1;
  }
}

module.exports = {
  FIXTURE_ENV,
  FIXTURE_SWAP_TARGET_ENV,
  FIXTURE_NESTED_CHILD_REPLACE_TARGET_ENV,
  FIXTURE_NESTED_CHILD_ADD_TARGET_ENV,
  FIXTURE_MARKER,
  FIXTURE_MARKER_VALUE,
  FIXTURE_PREFIX,
  LIVE_ACTIVE_SKILLS_ROOT,
  LIVE_CODEX_ROOT,
  SOURCE_PLUGIN_ALIASES,
  collectRetired,
  isInside,
};

if (require.main === module) main();
