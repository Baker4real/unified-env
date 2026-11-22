"""Stage Magpie delivery of a guarded shared skill through DeepSeek Harness first."""
import argparse
import contextlib
import errno
from fnmatch import fnmatch
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import socket
import stat
import subprocess
import sys
import time

from evidence_io import RunEvidence, _is_reparse

ROOT = Path(__file__).resolve().parents[2]
ACTIVE = Path('D:/agents/skills-manager/skills')
EVIDENCE = Path('D:/agents/run-evidence')
MAGPIE_SCOPE_EXE = Path('D:/Codex/tools/magpie-scoped-library/magpie-scoped-library.exe')
MAGPIE_STATE = Path('D:/Codex/.config/magpie/library.json')
SUPPORTED_AGENTS = frozenset(('dsh', 'claude', 'claude-desktop', 'codex', 'kimi', 'antigravity'))
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
        operation = receipt['decision']['decision']
        require((operation == 'install' and record['had_existing'] is False)
                or (operation == 'update' and record['had_existing'] is True), 'invalid-guarded-operation')
        self.new_install = operation == 'install'
        self.operation = operation
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
        'antigravity': home / '.gemini/config',
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


# This is a fixed Windows observation scope, separate from write authorization.
AUDIT_EXCLUSIONS = (
    'other-hosts-and-profiles', 'other-skills-and-linked-payloads',
    'field-level-attribution-and-other-artifacts', 'projects-and-shared-or-router-skills',
    'backups-and-temporary-files', 'concurrent-or-restored-writes',
    'gui-instance-and-follow-up-sync-not-attributed',
    'antigravity-mcp-and-skill-files-shared-with-agy-if-installed',
)
AUDIT_FIELDS = {'present', 'missing', 'unknown', 'inventory_sha256', 'sha256'}
AUDIT_CONFIG_ARTIFACTS = {'library.state', 'claude-desktop.manifest'} | {f'{host}.mcp' for host in SUPPORTED_AGENTS}


