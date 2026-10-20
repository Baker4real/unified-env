'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const MODULE_MANIFEST_PATH = path.join(PROJECT_ROOT, 'modules', 'manifest.json');
const PYTHON_EXECUTABLE = process.env.PYTHON_PATH || 'python';
const TEST_KINDS = Object.freeze(['python', 'node']);
// Fixture tests that build temporary fixtures but launch a host script kept outside this repository,
// which CI runners do not have. They keep running locally; --exclude-host-bound reports each one with
// its reason instead of running it. Tests that read live host state belong in the host-live profile.
const SKILL_RESOURCE_CLOSURE = 'runs the resource closure script '
  + 'D:\\agents\\skills-manager\\skills\\skill-install-guard\\scripts\\skill_resource_closure.py '
  + 'from the skills repository';
const HOST_BOUND_TESTS = Object.freeze({
  'modules/skill-supply-chain/tests/Test-SkillInstallGuarded.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedBundled.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedCanonicalRename.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedDecision.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedLedger.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedMergeRetirement.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedPayload.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedSourceRecord.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedSystemOverlay.py': SKILL_RESOURCE_CLOSURE,
  'modules/skill-supply-chain/tests/Test-SkillInstallGuardedSystemRepair.py': SKILL_RESOURCE_CLOSURE,
  'tests/Test-RetiredSkillMenuSurface.cjs': 'anchors fixture gates and handle-bound deletion to the canonical checkout '
    + 'D:\\agents\\projects\\统一环境 and the fixed host PowerShell runtime',
});

function getOwners(manifest, moduleId) {
  if (!moduleId) return [{ id: 'shared', ...manifest.shared }, ...manifest.modules];
  const owner = moduleId === 'shared'
    ? { id: 'shared', ...manifest.shared }
    : manifest.modules.find((entry) => entry.id === moduleId);
  if (!owner) {
    throw new Error(`Unknown module: ${moduleId}`);
  }
  return [owner];
}

function findStaleHostBoundTests(manifest, hostBoundTests = HOST_BOUND_TESTS) {
  const manifestTests = new Set(getOwners(manifest, null).flatMap((owner) => (
    Object.values(owner.tests || {}).flatMap((profile) => TEST_KINDS.flatMap((kind) => profile[kind] || []))
  )));
  return Object.keys(hostBoundTests).filter((testPath) => !manifestTests.has(testPath));
}

function buildTestPlan(manifest, {
  moduleId = null,
  profileName = 'fixture',
  kinds = TEST_KINDS,
  excludeHostBound = false,
  hostBoundTests = HOST_BOUND_TESTS,
} = {}) {
  const stale = findStaleHostBoundTests(manifest, hostBoundTests);
  if (stale.length > 0) {
    throw new Error(`Host-bound entry is not a manifest python or node test: ${stale.join(', ')}`);
  }

  const owners = getOwners(manifest, moduleId);
  if (moduleId && !owners[0].tests?.[profileName]) {
    throw new Error(`Unknown test profile for ${moduleId}: ${profileName}`);
  }
  const plan = { run: [], hostBound: [] };
  for (const kind of kinds) {
    for (const owner of owners) {
      for (const testPath of owner.tests?.[profileName]?.[kind] ?? []) {
        const reason = hostBoundTests[testPath];
        if (excludeHostBound && reason) {
          plan.hostBound.push({ kind, testPath, reason });
        } else {
          plan.run.push({ kind, testPath });
        }
      }
    }
  }
  return plan;
}

function escapeWorkflowCommandData(text) {
  return text.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}

function reportHostBound(test) {
  const message = `Not run (host-bound): ${test.testPath} - ${test.reason}`;
  console.log(message);
  if (process.env.GITHUB_ACTIONS === 'true') {
    console.log(`::warning title=Host-bound test not run::${escapeWorkflowCommandData(message)}`);
  }
}

