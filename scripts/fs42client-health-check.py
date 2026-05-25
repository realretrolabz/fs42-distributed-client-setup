#!/usr/bin/env python3
"""Health checks for FieldStation42 distributed nodes/headends."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys


def ok(message: str) -> None:
    print(f"OK   {message}")


def warn(message: str) -> None:
    print(f"WARN {message}")


def fail(message: str) -> None:
    print(f"FAIL {message}")


def table_count(conn: sqlite3.Connection, table: str) -> int:
    return int(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])


def main() -> int:
    parser = argparse.ArgumentParser(description="Check an FS42 distributed install")
    parser.add_argument("--fs42-dir", default=os.environ.get("FS42_DIR", str(Path.home() / "FieldStation42")))
    parser.add_argument("--media-root", default=os.environ.get("NODE_MEDIA_MOUNT", "/media/FS42DB/fs42"))
    parser.add_argument("--db-path", default=None, help="Defaults to <fs42-dir>/runtime/fs42_fluid.db")
    parser.add_argument("--warn-days", type=float, default=3.0)
    args = parser.parse_args()

    fs42_dir = Path(args.fs42_dir).expanduser()
    media_root = Path(args.media_root).expanduser()
    db_path = Path(args.db_path).expanduser() if args.db_path else fs42_dir / "runtime" / "fs42_fluid.db"
    confs_dir = fs42_dir / "confs"

    failures = 0

    if fs42_dir.is_dir():
        ok(f"FS42 dir exists: {fs42_dir}")
    else:
        fail(f"FS42 dir missing: {fs42_dir}")
        failures += 1

    if confs_dir.is_dir():
        station_files = [p for p in confs_dir.glob("*.json") if p.name != "main_config.json"]
        if station_files:
            ok(f"station configs found: {len(station_files)}")
        else:
            fail(f"no station configs in {confs_dir}")
            failures += 1
    else:
        fail(f"confs dir missing: {confs_dir}")
        failures += 1

    main_config = confs_dir / "main_config.json"
    if main_config.exists():
        try:
            data = json.loads(main_config.read_text())
            if data.get("schedule_agent"):
                warn("main_config.json contains schedule_agent; do not enable this on kiosk nodes")
            ok("main_config.json is valid JSON")
        except Exception as exc:
            fail(f"main_config.json is not valid JSON: {exc}")
            failures += 1
    else:
        warn(f"main_config.json missing: {main_config}")

    if media_root.is_dir():
        ok(f"media root exists: {media_root}")
    else:
        fail(f"media root missing: {media_root}")
        failures += 1

    if db_path.exists():
        link_note = " symlink" if db_path.is_symlink() else ""
        ok(f"DB exists{link_note}: {db_path}")
    else:
        fail(f"DB missing: {db_path}")
        return failures + 1

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.Error as exc:
        fail(f"cannot open DB read-only: {exc}")
        return failures + 1

    with conn:
        required = {
            "catalog_entries",
            "file_meta",
            "liquid_blocks",
            "named_sequence",
            "sequence_entries",
        }
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing = sorted(required - tables)
        if missing:
            fail(f"DB missing required tables: {', '.join(missing)}")
            failures += 1
        else:
            ok("DB has required FS42 tables")

        if "catalog_entries" in tables:
            count = table_count(conn, "catalog_entries")
            if count:
                ok(f"catalog entries: {count}")
            else:
                fail("catalog_entries is empty")
                failures += 1

        if "liquid_blocks" in tables:
            count = table_count(conn, "liquid_blocks")
            if count:
                ok(f"schedule blocks: {count}")
                rows = conn.execute(
                    "SELECT station, MAX(end_time) FROM liquid_blocks GROUP BY station ORDER BY station"
                ).fetchall()
                for station, end_time in rows:
                    print(f"INFO schedule_end {station}: {end_time}")
            else:
                fail("liquid_blocks is empty")
                failures += 1

    if failures:
        print(f"Health check completed with {failures} failure(s)")
    else:
        print("Health check completed successfully")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
