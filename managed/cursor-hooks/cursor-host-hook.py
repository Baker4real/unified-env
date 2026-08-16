from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


PWSH = Path(r"D:\Codex\tools\PowerShell\7.6.4\pwsh.exe")
GUARD = Path(r"D:\Codex\.codex\hooks\serena-behavior-guard.ps1")
SERENA_HOOKS = Path(r"D:\Codex\tools\uv\bin\serena-hooks.exe")
GITHUB_CLI = Path(r"D:\Codex\.codex\hooks\codex-github-cli-guard.ps1")
SERENA_DASHBOARD = Path(r"D:\Codex\.codex\hooks\serena-dashboard-guard.ps1")
SERENA_HOME = r"D:\Codex\.serena"
SESSION_ID_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z")
CREATE_NO_WINDOW = 0x08000000
MODES = frozenset(
    {"Activation", "Cleanup", "Reminder", "AutoApprove", "GitHubCli", "SerenaDashboard"}
)
SERENA_TOOL_NAMES = frozenset(
    {
        "activate_project",
        "create_text_file",
        "delete_memory",
        "edit_memory",
        "execute_shell_command",
        "find_declaration",
        "find_file",
        "find_implementations",
        "find_referencing_symbols",
        "find_symbol",
        "get_current_config",
        "get_diagnostics_for_file",
        "get_symbols_overview",
        "initial_instructions",
        "insert_after_symbol",
        "insert_before_symbol",
        "list_dir",
        "list_memories",
        "onboarding",
        "open_dashboard",
        "read_file",
        "read_memory",
        "rename_memory",
        "rename_symbol",
        "replace_content",
        "replace_in_files",
        "replace_symbol_body",
        "safe_delete_symbol",
        "search_for_pattern",
        "write_memory",
    }
)
CURSOR_ACTIVATION_CONTEXT = (
    "If this workspace is a coding project, call Serena activate_project with the "
    "absolute workspace root, then call Serena get_current_config and confirm the "
    "active project matches that root. Do not infer the project from cwd. If you "
    "have not read the Serena Instructions Manual in this conversation, call "
    "Serena initial_instructions first."
)


def _parse_json_object(raw: bytes) -> dict[str, Any]:
    text = raw.decode("utf-8-sig")
    payload = json.loads(text)
    if not isinstance(payload, dict):
        raise ValueError("hook payload 根非法。")
    return payload


def _session_id(payload: dict[str, Any]) -> str:
    preferred = payload.get("session_id")
    if not isinstance(preferred, str) or not preferred:
        preferred = payload.get("sessionId")
    if not isinstance(preferred, str) or not preferred:
        preferred = payload.get("conversation_id")
    if not isinstance(preferred, str) or not preferred or not SESSION_ID_RE.match(preferred):
        raise ValueError("Cursor session id 非法。")
    return preferred


def _tool_name(payload: dict[str, Any]) -> str:
    value = payload.get("tool_name")
    if not isinstance(value, str) or not value.strip():
        value = payload.get("toolName")
    if not isinstance(value, str):
        return ""
    return value.strip()


def _tool_input(payload: dict[str, Any]) -> Any:
    value = payload.get("tool_input")
    if value is None:
        value = payload.get("toolInput")
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return value
        return parsed
    return value


def _bare_tool_name(name: str) -> str:
    lowered = name.strip().lower()
    if lowered.startswith("mcp:"):
        lowered = lowered[4:]
    if "__" in lowered:
        lowered = lowered.rsplit("__", 1)[-1]
    if "/" in lowered:
        lowered = lowered.rsplit("/", 1)[-1]
    return lowered


def _is_serena_tool(payload: dict[str, Any]) -> bool:
    name = _tool_name(payload)
    lowered = name.lower()
    if "serena" in lowered:
        return True
    command = payload.get("command")
    if isinstance(command, str) and "serena" in command.lower():
        return True
    return _bare_tool_name(name) in SERENA_TOOL_NAMES


