"""Stage or verify one skill from a local Git clone and a read-only active baseline.

Writes are confined to the current run's skills/staging/<name> before review.
The guarded installer still owns decision manifests, validation, and activation.
"""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
from evidence_io import RunEvidence


EVIDENCE_ROOT = Path('D:/agents/run-evidence')
CONFIG_FIELDS = {'run_directory', 'repository', 'active_root', 'name', 'mode', 'upstream_path',
                 'old_commit', 'new_commit'}
MAX_JSON = 8192
MAX_ATTEMPTS = 8
MAX_ENTRIES = 10000
MAX_LISTING = 8 * 1024 * 1024
MAX_FILE = 16 * 1024 * 1024
MAX_TREE = 128 * 1024 * 1024
MAX_SAMPLE_PATH_BYTES = 256
SOURCE = 'SOURCE.md'
SKILL = 'SKILL.md'
DIRECTORY = object()
NAME = re.compile(r'[a-z0-9][a-z0-9-]{0,63}')
WINDOWS_DEVICE = re.compile(r'CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|(?:COM|LPT)[0-9¹²³]')
CANDIDATE_HASH_ALGORITHM = 'sha256-sorted-posix-directory-and-file-sha256-v1'


class StageError(ValueError):
    def __init__(self, status, **details):
        super().__init__(status)
        self.details = details


def sample_path(path):
    raw = path.encode('utf-8', errors='replace')
    return raw.decode('utf-8') if len(raw) <= MAX_SAMPLE_PATH_BYTES else '<long-path>'


def check_component(name, path):
    if (name in ('', '.', '..') or name.endswith((' ', '.'))
            or any(c in '<>:"\\/|?*' or not c.isprintable() for c in name)
            or WINDOWS_DEVICE.fullmatch(name.split('.', 1)[0].rstrip(' ').upper())
            or len(name.encode('utf-16-le')) > 510):
        raise StageError('unsafe-path', path=sample_path(path))


def check_relative(path):
    if len(path.encode('utf-16-le')) > 32000:
        raise StageError('unsafe-path', path='<long-path>')
    for part in path.split('/'):
        check_component(part, path)
        if part.casefold() == '.git' or re.fullmatch(r'git~[0-9]+', part.casefold()):
            raise StageError('unsafe-path', path=sample_path(path))


def absolute_d(value):
    if not isinstance(value, str) or len(value.encode('utf-8')) > 768:
        raise StageError('invalid-absolute-d-path')
    path = Path(value)
    if not path.is_absolute() or path.drive.casefold() != 'd:':
        raise StageError('invalid-absolute-d-path')
    for part in path.parts[1:]:
        check_component(part, part)
    return path


def disk(path):
    # All disk paths are validated, absolute D: paths. Extend them for deep resource trees.
    return Path('\\\\?\\' + str(path))


def ordinary_stat(path):
    try:
        info = disk(path).lstat()
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode) or info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        raise StageError('reparse-path', path=sample_path(str(path)))
    return info


def checked_path(path):
    for parent in reversed(path.parents):
        info = ordinary_stat(parent)
        if info is not None and not stat.S_ISDIR(info.st_mode):
            raise StageError('expected-directory')
    return ordinary_stat(path)


def unique_object(pairs):
    value = dict(pairs)
    if len(value) != len(pairs):
        raise ValueError('duplicate-json-key')
    return value


def read_json(path):
    info = checked_path(path)
    if info is None or not stat.S_ISREG(info.st_mode) or info.st_size > MAX_JSON:
        raise StageError('invalid-or-missing-json')
    with disk(path).open('rb') as stream:
        raw = stream.read(MAX_JSON + 1)
    if len(raw) > MAX_JSON:
        raise StageError('invalid-or-missing-json')
    try:
        value = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique_object)
    except (ValueError, RecursionError) as exc:
        raise StageError('invalid-or-missing-json') from exc
    if not isinstance(value, dict):
        raise StageError('invalid-or-missing-json')
    return value


def overlaps(left, right):
    return left.is_relative_to(right) or right.is_relative_to(left)


