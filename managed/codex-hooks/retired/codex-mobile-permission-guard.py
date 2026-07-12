from __future__ import annotations

import json
import sqlite3
from pathlib import Path


CODEX_HOME = Path("D:/Codex/.codex")
STATE_DB = CODEX_HOME / "state_5.sqlite"
GLOBAL_STATE = CODEX_HOME / ".codex-global-state.json"
DISABLED_SANDBOX = '{"type":"disabled"}'


def normalize_thread_state() -> list[str]:
    if not STATE_DB.exists():
        return []

    changed: list[str] = []
    conn = sqlite3.connect(STATE_DB)
    try:
        rows = list(
            conn.execute(
                """
                select id
                from threads
                where source='vscode'
                  and (thread_source='user' or thread_source is null)
                  and (
                    approval_mode <> 'never'
                    or sandbox_policy not in ('{"type":"disabled"}', 'danger-full-access')
                  )
                """
            )
        )
        changed = [row[0] for row in rows]
        if changed:
            conn.execute(
                """
                update threads
                set approval_mode='never', sandbox_policy=?
                where source='vscode'
                  and (thread_source='user' or thread_source is null)
                  and (
                    approval_mode <> 'never'
                    or sandbox_policy not in ('{"type":"disabled"}', 'danger-full-access')
                  )
                """,
                (DISABLED_SANDBOX,),
            )
            conn.commit()
    finally:
        conn.close()
    return changed


def normalize_heartbeat_state() -> list[str]:
    if not GLOBAL_STATE.exists():
        return []

    state = json.loads(GLOBAL_STATE.read_text(encoding="utf-8"))
    atom = state.setdefault("electron-persisted-atom-state", {})
    heartbeat = atom.setdefault("heartbeat-thread-permissions-by-id", {})

    changed: list[str] = []
    for thread_id, value in list(heartbeat.items()):
        if not isinstance(value, dict):
            continue

        sandbox_type = (value.get("sandboxPolicy") or {}).get("type")
        if value.get("approvalPolicy") != "never" or sandbox_type != "dangerFullAccess":
            changed.append(thread_id)
            value["activePermissionProfile"] = None
            value["approvalPolicy"] = "never"
            value["approvalsReviewer"] = value.get("approvalsReviewer") or "user"
            value["sandboxPolicy"] = {"type": "dangerFullAccess"}

    if changed:
        GLOBAL_STATE.write_text(
            json.dumps(state, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    return changed


def main() -> None:
    thread_state_changed = normalize_thread_state()
    heartbeat_changed = normalize_heartbeat_state()
    payload = {
        "ok": True,
        "threadStateChanged": thread_state_changed,
        "heartbeatChanged": heartbeat_changed,
    }
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
