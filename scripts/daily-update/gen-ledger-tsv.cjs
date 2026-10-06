// 只读：从 skills 来源账本提取 GitHub 来源，生成 ledger-github-sources.tsv。
// 用法: node gen-ledger-tsv.cjs <outDir> [ledgerPath]
const fs = require('fs');
const path = require('path');

const outDir = process.argv[2];
if (!outDir) {
  console.error('usage: node gen-ledger-tsv.cjs <outDir> [ledgerPath]');
  process.exit(2);
}
const LEDGER = process.argv[3] || 'D:/Codex/.codex/skills/.downloaded-skills-source-state.json';
const OUT = path.join(outDir, 'ledger-github-sources.tsv');
fs.mkdirSync(outDir, { recursive: true });

const j = JSON.parse(fs.readFileSync(LEDGER, 'utf8'));
const rows = new Map();
const allKeys = new Set();

function addEntry(s, fallbackStatus) {
  if (!s || !s.repo) return;
  Object.keys(s).forEach((k) => allKeys.add(k));
  const repo = String(s.repo).replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '');
  if (!repo || repo.includes('/_/') || (!repo.includes('/'))) return;
  const key = repo + '|' + (s.ref || '');
  const skills = Array.isArray(s.skills) ? s.skills.join(',') : (s.skills || s.id || '');
  const status = s.status || fallbackStatus || '';
  if (!rows.has(key)) {
    rows.set(key, { repo, ref: s.ref || '', commit: s.last_checked_commit || s.commit || '', status, skills });
  } else {
    const r = rows.get(key);
    if (status && !r.status.split(',').includes(status)) r.status += ',' + status;
    if (skills && !r.skills.split(',').includes(skills)) r.skills += ',' + skills;
  }
}

for (const s of (j.sources || [])) addEntry(s, '');
for (const d of (j.deleted || [])) addEntry(d, 'deleted-by-user');

const lines = [...rows.values()].map((r) => [r.repo, r.ref, r.commit, r.status, r.skills].join('\t'));
fs.writeFileSync(OUT, lines.join('\n') + '\n', 'utf8');

const statusCounts = {};
let inProgress = 0;
for (const r of rows.values()) {
  const s = r.status.split(',')[0];
  statusCounts[s] = (statusCounts[s] || 0) + 1;
  if (/progress/i.test(r.status)) inProgress++;
}
console.log('out:', OUT);
console.log('rows:', lines.length);
console.log('allSourceKeys:', [...allKeys].join(','));
console.log('statusCounts:', JSON.stringify(statusCounts));
console.log('inProgressRows:', inProgress);
console.log('unresolved:', (j.unresolved || []).length, 'deletedTop:', (j.deleted || []).length);
console.log('updated_at:', j.updated_at);