def _vendor_reminder_payload(payload: dict[str, Any]) -> dict[str, Any]:
    name = _tool_name(payload)
    lowered = name.lower()
    tool_input = _tool_input(payload)
    if lowered == "read":
        mapped_name = "read_file"
        if isinstance(tool_input, dict) and "file_path" not in tool_input:
            path = tool_input.get("path")
            if isinstance(path, str) and path:
                tool_input = dict(tool_input)
                tool_input["file_path"] = path
    elif lowered == "grep":
        mapped_name = "grep"
    elif lowered in {"shell", "bash"}:
        mapped_name = "Bash"
    else:
        mapped_name = name or "unknown"
    rendered: dict[str, Any] = {
        "session_id": _session_id(payload),
        "tool_name": mapped_name,
    }
    if tool_input is not None:
        rendered["tool_input"] = tool_input
    return rendered


def _vendor_auto_approve_payload(payload: dict[str, Any]) -> dict[str, Any] | None:
    if not _is_serena_tool(payload):
        return None
    bare = _bare_tool_name(_tool_name(payload)) or "unknown"
    permission_mode = payload.get("permission_mode")
    if not isinstance(permission_mode, str) or not permission_mode.strip():
        permission_mode = payload.get("permissionMode")
    if not isinstance(permission_mode, str) or not permission_mode.strip():
        permission_mode = "auto"
    rendered: dict[str, Any] = {
        "session_id": _session_id(payload),
        "tool_name": f"mcp__serena__{bare}",
        "permission_mode": permission_mode.strip(),
    }
    tool_input = _tool_input(payload)
    if tool_input is not None:
        rendered["tool_input"] = tool_input
    return rendered


def _activation_context(payload: dict[str, Any]) -> str:
    roots = payload.get("workspace_roots")
    chosen: list[str] = []
    if isinstance(roots, list):
        for item in roots:
            if isinstance(item, str) and item.strip():
                chosen.append(item.strip())
    if chosen:
        root_text = "; ".join(chosen)
        return (
            f"Workspace root: {root_text}. {CURSOR_ACTIVATION_CONTEXT}"
        )
    return CURSOR_ACTIVATION_CONTEXT


def _cursor_permission_output(stdout: bytes) -> dict[str, Any] | None:
    if not stdout.strip():
        return None
    payload = json.loads(stdout.decode("utf-8-sig"))
    if not isinstance(payload, dict):
        return None
    decision = payload.get("decision")
    reason = payload.get("reason")
    if decision not in {"deny", "allow"}:
        specific = payload.get("hookSpecificOutput")
        if not isinstance(specific, dict):
            return None
        decision = specific.get("permissionDecision")
        reason = specific.get("permissionDecisionReason")
    if decision not in {"deny", "allow"}:
        return None
    rendered: dict[str, Any] = {"permission": decision}
    if isinstance(reason, str) and reason.strip():
        rendered["agent_message"] = reason
        rendered["user_message"] = reason
    return rendered


def _emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _emit_empty() -> None:
    _emit({})


def _encode(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


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


def _invoke_pwsh(script: Path) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [
            str(PWSH),
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
        ],
        capture_output=True,
        check=False,
        creationflags=CREATE_NO_WINDOW,
    )


