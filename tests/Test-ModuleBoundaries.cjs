'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const MANIFEST_PATH = path.join(PROJECT_ROOT, 'modules', 'manifest.json');
const VALIDATOR_PATH = path.join(PROJECT_ROOT, 'scripts', 'Validate-ModuleBoundaries.cjs');
const POWERSHELL_RUNNER_PATH = path.join(PROJECT_ROOT, 'scripts', 'Run-PowerShellTests.cjs');
const MANIFEST_RUNNER_PATH = path.join(PROJECT_ROOT, 'scripts', 'Run-ManifestTests.cjs');

assert.equal(fs.existsSync(VALIDATOR_PATH), true, 'module boundary validator must exist');

const {
  checkCommitScope,
  validateCrossModuleCodeReferences,
  validateManifest,
  validateOwnership,
  validateRepository,
  workTree,
} = require(VALIDATOR_PATH);

const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
const tree = workTree(PROJECT_ROOT);
const repositoryFiles = tree.files;
const expectedModules = [
  'codex-host',
  'dev-environment',
  'host-safety',
  'skill-supply-chain',
  'workstation-operations',
];

assert.deepEqual(
  manifest.modules.map((entry) => entry.id).sort(),
  expectedModules,
  'manifest must define the five approved modules',
);
assert.deepEqual(
  validateManifest(manifest, tree),
  [],
  'module manifest structure must be valid',
);
assert.deepEqual(
  validateOwnership(manifest, repositoryFiles),
  [],
  'every repository file must have exactly one owner',
);
assert.deepEqual(
  validateCrossModuleCodeReferences(manifest, repositoryFiles, tree),
  [],
  'cross-module code references must use declared dependency interfaces',
);

const duplicateManifest = structuredClone(manifest);
duplicateManifest.modules[0].ownership.files.push('README.md');
assert.match(
  validateOwnership(duplicateManifest, ['README.md']).join('\n'),
  /multiple owners/i,
  'duplicate ownership must fail closed',
);

const unownedManifest = structuredClone(manifest);
unownedManifest.shared.ownership.files = unownedManifest.shared.ownership.files
  .filter((entry) => entry !== '.gitattributes');
assert.match(
  validateOwnership(unownedManifest, ['.gitattributes']).join('\n'),
  /no owner/i,
  'unowned files must fail closed',
);

const orphanTestManifest = structuredClone(manifest);
const orphanTestHostSafety = orphanTestManifest.modules.find((entry) => entry.id === 'host-safety');
const orphanTestPath = 'tests/Test-CodexSafeTreeDeleteNativeLoading.ps1';
assert.ok(orphanTestHostSafety.ownership.files.includes(orphanTestPath));
for (const profile of Object.values(orphanTestHostSafety.tests)) {
  for (const kind of Object.keys(profile)) {
    profile[kind] = profile[kind].filter((entry) => entry !== orphanTestPath);
  }
}
assert.match(
  validateManifest(orphanTestManifest, tree).join('\n'),
  /owned test file is not in any test profile: tests\/Test-CodexSafeTreeDeleteNativeLoading\.ps1/i,
  'an owned test file missing from every profile must fail closed',
);

function listPowerShellTests(...args) {
  const result = spawnSync(process.execPath, [POWERSHELL_RUNNER_PATH, ...args, '--list'], {
    cwd: PROJECT_ROOT,
    encoding: 'utf8',
    windowsHide: true,
  });
  assert.equal(result.status, 0, String(result.stderr || result.stdout));
  return String(result.stdout || '');
}

const codexHostFixtureTests = listPowerShellTests('--module', 'codex-host');
assert.match(codexHostFixtureTests, /Test-CodexHookPolicy\.ps1/);
assert.doesNotMatch(codexHostFixtureTests, /VendorAbortStress|LauncherTerminalEnvironment|IfeoRouter/);

const codexHostLiveTests = listPowerShellTests('--module', 'codex-host', '--profile', 'host-live');
assert.match(codexHostLiveTests, /Test-CodexRemotePluginCatalogGuardVendorAbortStress\.ps1/);
assert.match(codexHostLiveTests, /Test-CodexLauncherTerminalEnvironment\.ps1/);

