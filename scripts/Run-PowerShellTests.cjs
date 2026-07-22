'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const TEST_DIRECTORY = path.join(PROJECT_ROOT, 'tests');
const PARAMETERIZED_TEST = 'Test-CodexHookProductionRegistrationRepairHardening.ps1';
const POWERSHELL_EXECUTABLE = process.env.PWSH_PATH || 'pwsh';
const HARDENING_CASES = Object.freeze([
  'semantic-noop', 'crash-applying-deployed', 'crash-applied-before',
  'crash-applying-before', 'terminal-incompatible', 'third-hash-rejected',
  'postpublish-source-drift', 'postpublish-live-drift',
  'postpublish-static-and-registry-third', 'rollback-cas-race',
  'rollback-write-excluding-lease', 'forged-evidence', 'projection-summary',
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

function buildCommands() {
  const standardTests = fs.readdirSync(TEST_DIRECTORY, { withFileTypes: true })
    .filter((entry) => entry.isFile() && isPowerShellTest(entry.name))
    .map((entry) => entry.name)
    .filter((name) => name.toLowerCase() !== PARAMETERIZED_TEST.toLowerCase())
    .sort((left, right) => left.localeCompare(right));

  return [
    ...standardTests.map((name) => ({
      arguments: ['-NoProfile', '-File', path.join(TEST_DIRECTORY, name)],
      label: name,
    })),
    ...HARDENING_CASES.map((testCase) => ({
      arguments: ['-NoProfile', '-File', path.join(TEST_DIRECTORY, PARAMETERIZED_TEST), '-Case', testCase],
      label: `${PARAMETERIZED_TEST} -Case ${testCase}`,
    })),
  ];
}

function run(command, powershellExecutable) {
  console.log(`Running ${command.label}`);
  const result = spawnSync(powershellExecutable, command.arguments, {
    cwd: PROJECT_ROOT,
    stdio: 'inherit',
    windowsHide: true,
  });

  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command.label} failed with exit code ${result.status ?? 'unknown'}`);
  }
}

function main(args) {
  const commands = buildCommands();
  const powershellExecutable = getPowerShellExecutable();
  if (args.length === 1 && args[0] === '--list') {
    for (const command of commands) console.log(command.label);
    return;
  }
  if (args.length !== 0) {
    throw new Error('Usage: node scripts/Run-PowerShellTests.cjs [--list]');
  }

  for (const command of commands) run(command, powershellExecutable);
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
