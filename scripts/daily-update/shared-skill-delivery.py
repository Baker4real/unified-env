"""Stage Magpie delivery of a guarded shared skill through DeepSeek Harness first."""
import argparse
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import time

from evidence_io import RunEvidence, _is_reparse

ROOT = Path(__file__).resolve().parents[2]
ACTIVE = Path('D:/agents/skills-manager/skills')
EVIDENCE = Path('D:/agents/run-evidence')
MAGPIE_EXE = Path('D:/Apps/magpie/magpie.exe')
MAGPIE_STATE = Path('D:/Codex/.config/magpie/library.json')
SUPPORTED_AGENTS = frozenset(('dsh', 'claude', 'claude-desktop', 'codex', 'kimi'))
MAGPIE_MARKER = '.magpie-library'


class DeliveryError(ValueError):
    """A bounded business failure that is safe to put in a receipt."""


def require(condition, reason):
    if not condition:
        raise DeliveryError(reason)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class GuardedSkill:
    def __init__(self, name, manifest, preset, cwd, model_invocable, user_invocable):
        require(re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', name) and len(name) <= 64, 'invalid-skill-name')
        require(re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', preset), 'invalid-preset')
        require(cwd.is_absolute() and cwd.is_dir(), 'invalid-workspace')
        require(manifest.is_absolute() and manifest.is_relative_to(EVIDENCE) and manifest.name == 'manifest.json'
                and '..' not in manifest.parts, 'invalid-transaction-path')
        require(not any(_is_reparse(path) for path in (manifest, *manifest.parents)), 'transaction-reparse-point')
        raw = manifest.read_bytes()
        receipt = json.loads(raw.decode('utf-8-sig'))
        require(receipt['schema_version'] == 1 and receipt['status'] == 'succeeded'
                and receipt['targets'] == [name] and receipt['target_scope'] == 'active'
                and Path(receipt['active_root']).resolve(strict=True) == ACTIVE.resolve(strict=True),
                'guarded-install-required')
        # An update is accepted for read-only verification. Mutating commands check `new_install`.
        self.source = ACTIVE / name
        record, = receipt['directory_records']
        require(record['name'] == name and Path(record['active']) == self.source
                and record['activated'] is True, 'activation-does-not-bind-skill')
        self.seal = record['activated_payload_seal']
        self.new_install = receipt['decision']['decision'] == 'install' and record['had_existing'] is False
        row, = receipt['catalog_verification']['skills']
        require(row['name'] == name and row['path'] == name, 'catalog-does-not-bind-skill')
        self.sha256 = row['skill_md_sha256']
        self.transaction = receipt['transaction_id']
        self.manifest = manifest
        self.manifest_sha256 = sha256(raw)
        self.name = name
        self.cwd = cwd
        self.preset = preset
        self.model_invocable = model_invocable
        self.user_invocable = user_invocable

    def verify(self):
        # Reuse the guarded transaction's full activated-tree hashing contract.
        sys.path.insert(0, str(ROOT / 'modules/skill-supply-chain/implementation'))
        from install_skill_guarded_base import InstallError
        from install_skill_guarded_tree import verify_tree_seal
        try:
            verify_tree_seal(self.source, seal=self.seal, label=self.name)
        except InstallError:
            raise DeliveryError('guarded-payload-drift') from None
        require(file_hash(self.source / 'SKILL.md') == self.sha256 and file_hash(self.manifest) == self.manifest_sha256,
                'guarded-payload-drift')


def same_dsh_policy(result, skill):
    expected = {
        'ok': True,
        'preset': skill.preset,
        'source': 'user-dsh',
        'sha256': skill.sha256,
        'modelInvocable': skill.model_invocable,
        'userInvocable': skill.user_invocable,
        'bodyLoaded': True,
    }
    return (all(result.get(key) == value and type(result.get(key)) is type(value) for key, value in expected.items())
            and result.get('path') and Path(result['path']) == (skill.source / 'SKILL.md').resolve())


def advance(mode, skill, agents, magpie, probe):
    """Use fresh runtime acceptance before calling Magpie's secondary distribution."""
    skill.verify()
    initial = magpie.selected(skill)
    first = ('dsh',)
    if mode == 'register':
        require(initial in (None, first), 'registration-already-has-other-agents')
        if initial is None:
            magpie.install(skill)
    else:
        require(initial in (first, agents), 'dsh-registration-required' if initial is None else 'magpie-selection-drift')
    try:
        counts = magpie.verify_delivery(skill, first)
    except DeliveryError:
        if mode != 'register' or initial != first:
            raise
        magpie.distribute(skill, first)
        counts = magpie.verify_delivery(skill, first)
    observed = probe(skill)
    require(same_dsh_policy(observed, skill), 'dsh-acceptance-mismatch')
    skill.verify()
    status = 'dsh-verified'
    if mode == 'deliver' and agents != first:
        current = magpie.selected(skill)
        require(current == initial, 'magpie-selection-drift')
        if current == agents:
            try:
                counts = magpie.verify_delivery(skill, agents)
            except DeliveryError:
                magpie.distribute(skill, agents)
                counts = magpie.verify_delivery(skill, agents)
        else:
            magpie.distribute(skill, agents)
            counts = magpie.verify_delivery(skill, agents)
    if mode == 'deliver':
        status = 'distributed'
    elif mode == 'verify':
        require(initial == agents, 'magpie-selection-drift')
        if agents != first:
            counts = magpie.verify_delivery(skill, agents)
        status = 'verified'
    skill.verify()
    return dict(ok=True, status=status, dsh=observed, verified_target_counts=counts)


def probe_dsh(skill):
    executable = os.environ.get('DSH_NODE_EXECUTABLE')
    require(executable and Path(executable).is_file(), 'dsh-runtime-unavailable')
    env = dict(os.environ, ELECTRON_RUN_AS_NODE='1')
    child = subprocess.run([executable, '--expose-internals', str(Path(__file__).with_name('probe-dsh-skill.mjs')),
                            skill.preset, str(skill.cwd), skill.name], stdin=subprocess.DEVNULL,
                           capture_output=True, env=env, timeout=40, creationflags=subprocess.CREATE_NO_WINDOW)
    if child.returncode != 0:
        try:
            reason = json.loads(child.stdout).get('reason')
        except (ValueError, AttributeError):
            reason = None
        raise DeliveryError(reason if isinstance(reason, str) and re.fullmatch(r'[a-z]+(?:-[a-z]+)+', reason)
                            else 'dsh-runtime-probe-failed')
    return json.loads(child.stdout)


def skills_inventory(root, ignore_marker=False):
    """The regular payload bytes of a delivery copy, ignoring Magpie's ownership marker."""
    def walk_error(error):
        raise error

    result = {}
    require(root.is_dir() and not _is_reparse(root), 'invalid-delivery-copy')
    for parent, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        base = Path(parent)
        require(not any(_is_reparse(base / item) for item in dirs + files), 'invalid-delivery-copy')
        for item in files:
            path = base / item
            relative = path.relative_to(root).as_posix()
            if ignore_marker and relative == MAGPIE_MARKER:
                continue
            require(path.is_file(), 'invalid-delivery-copy')
            result[relative] = file_hash(path)
    return result


def verify_target(path, skill, library, *, agent=None):
    if agent == 'claude-desktop':
        manifest = path.parents[1] / 'manifest.json'
        require(manifest.is_file() and not _is_reparse(manifest), 'desktop-skill-manifest-unavailable')
        rows = json.loads(manifest.read_text(encoding='utf-8-sig'))['skills']
        matched = [row for row in rows if row['name'] == skill.name]
        require(len(matched) == 1 and matched[0].get('enabled') is True, 'desktop-skill-not-enabled')
    if path.resolve(strict=True) == skill.source.resolve(strict=True):
        if path.is_symlink():
            link = os.readlink(path)
            if os.name == 'nt':
                link = link.removeprefix('\\\\?\\')
            target = Path(os.path.abspath(path.parent / link))
            require(target == library.absolute(), 'consumer-link-not-owned-by-magpie')
        else:
            require(path == Path('D:/Codex/.codex/skills') / skill.name, 'unexpected-direct-delivery')
        return
    marker = path / MAGPIE_MARKER
    require(marker.is_file() and not _is_reparse(marker), 'unmanaged-consumer-copy')
    require(skills_inventory(path, ignore_marker=True) == skills_inventory(skill.source), 'consumer-copy-drift')


def consumer_paths(agent, name):
    home = Path(os.environ['USERPROFILE'])
    roots = {
        'dsh': Path(os.environ['DSH_HOME']),
        'claude': Path(os.environ.get('CLAUDE_CONFIG_DIR') or home / '.claude'),
        'codex': Path('D:/Codex/.codex'),
        'kimi': Path(os.environ.get('KIMI_CODE_HOME') or home / '.kimi-code'),
    }
    if agent != 'claude-desktop':
        return [roots[agent] / 'skills' / name]
    data_dirs = {Path(os.environ[x]) / folder for x in ('LOCALAPPDATA', 'APPDATA') for folder in ('Claude', 'Claude-3p')}
    accounts = []
    for data in sorted(data_dirs):
        root = data / 'local-agent-mode-sessions/skills-plugin'
        for path in sorted(root.glob('*/*')):
            if (path / 'manifest.json').is_file() or (path / '.claude-plugin/plugin.json').is_file():
                accounts.append(path / 'skills' / name)
    return accounts


class Magpie:
    def __init__(self, state=MAGPIE_STATE, executable=MAGPIE_EXE):
        self.state = state
        self.executable = executable

    def read(self):
        # Keep library credentials in process. Only per-skill results leave this adapter.
        return json.loads(self.state.read_text(encoding='utf-8-sig'))

    def entry(self, state, name):
        matches = [row for row in state.get('skills', []) if row['name'].casefold() == name]
        require(len(matches) <= 1, 'duplicate-magpie-entry')
        return matches[0] if matches else None

    def selected(self, skill):
        entry = self.entry(self.read(), skill.name)
        if entry is None:
            return None
        source = entry['source']
        require(source['kind'] == 'folder' and Path(source['dir']) == skill.source
                and not entry.get('offHere'), 'magpie-source-or-local-state-mismatch')
        agents = tuple(sorted(entry['agents']))
        require(len(agents) == len(set(agents)), 'invalid-magpie-selection')
        return agents

    @property
    def library_root(self):
        return self.state.parent / 'library/skills'

    def verify_delivery(self, skill, agents):
        current = self.selected(skill)
        require(current is not None and set(agents) <= set(current), 'magpie-selection-mismatch')
        state = self.read()
        self.require_direct_delivery(state)
        library = self.library_root / skill.name
        require(library.is_symlink() and library.resolve(strict=True) == skill.source.resolve(strict=True), 'magpie-library-link-mismatch')
        counts = {}
        for agent in agents:
            require(skill.name in state.get('applied', {}).get(agent, {}).get('skills', []), 'magpie-application-not-confirmed')
            paths = consumer_paths(agent, skill.name)
            require(paths, 'consumer-skill-location-unavailable')
            for path in paths:
                require(path.is_dir(), 'consumer-skill-missing')
                verify_target(path, skill, library, agent=agent)
            counts[agent] = len(paths)
        return counts

    @contextlib.contextmanager
    def endpoint(self):
        config_home = os.environ.get('XDG_CONFIG_HOME')
        executable_dir = self.executable.resolve(strict=True).parent
        require(config_home and self.state == Path(config_home) / 'magpie/library.json'
                and not (executable_dir / '.portable').exists() and not (executable_dir / 'data').is_dir(),
                'magpie-config-root-mismatch')
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        key = secrets.token_hex(32)
        env = {k: v for k, v in os.environ.items() if not k.startswith('MAGPIE_WEB_')}
        env['MAGPIE_WEB_KEY'] = key
        with subprocess.Popen([str(self.executable), 'web', '--addr', f'127.0.0.1:{port}', '--no-open'],
                              env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              creationflags=subprocess.CREATE_NO_WINDOW) as process:
            try:
                deadline = time.monotonic() + 12
                while True:
                    require(process.poll() is None, 'magpie-endpoint-exited')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.25):
                            break
                    except OSError:
                        require(time.monotonic() < deadline, 'magpie-endpoint-timeout')
                        time.sleep(0.10)

                def post(operation, payload):
                    require(process.poll() is None, 'magpie-endpoint-exited')
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
                    try:
                        connection.request('POST', f'/api/library/skills/{operation}', json.dumps(payload),
                                           {'Content-Type': 'application/json', 'Cookie': f'magpie_web_{port}={key}'})
                        reply = connection.getresponse()
                        require(reply.status == 200, 'magpie-library-request-failed')
                        response = reply.read(2_000_001)
                        require(len(response) <= 2_000_000, 'magpie-response-too-large')
                        return json.loads(response)
                    finally:
                        connection.close()

                yield post
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=6)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=6)

    @staticmethod
    def require_direct_delivery(state):
        require(state.get('sharedSkills', False) is False and state.get('skillRouter', False) is False,
                'magpie-per-agent-delivery-required')

    def install(self, skill):
        before = self.read()
        self.require_direct_delivery(before)
        library = self.library_root / skill.name
        orphan = (library.is_symlink() and library.resolve() == skill.source.resolve())
        require(self.entry(before, skill.name) is None and (not os.path.lexists(library) or orphan),
                'magpie-initial-registration-conflict')
        with self.endpoint() as post:
            probe = post('probe', {'source': str(skill.source)})
            candidates = probe['candidates']
            require(probe['kind'] == 'folder' and len(candidates) == 1, 'magpie-folder-probe-mismatch')
            candidate = candidates[0]
            require(candidate['name'] == skill.name and candidate['path'] == '' and not candidate.get('have')
                    and not candidate.get('as'), 'magpie-folder-probe-mismatch')
            require(self.read() == before, 'magpie-state-changed-during-registration')
            skill.verify()
            result = post('install', {'source': str(skill.source), 'paths': [''], 'agents': ['dsh']})['result']
            require(result['installed'] == [skill.name], 'magpie-install-not-acknowledged')
        require(self.selected(skill) == ('dsh',), 'magpie-dsh-only-registration-mismatch')

    def distribute(self, skill, agents):
        state = self.read()
        self.require_direct_delivery(state)
        before = self.selected(skill)
        require(before in (('dsh',), agents), 'magpie-selection-drift')
        with self.endpoint() as post:
            require(self.read() == state and self.selected(skill) == before, 'magpie-selection-drift')
            skill.verify()
            post('agents', {'name': skill.name, 'agents': list(agents)})['result']
        require(self.selected(skill) == agents, 'magpie-selection-mismatch')


