'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const projectRoot = path.resolve(__dirname, '..');
const scriptPath = 'D:/Codex/.codex/scripts/purge-retired-skill-backups.cjs';
const fixturePrefix = '.tmp-retired-skill-backup-fixture-';
const fixtureMarkerName = '.retired-skill-backup-fixture.json';
const fixturePayloadMarkerName = '.retired-skill-backup-payload.json';

function runRaw(fixtureRoot, args = [], { testMode = true } = {}) {
  const env = {
    ...process.env,
    // A hostile caller must not be able to redirect the production root through
    // legacy environment variables. The fixture argument is the only test seam.
    CODEX_ROOT: path.join(fixtureRoot, 'forged-codex-root'),
    CODEX_PARENT: path.join(fixtureRoot, 'forged-codex-parent'),
  };
  if (testMode) env.TEST_MODE = '1';
  else delete env.TEST_MODE;
  return spawnSync(process.execPath, [scriptPath, '--fixture-root', fixtureRoot, ...args], {
    encoding: 'utf8',
    env,
  });
}

function runPurger(fixtureRoot, args = [], expectedStatus = 0, options = {}) {
  const result = runRaw(fixtureRoot, args, options);
  assert.equal(result.status, expectedStatus, `purger 退出码异常：${result.stderr || result.stdout}`);
  assert.equal(result.stderr, '', `purger 不应向 stderr 写非 JSON：${result.stderr}`);
  assert.notEqual(result.stdout.trim(), '', 'purger 必须输出 JSON 摘要');
  return JSON.parse(result.stdout);
}

function sourceById(ledger, id) {
  const source = (ledger.sources || []).find((entry) => entry.id === id);
  assert.ok(source, `缺少 source group：${id}`);
  return source;
}

function assertManifestCleared(record, label, originalReason) {
  assert.equal(record.backup_cleanup_manifest, null, `${label} 的失效 manifest 未清空`);
  assert.equal(record.backup_cleanup_reason, originalReason, `${label} 以外的 ledger 字段不应被改写`);
}

function writeFixtureMarker(fixtureRoot) {
  fs.writeFileSync(path.join(fixtureRoot, fixtureMarkerName), JSON.stringify({
    kind: 'retired-skill-backup-purger-fixture',
    version: 1,
  }), 'utf8');
}

function writePayloadTarget(fixtureRoot) {
  const target = path.join(fixtureRoot, 'payload', 'retired-hyperframes-backup');
  fs.mkdirSync(target, { recursive: true });
  fs.writeFileSync(path.join(target, fixturePayloadMarkerName), JSON.stringify({
    kind: 'retired-skill-backup-payload',
    version: 1,
    targetId: 'fixture-retired-hyperframes-backup',
  }), 'utf8');
  fs.writeFileSync(path.join(target, 'payload.txt'), 'retired payload', 'utf8');
  return target;
}

const fixtureRoot = fs.mkdtempSync(path.join(projectRoot, fixturePrefix));
const ledgerPath = path.join(fixtureRoot, 'skills', '.downloaded-skills-source-state.json');
const staleManifest = path.join(fixtureRoot, 'removed-evidence', 'delete-manifest.json');
const staleReason = `Historical cleanup evidence: ${staleManifest}`;
const collisionPath = path.join(fixtureRoot, 'payload', 'retired-name-collision');