def run_activation(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    vendor = {"session_id": _session_id(payload)}
    completed = _invoke_guard("Activation", _encode(vendor))
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    _emit(
        {
            "env": {"SERENA_HOME": SERENA_HOME},
            "additional_context": _activation_context(payload),
        }
    )
    return 0


def run_cleanup(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    if payload.get("subagent_type") or payload.get("subagentType"):
        _emit_empty()
        return 0
    vendor = {"session_id": _session_id(payload)}
    completed = _invoke_guard("Cleanup", _encode(vendor))
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    _emit_empty()
    return 0


def run_reminder(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    vendor = _vendor_reminder_payload(payload)
    completed = _invoke_guard("Reminder", _encode(vendor))
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    rendered = _cursor_permission_output(completed.stdout)
    _emit(rendered if rendered is not None else {})
    return 0


def run_auto_approve(raw: bytes) -> int:
    payload = _parse_json_object(raw)
    vendor = _vendor_auto_approve_payload(payload)
    if vendor is None:
        _emit_empty()
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
    rendered = _cursor_permission_output(completed.stdout)
    _emit(rendered if rendered is not None else {})
    return 0


def run_host_utility(script: Path) -> int:
    completed = _invoke_pwsh(script)
    if completed.stderr:
        sys.stderr.buffer.write(completed.stderr)
    _emit_empty()
    return 0


def _self_test() -> int:
    session = "11111111-2222-4333-8444-555555555555"
    if _session_id({"conversation_id": session, "tool_name": "Grep"}) != session:
        raise SystemExit("conversation_id session mapping failed")
    if _session_id({"session_id": session}) != session:
        raise SystemExit("session_id mapping failed")
    reminder = _vendor_reminder_payload(
        {
            "conversation_id": session,
            "tool_name": "Read",
            "tool_input": {"path": r"D:\Codex\projects\demo\app.py"},
        }
    )
    if reminder != {
        "session_id": session,
        "tool_name": "read_file",
        "tool_input": {
            "path": r"D:\Codex\projects\demo\app.py",
            "file_path": r"D:\Codex\projects\demo\app.py",
        },
    }:
        raise SystemExit("read reminder mapping failed")
    grep_payload = _vendor_reminder_payload(
        {"session_id": session, "tool_name": "Grep", "tool_input": {"pattern": "hook"}}
    )
    if grep_payload["tool_name"] != "grep":
        raise SystemExit("grep reminder mapping failed")
    shell_payload = _vendor_reminder_payload(
        {"session_id": session, "tool_name": "Shell", "tool_input": {"command": "rg -n hook"}}
    )
    if shell_payload["tool_name"] != "Bash" or shell_payload["tool_input"]["command"] != "rg -n hook":
        raise SystemExit("shell reminder mapping failed")
    deny = _cursor_permission_output(
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
    if deny != {
        "permission": "deny",
        "agent_message": "Too many consecutive grep calls",
        "user_message": "Too many consecutive grep calls",
    }:
        raise SystemExit("deny translation failed")
    if _cursor_permission_output(b"") is not None:
        raise SystemExit("empty permission translation failed")
    if _is_serena_tool({"tool_name": "Grep"}):
        raise SystemExit("grep must not look like Serena")
    if not _is_serena_tool({"tool_name": "activate_project"}):
        raise SystemExit("activate_project must look like Serena")
    if not _is_serena_tool({"tool_name": "get_symbols_overview", "command": r"D:\Codex\.codex\scripts\start-serena-mcp.cmd"}):
        raise SystemExit("command-scoped Serena detection failed")
    auto = _vendor_auto_approve_payload(
        {"conversation_id": session, "tool_name": "replace_symbol_body"}
    )
    if auto != {
        "session_id": session,
        "tool_name": "mcp__serena__replace_symbol_body",
        "permission_mode": "auto",
    }:
        raise SystemExit("auto-approve mapping failed")
    if _vendor_auto_approve_payload({"session_id": session, "tool_name": "browser_click"}) is not None:
        raise SystemExit("non-Serena auto-approve must stay silent")
    if "activate_project" not in _activation_context({"workspace_roots": [r"D:\Codex\projects\demo"]}):
        raise SystemExit("activation context missing tool name")
    if r"D:\Codex\projects\demo" not in _activation_context({"workspace_roots": [r"D:\Codex\projects\demo"]}):
        raise SystemExit("activation context missing workspace root")
    allow = _cursor_permission_output(
        json.dumps({"decision": "allow", "reason": "Auto-approved: Serena tool call while client is in auto mode."}).encode("utf-8")
    )
    if allow != {
        "permission": "allow",
        "agent_message": "Auto-approved: Serena tool call while client is in auto mode.",
        "user_message": "Auto-approved: Serena tool call while client is in auto mode.",
    }:
        raise SystemExit("allow translation failed")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()
    if len(argv) != 2 or argv[1] not in MODES:
        sys.stderr.write("cursor host hook mode required\n")
        return 1
    mode = argv[1]
    if mode == "GitHubCli":
        try:
            return run_host_utility(GITHUB_CLI)
        except Exception:
            _emit_empty()
            return 0
    if mode == "SerenaDashboard":
        try:
            return run_host_utility(SERENA_DASHBOARD)
        except Exception:
            _emit_empty()
            return 0
    raw = sys.stdin.buffer.read()
    try:
        if mode == "Activation":
            return run_activation(raw)
        if mode == "Cleanup":
            return run_cleanup(raw)
        if mode == "AutoApprove":
            return run_auto_approve(raw)
        return run_reminder(raw)
    except Exception:
        # Match Codex/Grok Serena guards: protocol errors fail open.
        _emit_empty()
        return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
