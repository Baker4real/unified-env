'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Exercises scripts/Deploy-RetiredSkillCleanup.ps1 against isolated D: fixture
// roots under its controlled evidence root, never the live runtime.
const repoRoot = path.resolve(__dirname, '..');
const sourceRoot = path.join(repoRoot, 'scripts');
const deployScript = path.join(sourceRoot, 'Deploy-RetiredSkillCleanup.ps1');
const pwshPath = 'D:\\Codex\\tools\\PowerShell\\7.6.5\\pwsh.exe';
const controlledRoot = 'D:\\agents\\run-evidence\\retired-skill-cleanup';
const deployedFiles = ['retired-skill-menu-surface.cjs', 'purge-retired-skill-backups.cjs'];

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').toUpperCase();
}

function runDeploy(codexRoot, evidenceRoot, extraArgs = []) {
  const result = spawnSync(pwshPath, [
    '-NoProfile',
    '-NonInteractive',
    '-File',
    deployScript,
    '-SourceRoot', sourceRoot,
    '-CodexRoot', codexRoot,
    '-EvidenceRoot', evidenceRoot,
    ...extraArgs,
  ], { encoding: 'utf8', windowsHide: true });
  if (result.error) throw result.error;
  return result;
}

// -WhatIf messages share stdout with the JSON report, which starts on its own line.
function report(result) {
  const start = result.stdout.search(/^\{/m);
  assert.ok(start >= 0, `部署脚本必须输出 JSON：${result.stdout}${result.stderr}`);
  return JSON.parse(result.stdout.slice(start));
}

function seedRuntime(codexRoot) {
  const runtime = path.join(codexRoot, 'scripts');
  fs.mkdirSync(runtime, { recursive: true });
  for (const name of deployedFiles) fs.writeFileSync(path.join(runtime, name), `previous ${name}\n`, 'utf8');
  return runtime;
}

const testRoot = path.join(controlledRoot, `deploy-test-${crypto.randomBytes(8).toString('hex')}`);
try {
  const whatIfCodex = path.join(testRoot, 'whatif-codex');
  const whatIfEvidence = path.join(testRoot, 'whatif-evidence');
  const whatIf = runDeploy(whatIfCodex, whatIfEvidence, ['-WhatIf']);
  assert.equal(whatIf.status, 0, whatIf.stderr || whatIf.stdout);
  const whatIfReport = report(whatIf);
  assert.equal(whatIfReport.whatIf, true);
  assert.deepEqual(
    whatIfReport.deployed.map((entry) => [entry.relative, entry.sha256]),
    deployedFiles.map((name) => [name, sha256(path.join(sourceRoot, name))]),
    '-WhatIf 必须报告两份源码的 hash',
  );
  assert.equal(fs.existsSync(whatIfCodex), false, '-WhatIf 不得创建 runtime 目录');
  assert.equal(fs.existsSync(whatIfEvidence), false, '-WhatIf 不得创建 evidence');

  const codexRoot = path.join(testRoot, 'codex');
  const runtime = seedRuntime(codexRoot);
  const deployed = runDeploy(codexRoot, path.join(testRoot, 'evidence'));
  assert.equal(deployed.status, 0, deployed.stderr || deployed.stdout);
  const deployedReport = report(deployed);
  assert.equal(deployedReport.ok, true);
  assert.ok(deployedReport.manifestPath.startsWith(testRoot), 'evidence 必须写在受控根下');
  for (const name of deployedFiles) {
    assert.equal(sha256(path.join(runtime, name)), sha256(path.join(sourceRoot, name)), `${name} 必须与仓库源码逐字节一致`);
    assert.equal(
      fs.readFileSync(path.join(deployedReport.evidenceDir, `before-${name}`), 'utf8'),
      `previous ${name}\n`,
      `${name} 的部署前副本必须留在 evidence`,
    );
  }
  const manifest = JSON.parse(fs.readFileSync(deployedReport.manifestPath, 'utf8'));
  assert.equal(manifest.status, 'succeeded');
  assert.deepEqual(manifest.files.map((file) => file.status), ['deployed', 'deployed']);

  // A failure before the second file restores the first from its before-image.
  const rollbackCodex = path.join(testRoot, 'rollback-codex');
  const rollbackRuntime = seedRuntime(rollbackCodex);
  const rolledBack = runDeploy(rollbackCodex, path.join(testRoot, 'rollback-evidence'), ['-InjectFailureAfter', '1']);
  assert.notEqual(rolledBack.status, 0, rolledBack.stdout || rolledBack.stderr);
  const rolledBackReport = report(rolledBack);
  assert.equal(rolledBackReport.status, 'rolled-back');
  assert.equal(rolledBackReport.rolledBack, true);
  for (const name of deployedFiles) {
    assert.equal(fs.readFileSync(path.join(rollbackRuntime, name), 'utf8'), `previous ${name}\n`, `${name} 回滚后必须恢复原内容`);
  }

  // A file the failed deployment created in an empty runtime is removed again.
  const freshCodex = path.join(testRoot, 'fresh-codex');
  const freshFailed = runDeploy(freshCodex, path.join(testRoot, 'fresh-evidence'), ['-InjectFailureAfter', '1']);
  assert.notEqual(freshFailed.status, 0, freshFailed.stdout || freshFailed.stderr);
  assert.equal(report(freshFailed).status, 'rolled-back');
  for (const name of deployedFiles) {
    assert.equal(fs.existsSync(path.join(freshCodex, 'scripts', name)), false, `${name} 回滚后不得残留`);
  }

  // Rollback never overwrites a concurrent change to a file it replaced.
  const concurrentCodex = path.join(testRoot, 'concurrent-codex');
  const concurrent = runDeploy(
    concurrentCodex,
    path.join(testRoot, 'concurrent-evidence'),
    ['-InjectFailureAfter', '1', '-InjectConcurrentChangeBeforeRollback'],
  );
  assert.notEqual(concurrent.status, 0, concurrent.stdout || concurrent.stderr);
  const concurrentReport = report(concurrent);
  assert.equal(concurrentReport.status, 'unsafe-partial');
  assert.equal(concurrentReport.rolledBack, false);
  assert.match(
    fs.readFileSync(path.join(concurrentCodex, 'scripts', deployedFiles[0]), 'utf8'),
    /concurrent change detected during rollback/,
  );

  // A sibling sharing the controlled root's name prefix is outside it.
  const outsideCodex = path.join(testRoot, 'outside-codex');
  const outsideEvidence = `${controlledRoot}-outside`;
  const outside = runDeploy(outsideCodex, outsideEvidence);
  assert.notEqual(outside.status, 0);
  assert.match(outside.stderr, /EvidenceRoot/);
  assert.equal(fs.existsSync(outsideCodex), false, 'evidence 根越界时不得写 runtime');
  assert.equal(fs.existsSync(outsideEvidence), false, 'evidence 根越界时不得创建 evidence');
} finally {
  fs.rmSync(testRoot, { recursive: true, force: true, maxRetries: 3 });
}

console.log('Retired skill cleanup deployment: PASS (what-if, byte-identical deploy, rollback, concurrent-change refusal, evidence root)');