def audit_stat(path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def audit_reparse(info):
    return bool(getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT) or stat.S_ISLNK(info.st_mode)


def audit_identity(info, *, handle=False):
    # On Windows lstat synthesizes executable bits from the filename (.cmd/.bat), fstat cannot.
    mode = stat.S_IFMT(info.st_mode) if handle and os.name == 'nt' else info.st_mode
    return (info.st_dev, info.st_ino, mode, info.st_size, info.st_mtime_ns)


def audit_digest(value):
    return sha256(json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode('ascii'))


def audit_parents(path, junctions):
    require(path.is_absolute() and '..' not in path.parts, 'magpie-audit-path-unknown')
    links = []
    for parent in reversed(path.parents):
        info = audit_stat(parent)
        if info is None:
            break
        require(stat.S_ISDIR(info.st_mode), 'magpie-audit-parent-not-directory')
        if audit_reparse(info):
            require(parent in junctions and parent.is_junction(), 'magpie-audit-unexpected-reparse')
            destination = Path(os.readlink(parent).removeprefix('\\\\?\\'))
            require(destination == junctions[parent] and not audit_parents(destination, {}),
                    'magpie-audit-junction-mismatch')
            resolved = audit_stat(destination)
            require(resolved is not None and stat.S_ISDIR(resolved.st_mode) and not audit_reparse(resolved),
                    'magpie-audit-junction-mismatch')
            links.append((str(parent), str(destination), audit_identity(info), resolved.st_ino))
    return links


def audit_regular_file(path, info):
    require(stat.S_ISREG(info.st_mode) and not audit_reparse(info), 'magpie-audit-not-regular-file')
    identity = audit_identity(info, handle=True)
    with path.open('rb') as stream:
        require(audit_identity(os.fstat(stream.fileno()), handle=True) == identity, 'magpie-audit-file-drift')
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        require(audit_identity(os.fstat(stream.fileno()), handle=True) == identity, 'magpie-audit-file-drift')
    current = path.lstat()
    require(not audit_reparse(current) and audit_identity(current) == audit_identity(info), 'magpie-audit-file-drift')
    return (audit_identity(info), digest)


def audit_skill_artifact(path, info):
    if audit_reparse(info):
        require(path.is_symlink() or path.is_junction(), 'magpie-audit-unexpected-reparse')
        target = os.readlink(path)  # Record link identity without following its payload.
        require(audit_identity(path.lstat()) == audit_identity(info), 'magpie-audit-link-drift')
        return ('link', audit_identity(info), target)
    require(stat.S_ISDIR(info.st_mode), 'magpie-audit-not-skill-directory')

    def walk_error(error):
        raise error

    rows = []
    for parent, dirs, files in os.walk(path, followlinks=False, onerror=walk_error):
        base = Path(parent)
        for name in sorted(dirs):
            child = base / name
            metadata = child.lstat()
            require(stat.S_ISDIR(metadata.st_mode) and not audit_reparse(metadata), 'magpie-audit-unexpected-reparse')
            rows.append((str(child.relative_to(path)), audit_identity(metadata)))
        for name in sorted(files):
            child = base / name
            rows.append((str(child.relative_to(path)), audit_regular_file(child, child.lstat())))
    require(audit_identity(path.lstat()) == audit_identity(info), 'magpie-audit-skill-drift')
    return ('tree', audit_identity(info), sorted(rows))


def audit_fingerprint(paths, junctions, *, skill=False):
    paths = sorted(set(paths))
    counts = dict(present=0, missing=0, unknown=0)
    fingerprints = []
    for path in paths:
        try:
            links = audit_parents(path, junctions)
            info = audit_stat(path)
            if info is None:
                status, value = 'missing', None
            else:
                status = 'present'
                value = audit_skill_artifact(path, info) if skill else audit_regular_file(path, info)
            require(links == audit_parents(path, junctions), 'magpie-audit-parent-drift')
        except (OSError, DeliveryError):
            status, value, links = 'unknown', None, []
        counts[status] += 1
        fingerprints.append((status, value, links))
    return dict(counts, inventory_sha256=audit_digest([str(path) for path in paths]),
                sha256=audit_digest(fingerprints))


def audit_subdirs(root, junctions, patterns=None):
    audit_parents(root, junctions)
    info = audit_stat(root)
    if info is None:
        return []
    require(stat.S_ISDIR(info.st_mode) and not audit_reparse(info), 'magpie-audit-directory-unavailable')
    result = []
    for entry in sorted(root.iterdir()):
        if patterns is not None and not any(fnmatch(entry.name, pattern) for pattern in patterns):
            continue
        metadata = entry.lstat()
        require(not audit_reparse(metadata), 'magpie-audit-unexpected-reparse')
        if stat.S_ISDIR(metadata.st_mode):
            result.append(entry)
    return result


def audit_artifacts(state, kind, name):
    home = Path(os.environ['USERPROFILE'])
    roaming, local = (Path(os.environ[key]) for key in ('APPDATA', 'LOCALAPPDATA'))
    dsh = Path(os.environ.get('DSH_HOME') or home / '.dsh')
    claude = Path(os.environ.get('CLAUDE_CONFIG_DIR') or home / '.claude')
    codex = Path(os.environ.get('CODEX_HOME') or home / '.codex')
    kimi_code, kimi_legacy = home / '.kimi-code', home / '.kimi'
    kimi = Path(os.environ.get('KIMI_CODE_HOME') or (kimi_code if kimi_code.is_dir() else
                os.environ.get('KIMI_SHARE_DIR') or (kimi_legacy if kimi_legacy.is_dir() else kimi_code)))
    antigravity = home / '.gemini/config'
    junctions = {
        Path('D:/Codex/.codex/skills'): ACTIVE,
        antigravity / 'skills': Path('D:/Codex/.config/antigravity/skills'),
        local / 'Claude-3p': Path('D:/Codex/.claude-home/AppData/Local/Claude-3p'),
    }
    artifacts = {
        'library.state': [state],
        'antigravity.mcp': [antigravity / 'mcp_config.json'],
        'claude.mcp': [(claude if os.environ.get('CLAUDE_CONFIG_DIR') else home) / '.claude.json'],
        'codex.mcp': [codex / 'config.toml'],
        'kimi.mcp': [kimi / 'mcp.json'],
    }
    unavailable = set()
    try:
        profiles = audit_subdirs(dsh / 'profiles', junctions)
        patches = [p / 'cordis.patch.yml' for p in profiles if audit_stat(p / 'cordis.patch.yml') is not None]
        artifacts['dsh.mcp'] = patches or [dsh / 'config.yaml']
    except (OSError, DeliveryError):
        unavailable.add('dsh.mcp')

    desktop_data = {base / folder for base in (roaming, local) for folder in ('Claude', 'Claude-3p')}
    desktop_accounts = set()
    try:
        for package in audit_subdirs(local / 'Packages', junctions, ('Claude_*', 'AnthropicPBC.Claude_*')):
            desktop_data.update(package / 'LocalCache' / folder
                                for folder in ('Roaming/Claude', 'Local/Claude', 'Local/Claude-3p'))
    except (OSError, DeliveryError):
        unavailable.update(('claude-desktop.mcp', 'claude-desktop.manifest'))
        if kind == 'skill':
            unavailable.add('claude-desktop.skill')
    artifacts['claude-desktop.mcp'] = [p / 'claude_desktop_config.json' for p in desktop_data]
    try:
        for data in desktop_data:
            plugin = data / 'local-agent-mode-sessions/skills-plugin'
            for org in audit_subdirs(plugin, junctions):
                for account in audit_subdirs(org, junctions):
                    for marker in (account / 'manifest.json', account / '.claude-plugin/plugin.json'):
                        audit_parents(marker, junctions)
                        info = audit_stat(marker)
                        if info is not None:
                            require(stat.S_ISREG(info.st_mode) and not audit_reparse(info), 'magpie-audit-desktop-marker-unknown')
                            desktop_accounts.add(account)
    except (OSError, DeliveryError):
        unavailable.add('claude-desktop.manifest')
        if kind == 'skill':
            unavailable.add('claude-desktop.skill')
    artifacts['claude-desktop.manifest'] = [p / 'manifest.json' for p in desktop_accounts]
    if kind == 'skill':
        artifacts.update({f'{host}.skill': [base / 'skills' / name] for host, base in {
            'library': state.parent / 'library', 'antigravity': antigravity, 'claude': claude,
            'codex': codex, 'dsh': dsh, 'kimi': kimi,
        }.items()})
        artifacts['claude-desktop.skill'] = [p / 'skills' / name for p in desktop_accounts]
    return artifacts, junctions, unavailable


def magpie_audit_before(state, kind, name, agents):
    require(kind in ('mcp', 'skill'), 'invalid-magpie-audit-kind')
    require((kind == 'mcp' and name is None) or (kind == 'skill' and isinstance(name, str)
            and len(name) <= 64 and re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', name)), 'invalid-magpie-audit-name')
    require(isinstance(agents, (list, tuple)) and all(isinstance(a, str) and a in SUPPORTED_AGENTS for a in agents)
            and len(set(agents)) == len(agents), 'invalid-magpie-audit-agents')
    report = dict(schema_version=1, receipt_kind='magpie-write-audit', kind=kind, name=name,
                  intended_agents=sorted(agents), limitations=list(AUDIT_EXCLUSIONS), fingerprints={})
    try:
        artifacts, junctions, unavailable = audit_artifacts(state, kind, name)
        report['fingerprints'] = {key: audit_fingerprint(paths, junctions, skill=key.endswith('.skill'))
                                  for key, paths in artifacts.items()}
    except (OSError, DeliveryError, KeyError):
        report.update(ok=False, status='preflight-incomplete', unavailable_artifacts=['inventory'],
                      reason='magpie-audit-inventory-unavailable')
        return report
    unavailable |= {key for key, value in report['fingerprints'].items() if value['unknown']}
    if report['fingerprints']['library.state']['present'] != 1:
        unavailable.add('library.state')
    report.update(ok=not unavailable, status='preflight-incomplete' if unavailable else 'preflight-ready',
                  unavailable_artifacts=sorted(unavailable))
    return report


def magpie_audit_after(state, before, result):
    after = magpie_audit_before(state, before['kind'], before['name'], before['intended_agents'])
    baseline, current = before['fingerprints'], after['fingerprints']
    unavailable = set(before.get('unavailable_artifacts', ())) | set(after.get('unavailable_artifacts', ()))
    unavailable |= {key for key in baseline.keys() | current.keys() if key not in baseline or key not in current
                    or baseline[key]['inventory_sha256'] != current[key]['inventory_sha256']}
    changes = {key: dict(before=baseline[key], after=current[key]) for key in baseline.keys() & current.keys()
               if key not in unavailable and baseline[key] != current[key]}
    reported = result.get('changed') if isinstance(result, dict) else None
    problems = result.get('problems') if isinstance(result, dict) else None
    result_complete = (isinstance(reported, list) and all(host is None or isinstance(host, str) and host for host in reported)
                       and isinstance(problems, list)
                       and all(isinstance(problem, dict) and isinstance(problem.get('agent'), str)
                               for problem in problems))
    reported = [host for host in reported if isinstance(host, str)] if isinstance(reported, list) else []
    result_complete = result_complete and len(set(reported)) == len(reported)
    problems = problems if isinstance(problems, list) else []
    reported_hosts = set(reported) & SUPPORTED_AGENTS
    unknown_reported_count = (sum(not isinstance(host, str) or host not in SUPPORTED_AGENTS for host in result['changed'])
                              if isinstance(result, dict) and isinstance(result.get('changed'), list) else 0)
    problem_hosts = {p['agent'] for p in problems if isinstance(p, dict) and isinstance(p.get('agent'), str)
                     and p['agent'] in SUPPORTED_AGENTS}
    observed_hosts = {key.split('.')[0] for key in changes} & SUPPORTED_AGENTS
    intended = set(before['intended_agents'])
    unexpected_hosts = (reported_hosts | observed_hosts) - intended
    expected_roles = {'skill', 'manifest'} if before['kind'] == 'skill' else {'mcp'}
    unexpected_artifacts = [key for key in changes if not key.startswith('library.')
                            and (key.split('.')[0] not in intended or key.split('.')[1] not in expected_roles)]
    unverified_hosts = reported_hosts - observed_hosts
    unreported_hosts = observed_hosts - reported_hosts
    ok = (before['ok'] and after['ok'] and result_complete and not problems and not unknown_reported_count
          and not unavailable and not unexpected_hosts and not unexpected_artifacts
          and not unverified_hosts and not unreported_hosts)
    return dict(schema_version=1, receipt_kind='magpie-write-audit', kind=before['kind'], name=before['name'],
                intended_agents=before['intended_agents'], limitations=list(AUDIT_EXCLUSIONS), ok=ok,
                status='observed-within-scope' if ok else 'review-required', result_complete=result_complete,
                reported_changed_hosts=sorted(reported_hosts), unknown_reported_host_count=unknown_reported_count,
                problem_count=len(problems), problem_hosts=sorted(problem_hosts),
                backup_reported=(isinstance(result, dict) and bool(result.get('backup') or result.get('backup_reported'))),
                unexpected_changed_hosts=sorted(unexpected_hosts), unverified_reported_hosts=sorted(unverified_hosts),
                unreported_observed_hosts=sorted(unreported_hosts), unexpected_artifacts=sorted(unexpected_artifacts),
                changed_artifacts=sorted(changes), unavailable_artifacts=sorted(unavailable),
                compared_artifacts=sorted(baseline.keys() & current.keys() - unavailable),
                changed_fingerprints={key: changes[key] for key in sorted(changes)})


class Magpie:
    def __init__(self, state=MAGPIE_STATE, executable=MAGPIE_SCOPE_EXE):
        self.state = state
        self.executable = executable
        self.write_audits = []

    @contextlib.contextmanager
    def audit_write(self, operation, kind, name, agents):
        before = magpie_audit_before(self.state, kind, name, agents)
        if not before['ok']:
            self.write_audits.append(dict(before, operation=operation))
            raise DeliveryError('magpie-write-audit-preflight-incomplete')
        result = None

        def capture(response):
            nonlocal result
            result = response.get('result') if isinstance(response, dict) else None
            return result

        try:
            yield capture
        finally:
            audit = magpie_audit_after(self.state, before, result)
            self.write_audits.append(dict(audit, operation=operation))
        require(audit['ok'], 'magpie-write-audit-needs-review')

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
    def write_lock(self):
        require(os.name == 'nt', 'magpie-scoped-writer-windows-required')
        import msvcrt

        require(not any(_is_reparse(path) for path in (self.state, *self.state.parents)),
                'magpie-config-root-mismatch')
        lock_path = self.state.resolve(strict=True).with_name('library.scoped.lock')
        metadata = audit_stat(lock_path)
        require(metadata is None or stat.S_ISREG(metadata.st_mode) and not audit_reparse(metadata),
                'invalid-magpie-scoped-lock')
        # Keep the file in place so every process locks the same identity.
        # Closing the handle releases the OS lock, including on process exit.
        with lock_path.open('a+b') as lock:
            lock.seek(0)
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                if error.errno in (errno.EACCES, errno.EAGAIN):
                    raise DeliveryError('magpie-scoped-write-busy') from error
                raise
            yield

    @contextlib.contextmanager
    def endpoint(self):
        config_home = os.environ.get('XDG_CONFIG_HOME')
        require(self.executable.is_file(), 'magpie-scoped-writer-unavailable')
        executable = self.executable.resolve(strict=True)
        require(config_home and self.state == Path(config_home) / 'magpie/library.json'
                and not (executable.parent / '.portable').exists() and not (executable.parent / 'data').is_dir(),
                'magpie-config-root-mismatch')
        env = {k: v for k, v in os.environ.items() if not k.startswith('MAGPIE_WEB_')}
        flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
        version = subprocess.run([str(executable), '--version'], env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, creationflags=flags,
                                 timeout=6, check=False)
        require(version.returncode == 0 and re.fullmatch(rb'magpie v\d+\.\d+\.\d+\+libraryscope\.1',
                                                         version.stdout.strip()), 'magpie-scoped-writer-unavailable')
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        key = secrets.token_hex(32)
        env['MAGPIE_WEB_KEY'] = key
        with subprocess.Popen([str(executable), 'web', '--library-scoped', '--addr', f'127.0.0.1:{port}'],
                              env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              creationflags=flags) as process:
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

                def request(method, suffix='', payload=None):
                    require(process.poll() is None, 'magpie-endpoint-exited')
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
                    try:
                        body = json.dumps(payload) if payload is not None else None
                        connection.request(method, f'/api/library/scoped{suffix}', body,
                                           {'Content-Type': 'application/json', 'Cookie': f'magpie_web_{port}={key}'})
                        reply = connection.getresponse()
                        require(reply.status == 200, 'magpie-scoped-library-request-failed')
                        response = reply.read(2_000_001)
                        require(len(response) <= 2_000_000, 'magpie-response-too-large')
                        return json.loads(response)
                    finally:
                        connection.close()

                capability = request('GET')
                require(isinstance(capability, dict) and type(capability.get('scopeVersion')) is int
                        and capability['scopeVersion'] == 1 and isinstance(capability.get('statePath'), str),
                        'magpie-scoped-writer-capability-mismatch')
                require(Path(capability['statePath']) == self.state, 'magpie-config-root-mismatch')
                yield lambda route, payload: request('POST', f'/{route}', payload)
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
        # Scoped startup and the capability probe perform no host reconciliation.
        with self.write_lock(), self.endpoint() as post, self.audit_write('skills/install', 'skill', skill.name, ('dsh',)) as capture:
            probe = post('skills/probe', {'source': str(skill.source)})
            candidates = probe['candidates']
            require(probe['kind'] == 'folder' and len(candidates) == 1, 'magpie-folder-probe-mismatch')
            candidate = candidates[0]
            require(candidate['name'] == skill.name and candidate['path'] == '' and not candidate.get('have')
                    and not candidate.get('as'), 'magpie-folder-probe-mismatch')
            require(self.read() == before, 'magpie-state-changed-during-registration')
            skill.verify()
            result = capture(post('skills/install', {'source': str(skill.source), 'paths': [''], 'agents': ['dsh']}))
            require(isinstance(result, dict) and result.get('installed') == [skill.name], 'magpie-install-not-acknowledged')
            require(self.selected(skill) == ('dsh',), 'magpie-dsh-only-registration-mismatch')

    def distribute(self, skill, agents):
        state = self.read()
        self.require_direct_delivery(state)
        before = self.selected(skill)
        require(before in (('dsh',), agents), 'magpie-selection-drift')
        with self.write_lock(), self.endpoint() as post, self.audit_write('skills/agents', 'skill', skill.name, agents) as capture:
            require(self.read() == state and self.selected(skill) == before, 'magpie-selection-drift')
            skill.verify()
            capture(post('skills/agents', {'name': skill.name, 'agents': list(agents)}))
            require(self.selected(skill) == agents, 'magpie-selection-mismatch')

    def set_mcp_agents(self, names, agents, on):
        route = 'servers/agents-some'
        with self.write_lock(), self.endpoint() as post, self.audit_write(route, 'mcp', None, agents) as capture:
            capture(post(route, {'names': list(names), 'agents': list(agents), 'on': on}))
            selected = {server['name']: set(server.get('agents') or ()) for server in self.read().get('mcp', [])}
            require(all(name in selected and all((agent in selected[name]) == on for agent in agents) for name in names),
                    'magpie-mcp-selection-mismatch')


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


def validate_audit_baseline(before):
    require(isinstance(before, dict) and set(before) == {
        'schema_version', 'receipt_kind', 'kind', 'name', 'intended_agents', 'limitations', 'fingerprints',
        'ok', 'status', 'unavailable_artifacts',
    } and type(before['schema_version']) is int and before['schema_version'] == 1
        and before['receipt_kind'] == 'magpie-write-audit' and before['ok'] is True
        and before['status'] == 'preflight-ready' and before['unavailable_artifacts'] == []
        and before['limitations'] == list(AUDIT_EXCLUSIONS), 'invalid-magpie-audit-baseline')
    artifacts = AUDIT_CONFIG_ARTIFACTS | ({f'{host}.skill' for host in SUPPORTED_AGENTS | {'library'}}
                                         if before['kind'] == 'skill' else set())
    require(isinstance(before['fingerprints'], dict) and set(before['fingerprints']) == artifacts,
            'invalid-magpie-audit-baseline')
    for fingerprint in before['fingerprints'].values():
        require(isinstance(fingerprint, dict) and set(fingerprint) == AUDIT_FIELDS
                and all(type(fingerprint[k]) is int and 0 <= fingerprint[k] < 10000
                        for k in ('present', 'missing', 'unknown')) and fingerprint['unknown'] == 0
                and all(isinstance(fingerprint[k], str) and re.fullmatch(r'[0-9a-f]{64}', fingerprint[k])
                        for k in ('sha256', 'inventory_sha256')), 'invalid-magpie-audit-baseline')
    require(before['fingerprints']['library.state']['present'] == 1, 'invalid-magpie-audit-baseline')


def unique_audit_keys(items):
    obj = dict(items)
    require(len(obj) == len(items), 'duplicate-magpie-audit-field')
    return obj


class AuditParser(argparse.ArgumentParser):
    def error(self, message):
        raise DeliveryError('invalid-magpie-audit-arguments')


def audit_cli(mode, argv):
    parser = AuditParser(prog=f'{Path(__file__).name} {mode}', description='Read-only local Magpie fingerprint audit.')
    if mode == 'audit-before':
        parser.add_argument('--kind', required=True, choices=('mcp', 'skill'))
        parser.add_argument('--name', help='One skill name; required only for --kind skill')
        parser.add_argument('--agents', required=True,
                            help='Exact comma-separated Magpie writer IDs; empty for none. Not write authority or '
                                 'impact isolation: antigravity files also serve agy if installed.')
    else:
        parser.epilog = ('stdin JSON: {"before": <audit-before output>, "result": '
                         '{"changed": [<host ID or null>], "problems": [{"agent": <host ID or empty string>}], '
                         '"backup_reported": <optional boolean>}}. Use result:null for missing action evidence.')
    try:
        args = parser.parse_args(argv)
        if mode == 'audit-before':
            agents = args.agents.split(',') if args.agents else []
            output = magpie_audit_before(MAGPIE_STATE, args.kind, args.name, agents)
        else:
            raw = sys.stdin.buffer.read(65_537)
            require(len(raw) <= 65_536, 'magpie-audit-input-too-large')
            request = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique_audit_keys)
            require(isinstance(request, dict) and set(request) == {'before', 'result'}, 'invalid-magpie-audit-input')
            before, result = request['before'], request['result']
            validate_audit_baseline(before)
            safe_projection = (result is None or (isinstance(result, dict)
                and set(result) <= {'changed', 'problems', 'backup_reported'}
                and type(result.get('backup_reported', False)) is bool
                and isinstance(result.get('changed'), list)
                and all(host is None or isinstance(host, str) and host in SUPPORTED_AGENTS for host in result['changed'])
                and isinstance(result.get('problems'), list)
                and all(isinstance(p, dict) and set(p) == {'agent'} and isinstance(p['agent'], str)
                        and (not p['agent'] or p['agent'] in SUPPORTED_AGENTS) for p in result['problems'])))
            output = magpie_audit_after(MAGPIE_STATE, before, result if safe_projection else None)
            if not safe_projection:
                output.update(status='input-invalid', reason='invalid-magpie-audit-projection')
    except (OSError, ValueError, TypeError, KeyError, RecursionError) as error:
        output = dict(schema_version=1, receipt_kind='magpie-write-audit', ok=False, status='input-invalid',
                      reason=str(error) if isinstance(error, DeliveryError) else 'invalid-magpie-audit-input')
    sys.stdout.buffer.write(json.dumps(output, ensure_ascii=True).encode('ascii') + b'\n')
    return 0 if output['ok'] else 1


def record_operation(run_directory, receipt, output, perform):
    try:
        require(run_directory.is_relative_to(EVIDENCE), 'invalid-run-directory')
        run = RunEvidence(run_directory)
        destination = run.output_path(receipt)
        require(destination.suffix == '.json', 'expected-json-receipt')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with run.output_path(destination).open('x', encoding='utf-8') as stream:
            try:
                perform()
            except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError,
                    http.client.HTTPException) as error:
                output.update(status='pending', reason=str(error) if isinstance(error, DeliveryError) else type(error).__name__)
            audits = output.get('magpie_write_audits')
            if audits:
                output['magpie_write_audit_status'] = ('observed-within-scope' if all(a['ok'] for a in audits)
                                                      else 'review-required')
            json.dump(output, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        output['receipt'] = str(destination)
    except (OSError, ValueError) as error:
        output.update(status='receipt-not-created', ok=False,
                      reason=str(error) if isinstance(error, DeliveryError) else type(error).__name__)
    sys.stdout.buffer.write(json.dumps(output, ensure_ascii=False).encode('utf-8') + b'\n')
    return 0 if output['ok'] else 1


def scoped_mcp_cli(argv):
    parser = argparse.ArgumentParser(prog=f'{Path(__file__).name} scoped-mcp',
                                     description='Set named Library MCP servers for explicitly authorized local agents.')
    parser.add_argument('--run-directory', required=True, type=Path)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--agents', required=True, help='Exact comma-separated Magpie agent IDs')
    parser.add_argument('--servers', required=True, help='Exact comma-separated Library MCP server names')
    change = parser.add_mutually_exclusive_group(required=True)
    change.add_argument('--enable', dest='enabled', action='store_true')
    change.add_argument('--disable', dest='enabled', action='store_false')
    args = parser.parse_args(argv)
    output = dict(schema_version=1, receipt_kind='magpie-mcp-delivery', ok=False,
                  enabled=args.enabled, magpie_write_audit_status='not-observed')

    def perform():
        agents, names = sorted(args.agents.split(',')), sorted(args.servers.split(','))
        require(len(set(agents)) == len(agents) and set(agents) <= SUPPORTED_AGENTS, 'unsupported-distribution-targets')
        require(len(set(names)) == len(names) and all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', name) for name in names),
                'invalid-magpie-mcp-server-names')
        magpie = Magpie()
        output.update(intended_agents=agents, servers=names, magpie_write_audits=magpie.write_audits)
        magpie.set_mcp_agents(names, agents, args.enabled)
        output.update(ok=True, status='applied')

    return record_operation(args.run_directory, args.receipt, output, perform)


def main():
    if sys.argv[1:2] in (['audit-before'], ['audit-after']):
        return audit_cli(sys.argv[1], sys.argv[2:])
    if sys.argv[1:2] == ['scoped-mcp']:
        return scoped_mcp_cli(sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__,
                                     epilog='Additional modes: scoped-mcp, audit-before, audit-after (see their --help).')
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
    output = {'schema_version': 1, 'receipt_kind': 'shared-skill-delivery', 'ok': False, 'phase': args.mode,
              'magpie_write_audit_status': 'not-observed'}

    def perform():
        magpie = Magpie()
        if args.mode != 'verify':
            output['magpie_write_audits'] = magpie.write_audits
        skill = GuardedSkill(args.name, args.transaction_manifest, args.preset, args.cwd,
                             args.model_invocable == 'yes', args.user_invocable == 'yes')
        require(args.mode == 'verify' or skill.new_install, 'new-guarded-install-required')
        agents = enabled_agents(args, magpie)
        output.update(name=skill.name, intended_agents=list(agents), preset=skill.preset, cwd=str(skill.cwd),
                      expected_model_invocable=skill.model_invocable, expected_user_invocable=skill.user_invocable,
                      transaction_id=skill.transaction, transaction_manifest=str(skill.manifest),
                      transaction_manifest_sha256=skill.manifest_sha256, guarded_operation=skill.operation)
        output.update(advance(args.mode, skill, agents, magpie, probe_dsh))

    return record_operation(args.run_directory, args.receipt, output, perform)


if __name__ == '__main__':
    raise SystemExit(main())
