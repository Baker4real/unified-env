#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import time
import uuid
from pathlib import Path

RESET_TABLE = "device_algorithm_combination_miner_benchmark_reset"


def d_path(value: str) -> Path:
    path = Path(value).expanduser().resolve(strict=False)
    if not path.is_absolute() or path.drive.upper() != "D:":
        raise ValueError("paths must resolve to D:")
    return path


def existing_db_path(value: str) -> Path:
    raw = Path(value)
    if not raw.is_absolute():
        raise ValueError("database path must be absolute")
    return raw.expanduser().resolve(strict=False)


def ro(db: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True)


def plan(db_path: str, device_id: int, combination_id: int, miner_id: int) -> dict:
    db = existing_db_path(db_path)
    con = ro(db)
    try:
        tables = {row[0] for row in con.execute("select name from sqlite_master where type='table'")}
        required = {"device", "miner", "algorithm_combination_element", "coin_algorithm", "coin", "algorithm", "reading", RESET_TABLE}
        missing = sorted(required - tables)
        if missing:
            raise ValueError("missing schema tables: " + ",".join(missing))
        if not con.execute("select 1 from device where id=?", (device_id,)).fetchone():
            raise ValueError("device not found")
        if not con.execute("select 1 from miner where id=?", (miner_id,)).fetchone():
            raise ValueError("miner not found")
        if not con.execute("select 1 from algorithm_combination_element where algorithm_combination_id=?", (combination_id,)).fetchone():
            raise ValueError("algorithm combination not found")
        reading = con.execute("select max(id) from reading").fetchone()[0]
        if reading is None:
            raise ValueError("no current reading")
        duplicate = con.execute(f"select 1 from {RESET_TABLE} where device_id=? and algorithm_combination_id=? and miner_id=?", (device_id, combination_id, miner_id)).fetchone() is not None
        return {"deviceId": device_id, "combinationId": combination_id, "minerId": miner_id, "readingId": reading, "duplicate": duplicate}
    finally:
        con.close()


def request(db_path: str, device_id: int, combination_id: int, miner_id: int, backup_dir: str, approve: bool) -> dict:
    if not approve:
        raise ValueError("request requires explicit --approve")
    current = plan(db_path, device_id, combination_id, miner_id)
    if current["duplicate"]:
        raise ValueError("benchmark reset request already exists")
    db = existing_db_path(db_path)
    backup = d_path(backup_dir)
    backup.mkdir(parents=True, exist_ok=True)
    # 每次请求一份新备份：同一目录里的上一份备份是那次写入前的唯一回滚点，不能被覆盖。
    backup_db = backup / f"kryptex-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{uuid.uuid4().hex[:8]}.db"
    if backup_db.exists():
        raise ValueError("backup file already exists")
    src = ro(db)
    try:
        dst = sqlite3.connect(backup_db)
        try:
            src.backup(dst)
            if dst.execute("pragma integrity_check").fetchone()[0] != "ok":
                raise ValueError("backup integrity_check failed")
        finally:
            dst.close()
    finally:
        src.close()
    con = sqlite3.connect(db, timeout=10)
    try:
        con.execute("begin immediate")
        if con.execute(f"select 1 from {RESET_TABLE} where device_id=? and algorithm_combination_id=? and miner_id=?", (device_id, combination_id, miner_id)).fetchone():
            raise ValueError("benchmark reset request already exists")
        cur = con.execute(f"insert into {RESET_TABLE}(device_id,algorithm_combination_id,miner_id,reading_id) values(?,?,?,?)", (device_id, combination_id, miner_id, current["readingId"]))
        request_id = cur.lastrowid
        stored = con.execute(f"select reading_id from {RESET_TABLE} where id=?", (request_id,)).fetchone()
        if not stored or stored[0] != current["readingId"]:
            raise ValueError("request readback mismatch")
        con.commit()
        return {"requested": True, "id": request_id, "readingId": current["readingId"], "backup": str(backup_db)}
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


def wait(db_path: str, device_id: int, coin: str, since_ms: int, timeout_seconds: float, poll_seconds: float) -> dict:
    deadline = time.monotonic() + timeout_seconds
    while True:
        con = ro(existing_db_path(db_path))
        try:
            row = con.execute("""select max(pdr.hashrate),max(pdr.shares_accepted),max(pdr.shares_accepted_total),max(r.timestamp)
                from process_device_reading pdr join process_device pd on pd.id=pdr.process_device_id
                join reading r on r.id=pdr.reading_id join coin_algorithm ca on ca.id=pdr.coin_algorithm_id
                join coin c on c.id=ca.coin_id where pd.device_id=? and c.name=? and r.timestamp>=?""", (device_id, coin, since_ms)).fetchone()
        finally:
            con.close()
        if row and row[0] is not None and row[0] > 0:
            return {"coin": coin, "hashrate": row[0], "accepted": row[1], "acceptedTotal": row[2], "latest": row[3]}
        if time.monotonic() >= deadline:
            raise TimeoutError("no real non-zero hashrate reading before deadline")
        time.sleep(poll_seconds)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Guarded Kryptex benchmark reset requests")
    sub = parser.add_subparsers(dest="command", required=True)
    def common(p):
        p.add_argument("--db", required=True)
        p.add_argument("--device-id", type=int, default=1)
    p = sub.add_parser("plan")
    common(p); p.add_argument("--combination-id", type=int, required=True); p.add_argument("--miner-id", type=int, required=True)
    p = sub.add_parser("request")
    common(p); p.add_argument("--combination-id", type=int, required=True); p.add_argument("--miner-id", type=int, required=True); p.add_argument("--backup-dir", required=True); p.add_argument("--approve", action="store_true")
    p = sub.add_parser("wait")
    common(p); p.add_argument("--coin", required=True); p.add_argument("--since-ms", type=int, required=True); p.add_argument("--timeout-seconds", type=float, default=240); p.add_argument("--poll-seconds", type=float, default=5)
    args = parser.parse_args(argv)
    try:
        if args.command == "plan":
            result = plan(args.db, args.device_id, args.combination_id, args.miner_id)
        elif args.command == "request":
            result = request(args.db, args.device_id, args.combination_id, args.miner_id, args.backup_dir, args.approve)
        else:
            result = wait(args.db, args.device_id, args.coin, args.since_ms, args.timeout_seconds, args.poll_seconds)
    except (OSError, ValueError, TimeoutError, sqlite3.Error) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
