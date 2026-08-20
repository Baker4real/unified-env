'use strict';

// GitHub #22 关票证据：host-safety fixture 全量回归 runner（HEAD cd7661f）。
// 设计沿用 reports/safe-tree-delete-issue21-regression-20260818-rerun1/run-fixture-regression.cjs，
// 新增：断点续跑（跳过 summary.json 中已完成的测试）、git HEAD 记录、
// 耦合债务 tracked 快照 + grok 只读文件 + #53 quarantine leftover 的前后 SHA-256 守护。

const { spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const REPO = path.resolve(__dirname, '..', '..');
const OUT_DIR = __dirname;
const PWSH = process.env.PWSH_PATH || 'D:\\Codex\\tools\\PowerShell\\7.6.4\\pwsh.exe';
const MANIFEST_PATH = path.join(REPO, 'modules', 'manifest.json');
const SUMMARY_PATH = path.join(OUT_DIR, 'summary.json');
const LEFTOVER_TX =
  'D:\\Codex\\.codex\\run-evidence\\safe-tree-delete\\20260816T021845Z-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e\\transaction.json';
const LEFTOVER_Q = path.join(
  REPO,
  'reports',
  '.codex-safe-delete-0ab1e1b6-dd25-47b4-8def-0f1c1f6e8e3e.quarantine'
);
const TAIL_LINES = 40;
const FILESYSTEM_TEST = 'tests/Test-CodexSafeTreeDeleteFileSystem.ps1';

// 已知耦合债务：fixture 测试会硬编码覆写这些 tracked 快照（#42 恢复记录 +
// rerun1 notes 证实的并集）。本 runner 只记录前后 SHA-256，不做任何恢复；
// 恢复由人工判定后用 git checkout -- 处理并另行落证。
const GUARDED_SNAPSHOTS = [
  'reports/safe-tree-delete-issue32-20260817/scale-1000.json',
  'reports/safe-tree-delete-issue32-20260817/scale-10000.json',
  'reports/safe-tree-delete-issue33-20260817/scale-1000.json',
  'reports/safe-tree-delete-issue33-20260817/scale-10000.json',
  'reports/safe-tree-delete-issue34-20260817/integration-results.json',
  'reports/safe-tree-delete-issue36-20260817/filesystem-probe.json',
  'reports/safe-tree-delete-issue36-20260817/scale-phase1.json',
  'reports/safe-tree-delete-issue37-20260817/scale-10000.json',
  'reports/safe-tree-delete-issue39-20260817/scale-10000.json',
  'reports/safe-tree-delete-issue42-20260817/baseline-partial.json',
  'reports/safe-tree-delete-issue42-20260817/coordinator-journal.json',
  'reports/safe-tree-delete-issue42-20260817/filesystem-probe.json',
  'reports/safe-tree-delete-issue42-20260817/scale-phase3.json',
  'reports/safe-tree-delete-issue42-20260819/baseline-partial.json',
  'reports/safe-tree-delete-issue42-20260819/coordinator-journal.json',
  'reports/safe-tree-delete-issue42-20260819/filesystem-probe.json',
  'reports/safe-tree-delete-issue42-20260819/scale-phase3.json',
];

// 只读守护：用户未提交改动 + #53 leftover，前后必须 bit-for-bit 不变。
const GUARDED_READONLY = [
  'managed/grok-hooks/host-lifecycle.json',
  'tests/Test-GrokHostHooks.ps1',
];

function sha256File(filePath) {
  if (!fs.existsSync(filePath)) return null;
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function tailText(text, lineCount) {
  const normalized = String(text || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  if (!normalized) return '';
  const lines = normalized.split('\n');
  return lines.slice(Math.max(0, lines.length - lineCount)).join('\n');
}

function probePwsh() {
  const result = spawnSync(
    PWSH,
    ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSEdition + " " + $PSVersionTable.PSVersion.ToString()'],
    { cwd: REPO, encoding: 'utf8', windowsHide: true }
  );
  if (result.status !== 0) {
    throw new Error(`pwsh probe failed: ${(result.stderr || result.stdout || result.status)}`);
  }
  return String(result.stdout || '').trim();
}

function probeGitHead() {
  const result = spawnSync('git', ['rev-parse', 'HEAD'], {
    cwd: REPO,
    encoding: 'utf8',
    windowsHide: true,
  });
  if (result.status !== 0) {
    throw new Error(`git rev-parse failed: ${(result.stderr || result.status)}`);
  }
  return String(result.stdout || '').trim();
}

function loadFixtureList() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
  const owner = manifest.modules.find((entry) => entry.id === 'host-safety');
  if (!owner) throw new Error('host-safety module missing from manifest');
  const tests = owner.tests?.fixture?.powershell;
  if (!Array.isArray(tests) || tests.length === 0) {
    throw new Error('host-safety.tests.fixture.powershell missing or empty');
  }
  return tests;
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function hashGuard(files) {
  const out = {};
  for (const rel of files) {
    out[rel] = sha256File(path.join(REPO, rel));
  }
  return out;
}

function loadResumableState(manifestTests) {
  // 续跑：沿用既有 summary.json 的 completed 测试条目与全局 startedAtUtc。
  if (fs.existsSync(SUMMARY_PATH)) {
    try {
      const prev = JSON.parse(fs.readFileSync(SUMMARY_PATH, 'utf8'));
      const prevTests = Array.isArray(prev.tests) ? prev.tests : [];
      const prevByName = new Map(prevTests.map((t) => [t.name, t]));
      const resumed = manifestTests
        .map((rel) => rel.replace(/\\/g, '/'))
        .filter((name) => prevByName.has(name))
        .map((name) => prevByName.get(name));
      if (resumed.length > 0) {
        return { tests: resumed, startedAtUtc: prev.startedAtUtc, resumedCount: resumed.length };
      }
    } catch {
      // 损坏的 summary.json 视为无续跑数据，从头开始。
    }
  }
  return { tests: [], startedAtUtc: new Date().toISOString(), resumedCount: 0 };
}

function buildSummary(state) {
  const failed = state.tests.filter((t) => t.exit !== 0);
  const unexpected = failed.filter((t) => t.name.replace(/\\/g, '/') !== FILESYSTEM_TEST);
  return {
    artifactType: 'env-governance.codex-safe-tree-delete-issue22-fixture-regression',
    issue: 22,
    acceptanceCriterion: '既有全部 safe-tree-delete 测试保持通过（当前 HEAD 全绿证据）',
    module: 'host-safety',
    profile: 'fixture',
    source: 'modules/manifest.json host-safety.tests.fixture.powershell',
    gitHead: state.gitHead,
    pwsh: PWSH,
    pwshVersion: state.pwshVersion,
    repo: REPO,
    startedAtUtc: state.startedAtUtc,
    generatedAtUtc: new Date().toISOString(),
    incomplete: state.incomplete,
    resumedCount: state.resumedCount,
    manifestCount: state.manifestTests.length,
    completedCount: state.tests.length,
    passCount: state.tests.filter((t) => t.exit === 0).length,
    failCount: failed.length,
    unexpectedFailCount: unexpected.length,
    guardedSnapshotsAtStart: state.guardedSnapshotsAtStart,
    guardedSnapshotsAtEnd: state.guardedSnapshotsAtEnd,
    guardedSnapshotsDirty: state.guardedSnapshotsAtEnd
      ? Object.keys(state.guardedSnapshotsAtStart).filter(
          (rel) => state.guardedSnapshotsAtEnd[rel] !== state.guardedSnapshotsAtStart[rel]
        )
      : null,
    readonlyGuardAtStart: state.readonlyGuardAtStart,
    readonlyGuardAtEnd: state.readonlyGuardAtEnd,
    readonlyUntouched: state.readonlyGuardAtEnd
      ? Object.keys(state.readonlyGuardAtStart).every(
          (rel) => state.readonlyGuardAtEnd[rel] === state.readonlyGuardAtStart[rel]
        )
      : null,
    leftoverTransactionSha256AtStart: state.leftoverTransactionSha256AtStart,
    leftoverTransactionSha256AtEnd: state.leftoverTransactionSha256AtEnd,
    leftoverQuarantineExistsAtStart: state.leftoverQuarantineExistsAtStart,
    leftoverQuarantineExistsAtEnd: state.leftoverQuarantineExistsAtEnd,
    leftoverUntouched:
      state.leftoverTransactionSha256AtStart != null &&
      state.leftoverTransactionSha256AtEnd != null &&
      state.leftoverTransactionSha256AtStart === state.leftoverTransactionSha256AtEnd,
    knownWaivers: [
      {
        name: FILESYSTEM_TEST,
        reason: 'FAT32/网络实卷 e2e 维护者 waiver（GitHub #35）。未提权 diskpart/VHD；红不改 DetectFileSystem。',
      },
    ],
    tests: state.tests,
    unexpectedFails: unexpected.map((t) => t.name),
    failedNames: failed.map((t) => t.name),
    totalElapsedMs: state.tests.reduce((sum, t) => sum + (t.elapsedMs || 0), 0),
    acVerdict: state.incomplete
      ? 'incomplete'
      : unexpected.length === 0
        ? '通过'
        : '部分',
    notes: state.notes || [],
  };
}

function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const manifestTests = loadFixtureList();
  const resume = loadResumableState(manifestTests);
  const state = {
    gitHead: probeGitHead(),
    pwshVersion: probePwsh(),
    startedAtUtc: resume.startedAtUtc,
    resumedCount: resume.resumedCount,
    incomplete: true,
    manifestTests,
    guardedSnapshotsAtStart: hashGuard(GUARDED_SNAPSHOTS),
    readonlyGuardAtStart: hashGuard(GUARDED_READONLY),
    leftoverTransactionSha256AtStart: sha256File(LEFTOVER_TX),
    leftoverQuarantineExistsAtStart: fs.existsSync(LEFTOVER_Q),
    guardedSnapshotsAtEnd: null,
    readonlyGuardAtEnd: null,
    leftoverTransactionSha256AtEnd: null,
    leftoverQuarantineExistsAtEnd: null,
    tests: resume.tests,
    notes: [
      '#22 关票回归：在 HEAD cd7661f 上重跑 27 项 fixture，补齐 2026-08-18 审核时缺失的当前代码状态全绿证据。',
      '支持续跑：重启后跳过 summary.json 中已有条目的测试，沿用首次 startedAtUtc。',
      '#35 FileSystem 保持 knownWaivers；host-live（ProductionSmoke、Phase3Production）不在本 runner 范围（#24 管辖）。',
      '未 Purge leftover 0ab1e1b6（#53 管辖）；只核验 transaction SHA-256 与 quarantine 存在性前后一致。',
      '耦合债务（本票不修代码）：HashReuse 覆写 issue32/scale-*.json；Phase3Integration 覆写 issue42-20260819/{baseline-partial,coordinator-journal,filesystem-probe,scale-phase3}.json；#42 恢复记录另见 issue33/34/36/37/39 的历史写入。runner 只记录 SHA，恢复动作另行落证。',
      'grok 两文件（managed/grok-hooks/host-lifecycle.json、tests/Test-GrokHostHooks.ps1）为用户未提交改动，只读守护。',
    ],
  };

  writeJson(SUMMARY_PATH, buildSummary(state));
  console.log(
    `RUNNER_START head=${state.gitHead} count=${manifestTests.length} resumed=${resume.resumedCount} pwsh=${state.pwshVersion}`
  );

  for (const rel of manifestTests) {
    const name = rel.replace(/\\/g, '/');
    if (state.tests.some((t) => t.name === name)) {
      console.log(`SKIP_RESUMED ${rel}`);
      continue;
    }
    const abs = path.resolve(REPO, rel);
    const base = path.basename(rel);
    const stdoutPath = path.join(OUT_DIR, `${base}.stdout.txt`);
    const stderrPath = path.join(OUT_DIR, `${base}.stderr.txt`);
    console.log(`START ${rel}`);
    const startedMs = Date.now();
    const startedAtUtc = new Date(startedMs).toISOString();
    const outFd = fs.openSync(stdoutPath, 'w');
    const errFd = fs.openSync(stderrPath, 'w');
    let spawnError = null;
    let result;
    try {
      result = spawnSync(PWSH, ['-NoProfile', '-NonInteractive', '-File', abs], {
        cwd: REPO,
        windowsHide: true,
        stdio: ['ignore', outFd, errFd],
      });
    } catch (error) {
      spawnError = error;
      result = { status: -1, error };
    } finally {
      fs.closeSync(outFd);
      fs.closeSync(errFd);
    }
    const endedMs = Date.now();
    const stdout = fs.readFileSync(stdoutPath, 'utf8');
    const stderr = fs.readFileSync(stderrPath, 'utf8');
    const exit = spawnError ? -1 : (result.status ?? (result.error ? -1 : 0));
    const entry = {
      name,
      exit,
      elapsedMs: endedMs - startedMs,
      startedAtUtc,
      endedAtUtc: new Date(endedMs).toISOString(),
      stderrTail: tailText(stderr, TAIL_LINES),
      stdoutTail: exit === 0 ? '' : tailText(stdout, TAIL_LINES),
      stdoutPath,
      stderrPath,
    };
    if (spawnError) entry.spawnError = String(spawnError.message || spawnError);
    if (result.error && !spawnError) entry.spawnError = String(result.error.message || result.error);
    if (entry.name === FILESYSTEM_TEST && exit !== 0) {
      entry.waiver = 'github-35-fat32-network-live-volume';
    }
    state.tests.push(entry);
    writeJson(SUMMARY_PATH, buildSummary(state));
    console.log(`COMPLETED ${rel} exit=${exit} elapsedMs=${entry.elapsedMs}`);
  }

  state.incomplete = false;
  state.guardedSnapshotsAtEnd = hashGuard(GUARDED_SNAPSHOTS);
  state.readonlyGuardAtEnd = hashGuard(GUARDED_READONLY);
  state.leftoverTransactionSha256AtEnd = sha256File(LEFTOVER_TX);
  state.leftoverQuarantineExistsAtEnd = fs.existsSync(LEFTOVER_Q);
  writeJson(SUMMARY_PATH, buildSummary(state));
  console.log('RUNNER_DONE');
  process.exitCode = state.tests.some(
    (t) => t.exit !== 0 && t.name.replace(/\\/g, '/') !== FILESYSTEM_TEST
  )
    ? 1
    : 0;
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exitCode = 1;
}
