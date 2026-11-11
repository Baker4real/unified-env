"""Read-only component retirement: every required observation participates in success."""
import argparse
import importlib.util
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
_source_spec = importlib.util.spec_from_file_location('retirement_source_adapter', ROOT / 'scripts/skill_source_record.py')
_source_module = importlib.util.module_from_spec(_source_spec)
_source_spec.loader.exec_module(_source_module)


def marker_identity(filename, text):
    if filename == 'SOURCE.md':
        record = _source_module.parse_current_source_record(text)
        if 'skill' in record.conflicts:
            raise ValueError('ambiguous-source-identity')
        return record.fields.get('skill')
    lines = text.splitlines()
    if not lines or lines[0].strip() != '---':
        raise ValueError('missing-skill-frontmatter')
    end = next((index for index, line in enumerate(lines[1:], 1) if line.strip() in {'---', '...'}), None)
    if end is None:
        raise ValueError('unclosed-skill-frontmatter')
    header = '\n'.join(lines[1:end])
    identity_lines = re.findall(r'(?m)^name\s*:[^\r\n]*$', header)
    if len(identity_lines) != 1:
        raise ValueError('ambiguous-skill-name')
    try:
        # This verifier owns identity, not unrelated legacy description schemas.
        metadata = yaml.safe_load(identity_lines[0])
    except yaml.YAMLError as exc:
        raise ValueError('invalid-frontmatter') from exc
    if not isinstance(metadata, dict) or not isinstance(metadata.get('name'), str):
        raise ValueError('missing-skill-name')
    return metadata['name']


def physical(path):
    supplied = pathlib.Path(path)
    if not supplied.is_absolute() or '..' in supplied.parts:
        raise ValueError('absolute-path-required')
    for item in (supplied, *supplied.parents):
        try:
            info = item.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ValueError('reparse-path')
    return supplied


def exists(path):
    try:
        pathlib.Path(path).lstat()
        return True
    except FileNotFoundError:
        return False


def read_json(path):
    return json.loads(physical(path).read_text(encoding='utf-8-sig'))


