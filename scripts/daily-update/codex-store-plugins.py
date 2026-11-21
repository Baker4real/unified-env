"""Verify enabled local Codex Store plugins; return one bounded JSON result, with no receipt writes."""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import shutil
import stat
import subprocess
import threading
import time
import tomllib


BUNDLED = 'openai-bundled'
PRIMARY = 'openai-primary-runtime'
PACKAGE_NAME = 'OpenAI.Codex'
PUBLISHER = '2p2nqsd0c76g0'
PACKAGE_FAMILY = f'{PACKAGE_NAME}_{PUBLISHER}'
PACKAGE_QUERY = """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
@{packages = @(Get-AppxPackage -Name OpenAI.Codex -PackageTypeFilter Main | ForEach-Object {
    @{name = $_.Name; family = $_.PackageFamilyName; full_name = $_.PackageFullName;
      version = $_.Version.ToString(); architecture = $_.Architecture.ToString();
      status = $_.Status.ToString(); signature_kind = $_.SignatureKind.ToString();
      development_mode = $_.IsDevelopmentMode; install_location = $_.InstallLocation}
})} | ConvertTo-Json -Depth 4 -Compress
"""

MAX_INPUT_BYTES = 256 * 1024
MAX_RESULT_BYTES = 16 * 1024
MAX_ROWS = 64
PACKAGE_TIMEOUT = 15
PLUGIN_TIMEOUT = 30
APPX_VERSION = re.compile(r'(?:0|[1-9][0-9]{0,4})(?:\.(?:0|[1-9][0-9]{0,4})){3}')
PLUGIN_NAME = re.compile(r'[a-z0-9][a-z0-9._-]{0,63}')
PLUGIN_VERSION = re.compile(r'[0-9]+(?:\.[0-9]+){1,3}(?:[-+][a-zA-Z0-9][a-zA-Z0-9.+-]*)?')
SYSTEM_ENV = frozenset('SystemRoot windir SystemDrive PATH PATHEXT ComSpec USERPROFILE HOME HOMEDRIVE HOMEPATH '
                       'LOCALAPPDATA APPDATA TEMP TMP ProgramData ProgramFiles ProgramFiles(x86) '
                       'ProgramW6432 CommonProgramFiles'.upper().split())
ERROR_CODES = frozenset({
    'invalid-arguments', 'invalid-expected-appx-version', 'appx-version-mismatch', 'package-query-unavailable',
    'registered-package-not-unique', 'registered-package-unhealthy', 'registered-package-changed',
    'invalid-local-path', 'nonordinary-path', 'local-io-failed', 'input-too-large',
    'unexpected-child-output', 'child-timed-out', 'child-failed', 'invalid-config', 'config-changed',
    'unexpected-marketplace-root', 'no-enabled-bundled-plugins', 'invalid-marketplace-manifest',
    'enabled-plugin-missing-from-marketplace', 'invalid-plugin-manifest', 'cache-version-mismatch',
    'invalid-cli-plugin-list', 'enabled-plugin-set-mismatch', 'result-too-large', 'invalid-result',
})


class Rejected(ValueError):
    """An observation failure with a fixed, safe error code."""


def appx_version(value):
    return (isinstance(value, str) and APPX_VERSION.fullmatch(value) is not None
            and all(int(part) <= 65535 for part in value.split('.')))


def plugin_name(value):
    return isinstance(value, str) and PLUGIN_NAME.fullmatch(value) is not None


def plugin_version(value):
    return isinstance(value, str) and len(value) <= 64 and PLUGIN_VERSION.fullmatch(value) is not None


def package_full_name(version):
    return f'{PACKAGE_NAME}_{version}_x64__{PUBLISHER}'


def local_path(value):
    if not isinstance(value, str) or len(value) > 1024 or any(ord(char) < 32 for char in value):
        raise Rejected('invalid-local-path')
    # Codex emits the Win32 extended-length prefix for ordinary local drives.
    if os.name == 'nt':
        value = value.removeprefix('\\\\?\\')
        if not re.match(r'^[A-Za-z]:[\\/]', value) or ':' in value[2:]:
            raise Rejected('invalid-local-path')
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts:
        raise Rejected('invalid-local-path')
    return path