function getPythonExecutable() {
  const result = spawnSync(PYTHON_EXECUTABLE, [
    '-c',
    'import sys; print(sys.executable); print(sys.version.split()[0])',
  ], {
    cwd: PROJECT_ROOT,
    encoding: 'utf8',
    windowsHide: true,
  });
  if (result.error) {
    throw new Error(`Unable to start ${PYTHON_EXECUTABLE}: ${result.error.message}`);
  }

  const output = String(result.stdout || '').trim();
  const errorOutput = String(result.stderr || '').trim();
  if (result.status !== 0 || errorOutput) {
    throw new Error(`${PYTHON_EXECUTABLE} version probe failed: ${errorOutput || output || `exit code ${result.status ?? 'unknown'}`}`);
  }

  const [executable, version] = output.split(/\r?\n/);
  console.log(`Python ${version} at ${executable}`);
  return PYTHON_EXECUTABLE;
}

function run(test, pythonExecutable) {
  console.log(`Running ${test.testPath}`);
  const testFile = path.join(PROJECT_ROOT, ...test.testPath.split('/'));
  const [executable, args] = test.kind === 'python'
    ? [pythonExecutable, ['-B', testFile]]
    : [process.execPath, [testFile]];
  const result = spawnSync(executable, args, {
    cwd: PROJECT_ROOT,
    stdio: 'inherit',
    windowsHide: true,
  });

  if (result.error) throw result.error;
  return result.status;
}

function parseArguments(args) {
  const options = { list: false, module: null, profile: 'fixture', kinds: TEST_KINDS, excludeHostBound: false };
  let profileWasSet = false;
  let kindWasSet = false;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--list') {
      if (options.list) throw new Error('--list may only be specified once');
      options.list = true;
    } else if (argument === '--exclude-host-bound') {
      if (options.excludeHostBound) throw new Error('--exclude-host-bound may only be specified once');
      options.excludeHostBound = true;
    } else if (argument === '--kind') {
      index += 1;
      if (index >= args.length || args[index].startsWith('--')) {
        throw new Error('--kind requires python or node');
      }
      if (kindWasSet) throw new Error('--kind may only be specified once');
      if (!TEST_KINDS.includes(args[index])) {
        throw new Error(`Unknown test kind: ${args[index]} (expected python or node)`);
      }
      options.kinds = [args[index]];
      kindWasSet = true;
    } else if (argument === '--module') {
      index += 1;
      if (index >= args.length || args[index].startsWith('--')) {
        throw new Error('--module requires a module id');
      }
      if (options.module) throw new Error('--module may only be specified once');
      options.module = args[index];
    } else if (argument === '--profile') {
      index += 1;
      if (index >= args.length || args[index].startsWith('--')) {
        throw new Error('--profile requires a profile name');
      }
      if (profileWasSet) throw new Error('--profile may only be specified once');
      options.profile = args[index];
      profileWasSet = true;
    } else {
      throw new Error('Usage: node scripts/Run-ManifestTests.cjs [--list] [--exclude-host-bound] [--kind <python|node>] [--module <id> [--profile <name>]]');
    }
  }
  if (profileWasSet && !options.module) {
    throw new Error('--profile requires --module');
  }
  return options;
}

function main(args) {
  const options = parseArguments(args);
  const manifest = JSON.parse(fs.readFileSync(MODULE_MANIFEST_PATH, 'utf8'));
  const plan = buildTestPlan(manifest, {
    moduleId: options.module,
    profileName: options.profile,
    kinds: options.kinds,
    excludeHostBound: options.excludeHostBound,
  });
  if (options.list) {
    for (const test of plan.run) console.log(test.testPath);
    for (const test of plan.hostBound) reportHostBound(test);
    return;
  }

  const pythonExecutable = plan.run.some((test) => test.kind === 'python') ? getPythonExecutable() : null;
  const failures = [];
  for (const test of plan.run) {
    const status = run(test, pythonExecutable);
    if (status !== 0) failures.push({ ...test, status });
  }
  for (const test of plan.hostBound) reportHostBound(test);

  console.log(`Manifest tests: ${plan.run.length - failures.length} passed, ${failures.length} failed, ${plan.hostBound.length} not run (host-bound)`);
  for (const failure of failures) {
    console.error(`FAILED ${failure.testPath} (exit code ${failure.status ?? 'unknown'})`);
  }
  if (failures.length > 0) process.exitCode = 1;
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {
  HOST_BOUND_TESTS,
  buildTestPlan,
  findStaleHostBoundTests,
};