def config_context(config_path):
    config_path = absolute_d(config_path)
    if not config_path.is_relative_to(EVIDENCE_ROOT):
        raise StageError('outside-managed-evidence')
    config = read_json(config_path)
    if set(config) != CONFIG_FIELDS or config['mode'] not in ('update', 'install'):
        raise StageError('invalid-config')
    name, upstream = config['name'], config['upstream_path']
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise StageError('invalid-skill-name')
    check_component(name, name)
    if not isinstance(upstream, str) or '`' in upstream or len(upstream.encode('utf-8')) > 1024:
        raise StageError('invalid-upstream-path')
    if upstream != '.':
        check_relative(upstream)
    run, repo, active = (absolute_d(config[field]) for field in ('run_directory', 'repository', 'active_root'))
    if not config_path.is_relative_to(run) or not run.is_relative_to(EVIDENCE_ROOT):
        raise StageError('outside-current-run')
    checked_path(run)
    writer = RunEvidence(run)
    state_root = writer.root / 'skills' / 'staging'
    if any(overlaps(state_root, root) for root in (repo, active)):
        raise StageError('staging-overlaps-input')
    for root in (repo, active):
        info = checked_path(root)
        if info is None or not stat.S_ISDIR(info.st_mode):
            raise StageError('missing-input-directory')
    if config['mode'] == 'install' and config['old_commit'] is not None:
        raise StageError('install-requires-null-old-commit')
    config.update(run_directory=str(writer.root), repository=str(repo), active_root=str(active))
    return config, writer, repo, active / name


def run_tree_listing(argv, options, timeout):
    # Bound the output before buffering, including when an oversized subtree is supplied.
    with subprocess.Popen(argv, stdin=subprocess.DEVNULL, **options) as process:
        expired = threading.Event()

        def expire():
            expired.set()
            process.kill()

        timer = threading.Timer(timeout, expire)
        timer.start()
        try:
            raw = process.stdout.read(MAX_LISTING + 1)
            if len(raw) > MAX_LISTING:
                raise StageError('git-tree-listing-limit')
            code = process.wait()
            if expired.is_set():
                raise subprocess.TimeoutExpired(argv, timeout)
            return subprocess.CompletedProcess(argv, code, raw)
        finally:
            timer.cancel()
            if process.poll() is None:
                process.kill()


