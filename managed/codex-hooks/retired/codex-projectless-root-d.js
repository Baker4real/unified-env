#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const SRC_PREFIX = ['C:', 'Users', 'WINDOWS', 'Documents', 'Codex'].join('\\');
const DST_PREFIX = ['D:', 'Users', 'WINDOWS', 'Documents', 'Codex'].join('\\');
const TARGET_KEYS = [
  'thread-workspace-root-hints',
  'thread-projectless-output-directories',
];

function configDir() {
  return process.env.CODEX_HOME || String.raw`D:\Codex\.codex`;
}

function backupPath(statePath) {
  const dir = path.dirname(statePath);
  return path.join(dir, '.codex-global-state.json.bak-projectless-root-d-hook');
}

function rewriteValue(value) {
  if (typeof value !== 'string') return value;
  if (!value.startsWith(SRC_PREFIX)) return value;
  return `${DST_PREFIX}${value.slice(SRC_PREFIX.length)}`;
}

function countPrefixes(state) {
  const counts = {};
  for (const key of TARGET_KEYS) {
    const obj = state[key];
    counts[key] = { c: 0, d: 0, other: 0 };
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
      counts[key].other += 1;
      continue;
    }
    for (const value of Object.values(obj)) {
      if (typeof value === 'string' && value.startsWith(SRC_PREFIX)) counts[key].c += 1;
      else if (typeof value === 'string' && value.startsWith(DST_PREFIX)) counts[key].d += 1;
      else counts[key].other += 1;
    }
  }
  return counts;
}

function main() {
  const statePath = path.join(configDir(), '.codex-global-state.json');
  if (!fs.existsSync(statePath)) {
    process.stdout.write(JSON.stringify({ ok: true, status: 'state_missing', statePath }) + '\n');
    return;
  }

  const before = fs.readFileSync(statePath, 'utf8');
  const state = JSON.parse(before);
  let changed = 0;

  for (const key of TARGET_KEYS) {
    const obj = state[key];
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) continue;
    for (const [id, value] of Object.entries(obj)) {
      const next = rewriteValue(value);
      if (next !== value) {
        obj[id] = next;
        changed += 1;
      }
    }
  }

  if (changed > 0) {
    const backup = backupPath(statePath);
    if (!fs.existsSync(backup)) fs.writeFileSync(backup, before, 'utf8');
    fs.writeFileSync(statePath, JSON.stringify(state), 'utf8');
  }

  const verify = JSON.parse(fs.readFileSync(statePath, 'utf8'));
  const counts = countPrefixes(verify);
  const remainingC = Object.values(counts).reduce((sum, item) => sum + item.c, 0);
  const ok = remainingC === 0;
  process.stdout.write(JSON.stringify({ ok, changed, counts }) + '\n');
  if (!ok) process.exit(1);
}

main();
