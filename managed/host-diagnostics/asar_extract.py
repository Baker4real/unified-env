"""List or extract files from an Electron app.asar without node or npm.

Searching a whole app.asar (often hundreds of MB) with `rg -a` is slow and hits minified
third-party code. List the archive once, extract only the bundles you need, then search those.

  python -B -I asar_extract.py list <app.asar> [--grep REGEX] [--min-size BYTES]
  python -B -I asar_extract.py grep <app.asar> <regex> [--paths REGEX] [--context CHARS] [--max-per-file N]
  python -B -I asar_extract.py extract <app.asar> <path-in-asar>... --out <empty dir>

`grep` names the file each match is in, which `rg -a` over the whole archive cannot; narrow it
with --paths (e.g. '^out/') to skip node_modules. Prefer an exact discovered bundle
and method. `grep --json --max-output-bytes 6000 --max-files 8` returns bounded excerpts
and exact total/omission counts; each file still uses --max-per-file. Keep broad discovery
separate from method inspection. No installation member is modified by grep.

Paths inside the archive use forward slashes, as `list` prints them. Entries marked unpacked
are read from `<app.asar>.unpacked/`. The archive is untrusted data: run this with -I and keep
the output directory apart from this script.
"""
import argparse
import json
import os
import re
import struct
import sys


def read_header(path):
    """Returns (header dict, offset where file data starts)."""
    with open(path, 'rb') as f:
        size_pickle = f.read(8)
        if len(size_pickle) != 8:
            raise ValueError('not an asar archive: file too short')
        payload_size, header_size = struct.unpack('<II', size_pickle)
        if payload_size != 4:
            raise ValueError('not an asar archive: unexpected size pickle')
        header_pickle = f.read(header_size)
        if len(header_pickle) != header_size:
            raise ValueError('not an asar archive: truncated header')
        json_len = struct.unpack('<I', header_pickle[4:8])[0]
        header = json.loads(header_pickle[8:8 + json_len].decode('utf-8'))
    return header, 8 + header_size


def walk(node, prefix=''):
    """Yields (path, entry) for every file entry; links and directories are walked or skipped."""
    for name, entry in node.get('files', {}).items():
        path = f'{prefix}/{name}' if prefix else name
        if 'files' in entry:
            yield from walk(entry, path)
        elif 'link' not in entry:
            yield path, entry


def find(header, wanted):
    node = header
    for part in wanted.strip('/').split('/'):
        node = node.get('files', {}).get(part)
        if node is None:
            return None
    return node if 'files' not in node and 'link' not in node else None


def safe_target(out_dir, inner):
    target = os.path.realpath(os.path.join(out_dir, *inner.split('/')))
    root = os.path.realpath(out_dir)
    if os.path.commonpath([root, target]) != root:
        raise ValueError(f'refusing path outside the output directory: {inner}')
    return target


def cmd_list(args):
    header, _ = read_header(args.asar)
    pattern = re.compile(args.grep) if args.grep else None
    for path, entry in walk(header):
        size = int(entry.get('size', 0))
        if size < args.min_size or (pattern and not pattern.search(path)):
            continue
        flag = ' (unpacked)' if entry.get('unpacked') else ''
        print(f'{size:>12}  {path}{flag}')


def read_entry(f, asar, base, inner, entry):
    """Returns the file's bytes, or None for an unpacked entry missing on disk (other platforms' builds)."""
    if entry.get('unpacked'):
        try:
            with open(os.path.join(asar + '.unpacked', *inner.split('/')), 'rb') as src:
                return src.read()
        except FileNotFoundError:
            return None
    f.seek(base + int(entry['offset']))
    return f.read(int(entry.get('size', 0)))


