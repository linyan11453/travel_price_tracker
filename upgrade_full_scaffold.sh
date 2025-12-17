#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"

mkdir -p \
  "${ROOT}/src/travel_tracker/core" \
  "${ROOT}/src/travel_tracker/sources/flights" \
  "${ROOT}/src/travel_tracker/sources/hotels" \
  "${ROOT}/src/travel_tracker/sources/safety" \
  "${ROOT}/src/travel_tracker/sources/weather" \
  "${ROOT}/src/travel_tracker/sources/news" \
  "${ROOT}/src/travel_tracker/sources/prices" \
  "${ROOT}/src/travel_tracker/sources/poi" \
  "${ROOT}/src/travel_tracker/storage" \
  "${ROOT}/src/travel_tracker/pipelines" \
  "${ROOT}/src/travel_tracker/reporting" \
  "${ROOT}/src/travel_tracker/human_in_loop" \
  "${ROOT}/src/travel_tracker/tests" \
  "${ROOT}/scripts"

# Ensure __init__.py exists in packages
touch \
  "${ROOT}/src/travel_tracker/__init__.py" \
  "${ROOT}/src/travel_tracker/core/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/flights/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/hotels/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/safety/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/weather/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/news/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/prices/__init__.py" \
  "${ROOT}/src/travel_tracker/sources/poi/__init__.py" \
  "${ROOT}/src/travel_tracker/storage/__init__.py" \
  "${ROOT}/src/travel_tracker/pipelines/__init__.py" \
  "${ROOT}/src/travel_tracker/reporting/__init__.py" \
  "${ROOT}/src/travel_tracker/human_in_loop/__init__.py" \
  "${ROOT}/src/travel_tracker/tests/__init__.py"

# scripts/db_init.sql
cat > "${ROOT}/scripts/db_init.sql" <<'SQL'
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_type TEXT NOT NULL,
  run_date TEXT NOT NULL,
  created_at TEXT NOT NULL
);
SQL

# core/errors.py
cat > "${ROOT}/src/travel_tracker/core/errors.py" <<'PY'
class TravelTrackerError(Exception):
    pass

class NeedsHumanIntervention(TravelTrackerError):
    pass
PY

# reporting/render_md.py
cat > "${ROOT}/src/travel_tracker/reporting/render_md.py" <<'PY'
from pathlib import Path
from typing import Any

def write_markdown_report(out_dir: Path, filename: str, title: str, sections: list[dict[str, Any]]) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / filename
    lines = [f"# {title}", ""]
    for s in sections:
        lines.append(f"## {s.get('h2','Section')}")
        lines.append("")
        lines.append(s.get("body",""))
        lines.append("")
    p.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return p
PY

# storage/db.py + repository.py (SQLite minimal)
cat > "${ROOT}/src/travel_tracker/storage/db.py" <<'PY'
import sqlite3
from pathlib import Path

SQLITE_PATH = "data/processed/travel_tracker.sqlite"

def connect_sqlite() -> sqlite3.Connection:
    p = Path(SQLITE_PATH)
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(p))
    conn.row_factory = sqlite3.Row
    return conn
PY

cat > "${ROOT}/src/travel_tracker/storage/repository.py" <<'PY'
from datetime import datetime
from pathlib import Path
from travel_tracker.storage.db import connect_sqlite

def _now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")

class Repository:
    def __init__(self) -> None:
        self.conn = connect_sqlite()

    def close(self) -> None:
        self.conn.close()

    def init_schema(self) -> None:
        sql = Path("scripts/db_init.sql").read_text(encoding="utf-8")
        self.conn.executescript(sql)
        self.conn.commit()

    def has_daily_run(self, run_date: str) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM runs WHERE run_type='daily' AND run_date=? LIMIT 1",
            (run_date,),
        ).fetchone()
        return row is not None

    def record_run(self, run_type: str, run_date: str) -> None:
        self.conn.execute(
            "INSERT INTO runs(run_type, run_date, created_at) VALUES(?,?,?)",
            (run_type, run_date, _now_iso()),
        )
        self.conn.commit()
PY

# human_in_loop/alerts.py
cat > "${ROOT}/src/travel_tracker/human_in_loop/alerts.py" <<'PY'
from pathlib import Path

def write_human_alert(run_date: str, reason: str, next_step: str) -> Path:
    out_dir = Path("reports/daily")
    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / f"NEEDS_HUMAN_{run_date}.md"
    p.write_text(
        "\n".join([
            f"# Needs Human Intervention ({run_date})",
            "",
            "## Reason",
            reason,
            "",
            "## Next step",
            next_step,
            "",
        ]) + "\n",
        encoding="utf-8",
    )
    return p
PY

# pipelines/daily_snapshot.py
cat > "${ROOT}/src/travel_tracker/pipelines/daily_snapshot.py" <<'PY'
from travel_tracker.human_in_loop.alerts import write_human_alert
from travel_tracker.storage.repository import Repository

def run_daily(run_date: str) -> dict:
    repo = Repository()
    repo.init_schema()

    if repo.has_daily_run(run_date):
        repo.close()
        return {"sections": [{"h2": "Daily Snapshot", "body": f"已存在 {run_date} 的 daily run（每日最多一次）。本次不重跑。"}]}

    try:
        repo.record_run("daily", run_date)
        repo.close()
        return {"sections": [{"h2": "Run Summary", "body": f"- run_date: {run_date}\n- status: ok\n"}]}
    except Exception as e:
        write_human_alert(run_date, str(e), "檢查來源/格式是否變更或需要人工介入。")
        repo.close()
        raise
PY

# pipelines/biweekly_report.py
cat > "${ROOT}/src/travel_tracker/pipelines/biweekly_report.py" <<'PY'
from datetime import datetime, timedelta
from travel_tracker.storage.repository import Repository

def run_biweekly(run_date: str) -> dict:
    repo = Repository()
    repo.init_schema()
    start = datetime.strptime(run_date, "%Y-%m-%d") - timedelta(days=13)
    repo.close()
    return {"sections": [{"h2": "Window", "body": f"{start.strftime('%Y-%m-%d')} ~ {run_date} (14 days)"}]}
PY

# main.py (switch back to pipeline + markdown renderer)
cat > "${ROOT}/src/travel_tracker/main.py" <<'PY'
import argparse
from datetime import datetime
from pathlib import Path

from travel_tracker.pipelines.daily_snapshot import run_daily
from travel_tracker.pipelines.biweekly_report import run_biweekly
from travel_tracker.reporting.render_md import write_markdown_report

def _today_ymd() -> str:
    return datetime.now().strftime("%Y-%m-%d")

def main() -> int:
    p = argparse.ArgumentParser(prog="travel_price_tracker")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("daily", help="Run daily snapshot (max once/day)")
    d.add_argument("--date", default=_today_ymd())

    b = sub.add_parser("biweekly", help="Run biweekly report")
    b.add_argument("--date", default=_today_ymd())

    args = p.parse_args()

    if args.cmd == "daily":
        result = run_daily(args.date)
        out = write_markdown_report(Path("reports/daily"), f"daily_{args.date}.md", f"Daily Snapshot - {args.date}", result["sections"])
        print(f"[OK] {out}")
        return 0

    if args.cmd == "biweekly":
        result = run_biweekly(args.date)
        out = write_markdown_report(Path("reports/biweekly"), f"biweekly_{args.date}.md", f"Biweekly Report - {args.date}", result["sections"])
        print(f"[OK] {out}")
        return 0

    return 2

if __name__ == "__main__":
    raise SystemExit(main())
PY

echo "[OK] Upgraded scaffold (full core/pipelines/reporting/storage skeleton)."
