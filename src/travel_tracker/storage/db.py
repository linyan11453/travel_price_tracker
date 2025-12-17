import sqlite3
from pathlib import Path

SQLITE_PATH = "data/db/travel_tracker.sqlite"

def connect_sqlite() -> sqlite3.Connection:
    p = Path(SQLITE_PATH)
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(p))
    conn.row_factory = sqlite3.Row
    return conn