const devEnvironmentCiTests = listPowerShellTests('--module', 'dev-environment', '--profile', 'ci');
assert.match(devEnvironmentCiTests, /Test-EnvInventoryTrust\.ps1/);
const devEnvironmentCiTestNames = new Set(devEnvironmentCiTests.trim().split(/\r?\n/));
for (const hostInventoryTest of [
  'Test-EnvInventory.ps1',
  'Test-EnvMigrationPlan.ps1',
  'Test-EnvUpdateReadiness.ps1',
  'Test-ProjectLocalEnvReviewPack.ps1',
]) {
  assert.equal(devEnvironmentCiTestNames.has(hostInventoryTest), false);
}

function runManifestRunner(args, env = {}) {
  return spawnSync(process.execPath, [MANIFEST_RUNNER_PATH, ...args], {
    cwd: PROJECT_ROOT,
    encoding: 'utf8',
    env: { ...process.env, GITHUB_ACTIONS: '', ...env },
    windowsHide: true,
  });
}

function listManifestTests(...args) {
  const result = runManifestRunner([...args, '--list']);
  assert.equal(result.status, 0, String(result.stderr || result.stdout));
  return result.stdout.trim().split(/\r?\n/);
}

const { HOST_BOUND_TESTS, buildTestPlan } = require(MANIFEST_RUNNER_PATH);
for (const kind of ['python', 'node']) {
  assert.deepEqual(
    listManifestTests('--kind', kind).sort(),
    [manifest.shared, ...manifest.modules].flatMap((owner) => owner.tests?.fixture?.[kind] ?? []).sort(),
    `manifest runner must list every ${kind} fixture test`,
  );
}

const ciList = runManifestRunner(['--list', '--exclude-host-bound'], { GITHUB_ACTIONS: 'true' });
assert.equal(ciList.status, 0, String(ciList.stderr || ciList.stdout));
const ciLines = ciList.stdout.trim().split(/\r?\n/);
assert.ok(Object.keys(HOST_BOUND_TESTS).length > 0);
for (const [testPath, reason] of Object.entries(HOST_BOUND_TESTS)) {
  const report = `Not run (host-bound): ${testPath} - ${reason}`;
  assert.equal(ciLines.includes(testPath), false, `${testPath} must not run on CI`);
  assert.ok(ciLines.includes(report), `${testPath} must be reported as host-bound with its reason`);
  assert.ok(
    ciLines.includes(`::warning title=Host-bound test not run::${report}`),
    `${testPath} must raise a GitHub Actions warning`,
  );
}

const fixtureScriptTests = new Set(listManifestTests());
for (const [moduleId, liveStateTest] of [
  ['codex-host', 'tests/Test-CodexStatePathInventory.py'],
  ['skill-supply-chain', 'tests/Test-GitDefaultBranchSkillPolicy.cjs'],
  ['skill-supply-chain', 'tests/Test-SuperpowersSkillRetirement.cjs'],
]) {
  assert.equal(fixtureScriptTests.has(liveStateTest), false, `${liveStateTest} reads live host state`);
  assert.ok(listManifestTests('--module', moduleId, '--profile', 'host-live').includes(liveStateTest));
}

assert.throws(
  () => buildTestPlan(manifest, { hostBoundTests: { 'tests/Test-Missing.py': 'removed test' } }),
  /not a manifest python or node test: tests\/Test-Missing\.py/,
  'a stale host-bound entry must fail closed',
);
for (const [args, message] of [
  [['--module', 'missing-module', '--list'], /Unknown module: missing-module/],
  [['--kind', 'powershell', '--list'], /Unknown test kind: powershell/],
]) {
  const rejected = runManifestRunner(args);
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, message);
}

const hostSafetyModule = manifest.modules.find((entry) => entry.id === 'host-safety');
const codexHostModule = manifest.modules.find((entry) => entry.id === 'codex-host');
assert.deepEqual(hostSafetyModule.transitionalDependencies, []);
assert.deepEqual(codexHostModule.dependsOn, ['host-safety', 'workstation-operations']);
const workstationModule = manifest.modules.find((entry) => entry.id === 'workstation-operations');
assert.deepEqual(workstationModule.dependsOn, ['host-safety']);
assert.ok(workstationModule.interfaces.includes('scripts/daily-update/Read-DailyUpdateEvidence.ps1'));

