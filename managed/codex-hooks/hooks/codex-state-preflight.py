from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import time
import types
import uuid


PRODUCTION_CODEX_HOME = Path(r"D:\Codex\.codex")
PRODUCTION_HEALTH_ROOT = Path(r"D:\agents\run-evidence\codex-hook-health")
FIXTURE_PARENT = Path(r"D:\agents\projects\统一环境\reports\codex-state-preflight-test")
FIXTURE_MARKER = ".codex-state-preflight-fixture"
FIXTURE_MARKER_VALUE = "codex-state-preflight-test-v1\n"
EXPECTED_STATE_CORE_SHA256 = "51076559bcaa7ca573b4c81b8af5856d83db654aebce8932bc05bf06cff521e9"
FILE_ATTRIBUTE_REPARSE_POINT = 0x0400
FORBIDDEN_ARGUMENT = re.compile(r"(?i)(?:https?://|--check-(?:network|auth)\b|--(?:url|proxy)\b)")


class PreflightError(RuntimeError):
    pass


def _is_descendant(path: Path, parent: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(parent.resolve(strict=True))
    except (FileNotFoundError, OSError, ValueError):
        return False
    return True


def _fixture_home(root: Path) -> tuple[Path, Path]:
    if not _is_descendant(root, FIXTURE_PARENT) or root.parent != FIXTURE_PARENT:
        raise PreflightError("fixture capability is outside the fixed test root")
    resolved_root = root.resolve(strict=True)
    if str(resolved_root).casefold() != str(root).casefold():
        raise PreflightError("fixture capability root is redirected")
    marker = root / FIXTURE_MARKER
    try:
        if marker.read_text(encoding="utf-8") != FIXTURE_MARKER_VALUE:
            raise PreflightError("fixture capability marker is invalid")
    except (OSError, UnicodeError) as exc:
        raise PreflightError("fixture capability marker is unavailable") from exc
    codex_home = root / "codex-home"
    if (
        not codex_home.is_dir()
        or str(codex_home.resolve(strict=True)).casefold() != str(codex_home).casefold()
    ):
        raise PreflightError("fixture Codex home is unavailable")
    health_root = root / "health"
    if health_root.exists() and (
        not health_root.is_dir()
        or str(health_root.resolve(strict=True)).casefold() != str(health_root).casefold()
    ):
        raise PreflightError("fixture health root is redirected")
    return codex_home, health_root


def _load_state_core():
    source = Path(__file__).with_name("codex-state-policy-guard.py")
    try:
        metadata = source.lstat()
        if int(getattr(metadata, "st_file_attributes", 0)) & FILE_ATTRIBUTE_REPARSE_POINT:
            raise PreflightError("state core source is redirected")
        payload = source.read_bytes()
    except OSError as exc:
        raise PreflightError("state core source is unavailable") from exc
    if hashlib.sha256(payload).hexdigest() != EXPECTED_STATE_CORE_SHA256:
        raise PreflightError("state core source integrity failed")
    module = types.ModuleType("codex_state_preflight_core")
    module.__file__ = str(source)
    sys.modules[module.__name__] = module
    try:
        code = compile(payload, str(source), "exec")
        exec(code, module.__dict__)
    except BaseException as exc:
        raise PreflightError("state core failed to load") from exc
    return module


def _build_hot_path_approved_map(core, global_path: Path) -> dict[str, object]:
    try:
        state = core._strict_json_loads(global_path.read_bytes())
        inventory = core.build_path_inventory(
            state,
            core.PROJECTLESS_SOURCE_ROOT,
            core.CANONICAL_CANDIDATE_ROOT,
        )
    except Exception as exc:
        raise PreflightError("state path inventory failed") from exc
    inventory_maps = inventory.get("maps")
    mappings: dict[str, dict[str, str]] = {}
    if isinstance(inventory_maps, dict):
        for map_name, entries in inventory_maps.items():
            if not isinstance(map_name, str) or not isinstance(entries, dict):
                continue
            selected: dict[str, str] = {}
            for identity, entry in entries.items():
                if not isinstance(identity, str) or not isinstance(entry, dict):
                    continue
                candidate = entry.get("candidate")
                if entry.get("safe") is True and isinstance(candidate, str):
                    selected[identity] = candidate
            if selected:
                mappings[map_name] = selected
    return {
        "inventoryGeneration": inventory.get("inventoryGeneration"),
        "stateSha256": inventory.get("stateSha256"),
        "mappingSha256": inventory.get("mappingSha256"),
        "mappings": mappings,
    }


def _run_active_sqlite_preflight(
    core,
    codex_home: Path,
    health_root: Path,
    *,
    check_only: bool,
    write_health: bool,
) -> dict[str, object]:
    started = datetime.now(timezone.utc)
    started_clock = time.monotonic()
    global_result: dict[str, object] = {"status": "not-run", "driftCount": 0}
    thread_result: dict[str, object] = {"status": "not-run", "driftCount": 0}
    errors: list[str] = []
    global_lease = None
    try:
        permission_policy = core.resolve_permission_policy(codex_home)
        with core.WindowsNamedMutex():
            global_path = codex_home / ".codex-global-state.json"
            if check_only:
                path_mode = "inventory"
                approved_map = None
            else:
                path_mode = "repair-all-approved"
                approved_map = _build_hot_path_approved_map(core, global_path)
            global_result = core.update_global_state(
                global_path,
                codex_home / "backups_state" / "codex-state-policy",
                permission_policy=permission_policy,
                path_mode=path_mode,
                approved_map=approved_map,
                check_only=check_only,
            )
            expected_identity_value = global_result.get("afterIdentity")
            if (
                isinstance(expected_identity_value, list)
                and len(expected_identity_value) == 2
                and all(isinstance(value, int) for value in expected_identity_value)
            ):
                expected_identity = (
                    int(expected_identity_value[0]),
                    int(expected_identity_value[1]),
                )
            else:
                expected_identity = core._file_handle_identity(global_path)
            expected_hash = global_result.get("afterSha256")
            if not isinstance(expected_hash, str):
                expected_hash = core._sha256(global_path.read_bytes())
            if expected_identity is None:
                raise PreflightError("global state return identity is unavailable")
            global_lease = core.StateTargetLease(
                global_path,
                expected_identity=expected_identity,
                expected_hash=expected_hash,
            )
            global_lease.__enter__()
            global_lease.assert_unchanged()
            thread_result = core.update_thread_state(
                codex_home / "state_5.sqlite",
                permission_policy=permission_policy,
                check_only=True,
                snapshot_root=codex_home / "tmp" / "codex-state-policy-check",
            )
            core._assert_permission_policy_fingerprint(permission_policy)
            global_lease.assert_unchanged()
        ok = True
    except Exception as exc:
        ok = False
        errors.append(core._safe_error(exc))
    global_drift = int(global_result.get("driftCount", 0))
    thread_drift = int(thread_result.get("driftCount", 0))
    drift_count = global_drift + thread_drift
    changed = bool(global_result.get("changed"))
    def build_payload() -> dict[str, object]:
        return {
            "ok": ok,
            "changed": changed,
            "converged": ok and drift_count == 0,
            "driftCount": drift_count,
            "globalState": {
                "status": global_result.get("status"),
                "changedCount": int(global_result.get("changedCount", 0)),
                "driftCount": global_drift,
            },
            "threadState": {
                "status": thread_result.get("status"),
                "changedCount": 0,
                "driftCount": thread_drift,
                "maintenance": "cold-required" if thread_drift else "none",
            },
            "pathInventory": core._redact_path_inventory(global_result.get("pathInventory")),
            "errors": errors,
        }

    def mark_failure(message: str) -> None:
        nonlocal ok
        ok = False
        if message not in errors:
            errors.append(message)

    try:
        if global_lease is not None:
            global_lease.assert_unchanged()
    except Exception:
        mark_failure("global state changed before preflight return")
    try:
        if write_health:
            completed = datetime.now(timezone.utc)
            projected = _project(build_payload())
            try:
                core._write_health(
                    health_root / "codex-state-preflight.json",
                    {
                        "hookId": "codex-state-preflight",
                        "runId": uuid.uuid4().hex,
                        "startedAtUtc": started.isoformat(),
                        "completedAtUtc": completed.isoformat(),
                        "durationMs": int((time.monotonic() - started_clock) * 1000),
                        "ok": ok,
                        "changed": changed,
                        "repairRequired": bool(projected.get("repairRequired")),
                        "reviewRequired": bool(projected.get("reviewRequired")),
                        "errors": errors,
                    },
                )
            except Exception:
                mark_failure("state preflight health write failed")
    finally:
        if global_lease is not None:
            global_lease.close()
    return build_payload()


def _run_state_preflight(
    core,
    codex_home: Path,
    health_root: Path,
    *,
    check_only: bool,
    write_health: bool,
) -> dict[str, object]:
    snapshot = core._capture_sqlite_source(codex_home / "state_5.sqlite")
    if snapshot.identities[2] is not None:
        return _run_active_sqlite_preflight(
            core,
            codex_home,
            health_root,
            check_only=check_only,
            write_health=write_health,
        )
    buffer = io.StringIO()
    global_path = codex_home / ".codex-global-state.json"
    if check_only or not all(
        hasattr(core, name)
        for name in ("_strict_json_loads", "build_path_inventory", "PROJECTLESS_SOURCE_ROOT", "CANONICAL_CANDIDATE_ROOT")
    ):
        path_mode = "inventory"
        approved_map = None
    else:
        path_mode = "repair-all-approved"
        approved_map = _build_hot_path_approved_map(core, global_path)
    return core.run_policy(
        codex_home,
        check_only=check_only,
        health_root=health_root,
        output=buffer,
        write_health=write_health,
        path_mode=path_mode,
        approved_map=approved_map,
    )


def _project(core_payload: dict[str, object]) -> dict[str, object]:
    drift_count = int(core_payload.get("driftCount", 0))
    ok = core_payload.get("ok") is True
    converged = core_payload.get("converged") is True
    errors = core_payload.get("errors")
    error_values = errors if isinstance(errors, list) else []
    path_inventory = core_payload.get("pathInventory")
    path_entries = []
    if isinstance(path_inventory, dict):
        raw_entries = path_inventory.get("entries")
        if isinstance(raw_entries, list):
            path_entries = [entry for entry in raw_entries if isinstance(entry, dict)]
    has_repairable_path = any(entry.get("safe") is True for entry in path_entries)
    thread_state = core_payload.get("threadState")
    thread_repair_required = (
        isinstance(thread_state, dict)
        and int(thread_state.get("driftCount", 0)) > 0
    )
    repair_required = (
        not ok
        or has_repairable_path
        or thread_repair_required
        or "repair-required" in error_values
    )
    global_state = core_payload.get("globalState")
    review_required = ok and drift_count > 0 and not repair_required
    return {
        "ok": ok,
        "converged": converged,
        "driftCount": drift_count,
        "domains": {
            "globalState": global_state if isinstance(global_state, dict) else {"status": "unavailable"},
            "threadState": thread_state if isinstance(thread_state, dict) else {"status": "unavailable"},
            "paths": path_inventory if isinstance(path_inventory, dict) else {"status": "not-applicable"},
        },
        "repairRequired": repair_required,
        "reviewRequired": review_required,
    }


def _emit_failure(message: str, *, json_mode: bool) -> int:
    payload = {
        "ok": False,
        "converged": False,
        "driftCount": 0,
        "domains": {
            "globalState": {"status": "not-run"},
            "threadState": {"status": "not-run"},
            "paths": {"status": "not-run"},
        },
        "repairRequired": True,
    }
    rendered = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    if json_mode:
        sys.stdout.write(rendered + "\n")
    else:
        sys.stderr.write(json.dumps({"ok": False, "error": message}, separators=(",", ":")) + "\n")
    return 1


def main(argv: list[str] | None = None) -> int:
    values = list(sys.argv[1:] if argv is None else argv)
    json_mode = "--json" in values
    try:
        if any(FORBIDDEN_ARGUMENT.search(value) for value in values):
            raise PreflightError("forbidden preflight capability")
        parser = argparse.ArgumentParser(add_help=False, exit_on_error=False)
        parser.add_argument("--check-only", action="store_true")
        parser.add_argument("--json", action="store_true")
        parser.add_argument("--fixture-root")
        args, unknown = parser.parse_known_args(values)
        if unknown:
            raise PreflightError("unsupported preflight argument")
        if args.fixture_root is not None:
            if not args.fixture_root:
                raise PreflightError("fixture capability is empty")
            if not args.check_only:
                raise PreflightError("fixture capability is check-only")
            codex_home, health_root = _fixture_home(Path(args.fixture_root))
        else:
            codex_home = PRODUCTION_CODEX_HOME
            health_root = PRODUCTION_HEALTH_ROOT
        core = _load_state_core()
        core_payload = _run_state_preflight(
            core,
            codex_home,
            check_only=bool(args.check_only),
            health_root=health_root,
            write_health=not bool(args.check_only),
        )
        projected = _project(core_payload)
        if args.json:
            sys.stdout.write(json.dumps(projected, ensure_ascii=False, separators=(",", ":")) + "\n")
        elif core_payload.get("ok") is not True:
            sys.stderr.write('{"ok":false,"error":"state preflight failed"}\n')
        return 0 if core_payload.get("ok") is True else 1
    except Exception:
        return _emit_failure("state preflight unavailable", json_mode=json_mode)


if __name__ == "__main__":
    raise SystemExit(main())
