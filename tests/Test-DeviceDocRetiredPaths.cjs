'use strict';

// 设备文档（docs/environments/*.md）不得指向已退役的存储根：D:\Codex\.codex\run-evidence\ 与 D:\Codex\.gsd\ 下的具体路径
// 都已失效（D:\Codex\.codex\docs\agent-guidance\storage-and-junctions.md）。迁移说明里只提根目录本身、不带子路径的不算指向。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const PROJECT_ROOT = path.resolve(__dirname, '..');
const DOCS_ROOT = path.join(PROJECT_ROOT, 'docs', 'environments');
// A retired root, a separator, then at least one character of a sub-path.
const RETIRED_POINTER = /[A-Za-z]:[\\/]Codex[\\/](?:\.codex[\\/]run-evidence|\.gsd)[\\/][^\s`'"<>|)\]]+/gi;

function retiredPointers(text) {
  return text.split(/\r?\n/).flatMap((line, index) => (
    [...line.matchAll(RETIRED_POINTER)].map((match) => ({ line: index + 1, path: match[0] }))
  ));
}

assert.deepEqual(
  retiredPointers('证据位于 `D:\\Codex\\.codex\\run-evidence\\office\\x.json`。\n- D:/Codex/.gsd/tmp/replicator/a').map((found) => found.path),
  ['D:\\Codex\\.codex\\run-evidence\\office\\x.json', 'D:/Codex/.gsd/tmp/replicator/a'],
  'sub-paths under a retired root are pointers',
);
assert.deepEqual(
  retiredPointers('从旧根 `D:\\Codex\\.codex\\run-evidence\\` 迁移至此；指向已不存在的 `D:\\Codex\\.gsd`；现役 `D:\\agents\\run-evidence\\x`'),
  [],
  'the bare retired roots and active roots are not pointers',
);

const names = fs.readdirSync(DOCS_ROOT).filter((name) => name.toLowerCase().endsWith('.md')).sort();
assert.ok(names.length > 0, 'docs/environments must contain device docs');
const findings = names.flatMap((name) => (
  retiredPointers(fs.readFileSync(path.join(DOCS_ROOT, name), 'utf8')).map((found) => `docs/environments/${name}:${found.line} ${found.path}`)
));
assert.deepEqual(findings, [], 'device docs point into a retired storage root; repoint them to D:\\agents\\run-evidence\\ or keep only the bare root in a migration note');
console.log(`device doc retired paths: ${names.length} files clean`);