def require_ordinary(path, *, directory=False):
    for ancestor in (*reversed(path.parents), path):
        info = ancestor.lstat()
        expected_kind = stat.S_ISDIR if directory or ancestor != path else stat.S_ISREG
        if (not expected_kind(info.st_mode)
                or getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
            raise Rejected('nonordinary-path')
    return path


def read_bytes(path):
    with require_ordinary(path).open('rb') as stream:
        data = stream.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise Rejected('input-too-large')
    return data


def unique_object(pairs):
    value = dict(pairs)
    if len(value) != len(pairs):
        raise ValueError('duplicate JSON key')
    return value


def parse_json(data, error_code):
    def reject_non_json_constant(_):
        raise ValueError('non-JSON constant')

    try:
        return json.loads(data.decode('utf-8-sig'), object_pairs_hook=unique_object,
                          parse_constant=reject_non_json_constant)
    except (ValueError, RecursionError):
        raise Rejected(error_code) from None


def child_json(argv, *, timeout, env, cwd=None):
    """Drain no more than the cap plus one byte, within a single child deadline."""
    deadline = time.monotonic() + timeout
    child = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL,
                             creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    output = queue.Queue(maxsize=1)

    def read_stdout():
        try:
            with child.stdout:
                output.put(child.stdout.read(MAX_INPUT_BYTES + 1))
        except OSError:
            output.put(None)

    threading.Thread(target=read_stdout, daemon=True).start()
    try:
        data = output.get(timeout=max(0, deadline - time.monotonic()))
        if data is None:
            raise Rejected('unexpected-child-output')
        if len(data) > MAX_INPUT_BYTES:
            raise Rejected('input-too-large')
        if child.wait(timeout=max(0, deadline - time.monotonic())) != 0:
            raise Rejected('child-failed')
    except (queue.Empty, subprocess.TimeoutExpired):
        raise Rejected('child-timed-out') from None
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=2)
    return parse_json(data, 'unexpected-child-output')


