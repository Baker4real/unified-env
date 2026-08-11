const fs=require('fs');
for(const n of [11,12,13,14,15,16,17]){
  const j=JSON.parse(fs.readFileSync(`issue-${n}.json`,'utf8'));
  let out=`# Issue #${j.number} [${j.state}] ${j.title}\n\n${j.body}\n`;
  for(const c of (j.comments||[])){
    out+=`\n\n---\n## comment by ${c.author?.login||'?'} at ${c.createdAt}\n\n${c.body}\n`;
  }
  fs.writeFileSync(`issue-${n}.md`,out);
  console.log(n, out.length);
}