def probe_host(spec):
    selection = {key: spec[key] for key in ('tasks', 'products', 'process_names')}
    pwsh = shutil.which('pwsh')
    if not pwsh:
        return {}
    try:
        child = subprocess.run([pwsh, '-NoProfile', '-NonInteractive', '-File',
            str(ROOT / 'scripts/Get-ComponentRetirementObservation.ps1'),
            '-SpecJson', json.dumps(selection)], timeout=60, capture_output=True, text=True, encoding='utf-8',
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        return json.loads(child.stdout) if child.returncode == 0 else {}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


def scan_payloads(roots, names):
    found, unknown = [], []
    for supplied in roots:
        try:
            root = physical(supplied)
            if not exists(root):
                continue
            if not root.is_dir():
                raise ValueError('scan-root-unavailable')
        except (OSError, ValueError):
            unknown.append(dict(path=str(supplied), reason='scan-root-unavailable'))
            continue
        pending = [root]
        while pending:
            directory = pending.pop()
            try:
                with os.scandir(directory) as iterator:
                    entries = list(iterator)
                for entry in entries:
                    info = entry.stat(follow_symlinks=False)
                    if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                        unknown.append(dict(path=entry.path, reason='scan-reparse-not-followed'))
                    elif stat.S_ISDIR(info.st_mode):
                        pending.append(pathlib.Path(entry.path))
                    elif entry.name in {'SKILL.md', 'SOURCE.md'}:
                        if info.st_size > 512 * 1024:
                            unknown.append(dict(path=entry.path, reason='marker-too-large'))
                            continue
                        text = pathlib.Path(entry.path).read_text(encoding='utf-8-sig')
                        identity = marker_identity(entry.name, text)
                        if identity in names:
                            found.append(dict(skill=identity, path=str(pathlib.Path(entry.path).parent), marker=entry.name))
            except (OSError, UnicodeError, ValueError):
                unknown.append(dict(path=str(directory), reason='scan-unreadable'))
    return found, unknown


def verify(spec, probe=probe_host):
    if spec.get('schema_version') != 1 or not spec.get('skills'):
        raise ValueError('invalid-retirement-spec')
    for key in ('consumer_roots', 'scan_roots', 'temporary_policy_ids', 'absent_paths', 'tasks', 'products', 'process_names', 'manual_pending'):
        if not isinstance(spec.get(key), list):
            raise ValueError('explicit-retirement-scope-required')
    if not spec['scan_roots'] or not spec['consumer_roots']:
        raise ValueError('retirement-coverage-required')
    names = [row['name'] for row in spec['skills']]
    if len(set(names)) != len(names) or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) for name in names):
        raise ValueError('invalid-skill-identity')
    checks, unknown, residual = {}, [], []
    def check(key, action):
        try:
            value = action()
            checks[key] = 'passed' if value else 'failed'
            if not value:
                residual.append(key)
        except (OSError, ValueError, KeyError, TypeError):
            checks[key] = 'unknown'
            unknown.append(key)
    active = physical(spec['active_root'])
    check('active_root_readable', lambda: active.is_dir() and bool(list(active.iterdir()) or active.is_dir()))
    for name in names:
        check('active:' + name, lambda name=name: not exists(active / name))
    for root in spec['consumer_roots']:
        def consumer_root(root=root):
            physical(root)
            return pathlib.Path(root).is_dir()
        check('consumer_root:' + root, consumer_root)
        for name in names:
            check('link:' + root + ':' + name, lambda root=root, name=name: not exists(pathlib.Path(root) / name))
    for path in spec['absent_paths']:
        check('path:' + path, lambda path=path: not exists(path))
    def ledger_retired():
        ledger = read_json(spec['ledger'])
        for row in spec['skills']:
            matches = [group for group in ledger['sources'] if group.get('id') == row['source_id']]
            if len(matches) != 1:
                return False
            group = matches[0]
            if group.get('status') != 'deleted-by-user' or group.get('skills') != [] or group.get('backup') is not None:
                return False
            if group.get('backup_status') != 'no-local-backup-by-user-rule':
                return False
            for deleted in group.get('deleted_skills', []) + ledger.get('deleted', []):
                if deleted.get('name') == row['name'] and (deleted.get('backup_path') is not None or deleted.get('backup_status') != 'purged-by-user-rule'):
                    return False
        return True
    check('ledger', ledger_retired)
    def magpie_absent():
        library = read_json(spec['magpie_library'])
        return not any(row.get('name') in names for row in library['skills'])
    check('magpie', magpie_absent)
    check('temporary_policy', lambda: not any(row['id'] in spec['temporary_policy_ids'] for row in read_json(spec['policy'])['entries']))
    try:
        observations = probe(spec)
    except Exception:
        observations = {}
    for section, key in (('tasks', 'tasks'), ('products', 'products'), ('processes', 'process_names')):
        for identity in spec[key]:
            state = observations.get(section, {}).get(identity, 'unknown')
            label = section + ':' + identity
            checks[label] = state if state in {'absent', 'present'} else 'unknown'
            if checks[label] == 'unknown':
                unknown.append(label)
            elif state != 'absent':
                residual.append(label)
    payloads, scan_unknown = scan_payloads(spec['scan_roots'], names)
    unknown.extend(scan_unknown)
    residual.extend(payloads)
    ok = not unknown and not residual
    manual_pending = spec['manual_pending']
    status = 'unknown' if unknown else 'residual' if residual else 'manual-pending' if manual_pending else 'retired'
    return dict(schema_version=1, ok=ok and not manual_pending, machine_retired=ok, status=status,
                checks=checks, residual=residual, unknown=unknown, payloads=payloads, manual_pending=manual_pending,
                scan_roots=spec['scan_roots'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = verify(read_json(args.spec))
    except (OSError, ValueError, KeyError, TypeError):
        result = dict(ok=False, status='unknown', reason='retirement-input-invalid')
    if args.output:
        target = physical(args.output)
        if target.drive.lower() != 'd:':
            raise ValueError('d-drive-output-required')
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('x', encoding='utf-8') as stream:
            json.dump(result, stream, ensure_ascii=False, indent=2)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['ok'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
