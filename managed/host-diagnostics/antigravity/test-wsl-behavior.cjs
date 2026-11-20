const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function load(filename, registry, platform = 'win32') {
    const calls = [];
    const exports = {};
    const dependencies = {
        'node:child_process': {
            execFile(executable, args, options, callback) {
                const name = path.win32.basename(executable);
                calls.push([name, [...args], options.windowsHide]);
                if (registry === null) return callback(new Error('No distribution registered'));
                const text = name === 'reg.exe' ? registry : 'Ubuntu';
                callback(null, { stdout: Buffer.from(text, 'utf16le') });
            },
        },
        'node:fs': { existsSync: () => true },
        'node:path': path.win32,
    };
    vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
        exports, Buffer,
        process: { platform, env: { SystemRoot: 'C:\\Windows' } },
        require: name => dependencies[name] || require(name),
    }, { filename });
    return { list: exports.listWslDistros, calls };
}

async function main() {
    const [original, candidate] = process.argv.slice(2);
    const before = load(original, null);
    await assert.rejects(before.list(), /wsl.exe probe failed/);
    assert.deepEqual(before.calls.map(call => call[0]), ['wsl.exe']);

    for (const registry of [null, 'No DistributionName value']) {
        const absent = load(candidate, registry);
        assert.equal((await absent.list()).length, 0);
        assert.deepEqual(absent.calls.map(call => [call[0], call[2]]), [['reg.exe', true]]);
    }

    const installed = load(candidate, '    DistributionName    REG_SZ    Ubuntu\r\n');
    assert.deepEqual(Array.from(await installed.list()), ['Ubuntu']);
    assert.deepEqual(installed.calls[1], ['wsl.exe', ['--list', '--verbose'], true]);

    const linux = load(candidate, null, 'linux');
    assert.equal((await linux.list()).length, 0);
    assert.equal(linux.calls.length, 0);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