const missingInterfaceManifest = structuredClone(manifest);
const missingInterfaceHostSafety = missingInterfaceManifest.modules
  .find((entry) => entry.id === 'host-safety');
missingInterfaceHostSafety.interfaces = missingInterfaceHostSafety.interfaces
  .filter((entry) => entry !== 'scripts/lib/CodexHookHandleBoundIO.cs');
assert.match(
  validateCrossModuleCodeReferences(
    missingInterfaceManifest,
    [
      'scripts/Invoke-CodexRemotePluginCatalogGuard.ps1',
      'scripts/lib/CodexHookHandleBoundIO.cs',
    ],
    tree,
  ).join('\n'),
  /undeclared host-safety interface: codexhookhandleboundio\.cs/i,
  'an undeclared cross-module code seam must fail closed',
);

const hostSafetyPath = path.join(PROJECT_ROOT, 'scripts', 'lib', 'CodexHostSafety.ps1');
const hookPolicyPath = path.join(PROJECT_ROOT, 'scripts', 'lib', 'CodexHookPolicy.ps1');
const safeDeleteEntryPath = path.join(PROJECT_ROOT, 'scripts', 'Invoke-CodexSafeTreeDelete.ps1');
const hostSafetySource = fs.readFileSync(hostSafetyPath, 'utf8');
const hookPolicySource = fs.readFileSync(hookPolicyPath, 'utf8');
const safeDeleteEntrySource = fs.readFileSync(safeDeleteEntryPath, 'utf8');
assert.match(hookPolicySource, /CodexHostSafety\.ps1/);
assert.match(safeDeleteEntrySource, /CodexHostSafety\.ps1/);
assert.doesNotMatch(safeDeleteEntrySource, /CodexHookPolicy\.ps1/);

for (const functionName of [
  'Assert-CodexHookJsonElementUniqueProperties',
  'Assert-CodexHookStrictJsonText',
  'Assert-CodexHookString',
  'Assert-CodexHookDPath',
  'Test-CodexHookPathWithin',
  'Resolve-CodexHookAllowedReadPath',
  'Get-CodexHookSafeFileProbe',
  'Get-CodexHookInnermostException',
  'Get-CodexHookHandleBoundFileSnapshot',
  'Read-CodexHookSafeUtf8FileSnapshot',
  'Get-CodexHookTextSha256',
  'Get-CodexHookBytesSha256',
  'Assert-CodexHookNoReparseAncestor',
  'Assert-CodexHookCapabilityPath',
  'Get-CodexHookCapabilityFileSnapshot',
  'New-CodexHookCapabilityDirectory',
  'Assert-CodexHookSnapshotExpectedState',
  'Set-CodexHookAtomicFileBytesWithCapability',
  'Test-CodexHookDirectoryTreeIdentityEqual',
  'Assert-CodexHookDirectoryTreeIdentity',
  'Get-CodexHookDirectoryTreeRelativeParent',
  'Get-CodexHookDirectoryTreeRelativeLeaf',
  'Assert-CodexHookDirectoryTreeRelativePath',
  'Assert-CodexHookDirectoryTreeExactProperties',
  'Get-CodexHookCapabilityDirectoryTreeSnapshot',
  'ConvertTo-CodexHookExpectedDirectoryTreeManifest',
  'Remove-CodexHookCapabilityTreeFileWithDirectoryGuard',
  'Remove-CodexHookCapabilityDirectoryTree',
  'Set-CodexHookCapabilityJson',
]) {
  const definition = new RegExp(`^function ${functionName}\\b`, 'm');
  assert.match(hostSafetySource, definition, `${functionName} must be owned by host-safety`);
  assert.doesNotMatch(hookPolicySource, definition, `${functionName} must not be duplicated in hook policy`);
}

