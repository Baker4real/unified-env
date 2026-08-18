from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


PWSH = Path(r"D:\Codex\tools\PowerShell\7.6.5\pwsh.exe")
GUARD = Path(r"D:\Codex\.codex\hooks\serena-behavior-guard.ps1")
SERENA_HOOKS = Path(r"D:\Codex\tools\uv\bin\serena-hooks.exe")
SERENA_HOME = r"D:\Codex\.serena"
SESSION_ID_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z")
GROK_ACTIVATION_CONTEXT = (
    "Use the absolute workspace root from GROK_WORKSPACE_ROOT to call "
    "serena__activate_project, then call serena__get_current_config to verify "
    "the active project. Do not infer the project from cwd. Do not call "
    "serena__initial_instructions unless you need the full manual; it is optional "
    "and must not block other work."
)
CREATE_NO_WINDOW = 0x08000000
SERENA_TOOL_RE = re.compile(r"(?:^|__)serena(?:__|$)")


def _session_id(payload: object) -> str:
    if not isinstance(payload, dict):
        raise ValueError("Serena SessionStart payload 根非法。")
    ids = [key for key in payload if key in ("session_id", "sessionId")]
    if len(ids) != 1:
        raise ValueError("Serena SessionStart id 非法。")
    value = payload[ids[0]]
    if not isinstance(value, str) or not value or not SESSION_ID_RE.match(value):
        raise ValueError("Serena SessionStart id 路径语义非法。")
    return value


def _parse_json_object(raw: bytes) -> dict[str, object]:
    text = raw.decode("utf-8-sig")
    payload = json.loads(text)
    if not isinstance(payload, dict):
        raise ValueError("hook payload 根非法。")
    return payload


