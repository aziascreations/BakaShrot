"""
SQLite JSON subfield indexing demo.

Shows the pattern discussed: a table with a JSON blob column where rows have
varying shapes, a generated column that pulls one subfield out of the JSON,
and an index on that generated column so lookups by the subfield don't
require a full table scan. Also adds a couple of views so the result is
pleasant to poke around in a GUI tool like SQLiteStudio.

Stdlib only (sqlite3, json, random, pathlib). Writes events.db next to this
script; re-running the script deletes and regenerates it from scratch.
"""

import json
import random
import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent / "events.db"
MIN_SQLITE_VERSION = (3, 31, 0)  # generated columns require this


def check_sqlite_version() -> None:
    version = tuple(int(part) for part in sqlite3.sqlite_version.split("."))
    if version < MIN_SQLITE_VERSION:
        raise RuntimeError(
            f"sqlite3 {sqlite3.sqlite_version} is too old; generated columns "
            f"need >= {'.'.join(map(str, MIN_SQLITE_VERSION))}"
        )


def create_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            data TEXT NOT NULL,
            -- pulled out of data for indexing/querying; not stored twice
            msg_type TEXT GENERATED ALWAYS AS (
                json_extract(data, '$.messageData.MsgType')
            ) VIRTUAL
        )
        """
    )
    conn.execute("CREATE INDEX idx_events_msg_type ON events (msg_type)")


def create_views(conn: sqlite3.Connection) -> None:
    # Flattened, browsable overview of every row regardless of shape --
    # fields that don't apply to a given msg_type just come back NULL.
    conn.execute(
        """
        CREATE VIEW event_summary AS
        SELECT
            id,
            msg_type,
            json_extract(data, '$.messageData.userId') AS user_id,
            data
        FROM events
        """
    )

    # Type-specific view: only PURCHASE rows, with cents converted to a
    # normal dollar amount. This is the pattern for any other MsgType you
    # want to drill into -- copy this, swap the WHERE and the extracted
    # fields.
    conn.execute(
        """
        CREATE VIEW purchase_details AS
        SELECT
            id,
            json_extract(data, '$.messageData.userId')             AS user_id,
            json_extract(data, '$.messageData.amountCents') / 100.0 AS amount_usd,
            json_extract(data, '$.messageData.items')               AS items
        FROM events
        WHERE msg_type = 'PURCHASE'
        """
    )


def make_row(msg_type: str) -> dict:
    """Each MsgType has a genuinely different JSON shape."""
    if msg_type == "LOGIN":
        return {
            "messageData": {
                "MsgType": "LOGIN",
                "userId": random.randint(1, 500),
                "ip": f"10.0.{random.randint(0, 255)}.{random.randint(0, 255)}",
            }
        }
    if msg_type == "LOGOUT":
        return {
            "messageData": {
                "MsgType": "LOGOUT",
                "userId": random.randint(1, 500),
                "sessionDurationSec": random.randint(5, 3600),
            }
        }
    if msg_type == "PURCHASE":
        return {
            "messageData": {
                "MsgType": "PURCHASE",
                "userId": random.randint(1, 500),
                "amountCents": random.randint(99, 20000),
                "items": random.randint(1, 5),
            }
        }
    if msg_type == "ERROR":
        # no userId at all here -- deliberately a different shape
        return {
            "messageData": {
                "MsgType": "ERROR",
                "code": random.choice(["TIMEOUT", "BAD_AUTH", "RATE_LIMIT"]),
                "retryable": random.choice([True, False]),
            }
        }
    raise ValueError(f"unknown msg_type: {msg_type}")


def generate_rows(count: int) -> list[tuple[str]]:
    weights = {"LOGIN": 40, "LOGOUT": 35, "PURCHASE": 15, "ERROR": 10}
    types = list(weights.keys())
    picks = random.choices(types, weights=list(weights.values()), k=count)
    return [(json.dumps(make_row(t)),) for t in picks]


def insert_rows(conn: sqlite3.Connection, rows: list[tuple[str]]) -> None:
    conn.executemany("INSERT INTO events (data) VALUES (?)", rows)


def query_counts_by_type(conn: sqlite3.Connection) -> None:
    print("-- counts by msg_type --")
    for msg_type, count in conn.execute(
        "SELECT msg_type, COUNT(*) FROM events GROUP BY msg_type ORDER BY msg_type"
    ):
        print(f"{msg_type:10s} {count}")


def query_purchases(conn: sqlite3.Connection) -> None:
    print("\n-- sample PURCHASE rows (via the indexed column) --")
    rows = conn.execute(
        """
        SELECT id,
               json_extract(data, '$.messageData.userId')      AS user_id,
               json_extract(data, '$.messageData.amountCents') AS amount_cents
        FROM events
        WHERE msg_type = 'PURCHASE'
        ORDER BY id
        LIMIT 5
        """
    ).fetchall()
    for row in rows:
        print(row)


def confirm_index_is_used(conn: sqlite3.Connection) -> None:
    plan = conn.execute(
        "EXPLAIN QUERY PLAN SELECT * FROM events WHERE msg_type = 'ERROR'"
    ).fetchall()
    plan_text = " | ".join(row[-1] for row in plan)
    print(f"\n-- query plan for WHERE msg_type = 'ERROR' --\n{plan_text}")
    if "idx_events_msg_type" not in plan_text:
        raise AssertionError(
            f"expected idx_events_msg_type to be used, got: {plan_text}"
        )


def main() -> None:
    check_sqlite_version()
    random.seed(0)  # reproducible output

    conn = sqlite3.connect(":memory:")
    create_schema(conn)
    insert_rows(conn, generate_rows(2000))
    conn.commit()

    query_counts_by_type(conn)
    query_purchases(conn)
    confirm_index_is_used(conn)

    conn.close()


if __name__ == "__main__":
    main()