for (const fileName of [
  'EnvPathSafety.ps1',
  'ReportArtifactPublisher.ps1',
  'TrustedReportInput.ps1',
]) {
  const adapterPath = path.join(PROJECT_ROOT, 'scripts', 'lib', fileName);
  const implementationPath = path.join(PROJECT_ROOT, 'modules', 'host-safety', 'lib', fileName);
  assert.equal(fs.existsSync(implementationPath), true, `${fileName} implementation must live in host-safety`);
  assert.match(
    fs.readFileSync(adapterPath, 'utf8'),
    new RegExp(`modules\\\\host-safety\\\\lib\\\\${fileName.replace('.', '\\.')}`),
    `${fileName} legacy adapter must load the module implementation`,
  );
}

const skillSupplyChain = manifest.modules.find((entry) => entry.id === 'skill-supply-chain');
const skillImplementationRoot = path.join(PROJECT_ROOT, 'modules', 'skill-supply-chain', 'implementation');
const skillTestRoot = path.join(PROJECT_ROOT, 'modules', 'skill-supply-chain', 'tests');
for (const fileName of [
  'skill_source_record.py',
  'generate_skill_catalog.py',
  'system_skill_provenance_repair.py',
  'system_package_identity.py',
  'install_skill_guarded.py',
  'reconcile_skill_source_records.py',
]) {
  assert.equal(
    fs.existsSync(path.join(skillImplementationRoot, fileName)),
    true,
    `${fileName} implementation must live in skill-supply-chain`,
  );
}
for (const fileName of [
  'Test-SkillCatalog.py',
  'Test-SkillInstallGuarded.py',
  'Test-SkillSourceRecordMigration.py',
]) {
  assert.equal(
    fs.existsSync(path.join(skillTestRoot, fileName)),
    true,
    `${fileName} hot-path test must be local to skill-supply-chain`,
  );
}
assert.ok(
  skillSupplyChain.interfaces.includes('scripts/install_skill_guarded.py'),
  'skill-supply-chain must retain the guarded installer root adapter seam',
);
for (const adapterName of [
  'skill_source_record.py',
  'generate_skill_catalog.py',
  'install_skill_guarded.py',
  'reconcile_skill_source_records.py',
]) {
  const adapterSource = fs.readFileSync(path.join(PROJECT_ROOT, 'scripts', adapterName), 'utf8');
  assert.match(adapterSource, /"skill-supply-chain"/);
  assert.match(adapterSource, /"implementation"/);
}

const hostEvidenceModulePath = path.join(PROJECT_ROOT, 'modules', 'codex-host', 'CodexHostHookEvidence.ps1');
const hostReconcilerSource = fs.readFileSync(
  path.join(PROJECT_ROOT, 'scripts', 'Invoke-CodexHostHookReconciliation.ps1'),
  'utf8',
);
assert.equal(fs.existsSync(hostEvidenceModulePath), true, 'codex-host evidence lifecycle must be module-local');
assert.match(hostReconcilerSource, /CodexHostHookEvidence\.ps1/);
assert.match(hostReconcilerSource, /New-CodexHostHookEvidenceSnapshot/);

// A commit scope that names a module or shared must own one of the staged files; any other scope is free text.
const publisherFiles = ['scripts/Publish-GitHubIssueComment.ps1', 'tests/Test-PublishGitHubIssueComment.ps1'];
assert.match(
  checkCommitScope(manifest, "fix(workstation-operations): 评论发布脚本的 gh 命令始终按数组取，修掉生产路径只剩 'g'", publisherFiles).join('\n'),
  /^commit scope "workstation-operations" names a module that owns none of the staged files \(their owners: shared\)/,
  '272fd4c named a module that owns neither of its files',
);
assert.match(
  checkCommitScope(manifest, '# git comment\n\nfeat(host-safety, shared)!: x\n', publisherFiles).join('\n'),
  /^commit scope "host-safety" names a module/,
  'each module in a scope list is checked, after comment and blank lines',
);
for (const [message, files] of [
  ['fix(shared): x', publisherFiles],
  ['feat(shared)!: x', publisherFiles],
  ['docs(zi-xi-shi): x', ['docs/environments/zi-xi-shi.md']],
  ['feat(claude-hooks): x', ['managed/claude-hooks/claude-public-push-guard.mjs']],
  ['fix: x', publisherFiles],
  ["Merge branch 'topic'", publisherFiles],
  ['fix(workstation-operations): x', []],
]) {
  assert.deepEqual(checkCommitScope(manifest, message, files), [], `${message} must pass`);
}

