// 对比两次 lsremote-results.tsv，输出 HEAD 移动 / 决策沿用 / 新增行。
// 用法: node sweep-diff.cjs <prevResults.tsv> <curResults.tsv>
const fs = require('fs');

const [OLD, CUR] = process.argv.slice(2);
if (!OLD || !CUR) {
  console.error('usage: node sweep-diff.cjs <prevResults.tsv> <curResults.tsv>');
  process.exit(2);
}

function parse(f) {
  const m = new Map();
  for (const l of fs.readFileSync(f, 'utf8').split('\n')) {
    if (!l.trim()) continue;
    const c = l.split('\t');
    m.set(c[0], { verdict: c[1], head: c[2] || '', ref: c[3], status: c[4] });
  }
  return m;
}

const old = parse(OLD);
const cur = parse(CUR);
const moved = [], carried = [], newly = [];
for (const [repo, v] of cur) {
  if (v.verdict === 'EXCLUDED') continue;
  const o = old.get(repo);
  if (!o) { newly.push(repo + ' ' + JSON.stringify(v)); continue; }
  if (v.verdict === 'TAGPIN') continue;
  if (o.head !== v.head) {
    moved.push(repo + ' : old ' + o.head.slice(0, 8) + '(' + o.verdict + ') -> new ' + v.head.slice(0, 8) + '(' + v.verdict + ') status=' + v.status);
  } else if (v.verdict === 'CHANGED') {
    carried.push(repo + ' head=' + v.head.slice(0, 8) + ' status=' + v.status);
  }
}
console.log('== HEAD MOVED since previous ==');
moved.forEach((x) => console.log(x));
console.log('== CHANGED but same head as previous (decision carries) ==');
carried.forEach((x) => console.log(x));
console.log('== rows not in previous file ==');
newly.forEach((x) => console.log(x));
