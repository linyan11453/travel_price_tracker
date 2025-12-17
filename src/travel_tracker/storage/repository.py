from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any

from travel_tracker.storage.db import connect_sqlite
import sqlite3

def _now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


NEWS_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS news_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  city TEXT NOT NULL,
  topic TEXT NOT NULL,
  source TEXT NOT NULL,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  published_at TEXT,
  fetched_at TEXT NOT NULL,
  UNIQUE(url)
);
""".strip()


class Repository:
    def __init__(self) -> None:
        self.conn = connect_sqlite()

    def commit(self) -> None:
        self.conn.commit()

    def rollback(self) -> None:
        self.conn.rollback()

    def close(self) -> None:
        self.conn.close()

        self._cols_cache: dict[str, set[str]] = {}

    def close(self) -> None:
        self.conn.close()

    def init_schema(self) -> None:
        # Base schema from SQL file
        sql = Path("scripts/db_init.sql").read_text(encoding="utf-8")
        self.conn.executescript(sql)

        # News table (ours)
        self.conn.execute(f'''{NEWS_SCHEMA_SQL}''')

        self.conn.commit()

    def _table_cols(self, table: str) -> set[str]:
        if not hasattr(self, "_cols_cache"):
            self._cols_cache = {}
        if table in self._cols_cache:
            return self._cols_cache[table]
        rows = self.conn.execute(f"PRAGMA table_info({table});").fetchall()
        cols = {r[1] for r in rows}  # r[1] = column name
        self._cols_cache[table] = cols
        return cols

    # ---------- runs ----------
    def has_daily_run(self, run_date: str) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM runs WHERE run_type='daily' AND run_date=? LIMIT 1",
            (run_date,),
        ).fetchone()
        return row is not None

    def delete_daily_run(self, run_date: str) -> None:
        # When forcing a rerun, delete signals for the date to avoid duplicates
        for t in ("signals_news", "signals_weather", "signals_safety"):
            self.conn.execute(f"DELETE FROM {t} WHERE run_date=?", (run_date,))
        self.conn.execute("DELETE FROM runs WHERE run_type='daily' AND run_date=?", (run_date,))
        self.conn.commit()

    def record_run(self, run_type: str, run_date: str) -> None:
        self.conn.execute(
            "INSERT INTO runs(run_type, run_date, created_at) VALUES(?,?,?)",
            (run_type, run_date, _now_iso()),
        )
        self.conn.commit()

    # ---------- generic insert helper ----------
    def _insert_row_ignore(self, table: str, data: dict[str, Any]) -> None:
        cols = self._table_cols(table)
        col_names: list[str] = []
        values: list[Any] = []
        for k, v in data.items():
            if k in cols:
                col_names.append(k)
                values.append(v)
        if "created_at" in cols and "created_at" not in col_names:
            col_names.append("created_at")
            values.append(_now_iso())

        if not col_names:
            return

        placeholders = ",".join(["?"] * len(values))
        sql = f"INSERT OR IGNORE INTO {table}({','.join(col_names)}) VALUES ({placeholders})"
        self.conn.execute(sql, tuple(values))
        self.conn.commit()

    # ---------- signals ----------
    def insert_signal(
        self,
        table: str,
        run_date: str,
        city_code: str,
        city_name_zh: str,
        source_id: str,
        title: str,
        url: str,
        published_at: str | None,
    ) -> None:
        if table not in {"signals_news", "signals_weather", "signals_safety"}:
            raise ValueError("Invalid table")

        cols = self._table_cols(table)
        data: dict[str, Any] = {
            "run_date": run_date,
            "city_code": city_code,
            "city_name_zh": city_name_zh,
            "title": title,
            "url": url,
            "published_at": published_at,
        }

        # Backward compat: old schema may have `source` NOT NULL
        if "source" in cols:
            data["source"] = source_id

        # Newer schema
        if "source_id" in cols:
            data["source_id"] = source_id

        self._insert_row_ignore(table, data)

    # ---------- news ----------
    def insert_news_item(
        self,
        *,
        city: str,
        topic: str,
        source: str,
        title: str,
        url: str,
        published_at: str | None,
    ) -> bool:
        fetched_at = datetime.utcnow().isoformat(timespec="seconds")
        sql = """
        INSERT OR IGNORE INTO news_items
        (city, topic, source, title, url, published_at, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        cur = self.conn.execute(sql, (city, topic, source, title, url, published_at, fetched_at))
        self.conn.commit()
        try:
            return cur.rowcount == 1
        except Exception:
            return True

    def list_news(
        self,
        *,
        start_date: str,  # YYYY-MM-DD
        end_date: str,    # YYYY-MM-DD
        city: str | None = None,
        topic: str | None = None,
        limit: int = 50,
    ) -> list[dict]:
        where = []
        params: list[Any] = []

        where.append("SUBSTR(COALESCE(published_at, fetched_at), 1, 10) >= ?")
        where.append("SUBSTR(COALESCE(published_at, fetched_at), 1, 10) <= ?")
        params.extend([start_date, end_date])

        if city:
            where.append("city = ?")
            params.append(city)
        if topic:
            where.append("topic = ?")
            params.append(topic)

        sql = f"""
        SELECT city, topic, source, title, url, published_at, fetched_at
        FROM news_items
        WHERE {' AND '.join(where)}
        ORDER BY COALESCE(published_at, fetched_at) DESC
        LIMIT ?
        """
        params.append(limit)

        cur = self.conn.execute(sql, params)
        rows = cur.fetchall()
        return [
            {
                "city": r[0],
                "topic": r[1],
                "source": r[2],
                "title": r[3],
                "url": r[4],
                "published_at": r[5],
                "fetched_at": r[6],
            }
            for r in rows
        ]
    def insert_signal(self, table: str, row: dict) -> bool:
        """
        通用寫入 signals_* 表。
        - 只寫入表中存在的欄位（用 PRAGMA table_info）
        - 若因 UNIQUE 衝突導致 IntegrityError，回傳 False（視為已存在）
        """
        cols = self._table_cols(table)
        use_cols = [c for c in cols if c in row and row[c] is not None]

        if not use_cols:
            return False

        sql = f"INSERT INTO {table} ({','.join(use_cols)}) VALUES ({','.join(['?']*len(use_cols))})"
        vals = [row[c] for c in use_cols]

        try:
            self.conn.execute(sql, vals)
            self.conn.commit()
            return True
        except sqlite3.IntegrityError:
            self.conn.rollback()
            return False