'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const MANIFEST_PATH = path.join(PROJECT_ROOT, 'modules', 'manifest.json');
const VALIDATOR_PATH = path.join(PROJECT_ROOT, 'scripts', 'Validate-ModuleBoundaries.cjs');
const POWERSHELL_RUNNER_PATH = path.join(PROJECT_ROOT, 'scripts', 'Run-PowerShellTests.cjs');
const MANIFEST_RUNNER_PATH = path.join(PROJECT_ROOT, 'scripts', 'Run-ManifestTests.cjs');

assert.equal(fs.existsSync(VALIDATOR_PATH), true, 'module boundary validator must exist');

const {
  collectRepositoryFiles,
  validateCrossModuleCodeReferences,
  validateManifest,
  validateOwnership,
} = require(VALIDATOR_PATH);

const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
const repositoryFiles = collectRepositoryFiles(PROJECT_ROOT);
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
  validateManifest(manifest, PROJECT_ROOT),
  [],
  'module manifest structure must be valid',
);
assert.deepEqual(
  validateOwnership(manifest, repositoryFiles),
  [],
  'every repository file must have exactly one owner',
);
assert.deepEqual(
  validateCrossModuleCodeReferences(manifest, repositoryFiles, PROJECT_ROOT),
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
assert.deepEqual(codexHostModule.dependsOn, ['host-safety']);

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
    PROJECT_ROOT,
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

console.log(`PASS Test-ModuleBoundaries files=${repositoryFiles.length} modules=${manifest.modules.length}`);