def _tool_name(payload: dict[str, object]) -> str:
    for key in ("toolName", "tool_name"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _bare_tool_name(name: str) -> str:
    cleaned = name.strip()
    if cleaned.startswith("mcp__serena__"):
        return cleaned[len("mcp__serena__") :]
    if cleaned.startswith("serena__"):
        return cleaned[len("serena__") :]
    return cleaned


def _is_serena_tool(payload: dict[str, object]) -> bool:
    return bool(SERENA_TOOL_RE.search(_tool_name(payload)))


def _tool_input(payload: dict[str, object]) -> object | None:
    for key in ("toolInput", "tool_input"):
        if key in payload:
            return payload.get(key)
    return None


def _permission_mode(payload: dict[str, object]) -> str:
    for key in ("permissionMode", "permission_mode"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "auto"


def _encode(payload: dict[str, object]) -> bytes:
    return (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def _vendor_auto_approve_payload(payload: dict[str, object]) -> dict[str, object] | None:
    if not _is_serena_tool(payload):
        return None
    rendered: dict[str, object] = {
        "session_id": _session_id(payload),
        "tool_name": f"mcp__serena__{_bare_tool_name(_tool_name(payload)) or 'unknown'}",
        "permission_mode": _permission_mode(payload),
    }
    tool_input = _tool_input(payload)
    if tool_input is not None:
        rendered["tool_input"] = tool_input
    return rendered


def _invoke_guard(mode: str, raw: bytes) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [
            str(PWSH),
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(GUARD),
            "-Mode",
            mode,
        ],
        input=raw,
        capture_output=True,
        check=False,
        creationflags=CREATE_NO_WINDOW,
    )


def _translate_permission_decision(stdout: bytes) -> bytes:
    if not stdout.strip():
        return b""
    payload = json.loads(stdout.decode("utf-8-sig"))
    if not isinstance(payload, dict):
        return stdout
    decision = payload.get("decision")
    if decision in ("deny", "allow"):
        reason = payload.get("reason")
        if isinstance(reason, str) and reason:
            rendered = {"decision": decision, "reason": reason}
        else:
            rendered = {"decision": decision}
        return (json.dumps(rendered, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    specific = payload.get("hookSpecificOutput")
    if not isinstance(specific, dict):
        return stdout
    permission = specific.get("permissionDecision")
    reason = specific.get("permissionDecisionReason")
    if permission in ("deny", "allow") and isinstance(reason, str) and reason:
        rendered = {"decision": permission, "reason": reason}
        return (json.dumps(rendered, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    return stdout


def _emit(payload: dict[str, object]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def run_activation(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    _session_id(payload)
    completed = _invoke_guard("Activation", raw)
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    _emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": GROK_ACTIVATION_CONTEXT,
            }
        }
    )
    return 0


def run_cleanup(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    if payload.get("subagentType"):
        return 0
    _session_id(payload)
    completed = _invoke_guard("Cleanup", raw)
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    return 0


def run_reminder(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    _session_id(payload)
    completed = _invoke_guard("Reminder", raw)
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    translated = _translate_permission_decision(completed.stdout)
    if translated:
        sys.stdout.buffer.write(translated)
        sys.stdout.flush()
    return 0


def run_auto_approve(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    vendor = _vendor_auto_approve_payload(payload)
    if vendor is None:
        return 0
    env = os.environ.copy()
    env["SERENA_HOME"] = SERENA_HOME
    completed = subprocess.run(
        [str(SERENA_HOOKS), "auto-approve", "--client=claude-code"],
        input=_encode(vendor),
        capture_output=True,
        check=False,
        creationflags=CREATE_NO_WINDOW,
        env=env,
    )
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    translated = _translate_permission_decision(completed.stdout)
    if translated:
        sys.stdout.buffer.write(translated)
        sys.stdout.flush()
    return 0


def _self_test() -> int:
    translated = _translate_permission_decision(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "Too many consecutive grep calls",
                }
            },
            separators=(",", ":"),
        ).encode("utf-8")
    )
    expected = {"decision": "deny", "reason": "Too many consecutive grep calls"}
    if json.loads(translated.decode("utf-8")) != expected:
        raise SystemExit("reminder translation failed")
    if _translate_permission_decision(b"") != b"":
        raise SystemExit("empty reminder translation failed")
    already = json.dumps({"decision": "deny", "reason": "x"}, separators=(",", ":")).encode("utf-8")
    if json.loads(_translate_permission_decision(already).decode("utf-8")) != {"decision": "deny", "reason": "x"}:
        raise SystemExit("passthrough decision translation failed")
    allowed = _translate_permission_decision(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "Auto-approved: Serena tool call while client is in auto mode.",
                }
            },
            separators=(",", ":"),
        ).encode("utf-8")
    )
    if json.loads(allowed.decode("utf-8")) != {
        "decision": "allow",
        "reason": "Auto-approved: Serena tool call while client is in auto mode.",
    }:
        raise SystemExit("allow translation failed")
    _session_id({"sessionId": "01a00838-ab78-77a0-a7be-99f2f0b0c277"})
    grok_payload = {
        "hookEventName": "pre_tool_use",
        "sessionId": "01a00838-ab78-77a0-a7be-99f2f0b0c277",
        "permissionMode": "auto",
        "toolName": "serena__initial_instructions",
        "toolInput": {},
    }
    mapped = _vendor_auto_approve_payload(grok_payload)
    if mapped != {
        "session_id": "01a00838-ab78-77a0-a7be-99f2f0b0c277",
        "tool_name": "mcp__serena__initial_instructions",
        "permission_mode": "auto",
        "tool_input": {},
    }:
        raise SystemExit("grok serena payload mapping failed")
    if _vendor_auto_approve_payload(
        {"sessionId": "01a00838-ab78-77a0-a7be-99f2f0b0c277", "toolName": "run_terminal_command"}
    ) is not None:
        raise SystemExit("non-Serena auto-approve must stay silent")
    if "initial_instructions first" in GROK_ACTIVATION_CONTEXT:
        raise SystemExit("activation must not require initial_instructions")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()
    if len(argv) != 2 or argv[1] not in {"Activation", "Cleanup", "Reminder", "AutoApprove"}:
        sys.stderr.write("grok host hook mode required\n")
        return 1
    raw = sys.stdin.buffer.read()
    try:
        if argv[1] == "Activation":
            return run_activation(raw)
        if argv[1] == "Cleanup":
            return run_cleanup(raw)
        if argv[1] == "AutoApprove":
            return run_auto_approve(raw)
        return run_reminder(raw)
    except Exception:
        # Match the Codex Serena guard: fail open so a protocol error never
        # blocks a Grok tool call or session teardown.
        return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
