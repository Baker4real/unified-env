const { execFile } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { promisify } = require('node:util');
exports.WSL_EXE = path.join(process.env.SystemRoot, 'System32', 'wsl.exe');
function isWslAvailable() {
    return process.platform === 'win32' && fs.existsSync(exports.WSL_EXE);
}
function decodeWslOutput(stdout) {
    return stdout.includes(0) ? stdout.toString('utf16le') : stdout.toString('utf8');
}
const execFileAsync = promisify(execFile);
async function execWsl(args) {
    try {
        const { stdout } = await execFileAsync(exports.WSL_EXE, args, {
            encoding: 'buffer',
            timeout: 30000,
        });
        return decodeWslOutput(stdout);
    } catch (error) {
        throw new Error('wsl.exe probe failed', { cause: error });
    }
}
async function listWslDistros() {
    const output = await execWsl(['--list', '--verbose']);
    return output.trim().split(/\r?\n/).filter(Boolean);
}
exports.listWslDistros = listWslDistros;