def registration(pwsh, env, expected):
    value = child_json([pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', PACKAGE_QUERY],
                       timeout=PACKAGE_TIMEOUT, env=env)
    rows = value.get('packages') if isinstance(value, dict) else None
    if not isinstance(rows, list) or len(rows) != 1:
        raise Rejected('registered-package-not-unique')
    row = rows[0]
    if (not isinstance(row, dict) or row.get('name') != PACKAGE_NAME or row.get('family') != PACKAGE_FAMILY
            or not appx_version(row.get('version')) or row.get('full_name') != package_full_name(row['version'])
            or row.get('architecture') != 'X64' or row.get('status') != 'Ok'
            or row.get('signature_kind') != 'Store' or row.get('development_mode') is not False):
        raise Rejected('registered-package-unhealthy')
    version = row['version']
    if expected is not None and version != expected:
        raise Rejected('appx-version-mismatch')
    root = local_path(row.get('install_location'))
    if root.name != row['full_name']:
        raise Rejected('registered-package-unhealthy')
    return version, require_ordinary(root, directory=True)


def configured_scope(raw, home, profile):
    try:
        config = tomllib.loads(raw.decode('utf-8-sig'))
    except (ValueError, RecursionError):
        raise Rejected('invalid-config') from None
    plugins = config.get('plugins', {})
    markets = config.get('marketplaces', {})
    if not isinstance(plugins, dict) or not isinstance(markets, dict):
        raise Rejected('invalid-config')
    enabled = {BUNDLED: set(), PRIMARY: set()}
    for key, value in plugins.items():
        name, _, market = key.rpartition('@')
        if market in enabled:
            if (not plugin_name(name) or not isinstance(value, dict)
                    or ('enabled' in value and type(value['enabled']) is not bool)):
                raise Rejected('invalid-config')
            if value.get('enabled') is True:
                enabled[market].add(name)
    if not enabled[BUNDLED]:
        raise Rejected('no-enabled-bundled-plugins')
    if any(len(names) > MAX_ROWS for names in enabled.values()):
        raise Rejected('input-too-large')

    primary_suffix = Path('codex-primary-runtime/plugins') / PRIMARY
    allowed = {
        BUNDLED: {home / '.tmp/bundled-marketplaces' / BUNDLED},
        PRIMARY: {profile / '.cache/codex-runtimes' / primary_suffix,
                  home.parent / 'codex-runtimes' / primary_suffix},
    }
    roots = {}
    for market, candidates in allowed.items():
        if market == PRIMARY and market not in markets and not enabled[market]:
            continue
        entry = markets.get(market)
        if not isinstance(entry, dict) or entry.get('source_type') != 'local':
            raise Rejected('unexpected-marketplace-root')
        root = local_path(entry.get('source'))
        if root not in candidates:
            raise Rejected('unexpected-marketplace-root')
        roots[market] = require_ordinary(root, directory=True)
    return enabled, roots


def marketplace_paths(root, market, names):
    value = parse_json(read_bytes(root / '.agents/plugins/marketplace.json'), 'invalid-marketplace-manifest')
    rows = value.get('plugins') if isinstance(value, dict) and value.get('name') == market else None
    if not isinstance(rows, list) or len(rows) > MAX_ROWS:
        raise Rejected('invalid-marketplace-manifest')
    paths = {}
    for row in rows:
        name = row.get('name') if isinstance(row, dict) else None
        if not plugin_name(name) or name in paths:
            raise Rejected('invalid-marketplace-manifest')
        paths[name] = None
        if name in names:
            source = row.get('source')
            if source != {'source': 'local', 'path': f'./plugins/{name}'}:
                raise Rejected('invalid-marketplace-manifest')
            paths[name] = root / 'plugins' / name
    if not names.issubset(paths):
        raise Rejected('enabled-plugin-missing-from-marketplace')
    return {name: paths[name] for name in names}


def manifest_version(root, name):
    value = parse_json(read_bytes(root / '.codex-plugin/plugin.json'), 'invalid-plugin-manifest')
    if not isinstance(value, dict) or value.get('name') != name or not plugin_version(value.get('version')):
        raise Rejected('invalid-plugin-manifest')
    return value['version']


def cli_versions(codex, market, root, paths, home, env):
    # Exact local market filters short-circuit remote listings. Ephemeral auth and a
    # minimal environment keep the probe independent of the active account.
    command = [str(codex), '--no-daemon', '-c', 'cli_auth_credentials_store=ephemeral', '--disable',
               'remote_plugin', 'plugin', 'list', '--marketplace', market, '--json']
    value = child_json(command, timeout=PLUGIN_TIMEOUT, env=dict(env, CODEX_HOME=str(home)), cwd=codex.parent)
    if (not isinstance(value, dict) or set(value) != {'installed', 'available'} or value['available'] != []
            or not isinstance(value['installed'], list) or len(value['installed']) > MAX_ROWS):
        raise Rejected('invalid-cli-plugin-list')
    versions = {}
    seen = set()
    for row in value['installed']:
        name = row.get('name') if isinstance(row, dict) else None
        if (not plugin_name(name) or name in seen or row.get('pluginId') != f'{name}@{market}'
                or row.get('marketplaceName') != market or row.get('installed') is not True
                or type(row.get('enabled')) is not bool):
            raise Rejected('invalid-cli-plugin-list')
        seen.add(name)
        if not row['enabled']:
            continue
        if name not in paths:
            raise Rejected('enabled-plugin-set-mismatch')
        source = row.get('source')
        marketplace = row.get('marketplaceSource')
        if (not plugin_version(row.get('version')) or not isinstance(source, dict)
                or source.get('source') != 'local' or local_path(source.get('path')) != paths[name]
                or not isinstance(marketplace, dict) or marketplace.get('sourceType') != 'local'
                or local_path(marketplace.get('source')) != root):
            raise Rejected('invalid-cli-plugin-list')
        versions[name] = row['version']
    if versions.keys() != paths.keys():
        raise Rejected('enabled-plugin-set-mismatch')
    return versions


def inspect_market(codex, market, root, names, home, env, package_paths):
    paths = marketplace_paths(root, market, names)
    installed = cli_versions(codex, market, root, paths, home, env)
    rows = []
    for name, version in sorted(installed.items()):
        materialized = manifest_version(paths[name], name)
        source = manifest_version(package_paths[name], name) if market == BUNDLED else materialized
        cache = manifest_version(home / 'plugins/cache' / market / name / version, name)
        if cache != version:
            raise Rejected('cache-version-mismatch')
        rows.append(dict(plugin_id=f'{name}@{market}', source_version=source, marketplace_version=materialized,
                         enabled_version=version, cache_version=cache))
    return rows


def adopted(row):
    return row['source_version'] == row['marketplace_version'] == row['enabled_version'] == row['cache_version']


def observed(expected):
    if expected is not None and not appx_version(expected):
        raise Rejected('invalid-expected-appx-version')
    env = {key: value for key, value in os.environ.items() if key.upper() in SYSTEM_ENV}
    pwsh = shutil.which('pwsh')
    if not pwsh or not Path(pwsh).is_absolute():
        raise Rejected('package-query-unavailable')
    version, install = registration(pwsh, env, expected)
    profile = Path.home()
    home = local_path(os.environ.get('CODEX_HOME') or str(profile / '.codex'))
    config_path = home / 'config.toml'
    config = read_bytes(config_path)
    enabled, roots = configured_scope(config, home, profile)
    codex = require_ordinary(install / 'app/resources/codex.exe')
    package_paths = marketplace_paths(codex.parent / 'plugins' / BUNDLED, BUNDLED, enabled[BUNDLED])
    rows = {market: inspect_market(codex, market, root, enabled[market], home, env, package_paths)
            for market, root in roots.items()}
    if read_bytes(config_path) != config:
        raise Rejected('config-changed')
    if registration(pwsh, env, expected) != (version, install):
        raise Rejected('registered-package-changed')
    bundled = rows[BUNDLED]
    primary = rows.get(PRIMARY, [])
    all_rows = bundled + primary
    adopted_count = sum(adopted(row) for row in all_rows)
    pending_count = len(all_rows) - adopted_count
    return dict(schema_version=1, ok=pending_count == 0,
                status='official-client-refresh-pending' if pending_count else 'verified',
                registered_package=package_full_name(version), appx_version=version, enabled_count=len(all_rows),
                adopted_count=adopted_count, pending_count=pending_count, primary_runtime_checked=PRIMARY in rows,
                bundled=bundled, primary_runtime=primary)


def encode_result(result):
    return json.dumps(result, ensure_ascii=True, separators=(',', ':'), allow_nan=False)


def validate_result(result, *, expected_appx_version=None):
    """Enforce the v1 schema, invariants and stdout budget before a caller can publish it."""
    if not isinstance(result, dict) or type(result.get('schema_version')) is not int or result['schema_version'] != 1:
        raise Rejected('invalid-result')
    if result.get('status') == 'rejected':
        code = result.get('error_code')
        if (set(result) != {'schema_version', 'ok', 'status', 'error_code'} or result['ok'] is not False
                or not isinstance(code, str) or code not in ERROR_CODES):
            raise Rejected('invalid-result')
    else:
        if set(result) != {'schema_version', 'ok', 'status', 'registered_package', 'appx_version',
                           'enabled_count', 'adopted_count', 'pending_count', 'primary_runtime_checked',
                           'bundled', 'primary_runtime'}:
            raise Rejected('invalid-result')
        version = result['appx_version']
        if (not appx_version(version) or result['registered_package'] != package_full_name(version)
                or (expected_appx_version is not None and version != expected_appx_version)
                or type(result['primary_runtime_checked']) is not bool or not result['bundled']
                or (result['primary_runtime'] and not result['primary_runtime_checked'])):
            raise Rejected('invalid-result')
        enabled_count = adopted_count = 0
        version_fields = ('source_version', 'marketplace_version', 'enabled_version', 'cache_version')
        for key, market in (('bundled', BUNDLED), ('primary_runtime', PRIMARY)):
            rows = result[key]
            if not isinstance(rows, list) or len(rows) > MAX_ROWS:
                raise Rejected('invalid-result')
            seen = set()
            for row in rows:
                if not isinstance(row, dict) or set(row) != {'plugin_id', *version_fields}:
                    raise Rejected('invalid-result')
                plugin_id = row['plugin_id']
                name, _, scope = plugin_id.partition('@') if isinstance(plugin_id, str) else ('', '', '')
                if (scope != market or not plugin_name(name) or plugin_id in seen
                        or not all(plugin_version(row[field]) for field in version_fields)
                        or row['cache_version'] != row['enabled_version']
                        or (market == PRIMARY and row['source_version'] != row['marketplace_version'])):
                    raise Rejected('invalid-result')
                seen.add(plugin_id)
                adopted_count += adopted(row)
            enabled_count += len(rows)
        pending_count = enabled_count - adopted_count
        counts = dict(enabled_count=enabled_count, adopted_count=adopted_count, pending_count=pending_count)
        if (any(type(result[key]) is not int or result[key] != value for key, value in counts.items())
                or result['ok'] is not (pending_count == 0)
                or result['status'] != ('official-client-refresh-pending' if pending_count else 'verified')):
            raise Rejected('invalid-result')
    if len(encode_result(result)) + 1 > MAX_RESULT_BYTES:
        raise Rejected('result-too-large')
    return result


def rejected(code):
    return validate_result(dict(schema_version=1, ok=False, status='rejected', error_code=code))


def verify(*, expected_appx_version=None):
    """Observe the live Store package and config. The optional version pins the AppX registration."""
    try:
        return validate_result(observed(expected_appx_version), expected_appx_version=expected_appx_version)
    except Rejected as error:
        return rejected(str(error))
    except (OSError, subprocess.TimeoutExpired):
        return rejected('local-io-failed')


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Rejected('invalid-arguments')


def main(argv=None):
    parser = JsonArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--expected-appx-version', help='Require this exact registered AppX version.')
    try:
        args = parser.parse_args(argv)
        result = verify(expected_appx_version=args.expected_appx_version)
    except Rejected as error:
        result = rejected(str(error))
    print(encode_result(result))
    return {'verified': 0, 'rejected': 1, 'official-client-refresh-pending': 2}[result['status']]


if __name__ == '__main__':
    raise SystemExit(main())