// --owners names each path's module and test profiles; a path with no single owner fails.
const runValidator = (...args) => spawnSync(process.execPath, [VALIDATOR_PATH, ...args], {
  cwd: PROJECT_ROOT,
  encoding: 'utf8',
  windowsHide: true,
});
let owners = runValidator('--owners', 'scripts/Publish-GitHubIssueComment.ps1', path.join(PROJECT_ROOT, 'docs', 'environments', 'zi-xi-shi.md'));
assert.equal(owners.status, 0, owners.stderr);
assert.match(owners.stdout, /^scripts\/Publish-GitHubIssueComment\.ps1: shared \(test profiles: fixture\)$/m);
assert.match(owners.stdout, /^docs\/environments\/zi-xi-shi\.md: workstation-operations \(test profiles: fixture\)$/m);
owners = runValidator('--owners', 'no/such/file.txt', '--json');
assert.equal(owners.status, 1);
assert.deepEqual(JSON.parse(owners.stdout), [{ argument: 'no/such/file.txt', path: 'no/such/file.txt', owners: [] }]);
owners = runValidator('--owners', path.join(path.parse(PROJECT_ROOT).root, 'outside.txt'));
assert.equal(owners.status, 1);
assert.match(owners.stdout, /outside\.txt: outside the repository$/m);
for (const [args, message] of [
  [['--owners'], /--owners requires at least one path/],
  [['--commit-msg'], /--commit-msg requires the message file/],
  [['--owners', 'README.md', '--rev', 'HEAD'], /--rev only applies to the boundary check/],
]) {
  const rejected = runValidator(...args);
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, message);
}