def cmd_grep(args):
    header, base = read_header(args.asar)
    pattern = re.compile(args.regex.encode('utf-8'))
    paths = re.compile(args.paths) if args.paths else None
    hits, files_matched, missing = 0, 0, 0
    rows, used = [], 0
    budget = args.max_output_chars
    if not (800 <= budget <= 16000 and 0 <= args.context <= 2000 and 1 <= args.max_per_file <= 100 and 1 <= args.max_files <= 100):
        raise ValueError('Invalid bounded grep options')
    with open(args.asar, 'rb') as f:
        for inner, entry in walk(header):
            if paths and not paths.search(inner):
                continue
            data = read_entry(f, args.asar, base, inner, entry)
            if data is None:
                missing += 1
                continue
            file_hits = 0
            for m in pattern.finditer(data):
                hits += 1
                file_hits += 1
                if file_hits == 1:
                    files_matched += 1
                if file_hits > args.max_per_file or files_matched > args.max_files:
                    continue
                start, end = max(0, m.start() - args.context), min(len(data), m.end() + args.context)
                snippet = data[start:end].decode('utf-8', 'replace').replace('\r', ' ').replace('\n', ' ')
                row = {'file': inner, 'offset': m.start(), 'excerpt': snippet}
                size = len(json.dumps(row, ensure_ascii=False).encode('utf8')) + 2
                if used + size <= budget - 400:
                    rows.append(row)
                    used += size
    result = {'totalMatches': hits, 'filesMatched': files_matched, 'missingUnpacked': missing,
              'matches': rows, 'omittedMatches': hits-len(rows), 'outputBudgetBytes': budget}
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        for row in rows:
            print(f"{row['file']}@{row['offset']}: {row['excerpt']}")
        print(f"matches={hits} files={files_matched} shown={len(rows)} omitted={hits-len(rows)} missingUnpacked={missing}")
    return 0 if hits else 1


def cmd_extract(args):
    header, base = read_header(args.asar)
    os.makedirs(args.out, exist_ok=True)
    failed = 0
    with open(args.asar, 'rb') as f:
        for inner in args.paths:
            entry = find(header, inner)
            if entry is None:
                print(f'not found: {inner}', file=sys.stderr)
                failed += 1
                continue
            target = safe_target(args.out, inner)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            size = int(entry.get('size', 0))
            data = read_entry(f, args.asar, base, inner, entry)
            if data is None:
                print(f'unpacked file missing on disk: {inner}', file=sys.stderr)
                failed += 1
                continue
            if len(data) != size:
                print(f'short read: {inner}', file=sys.stderr)
                failed += 1
                continue
            with open(target, 'wb') as out:
                out.write(data)
            print(f'{size:>12}  {target}')
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    p_list = sub.add_parser('list', help='print size and path of each file')
    p_list.add_argument('asar')
    p_list.add_argument('--grep', help='only paths matching this regex')
    p_list.add_argument('--min-size', type=int, default=0, help='only files of at least this many bytes')
    p_grep = sub.add_parser('grep', help='print matches of a regex with the file each one is in')
    p_grep.add_argument('asar')
    p_grep.add_argument('regex')
    p_grep.add_argument('--paths', help='only files whose path matches this regex')
    p_grep.add_argument('--context', type=int, default=120, help='characters shown on each side')
    p_grep.add_argument('--max-per-file', type=int, default=3)
    p_grep.add_argument('--max-files', type=int, default=8)
    p_grep.add_argument('--max-output-bytes', '--max-output-chars', dest='max_output_chars', type=int, default=6000, help='total UTF-8 output byte budget, 800..16000')
    p_grep.add_argument('--json', action='store_true', help='bounded excerpts plus exact match/omission counts')
    p_extract = sub.add_parser('extract', help='write the named files under --out')
    p_extract.add_argument('asar')
    p_extract.add_argument('paths', nargs='+')
    p_extract.add_argument('--out', required=True)
    args = parser.parse_args()
    if args.command == 'list':
        cmd_list(args)
        return 0
    if args.command == 'grep':
        return cmd_grep(args)
    return cmd_extract(args)


if __name__ == '__main__':
    sys.exit(main())
