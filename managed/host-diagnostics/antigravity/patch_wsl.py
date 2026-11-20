"""Build the local Antigravity WSL fix against a pinned, signed-installer baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import struct
import sys

VERSION = '2.33.0.0'
ORIGINAL = 'b33c81600e82e65593aa8430ef01b37d6b28d9d98f0faf45e25957783b71e64b'
PATCHED = '70ff3d9b40d767bcef07b8b74b8b8be1325d30b883933221a403744868572e7f'
TARGET = 'dist/wsl.js'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unpack_asar(data):
    marker, header_size, payload_size, json_size = struct.unpack_from('<IIII', data)
    if marker != 4 or header_size != payload_size + 4 or not 0 <= payload_size - 4 - json_size <= 3:
        raise ValueError('Unexpected ASAR header')
    return json.loads(data[16:16 + json_size]), data[8 + header_size:]


def walk(node, prefix=''):
    for name, entry in node['files'].items():
        path = prefix + name
        if 'files' in entry:
            yield from walk(entry, path + '/')
        else:
            yield path, entry


def get_member(body, entry):
    offset = int(entry['offset'])
    return body[offset:offset + entry['size']]


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('Unexpected upstream WSL code')
    return source.replace(old, new, 1)


def patch_wsl(source):
    source = replace_once(
        source,
        b"            timeout: 30000,\n        });\n        return decodeWslOutput(stdout);",
        b"            timeout: 30000,\n            windowsHide: true,\n        });\n        return decodeWslOutput(stdout);",
    )
    return replace_once(
        source,
        b"async function listWslDistros() {\n    const output = await execWsl(['--list', '--verbose']);",
        rb"""async function listWslDistros() {
    // Windows keeps the wsl.exe launcher even when WSL has been uninstalled.
    // A distribution must be registered before querying that launcher.
    if (!isWslAvailable()) {
        return [];
    }
    try {
        const { stdout } = await execFileAsync(path.join(path.dirname(exports.WSL_EXE), 'reg.exe'), [
            'query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss', '/s', '/v', 'DistributionName',
        ], { encoding: 'buffer', timeout: 2000, windowsHide: true });
        if (!/\bDistributionName[ \t]+REG_SZ[ \t]+\S/.test(decodeWslOutput(stdout))) {
            return [];
        }
    }
    catch {
        return [];
    }
    const output = await execWsl(['--list', '--verbose']);""",
    )


def build_candidate(original):
    header, body = unpack_asar(original)
    entries = dict(walk(header))
    target = entries[TARGET]
    offset = int(target['offset'])
    old = get_member(body, target)
    integrity = target['integrity']
    if integrity['algorithm'] != 'SHA256' or integrity['hash'] != sha(old) or integrity['blocks'] != [sha(old)]:
        raise ValueError('Unexpected upstream WSL member integrity metadata')
    patched = patch_wsl(old)
    if len(patched) > integrity['blockSize']:
        raise ValueError('The patched WSL member would require multiple integrity blocks')
    payload = body[:offset] + patched + body[offset + len(old):]
    diff = len(patched) - len(old)
    for entry in entries.values():
        if 'offset' in entry and int(entry['offset']) > offset:
            entry['offset'] = str(int(entry['offset']) + diff)
    target['size'] = len(patched)
    integrity['hash'] = sha(patched)
    integrity['blocks'] = [integrity['hash']]
    header_bytes = json.dumps(header, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    padded = (len(header_bytes) + 3) & ~3
    candidate = (struct.pack('<IIII', 4, 8 + padded, 4 + padded, len(header_bytes))
                 + header_bytes + b'\0' * (padded - len(header_bytes)) + payload)

    original_entries = dict(walk(unpack_asar(original)[0]))
    new_header, new_body = unpack_asar(candidate)
    new_entries = dict(walk(new_header))
    if original_entries.keys() != new_entries.keys() or get_member(new_body, new_entries[TARGET]) != patched:
        raise ValueError('Unexpected change to the ASAR resource layout')
    for path, prev in original_entries.items():
        if path == TARGET:
            continue
        next_entry = new_entries[path]
        if {k: v for k, v in prev.items() if k != 'offset'} != {k: v for k, v in next_entry.items() if k != 'offset'}:
            raise ValueError(f'Unexpected metadata change for {path}')
        if 'offset' in prev and get_member(body, prev) != get_member(new_body, next_entry):
            raise ValueError(f'Unexpected content change for {path}')
    return candidate, len(original_entries) - 1


def staging_path(path):
    if sys.platform != 'win32':
        return path
    roots = (Path('D:/agents/tmp'), Path('D:/agents/run-evidence'))
    resolved = path.resolve()
    if not path.is_absolute() or resolved != path or path.suffix.lower() != '.asar' or not any(root in resolved.parents for root in roots):
        raise ValueError('Candidate output requires a new .asar under D:/agents/tmp or D:/agents/run-evidence')
    for parent in path.parents:
        if parent.lstat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ValueError('Candidate output has a reparse-point ancestor')
    return resolved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    commands.add_parser('status').add_argument('archive', type=Path)
    stage = commands.add_parser('stage')
    stage.add_argument('archive', type=Path)
    stage.add_argument('candidate', type=Path)
    args = parser.parse_args()
    try:
        original = args.archive.read_bytes()
        digest = sha(original)
        state = {ORIGINAL: 'official-baseline', PATCHED: 'local-patch'}.get(digest, 'unrecognized')
        if args.mode == 'status':
            print(json.dumps({'state': state, 'sha256': digest, 'version': VERSION if state != 'unrecognized' else None}))
            return 0
        if state != 'official-baseline':
            raise ValueError(f'{state}: stage requires the pinned official {VERSION} archive')
        candidate, unchanged = build_candidate(original)
        if sha(candidate) != PATCHED:
            raise ValueError('Candidate hash differs from the verified local patch')
        with staging_path(args.candidate).open('xb') as stream:
            stream.write(candidate)
        print(json.dumps({'originalSha256': digest, 'candidateSha256': PATCHED, 'changedMember': TARGET,
                          'unchangedMembers': unchanged}))
        return 0
    except (OSError, ValueError, KeyError, struct.error) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