// --rev checks the files, code text and manifest of a commit, not the work tree around it.
const revisionRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'module-boundaries-rev-'));
try {
  const runFixtureGit = (...args) => spawnSync('git', [
    '-c', 'core.autocrlf=false',
    '-c', 'user.name=Test',
    '-c', 'user.email=test@example.invalid',
    '-c', 'commit.gpgsign=false',
    ...args,
  ], { cwd: revisionRoot, encoding: 'utf8', windowsHide: true });
  const fixtureGit = (...args) => {
    const result = runFixtureGit(...args);
    assert.equal(result.status, 0, String(result.stderr || result.stdout));
    return String(result.stdout).trim();
  };
  const write = (repositoryPath, text) => {
    const fullPath = path.join(revisionRoot, ...repositoryPath.split('/'));
    fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    fs.writeFileSync(fullPath, text);
  };
  const fixtureModule = (id) => ({
    id,
    summary: id,
    context: `modules/${id}/CONTEXT.md`,
    interfaces: [`modules/${id}/${id}_api.py`],
    dependsOn: [],
    tests: { fixture: { powershell: [], python: [], node: [] } },
    ownership: { prefixes: [`modules/${id}/`] },
  });
  const committedManifest = {
    schemaVersion: 1,
    modules: [fixtureModule('alpha'), fixtureModule('beta')],
    shared: { ownership: { files: ['modules/manifest.json'] } },
  };
  write('modules/manifest.json', JSON.stringify(committedManifest));
  write('modules/alpha/CONTEXT.md', '# alpha\n');
  write('modules/alpha/alpha_api.py', 'VALUE = 1\n');
  write('modules/beta/CONTEXT.md', '# beta\n');
  write('modules/beta/beta_api.py', '# loads alpha_api.py\n');
  write('stray.txt', 'unowned\n');
  fixtureGit('init', '-q');
  fixtureGit('add', '-A');
  fixtureGit('commit', '-q', '-m', 'base');

  // The work tree fixes both committed violations and owns an untracked file in an uncommitted manifest edit.
  fs.unlinkSync(path.join(revisionRoot, 'stray.txt'));
  write('modules/beta/beta_api.py', 'VALUE = 2\n');
  write('untracked.txt', 'owned by the work-tree manifest only\n');
  write('modules/manifest.json', JSON.stringify({
    ...committedManifest,
    shared: { ownership: { files: ['modules/manifest.json', 'untracked.txt'] } },
  }));

  assert.deepEqual(validateRepository(revisionRoot), { ok: true, files: 6, modules: 2, errors: [] });
  assert.deepEqual(validateRepository(revisionRoot, { revision: 'HEAD' }), {
    ok: false,
    files: 6,
    modules: 2,
    errors: [
      'stray.txt: no owner',
      'modules/beta/beta_api.py references alpha_api.py without dependency beta -> alpha',
    ],
  });

  // --commit-msg takes the manifest and the staged files from the index being committed.
  const messagePath = path.join(revisionRoot, '.git', 'TEST_COMMIT_MSG');
  const checkMessage = (message) => {
    fs.writeFileSync(messagePath, message);
    return spawnSync(process.execPath, [VALIDATOR_PATH, '--commit-msg', messagePath], {
      cwd: revisionRoot,
      encoding: 'utf8',
      windowsHide: true,
    });
  };
  fixtureGit('add', 'modules/beta/beta_api.py');
  let checked = checkMessage('fix(alpha): change beta\n');
  assert.equal(checked.status, 1);
  assert.match(checked.stderr, /commit scope "alpha" names a module that owns none of the staged files \(their owners: beta\)/);
  assert.equal(checkMessage('fix(beta): change beta\n').status, 0);
  assert.equal(checkMessage('docs(device): note\n').status, 0);
  fixtureGit('reset', '-q');
  // untracked.txt is shared only in the work-tree manifest until that manifest is staged too.
  fixtureGit('add', 'untracked.txt');
  checked = checkMessage('feat(shared): own untracked.txt\n');
  assert.equal(checked.status, 1, 'ownership comes from the staged manifest');
  assert.match(checked.stderr, /\(their owners: no module\)/);
  fixtureGit('add', 'modules/manifest.json');
  checked = checkMessage('feat(shared): own untracked.txt\n');
  assert.equal(checked.status, 0, checked.stderr);
  fixtureGit('reset', '-q');
  // An index without the manifest has no modules to check, and a subject without a scope needs no repository.
  fixtureGit('rm', '-q', '--cached', 'modules/manifest.json');
  checked = checkMessage('fix(alpha): drop the manifest\n');
  assert.equal(checked.status, 0, checked.stderr);
  fixtureGit('reset', '-q');
  fs.writeFileSync(messagePath, 'probe\n');
  checked = spawnSync(process.execPath, [VALIDATOR_PATH, '--commit-msg', messagePath], {
    cwd: path.parse(PROJECT_ROOT).root,
    encoding: 'utf8',
    windowsHide: true,
  });
  assert.equal(checked.status, 0, checked.stderr);

  // The commit-msg hook runs the check on a real commit.
  fixtureGit('config', 'core.hooksPath', path.join(PROJECT_ROOT, '.githooks'));
  fixtureGit('add', 'modules/beta/beta_api.py');
  const headBefore = fixtureGit('rev-parse', 'HEAD');
  const rejectedCommit = runFixtureGit('commit', '-q', '-m', 'fix(alpha): change beta');
  assert.notEqual(rejectedCommit.status, 0, 'the hook must reject a scope that owns no staged file');
  assert.match(rejectedCommit.stderr, /commit scope "alpha"/);
  assert.equal(fixtureGit('rev-parse', 'HEAD'), headBefore);
  fixtureGit('commit', '-q', '-m', 'fix(beta): change beta');
  assert.notEqual(fixtureGit('rev-parse', 'HEAD'), headBefore);
} finally {
  fs.rmSync(revisionRoot, { recursive: true, force: true, maxRetries: 3 });
}

const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
for (const [args, message] of [
  [['--rev'], /--rev requires a commit or tree/],
  [['--rev', EMPTY_TREE], new RegExp(`modules/manifest\\.json is not in ${EMPTY_TREE}`)],
]) {
  const rejected = spawnSync(process.execPath, [VALIDATOR_PATH, ...args], {
    cwd: PROJECT_ROOT,
    encoding: 'utf8',
    windowsHide: true,
  });
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, message);
}

console.log(`PASS Test-ModuleBoundaries files=${repositoryFiles.length} modules=${manifest.modules.length}`);