class Git:
    def __init__(self, repo):
        # Address a clone itself, so Git cannot discover an unrelated parent repository.
        git_dir = repo / '.git'
        info = ordinary_stat(git_dir)
        if info is None:
            git_dir = repo
        elif not stat.S_ISDIR(info.st_mode):
            raise StageError('expected-local-clone')
        self.argv = ['git', '--no-pager', '-c', 'core.longpaths=true', '--git-dir', str(git_dir)]
        self.env = {k: v for k, v in os.environ.items() if not k.upper().startswith('GIT_')}
        self.env.update(GIT_NO_REPLACE_OBJECTS='1', GIT_NO_LAZY_FETCH='1', GIT_ALLOW_PROTOCOL='',
                        GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0', GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull)
        self.deadline = time.monotonic() + 120
        object_format = self.run('rev-parse', '--show-object-format').strip()
        if object_format not in (b'sha1', b'sha256'):
            raise StageError('unsupported-git-object-format')
        self.oid = re.compile('[0-9a-f]{' + ('40' if object_format == b'sha1' else '64') + '}')

    def run(self, operation, *args, data=None, merge_path=None):
        argv = [*self.argv, operation, *args]
        options = dict(stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=self.env,
                       creationflags=subprocess.CREATE_NO_WINDOW)
        timeout = max(0.01, min(45, self.deadline - time.monotonic()))
        try:
            if operation == 'ls-tree':
                result = run_tree_listing(argv, options, timeout)
            else:
                result = subprocess.run(argv, input=data, stdin=subprocess.DEVNULL if data is None else None,
                                        timeout=timeout, **options)
        except subprocess.TimeoutExpired as exc:
            raise StageError('git-timeout', git_operation=operation) from exc
        except FileNotFoundError as exc:
            raise StageError('git-not-found') from exc
        if result.returncode:
            conflict = merge_path is not None and 1 <= result.returncode <= 127
            status = 'text-merge-conflict' if conflict else 'git-failed'
            details = {} if merge_path is None else {'path': sample_path(merge_path)}
            raise StageError(status, git_operation=operation, git_exit_code=result.returncode, **details)
        return result.stdout

    def subtree(self, commit, path):
        if not isinstance(commit, str) or not self.oid.fullmatch(commit):
            raise StageError('full-commit-id-required')
        resolved = self.run('rev-parse', '--verify', '--end-of-options', f'{commit}^{{commit}}').strip()
        if resolved != commit.encode('ascii'):
            raise StageError('commit-object-id-required')
        expr = f'{commit}^{{tree}}' if path == '.' else f'{commit}:{path}'
        tree = self.run('rev-parse', '--verify', '--end-of-options', expr).strip().decode('ascii')
        if not self.oid.fullmatch(tree) or self.run('cat-file', '-t', tree).strip() != b'tree':
            raise StageError('upstream-path-is-not-tree')
        return tree

    def read_tree(self, tree):
        payload, files, objects = {}, {}, {}
        total_size = 0
        raw = self.run('ls-tree', '-r', '-t', '-z', '-l', tree)
        if raw and (not raw.endswith(b'\0') or raw.count(b'\0') > MAX_ENTRIES):
            raise StageError('git-tree-listing-limit')
        for entry in raw.split(b'\0')[:-1]:
            header, name = entry.split(b'\t', 1)
            mode, kind, oid, size = header.decode('ascii').split()
            path = name.decode('utf-8')
            check_relative(path)
            if path in payload or path in files or not self.oid.fullmatch(oid):
                raise StageError('invalid-git-tree')
            if mode == '040000' and kind == 'tree':
                payload[path] = DIRECTORY
            elif mode in ('100644', '100755') and kind == 'blob' and size.isdecimal():
                size = int(size)
                total_size += size
                if size > MAX_FILE or total_size > MAX_TREE:
                    raise StageError('skill-payload-size-limit')
                files[path] = oid
                objects[oid] = size
            else:
                raise StageError('unsupported-git-tree-entry', path=sample_path(path))
            if excluded(path.rsplit('/', 1)[-1], is_directory=path in payload):
                raise StageError('unsupported-upstream-metadata', path=sample_path(path))
        values = {}
        batch = {}
        batch_size = 0
        for oid, size in objects.items():
            if batch and (batch_size + size > MAX_FILE or len(batch) >= 256):
                values.update(self.read_blobs(batch))
                batch, batch_size = {}, 0
            batch[oid] = size
            batch_size += size
        if batch:
            values.update(self.read_blobs(batch))
        payload.update((path, values[oid]) for path, oid in files.items())
        check_tree(payload)
        return payload

    def read_blobs(self, objects):
        raw = self.run('cat-file', '--batch', data=('\n'.join(objects) + '\n').encode('ascii'))
        offset, blobs = 0, {}
        for oid, size in objects.items():
            header = f'{oid} blob {size}\n'.encode('ascii')
            start = offset + len(header)
            end = start + size
            if raw[offset:start] != header or raw[end:end + 1] != b'\n':
                raise StageError('invalid-git-blob')
            blobs[oid] = raw[start:end]
            offset = end + 1
        if offset != len(raw):
            raise StageError('invalid-git-blob')
        return blobs

    def merge(self, path, attempt, local, base, incoming):
        for value in (local, base, incoming):
            try:
                value.decode('utf-8')
            except UnicodeDecodeError as exc:
                raise StageError('binary-merge-conflict', path=sample_path(path)) from exc
            if re.search(rb'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', value):
                raise StageError('binary-merge-conflict', path=sample_path(path))
        with ExitStack() as stack:
            args = []
            for value in (local, base, incoming):
                stream = stack.enter_context(tempfile.NamedTemporaryFile(dir=disk(attempt), delete_on_close=False))
                stream.write(value)
                stream.flush()
                args.append(str(attempt / Path(stream.name).name))
            return self.run('merge-file', '-p', '--', *args, merge_path=path)


def excluded(name, *, is_directory):
    return name.casefold() in ('.git', '__pycache__') or (not is_directory and name.casefold().endswith('.pyc'))


def check_tree(payload):
    aliases = set()
    for path in payload:
        key = path.casefold()
        if key in aliases:
            raise StageError('case-colliding-path', path=sample_path(path))
        aliases.add(key)
        parent, sep, _ = path.rpartition('/')
        if sep and payload.get(parent) is not DIRECTORY:
            raise StageError('tree-merge-conflict', path=sample_path(path))


def read_disk_tree(root, *, active=False):
    info = checked_path(root)
    if info is None:
        return None
    if not stat.S_ISDIR(info.st_mode):
        raise StageError('expected-directory')
    payload, pending = {}, [(root, '')]
    total_size = entry_count = 0
    while pending:
        directory, relative = pending.pop()
        info = ordinary_stat(directory)
        if info is None or not stat.S_ISDIR(info.st_mode):
            raise StageError('tree-changed-during-read')
        for child in disk(directory).iterdir():
            path = relative + child.name
            check_component(child.name, path)
            info = ordinary_stat(directory / child.name)
            if info is None:
                raise StageError('tree-changed-during-read')
            is_directory = stat.S_ISDIR(info.st_mode)
            if not is_directory and not stat.S_ISREG(info.st_mode):
                raise StageError('unsupported-file-type', path=sample_path(path))
            entry_count += 1
            if entry_count > MAX_ENTRIES:
                raise StageError('skill-payload-entry-limit')
            if active and excluded(child.name, is_directory=is_directory):
                continue
            check_relative(path)
            if is_directory:
                payload[path] = DIRECTORY
                pending.append((directory / child.name, path + '/'))
                continue
            if info.st_size > MAX_FILE or total_size + info.st_size > MAX_TREE:
                raise StageError('skill-payload-size-limit')
            with child.open('rb') as stream:
                raw = stream.read(min(MAX_FILE, MAX_TREE - total_size) + 1)
            if len(raw) != info.st_size:
                raise StageError('tree-changed-during-read', path=sample_path(path))
            payload[path] = raw
            total_size += len(raw)
    check_tree(payload)
    return payload


def seal(payload):
    if payload is None:
        return None
    lines = []
    files = directories = 0
    for path, data in payload.items():
        if data is DIRECTORY:
            lines.append(f'D\t{path}\n')
            directories += 1
        else:
            lines.append(f'F\t{path}\t{hashlib.sha256(data).hexdigest()}\n')
            files += 1
    h = hashlib.sha256()
    for line in sorted(lines):
        h.update(line.encode('utf-8'))
    return {'tree_sha256': h.hexdigest(), 'file_count': files, 'directory_count': directories}


def replay_overlay(git, attempt, before, active, incoming):
    result = {}
    size = 0
    for path in sorted(before.keys() | active.keys() | incoming.keys()):
        base, local, new = before.get(path), active.get(path), incoming.get(path)
        if path == SOURCE or new == base or new == local:
            value = local
        elif local == base:
            value = new
        elif all(isinstance(data, bytes) for data in (base, local, new)):
            value = git.merge(path, attempt, local, base, new)
        else:
            raise StageError('tree-merge-conflict', path=sample_path(path))
        if value is not None:
            result[path] = value
            if isinstance(value, bytes):
                size += len(value)
                if len(value) > MAX_FILE or size > MAX_TREE:
                    raise StageError('skill-payload-size-limit')
            if len(result) > MAX_ENTRIES:
                raise StageError('skill-payload-entry-limit')
    check_tree(result)
    return result


def require_file(payload, file, status):
    if payload is None or not isinstance(payload.get(file), bytes):
        raise StageError(status)


def evidence_path(writer, relative):
    candidate = writer.root / relative
    checked_path(candidate)
    return writer.output_path(relative)


def take_attempt(writer, scope):
    parent = evidence_path(writer, scope)
    parent.mkdir(parents=True, exist_ok=True)
    for number in range(1, MAX_ATTEMPTS + 1):
        attempt = evidence_path(writer, scope / f'attempt-{number:02}')
        try:
            disk(attempt).mkdir()
        except FileExistsError:
            info = checked_path(attempt)
            if not info or not stat.S_ISDIR(info.st_mode):
                raise StageError('invalid-attempt-directory')
        else:
            return number, attempt
    raise StageError('attempt-limit-reached')


def materialize(candidate, payload):
    disk(candidate).mkdir()
    for path, data in sorted(payload.items()):
        target = disk(candidate / path)
        if data is DIRECTORY:
            target.mkdir()
        else:
            with target.open('xb') as stream:
                stream.write(data)


def candidate_result(status, binding, receipt, candidate, active, payload, candidate_seal):
    baseline = active or {}
    changed = [path for path in sorted(payload.keys() | baseline.keys()) if payload.get(path) != baseline.get(path)]
    samples = [path for path in changed[:8] if sample_path(path) == path]
    return dict(ok=True, status=status, name=binding['name'], receipt_path=str(receipt), candidate_path=str(candidate),
                candidate_tree_sha256=candidate_seal['tree_sha256'], changed_path_count=len(changed),
                changed_paths=samples, omitted_path_count=len(changed) - len(samples))


def validate_line_endings(payload, incoming, staged=None, unchanged=None):
    for path, data in sorted(payload.items()):
        if unchanged and path in unchanged and staged is not None and payload.get(path) == staged.get(path):
            continue  # Zero-payload upstream: preserving the active bytes introduces no line-ending drift.
        if path == SOURCE or not isinstance(data, bytes) or b'\r\n' not in data:
            continue
        try:
            data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        if re.search(rb'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', data):
            continue
        baseline = incoming.get(path, (staged or {}).get(path))
        if isinstance(baseline, bytes):
            crlf = baseline.count(b'\r\n')
            if crlf and baseline.count(b'\n') == crlf:
                continue  # The authoritative file already uses CRLF throughout.
            if crlf and data.count(b'\r\n') <= crlf:
                continue  # Preserve pre-existing mixed endings without increasing CRLF.
        raise StageError('candidate-line-ending-crlf', path=sample_path(path))


def stage_or_verify(action, config_path, reviewed_path=None):
    config, writer, repo, active_path = config_context(config_path)
    reviewed = None
    if reviewed_path is not None:
        reviewed = absolute_d(reviewed_path)
        if (action != 'verify' or not reviewed.is_relative_to(writer.root)
                or overlaps(reviewed, writer.root / 'skills' / 'staging')
                or any(overlaps(reviewed, root) for root in (repo, active_path.parent))):
            raise StageError('invalid-reviewed-candidate-path')
    git = Git(repo)
    old_tree = git.subtree(config['old_commit'], config['upstream_path']) if config['mode'] == 'update' else None
    new_tree = git.subtree(config['new_commit'], config['upstream_path'])
    before = git.read_tree(old_tree) if old_tree is not None else None
    binding = dict(config, old_tree=old_tree, new_tree=new_tree)
    scope = Path('skills/staging') / config['name']
    receipt = evidence_path(writer, scope / 'receipt.json')
    receipt_exists = ordinary_stat(receipt) is not None
    active = read_disk_tree(active_path, active=True)
    active_seal = seal(active)

    def verify(status):
        record = read_json(receipt)
        if record.get('binding') != binding:
            raise StageError('receipt-input-drift')
        if record.get('active_payload') != active_seal:
            raise StageError('active-payload-drift')
        number = record.get('attempt')
        if type(number) is not int or not 1 <= number <= MAX_ATTEMPTS:
            raise StageError('invalid-receipt')
        candidate = evidence_path(writer, scope / f'attempt-{number:02}' / 'candidate')
        payload = read_disk_tree(candidate)
        candidate_seal = seal(payload)
        if payload is None or record.get('candidate_payload') != candidate_seal:
            raise StageError('candidate-payload-drift')
        require_file(payload, SKILL, 'invalid-candidate')
        if config['mode'] == 'update':
            require_file(active, SOURCE, 'invalid-update-baseline')
            if payload.get(SOURCE) != active[SOURCE]:
                raise StageError('candidate-provenance-drift')
        elif active is not None:
            raise StageError('active-skill-already-exists')
        expected_record = receipt_record(binding, number, active_seal, candidate_seal)
        if json.dumps(record, sort_keys=True) != json.dumps(expected_record, sort_keys=True):
            raise StageError('invalid-receipt')
        incoming = git.read_tree(new_tree)
        unchanged = {path for path in incoming if before is not None and before.get(path) == incoming[path]}
        validate_line_endings(payload, incoming, active, unchanged)
        if reviewed is None:
            return candidate_result(status, binding, receipt, candidate, active, payload, candidate_seal)
        review_payload = read_disk_tree(reviewed)
        require_file(review_payload, SKILL, 'invalid-reviewed-candidate')
        if review_payload.get(SOURCE) != payload.get(SOURCE):
            raise StageError('candidate-provenance-drift')
        validate_line_endings(review_payload, incoming, payload, unchanged)
        result = candidate_result('reviewed', binding, receipt, reviewed, active, review_payload, seal(review_payload))
        result['skill_md_sha256'] = hashlib.sha256(review_payload[SKILL]).hexdigest()
        return result

    if receipt_exists:
        return verify('reused' if action == 'stage' else 'verified')
    if action == 'verify':
        raise StageError('receipt-not-found')

    incoming = git.read_tree(new_tree)
    require_file(incoming, SKILL, 'upstream-skill-missing')
    if config['mode'] == 'update':
        require_file(active, SKILL, 'active-skill-missing')
        require_file(active, SOURCE, 'active-source-missing')
        require_file(before, SKILL, 'upstream-baseline-missing')
    elif active is not None:
        raise StageError('active-skill-already-exists')

    number, attempt = take_attempt(writer, scope)
    candidate = evidence_path(writer, attempt.relative_to(writer.root) / 'candidate')
    payload = replay_overlay(git, attempt, before, active, incoming) if old_tree is not None else incoming
    require_file(payload, SKILL, 'candidate-skill-missing')
    unchanged = {path for path in incoming if before is not None and before.get(path) == incoming[path]}
    validate_line_endings(payload, incoming, active, unchanged)
    candidate_seal = seal(payload)
    materialize(candidate, payload)
    if seal(read_disk_tree(candidate)) != candidate_seal:
        raise StageError('candidate-payload-drift')
    if seal(read_disk_tree(active_path, active=True)) != active_seal:
        raise StageError('active-payload-drift')

    # Windows rename publishes an already written receipt and refuses any existing destination.
    # Interrupted attempts are never traversed for reuse without a valid published receipt.
    prepared = attempt / 'receipt-prepared.json'
    writer.write_json_new(prepared, receipt_record(binding, number, active_seal, candidate_seal))
    receipt = evidence_path(writer, scope / 'receipt.json')
    checked_path(prepared)
    try:
        os.rename(disk(prepared), disk(receipt))
    except FileExistsError:
        if seal(read_disk_tree(active_path, active=True)) != active_seal:
            raise StageError('active-payload-drift')
        return verify('reused')
    return candidate_result('staged', binding, receipt, candidate, active, payload, candidate_seal)


def receipt_record(binding, number, active, candidate):
    return dict(schema_version=1, status='staged', hash_algorithm=CANDIDATE_HASH_ALGORITHM,
                binding=binding, attempt=number, active_payload=active, candidate_payload=candidate)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise StageError('invalid-arguments')


def main():
    parser = Parser(description=__doc__)
    parser.add_argument('action', choices=('stage', 'verify'))
    parser.add_argument('--config', required=True, help='Absolute path to a same-run one-skill JSON config')
    parser.add_argument('--reviewed-candidate', help='Check a separate same-run review copy against the pinned upstream tree')
    try:
        args = parser.parse_args()
        result = stage_or_verify(args.action, args.config, args.reviewed_candidate)
        code = 0
    except StageError as exc:
        result, code = dict(ok=False, status=str(exc), **exc.details), 2
    except UnicodeError:
        result, code = dict(ok=False, status='invalid-utf8-path-or-git-metadata'), 2
    except ValueError:
        result, code = dict(ok=False, status='invalid-run-evidence-or-git-metadata'), 2
    except OSError as exc:
        result, code = dict(ok=False, status='filesystem-error', errno=exc.errno, winerror=exc.winerror), 2
    except KeyboardInterrupt:
        result, code = dict(ok=False, status='interrupted'), 130
    sys.stdout.buffer.write(json.dumps(result, ensure_ascii=False, separators=(',', ':')).encode('utf-8') + b'\n')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
