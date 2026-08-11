const fs = require('fs');
const path = require('path');
const dir = 'D:\\Codex\\temp\\claude\\D--Codex-projects-------claude-worktrees-ticket-9f84c0\\56f72243-4840-40b0-820c-5aa9e8a5c897\\tasks';
const map = {
  'ad23d5d0fc5d20f88': 12,
  'a39bf4ca96b8a4e58': 13,
  'ac306cffb58f832f9': 14,
  'ae96143132b212c39': 15,
  'a8baa236cc5968c83': 16,
  'a116b1264f65b0d2b': 17,
};
for (const [id, num] of Object.entries(map)) {
  const p = path.join(dir, id + '.output');
  if (!fs.existsSync(p)) { console.log('MISSING', num); continue; }
  const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/);
  const texts = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    const m = o.message || o;
    if (m && m.role === 'assistant' && Array.isArray(m.content)) {
      for (const c of m.content) {
        if (c.type === 'text' && c.text && c.text.trim().length > 40) texts.push(c.text);
      }
    }
  }
  const out = texts.slice(-2).join('\n\n---\n\n');
  fs.writeFileSync(`final-${num}.txt`, out || '(no text found)');
  console.log(num, 'chars=', out.length);
}
