'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const TEST_DIRECTORY = path.join(PROJECT_ROOT, 'tests');
const MODULE_MANIFEST_PATH = path.join(PROJECT_ROOT, 'modules', 'manifest.json');
const POWERSHELL_EXECUTABLE = process.env.PWSH_PATH || 'pwsh';
const HARDENING_CASES = Object.freeze([
  'semantic-noop', 'crash-applying-deployed', 'crash-applied-before',
  'crash-applying-before', 'terminal-incompatible', 'third-hash-rejected',
  'postpublish-source-drift', 'postpublish-live-drift',
  'postpublish-static-and-registry-third', 'rollback-cas-race',
  'rollback-write-excluding-lease', 'forged-evidence', 'projection-summary',
]);
const STATE_PATH_REPAIR_HARDENING_CASES = Object.freeze([
  'I1', 'I2', 'I3', 'I4', 'I5', 'I6', 'I7', 'I8', 'I9', 'I10', 'I11', 'I12',
  'I13', 'I14', 'I15', 'I16', 'I17', 'I18', 'I19', 'I20', 'I21', 'I22', 'I23',
  'I24', 'I25', 'I26',
]);
const PARAMETERIZED_TESTS = Object.freeze([
  {
    name: 'Test-CodexHookProductionRegistrationRepairHardening.ps1',
    cases: HARDENING_CASES,
  },
  {
    name: 'Test-CodexStatePathRepairHardening.ps1',
    cases: STATE_PATH_REPAIR_HARDENING_CASES,
  },
]);

function isPowerShellTest(name) {
  return /^test-.*\.ps1$/i.test(name);
}