def enabled_agents(args, magpie):
    if args.agents:
        requested = args.agents.split(',')
    else:
        sibling = magpie.entry(magpie.read(), args.like)
        require(sibling and not sibling.get('offHere'), 'distribution-reference-unavailable')
        requested = sorted(set(sibling['agents']) | {'dsh'})
    require('dsh' in requested and len(set(requested)) == len(requested)
            and set(requested) <= SUPPORTED_AGENTS, 'unsupported-distribution-targets')
    return tuple(sorted(requested))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('register', 'deliver', 'verify'))
    parser.add_argument('--run-directory', required=True, type=Path)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--transaction-manifest', required=True, type=Path)
    parser.add_argument('--name', required=True)
    parser.add_argument('--preset', required=True)
    parser.add_argument('--cwd', required=True, type=Path)
    parser.add_argument('--model-invocable', required=True, choices=('yes', 'no'))
    parser.add_argument('--user-invocable', required=True, choices=('yes', 'no'))
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--agents', help='Exact comma-separated agent IDs, including dsh')
    selection.add_argument('--like', help='Already adopted Magpie skill whose host selection to reuse')
    args = parser.parse_args()
    output = {'schema_version': 1, 'receipt_kind': 'shared-skill-delivery', 'ok': False, 'phase': args.mode}
    try:
        require(args.run_directory.is_relative_to(EVIDENCE), 'invalid-run-directory')
        run = RunEvidence(args.run_directory)
        destination = run.output_path(args.receipt)
        require(destination.suffix == '.json', 'expected-json-receipt')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with run.output_path(destination).open('x', encoding='utf-8') as stream:
            try:
                magpie = Magpie()
                skill = GuardedSkill(args.name, args.transaction_manifest, args.preset, args.cwd,
                                     args.model_invocable == 'yes', args.user_invocable == 'yes')
                require(args.mode == 'verify' or skill.new_install, 'new-guarded-install-required')
                agents = enabled_agents(args, magpie)
                output.update(name=skill.name, intended_agents=list(agents), preset=skill.preset, cwd=str(skill.cwd),
                              expected_model_invocable=skill.model_invocable, expected_user_invocable=skill.user_invocable,
                              transaction_id=skill.transaction, transaction_manifest=str(skill.manifest),
                              transaction_manifest_sha256=skill.manifest_sha256)
                output.update(advance(args.mode, skill, agents, magpie, probe_dsh))
            except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError,
                    http.client.HTTPException) as error:
                output.update(status='pending', reason=str(error) if isinstance(error, DeliveryError) else type(error).__name__)
            json.dump(output, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        output['receipt'] = str(destination)
    except (OSError, ValueError) as error:
        output.update(status='receipt-not-created', reason=str(error) if isinstance(error, DeliveryError) else type(error).__name__)
    sys.stdout.buffer.write(json.dumps(output, ensure_ascii=False).encode('utf-8') + b'\n')
    return 0 if output['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
