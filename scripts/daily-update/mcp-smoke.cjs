// 最小 MCP stdio 冒烟：仅 initialize + tools/list，不调用任何工具。
// 用法: node mcp-smoke.cjs <outDir>   结果写入 <outDir>/mcp-smoke-result.json（同时打印到 stdout）
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const outDir = process.argv[2];
if (!outDir) {
  console.error('usage: node mcp-smoke.cjs <outDir>');
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

function smoke(name, cmd, args, env, timeoutMs) {
  return new Promise((resolve) => {
    const proc = spawn(cmd, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    let buf = '';
    const timer = setTimeout(() => { try { proc.kill(); } catch {} resolve({ name, ok: false, error: 'timeout' }); }, timeoutMs);
    const send = (obj) => proc.stdin.write(JSON.stringify(obj) + '\n');
    const results = {};
    const finish = () => {
      clearTimeout(timer);
      try { proc.kill(); } catch {}
      resolve({ name, ...results });
    };
    proc.stdout.on('data', (d) => {
      buf += d.toString();
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim(); buf = buf.slice(idx + 1);
        if (!line) continue;
        let msg; try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id === 1) {
          results.initialize = { ok: !msg.error, protocol: msg.result && msg.result.protocolVersion, serverInfo: msg.result && msg.result.serverInfo };
          send({ jsonrpc: '2.0', method: 'notifications/initialized' });
          send({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
        } else if (msg.id === 2) {
          results.toolsList = { ok: !msg.error, count: msg.result && msg.result.tools ? msg.result.tools.length : null };
          finish();
        }
      }
    });
    proc.stderr.on('data', () => {});
    proc.on('error', (e) => { clearTimeout(timer); resolve({ name, ok: false, error: e.message }); });
    send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'daily-smoke', version: '1.0' } } });
  });
}

(async () => {
  const serena = await smoke('serena', 'cmd.exe',
    ['/c', 'D:\\Codex\\.codex\\scripts\\start-serena-mcp.cmd', 'start-mcp-server',
     '--context=D:\\Codex\\.serena\\contexts\\codex-file-tools.yml', '--project-from-cwd',
     '--enable-web-dashboard=true', '--open-web-dashboard=false'],
    {}, 120000);
  const cg = await smoke('codegraph', 'cmd.exe',
    ['/c', 'D:\\Codex\\tools\\codegraph\\current\\bin\\codegraph.cmd', 'serve', '--mcp'],
    { CODEGRAPH_NO_DAEMON: '0', CODEGRAPH_TELEMETRY: '0' }, 60000);
  const text = JSON.stringify(serena) + '\n' + JSON.stringify(cg) + '\n';
  fs.writeFileSync(path.join(outDir, 'mcp-smoke-result.json'), text, 'utf8');
  process.stdout.write(text);
  const bad = [serena, cg].some((r) => !(r.initialize && r.initialize.ok && r.toolsList && r.toolsList.ok));
  process.exit(bad ? 1 : 0);
})();