try {
  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true });
  fs.writeFileSync(ledgerPath, JSON.stringify({
    sources: [
      {
        id: 'hyperframes',
        status: 'deleted-by-user',
        backup_cleanup_manifest: staleManifest,
        backup_cleanup_reason: staleReason,
        deleted_skills: [
          {
            name: 'video-hyperframes',
            backup_cleanup_manifest: staleManifest,
            backup_cleanup_reason: staleReason,
          },
        ],
      },
      {
        id: 'remotion-skills',
        status: 'deleted-by-user',
        backup_cleanup_manifest: staleManifest,
        backup_cleanup_reason: staleReason,
        deleted_skills: [
          {
            name: 'remotion-best-practices',
            backup_cleanup_manifest: staleManifest,
            backup_cleanup_reason: staleReason,
          },
        ],
      },
      {
        id: 'active-source',
        status: 'active',
        backup_cleanup_manifest: staleManifest,
        backup_cleanup_reason: staleReason,
        excluded_skills: [
          {
            // This is deliberately the same display name as a retired skill.
            // It must not become a cleanup target merely due to a name collision.
            name: 'video-hyperframes',
            backup_cleanup_manifest: staleManifest,
            backup_cleanup_reason: staleReason,
          },
        ],
      },
    ],
    deleted: [
      {
        name: 'video-hyperframes',
        source: 'hyperframes',
        backup_cleanup_manifest: staleManifest,
        backup_cleanup_reason: staleReason,
      },
      {
        name: 'remotion-best-practices',
        source: 'remotion-skills',
        backup_cleanup_manifest: staleManifest,
        backup_cleanup_reason: staleReason,
      },
    ],
    unresolved: [],
    notes: [],
  }, null, 2), 'utf8');
  const originalLedger = fs.readFileSync(ledgerPath, 'utf8');

  // The fixture root is rejected unless all three deliberate test gates are present:
  // explicit argument, TEST_MODE, and a fixture marker/prefix.
  const unapproved = runRaw(fixtureRoot, ['--apply'], { testMode: false });
  assert.notEqual(unapproved.status, 0, '缺少 TEST_MODE 的 fixture 调用必须拒绝');
  assert.equal(fs.readFileSync(ledgerPath, 'utf8'), originalLedger, '拒绝的 fixture 调用不得改写 ledger');

  const missingMarker = runRaw(fixtureRoot, ['--apply']);
  assert.notEqual(missingMarker.status, 0, '缺少 fixture marker 的调用必须拒绝');
  assert.equal(fs.readFileSync(ledgerPath, 'utf8'), originalLedger, '缺少 marker 时不得改写 ledger');

  writeFixtureMarker(fixtureRoot);
  const payloadTarget = writePayloadTarget(fixtureRoot);
  fs.mkdirSync(collisionPath, { recursive: true });
  fs.writeFileSync(path.join(collisionPath, 'SKILL.md'), '---\nname: video-hyperframes\n---\nactive name collision', 'utf8');

  const audit = runPurger(fixtureRoot, [], 1);
  assert.equal(audit.mode, 'audit', `fixture audit should not fail: ${JSON.stringify(audit)}`);
  assert.equal(audit.dryRun, true);
  assert.equal(audit.candidateCount, 1, '只允许版本控制的精确 fixture payload target 成为候选');
  assert.equal(audit.blockedPayloadTargetCount, 0);
  assert.equal(audit.staleBackupCleanupManifestCount, 6, '必须报告所有且仅报告退役 source/deleted rows 的失效 manifest');
  assert.equal(audit.remainingStaleBackupCleanupManifestCount, 6);
  assert.ok(audit.staleBackupCleanupManifests.every((entry) => entry.manifest === staleManifest));
  assert.equal(fs.readFileSync(ledgerPath, 'utf8'), originalLedger, 'audit 不得修改 ledger');
  assert.equal(fs.existsSync(payloadTarget), true, 'audit 不得删除精确 target');
  assert.equal(fs.existsSync(collisionPath), true, '不在 allowlist 的同名目录不得成为候选');

  const dryRunApply = runPurger(fixtureRoot, ['--apply', '--dry-run'], 1);
  assert.equal(dryRunApply.clearedBackupCleanupManifestCount, 0, 'dry-run 不得清空 ledger');
  assert.equal(fs.readFileSync(ledgerPath, 'utf8'), originalLedger, 'apply dry-run 不得修改 ledger');

  // A prior interrupted move must never become an invisible retired payload.
  // The bounded, target-specific quarantine name is reported as blocked rather
  // than being rediscovered through a broad filesystem scan.
  const orphanedQuarantine = path.join(path.dirname(payloadTarget), '.retired-hyperframes-backup.retired-skill-purge-interrupted');
  fs.mkdirSync(orphanedQuarantine, { recursive: true });
  fs.writeFileSync(path.join(orphanedQuarantine, 'payload.txt'), 'interrupted payload', 'utf8');
  const interruptedAudit = runPurger(fixtureRoot, [], 1);
  assert.equal(interruptedAudit.blockedPayloadTargetCount, 1, '中断 quarantine 必须显式阻断而非被静默遗漏');
  assert.equal(fs.readFileSync(ledgerPath, 'utf8'), originalLedger, '中断 quarantine audit 不得改写 ledger');
  fs.rmSync(orphanedQuarantine, { recursive: true, force: true });

  // An exact target which becomes a junction after audit must fail closed and
  // must not follow the reparse point into the sentinel directory.
  const sentinel = path.join(fixtureRoot, 'sentinel');
  fs.mkdirSync(sentinel, { recursive: true });
  fs.writeFileSync(path.join(sentinel, 'must-survive.txt'), 'sentinel', 'utf8');
  fs.rmSync(payloadTarget, { recursive: true, force: true });
  fs.symlinkSync(sentinel, payloadTarget, 'junction');
  const reparseAudit = runPurger(fixtureRoot, [], 1);
  assert.equal(reparseAudit.blockedPayloadTargetCount, 1, 'reparse target 必须被单独阻断');
  assert.equal(fs.readFileSync(ledgerPath, 'utf8'), originalLedger, 'reparse audit 不得改写 ledger');
  assert.equal(fs.readFileSync(path.join(sentinel, 'must-survive.txt'), 'utf8'), 'sentinel', '不得跟随 junction 删除 sentinel');

  fs.rmSync(payloadTarget, { recursive: true, force: true });
  writePayloadTarget(fixtureRoot);

  const applied = runPurger(fixtureRoot, ['--apply']);
  assert.equal(applied.candidateCount, 1, 'apply 只删除精确 allowlist target');
  assert.equal(applied.removed.length, 1);
  assert.equal(applied.staleBackupCleanupManifestCount, 6);
  assert.equal(applied.clearedBackupCleanupManifestCount, 6);
  assert.equal(applied.remainingStaleBackupCleanupManifestCount, 0);
  assert.equal(fs.existsSync(payloadTarget), false, '精确 payload target 必须被删除');
  assert.equal(fs.existsSync(collisionPath), true, '同名但非 allowlist 的 payload 必须保留');

  const repaired = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
  const hyperframes = sourceById(repaired, 'hyperframes');
  const remotion = sourceById(repaired, 'remotion-skills');
  assertManifestCleared(hyperframes, 'hyperframes source', staleReason);
  assertManifestCleared(hyperframes.deleted_skills[0], 'hyperframes deleted skill', staleReason);
  assertManifestCleared(remotion, 'remotion source', staleReason);
  assertManifestCleared(remotion.deleted_skills[0], 'remotion deleted skill', staleReason);
  assertManifestCleared(repaired.deleted.find((entry) => entry.name === 'video-hyperframes'), 'global hyperframes deleted row', staleReason);
  assertManifestCleared(repaired.deleted.find((entry) => entry.name === 'remotion-best-practices'), 'global remotion deleted row', staleReason);
  const activeSource = sourceById(repaired, 'active-source');
  assert.equal(activeSource.backup_cleanup_manifest, staleManifest, '非退役 source 不应被本清理器改写');
  assert.equal(activeSource.excluded_skills[0].backup_cleanup_manifest, staleManifest, 'active source 的同名 excluded row 不应被本清理器改写');

  const finalAudit = runPurger(fixtureRoot);
  assert.equal(finalAudit.candidateCount, 0);
  assert.equal(finalAudit.blockedPayloadTargetCount, 0);
  assert.equal(finalAudit.staleBackupCleanupManifestCount, 0);
  assert.equal(finalAudit.remainingStaleBackupCleanupManifestCount, 0);

  console.log('Retired skill backup manifest purger: PASS (fixed root, fixture gates, exact allowlist, reparse refusal, scoped ledger apply)');
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true, maxRetries: 3 });
}
