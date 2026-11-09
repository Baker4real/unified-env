#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sqlite3
import unittest
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location("kryptex_benchmark_reset", Path(__file__).with_name("Request-KryptexBenchmarkReset.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

TEST_ROOT = Path(r"D:\Codex\.codex\tmp\kryptex-benchmark-reset-tests")
SCHEMA = """
create table device(id integer primary key,name text);
create table miner(id integer primary key,name text);
create table algorithm(id integer primary key,name text);
create table coin(id integer primary key,name text);
create table coin_algorithm(id integer primary key,coin_id integer,algorithm_id integer);
create table algorithm_combination_element(id integer primary key,algorithm_combination_id integer,coin_algorithm_id integer);
create table reading(id integer primary key,timestamp integer,computer_id integer);
create table device_algorithm_combination_miner_benchmark_reset(id integer primary key autoincrement,device_id integer,algorithm_combination_id integer,miner_id integer,reading_id integer);
create table process_device(id integer primary key,device_id integer);
create table process_device_reading(id integer primary key,reading_id integer,process_device_id integer,coin_algorithm_id integer,hashrate real,shares_accepted integer,shares_accepted_total integer);
"""


class BenchmarkResetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = TEST_ROOT / uuid.uuid4().hex
        self.root.mkdir(parents=True)
        self.db = self.root / "kryptex.db"
        con = sqlite3.connect(self.db)
        con.executescript(SCHEMA)
        con.execute("insert into device values(1,'fixture-cpu')")
        con.execute("insert into miner values(3,'xmrig')")
        con.execute("insert into algorithm values(1,'randomx')")
        con.execute("insert into coin values(1,'xtm')")
        con.execute("insert into coin_algorithm values(15,1,1)")
        con.execute("insert into algorithm_combination_element values(1,15,15)")
        con.execute("insert into algorithm_combination_element values(2,16,15)")
        con.execute("insert into reading values(100,2000000,1)")
        con.execute("insert into process_device values(1,1)")
        con.commit(); con.close()

    def test_plan_is_read_only_and_validates_combination(self) -> None:
        before = self.db.read_bytes()
        result = tool.plan(str(self.db), 1, 15, 3)
        self.assertEqual(100, result["readingId"])
        self.assertEqual(before, self.db.read_bytes())
        with self.assertRaises(ValueError):
            tool.plan(str(self.db), 1, 99, 3)

    def test_request_requires_approval_then_backs_up_and_inserts_once(self) -> None:
        with self.assertRaises(ValueError):
            tool.request(str(self.db), 1, 15, 3, str(self.root / "backup"), False)
        result = tool.request(str(self.db), 1, 15, 3, str(self.root / "backup"), True)
        self.assertTrue(result["requested"])
        self.assertTrue(Path(result["backup"]).is_file())
        with self.assertRaises(ValueError):
            tool.request(str(self.db), 1, 15, 3, str(self.root / "backup2"), True)
        con = sqlite3.connect(self.db)
        self.assertEqual(1, con.execute("select count(*) from device_algorithm_combination_miner_benchmark_reset").fetchone()[0])
        con.close()

    def test_second_request_keeps_the_first_backup(self) -> None:
        backup_dir = str(self.root / "backup")
        first = tool.request(str(self.db), 1, 15, 3, backup_dir, True)
        first_bytes = Path(first["backup"]).read_bytes()
        second = tool.request(str(self.db), 1, 16, 3, backup_dir, True)
        self.assertNotEqual(first["backup"], second["backup"])
        self.assertEqual(first_bytes, Path(first["backup"]).read_bytes())
        con = sqlite3.connect(first["backup"])
        self.assertEqual(0, con.execute("select count(*) from device_algorithm_combination_miner_benchmark_reset").fetchone()[0])
        con.close()

    def test_wait_requires_real_nonzero_reading(self) -> None:
        with self.assertRaises(TimeoutError):
            tool.wait(str(self.db), 1, "xtm", 0, 0, 0)
        con = sqlite3.connect(self.db)
        con.execute("insert into process_device_reading values(1,100,1,15,1982.0,1,3)")
        con.commit(); con.close()
        result = tool.wait(str(self.db), 1, "xtm", 0, 0, 0)
        self.assertEqual(1982.0, result["hashrate"])
        self.assertEqual(3, result["acceptedTotal"])

    def test_cli_plan_does_not_write(self) -> None:
        before = self.db.read_bytes()
        with contextlib.redirect_stdout(io.StringIO()):
            code = tool.main(["plan", "--db", str(self.db), "--combination-id", "15", "--miner-id", "3"])
        self.assertEqual(0, code)
        self.assertEqual(before, self.db.read_bytes())

    def test_existing_database_may_be_read_on_c_drive_but_backup_stays_on_d(self) -> None:
        path = tool.existing_db_path("C:/Users/fixture/AppData/Roaming/Kryptex/kryptex.db")
        self.assertEqual("C:/Users/fixture/AppData/Roaming/Kryptex/kryptex.db", path.as_posix())
        with self.assertRaises(ValueError):
            tool.d_path("C:/Users/fixture/backup")
        with self.assertRaises(ValueError):
            tool.existing_db_path("relative/kryptex.db")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BenchmarkResetTests)
    result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
    passed = result.wasSuccessful()
    print(json.dumps({
        "status": "passed" if passed else "failed",
        "cases": result.testsRun,
        "results": [{"case": "benchmark-reset-suite", "passed": passed} for _ in range(result.testsRun)],
    }))
    raise SystemExit(0 if passed else 1)