function getPowerShellExecutable() {
  const result = spawnSync(POWERSHELL_EXECUTABLE, [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '$PSVersionTable.PSVersion.ToString()',
  ], {
    cwd: PROJECT_ROOT,
    encoding: 'utf8',
    windowsHide: true,
  });
  if (result.error) {
    throw new Error(`Unable to start ${POWERSHELL_EXECUTABLE}: ${result.error.message}`);
  }

  const output = String(result.stdout || '').trim();
  const errorOutput = String(result.stderr || '').trim();
  if (result.status !== 0 || errorOutput) {
    throw new Error(`${POWERSHELL_EXECUTABLE} version probe failed: ${errorOutput || output || `exit code ${result.status ?? 'unknown'}`}`);
  }

  const match = output.match(/^(\d+)\.(\d+)(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?$/);
  if (!match) throw new Error(`Unable to determine the PowerShell version from: ${output}`);

  const major = Number(match[1]);
  const minor = Number(match[2]);
  if (major < 7 || (major === 7 && minor < 6)) {
    throw new Error(`PowerShell 7.6+ is required; found ${match[0]} at ${POWERSHELL_EXECUTABLE}`);
  }

  return POWERSHELL_EXECUTABLE;
}

function getModuleTestNames(moduleId, profileName) {
  const manifest = JSON.parse(fs.readFileSync(MODULE_MANIFEST_PATH, 'utf8'));
  const owner = moduleId === 'shared'
    ? { id: 'shared', ...manifest.shared }
    : manifest.modules.find((entry) => entry.id === moduleId);
  if (!owner) {
    throw new Error(`Unknown module: ${moduleId}`);
  }
  const profile = owner.tests?.[profileName];
  if (!profile) {
    throw new Error(`Unknown test profile for ${moduleId}: ${profileName}`);
  }

  return new Set(profile.powershell.map((testPath) => {
    const absolutePath = path.resolve(PROJECT_ROOT, testPath);
    if (path.dirname(absolutePath).toLowerCase() !== TEST_DIRECTORY.toLowerCase()) {
      throw new Error(`PowerShell module test must be a direct child of tests: ${testPath}`);
    }
    return path.basename(absolutePath).toLowerCase();
  }));
}

function buildCommands(moduleId = null, profileName = 'fixture', onlyPattern = null, skipPattern = null) {
  const selectedNames = moduleId ? getModuleTestNames(moduleId, profileName) : null;
  const parameterizedTestNames = new Set(PARAMETERIZED_TESTS.map((test) => test.name.toLowerCase()));
  const standardTests = fs.readdirSync(TEST_DIRECTORY, { withFileTypes: true })
    .filter((entry) => entry.isFile() && isPowerShellTest(entry.name))
    .map((entry) => entry.name)
    .filter((name) => !parameterizedTestNames.has(name.toLowerCase()))
    .filter((name) => !selectedNames || selectedNames.has(name.toLowerCase()))
    .sort((left, right) => left.localeCompare(right));

  if (selectedNames) {
    const discoveredNames = new Set([
      ...standardTests.map((name) => name.toLowerCase()),
      ...PARAMETERIZED_TESTS.map((test) => test.name.toLowerCase()),
    ]);
    const missing = [...selectedNames].filter((name) => !discoveredNames.has(name));
    if (missing.length > 0) {
      throw new Error(`Module test is not discoverable by the PowerShell runner: ${missing.join(', ')}`);
    }
  }

  const commands = [
    ...standardTests.map((name) => ({
      arguments: ['-NoProfile', '-NonInteractive', '-File', path.join(TEST_DIRECTORY, name)],
      label: name,
    })),
    ...PARAMETERIZED_TESTS
      .filter(({ name }) => !selectedNames || selectedNames.has(name.toLowerCase()))
      .flatMap(({ name, cases }) => cases.map((testCase) => ({
      arguments: ['-NoProfile', '-NonInteractive', '-File', path.join(TEST_DIRECTORY, name), '-Case', testCase],
      label: `${name} -Case ${testCase}`,
      }))),
  ];
  const only = onlyPattern ? new RegExp(onlyPattern, 'i') : null;
  const skip = skipPattern ? new RegExp(skipPattern, 'i') : null;
  return commands.filter(({ label }) => {
    if (only && !only.test(label)) return false;
    if (skip && skip.test(label)) return false;
    return true;
  });
}

function run(command, powershellExecutable) {
  console.log(`Running ${command.label}`);
  const startedAt = process.hrtime.bigint();
  const result = spawnSync(powershellExecutable, command.arguments, {
    cwd: PROJECT_ROOT,
    stdio: 'inherit',
    windowsHide: true,
  });

  if (result.error) throw result.error;
  const seconds = (Number(process.hrtime.bigint() - startedAt) / 1e9).toFixed(1);
  if (result.status !== 0) {
    throw new Error(`${command.label} failed with exit code ${result.status ?? 'unknown'} after ${seconds}s`);
  }
  console.log(`Passed ${command.label} in ${seconds}s`);
}

function parseArguments(args) {
  const options = { list: false, module: null, profile: 'fixture', only: null, skip: null };
  let profileWasSet = false;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === '--list') {
      if (options.list) throw new Error('--list may only be specified once');
      options.list = true;
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
    } else if (argument === '--only' || argument === '--skip') {
      index += 1;
      if (index >= args.length || args[index].startsWith('--')) {
        throw new Error(`${argument} requires a label regex`);
      }
      const key = argument === '--only' ? 'only' : 'skip';
      if (options[key]) throw new Error(`${argument} may only be specified once`);
      try {
        new RegExp(args[index], 'i');
      } catch {
        throw new Error(`${argument} received an invalid regex: ${args[index]}`);
      }
      options[key] = args[index];
    } else {
      throw new Error('Usage: node scripts/Run-PowerShellTests.cjs [--list] [--module <id> [--profile <name>]] [--only <labelRegex>] [--skip <labelRegex>]');
    }
  }
  if (profileWasSet && !options.module) {
    throw new Error('--profile requires --module');
  }
  return options;
}

function main(args) {
  const options = parseArguments(args);
  const commands = buildCommands(options.module, options.profile, options.only, options.skip);
  if ((options.only || options.skip) && commands.length === 0) {
    throw new Error('No tests selected by the given --only/--skip filters');
  }
  const powershellExecutable = getPowerShellExecutable();
  if (options.list) {
    for (const command of commands) console.log(command.label);
    return;
  }

  for (const command of commands) run(command, powershellExecutable);
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
