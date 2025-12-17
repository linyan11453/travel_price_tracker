#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
backup_dir="_migrated/patch_flights_${ts}"
mkdir -p "$backup_dir"

echo "[INFO] project_root=$ROOT"
echo "[INFO] backup_dir=$backup_dir"

# -------------------------
# 1) Patch db_init.sql
# -------------------------
if [ -f "scripts/db_init.sql" ]; then
  cp "scripts/db_init.sql" "$backup_dir/db_init.sql.bak"
else
  echo "[WARN] scripts/db_init.sql not found, creating a new one."
  cat > "scripts/db_init.sql" <<'SQL'
-- travel_tracker schema
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS runs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_type TEXT NOT NULL,
  run_date TEXT NOT NULL,
  created_at TEXT NOT NULL
);
SQL
fi

if ! grep -q "CREATE TABLE IF NOT EXISTS flights_quotes" scripts/db_init.sql; then
  cat >> scripts/db_init.sql <<'SQL'

-- =========================
-- Flights: quotes snapshot
-- =========================
CREATE TABLE IF NOT EXISTS flights_quotes(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_date TEXT NOT NULL,              -- YYYY-MM-DD (你的 daily/biweekly 同步用)
  provider TEXT NOT NULL,              -- e.g. "tripcom"
  origin TEXT NOT NULL,                -- SIN / JHB
  destination TEXT NOT NULL,           -- 20 cities codes
  route_id TEXT NOT NULL,              -- config route id, e.g. TRIPCOM_SIN_TPE
  source_url TEXT NOT NULL,            -- Trip.com route url
  status_code INTEGER,                 -- HTTP status
  parse_ok INTEGER NOT NULL DEFAULT 0, -- 1=解析到可用價格/資訊
  min_price_value REAL,                -- 若解析到最低價
  min_price_currency TEXT,             -- e.g. SGD/MYR/...
  notes TEXT,                          -- error msg / parse note
  raw_path TEXT,                       -- data/raw/<date>/flights/... html path
  created_at TEXT NOT NULL             -- ISO timestamp
);

-- 每天每條 route 只留一筆（避免重複灌）
CREATE UNIQUE INDEX IF NOT EXISTS uq_flights_quotes_dedup
  ON flights_quotes(run_date, provider, origin, destination, route_id);
SQL
  echo "[OK] Patched scripts/db_init.sql (flights_quotes added)."
else
  echo "[OK] scripts/db_init.sql already has flights_quotes."
fi

# -------------------------
# 2) Create provider: Trip.com (HTML fetch + best-effort parse)
# -------------------------
mkdir -p src/travel_tracker/sources/flights
cat > src/travel_tracker/sources/flights/tripcom.py <<'PY'
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from travel_tracker.core.http_client import PoliteHttpClient


@dataclass(frozen=True)
class TripcomRoute:
    route_id: str
    origin: str
    destination: str
    url: str
    destination_name_zh: str = ""


@dataclass
class TripcomFetchResult:
    status_code: int | None
    raw_path: str
    parse_ok: bool
    min_price_value: float | None
    min_price_currency: str | None
    notes: str | None


def load_tripcom_routes(path: str = "config/flights_tripcom_routes.json") -> list[TripcomRoute]:
    p = Path(path)
    data = json.loads(p.read_text(encoding="utf-8"))
    routes = []
    for r in data.get("routes", []):
        if (r.get("provider") or "") != "tripcom":
            continue
        routes.append(
            TripcomRoute(
                route_id=r["id"],
                origin=r["origin"],
                destination=r["destination"],
                url=r["url"],
                destination_name_zh=r.get("destination_name_zh", "") or "",
            )
        )
    return routes


def _best_effort_extract_price(html: str) -> tuple[float | None, str | None]:
    """
    Trip.com 頁面可能是 SSR/CSR 混合；價格位置不穩定。
    這裡做「盡力而為」的 regex 掃描：
    - 找像 "SGD 123" / "MYR 456" / "USD 789" 的片段
    - 或 JSON 片段裡的 currency + amount
    找不到就回 (None, None)，不要讓 pipeline 爆炸。
    """
    # 1) currency + number patterns
    m = re.search(r"\b(SGD|MYR|USD|TWD|THB|JPY|IDR|VND|PHP)\s*([0-9]{1,6}(?:\.[0-9]{1,2})?)\b", html)
    if m:
        return float(m.group(2)), m.group(1)

    # 2) JSON-ish patterns
    m2 = re.search(r'"currency"\s*:\s*"([A-Z]{3})".{0,80}?"amount"\s*:\s*([0-9]{1,6}(?:\.[0-9]{1,2})?)', html, re.S)
    if m2:
        return float(m2.group(2)), m2.group(1)

    return None, None


def fetch_route_html(
    client: PoliteHttpClient,
    run_date: str,
    route: TripcomRoute,
    raw_dir: Path,
) -> TripcomFetchResult:
    raw_dir.mkdir(parents=True, exist_ok=True)
    raw_path = raw_dir / f"{route.route_id}.html"

    try:
        resp = client.get(route.url)
        # PoliteHttpClient 可能回 304 且 body 來自 cache；照樣寫檔，便於追跡
        body = (resp.body or b"")
        raw_path.write_bytes(body)

        html = ""
        try:
            html = body.decode("utf-8", errors="replace")
        except Exception:
            html = ""

        v, c = _best_effort_extract_price(html)
        parse_ok = (v is not None and c is not None)

        return TripcomFetchResult(
            status_code=getattr(resp, "status", None),
            raw_path=str(raw_path),
            parse_ok=parse_ok,
            min_price_value=v,
            min_price_currency=c,
            notes=None if parse_ok else "price_not_found_best_effort",
        )

    except Exception as e:
        # 把錯誤記下來，但不中斷整個批次
        raw_path.write_text(f"ERROR: {e}\nURL: {route.url}\n", encoding="utf-8")
        return TripcomFetchResult(
            status_code=None,
            raw_path=str(raw_path),
            parse_ok=False,
            min_price_value=None,
            min_price_currency=None,
            notes=f"fetch_failed: {e}",
        )
PY
echo "[OK] Wrote: src/travel_tracker/sources/flights/tripcom.py"

# -------------------------
# 3) Add repository insert for flights_quotes
# -------------------------
if [ -f "src/travel_tracker/storage/repository.py" ]; then
  cp "src/travel_tracker/storage/repository.py" "$backup_dir/repository.py.bak"
else
  echo "[ERR] src/travel_tracker/storage/repository.py not found."
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
p = Path("src/travel_tracker/storage/repository.py")
s = p.read_text(encoding="utf-8")

if "def insert_flight_quote" in s:
    print("[OK] repository.py already has insert_flight_quote()")
    raise SystemExit(0)

# 插在 class Repository: 最後（commit 前）或檔尾
marker = "\n    def commit(self) -> None:"
idx = s.find(marker)
if idx == -1:
    raise SystemExit("[ERR] Cannot find 'def commit' in repository.py; please paste file top 120 lines.")

block = """
    def insert_flight_quote(
        self,
        run_date: str,
        provider: str,
        origin: str,
        destination: str,
        route_id: str,
        source_url: str,
        status_code: int | None,
        parse_ok: bool,
        min_price_value: float | None,
        min_price_currency: str | None,
        notes: str | None,
        raw_path: str,
    ) -> None:
        # 確保 schema 存在
        self.conn.execute(
            \"\"\"INSERT OR IGNORE INTO flights_quotes(
                run_date, provider, origin, destination, route_id, source_url,
                status_code, parse_ok, min_price_value, min_price_currency,
                notes, raw_path, created_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)\"\"\",
            (
                run_date, provider, origin, destination, route_id, source_url,
                status_code, 1 if parse_ok else 0, min_price_value, min_price_currency,
                notes, raw_path, _now_iso()
            ),
        )
"""

s2 = s[:idx] + block + s[idx:]
p.write_text(s2, encoding="utf-8")
print("[OK] Patched repository.py (insert_flight_quote added).")
PY

# -------------------------
# 4) Add flights pipeline
# -------------------------
mkdir -p src/travel_tracker/pipelines
cat > src/travel_tracker/pipelines/flights_snapshot.py <<'PY'
from __future__ import annotations

import os
from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.storage.repository import Repository
from travel_tracker.sources.flights.tripcom import load_tripcom_routes, fetch_route_html


def run_flights(run_date: str, force: bool = False) -> dict:
    """
    航班快照（最小可用版本）：
    - 讀取 config/flights_tripcom_routes.json
    - 逐 route 抓 HTML -> 存 raw
    - best-effort 抽最低價（能抽到就寫 min_price_*，抽不到也寫一筆 parse_ok=0）
    """
    repo = Repository()
    repo.init_schema()

    # 限制 route 數量（測試用，避免第一次跑太久）
    max_routes = int(os.environ.get("TRAVEL_FLIGHTS_MAX_ROUTES", "0") or "0")

    # Polite client settings (可透過 env 調整)
    rps = float(os.environ.get("TRAVEL_RPS", "0.2"))
    timeout = int(os.environ.get("TRAVEL_TIMEOUT", "8"))
    retries = int(os.environ.get("TRAVEL_RETRIES", "1"))

    client = PoliteHttpClient(cache_dir="data/cache/http", rps=rps, timeout_seconds=timeout, max_retries=retries)

    routes_path = os.environ.get("TRAVEL_FLIGHTS_ROUTES", "config/flights_tripcom_routes.json")
    routes = load_tripcom_routes(routes_path)

    if max_routes > 0:
        routes = routes[:max_routes]

    inserted = 0
    raw_dir = Path("data/raw") / run_date / "flights"

    for rt in routes:
        # raw 路徑按 origin/dest 分層
        ddir = raw_dir / rt.origin / rt.destination
        res = fetch_route_html(client=client, run_date=run_date, route=rt, raw_dir=ddir)

        repo.insert_flight_quote(
            run_date=run_date,
            provider="tripcom",
            origin=rt.origin,
            destination=rt.destination,
            route_id=rt.route_id,
            source_url=rt.url,
            status_code=res.status_code,
            parse_ok=res.parse_ok,
            min_price_value=res.min_price_value,
            min_price_currency=res.min_price_currency,
            notes=res.notes,
            raw_path=res.raw_path,
        )
        inserted += 1

        # 每 N 筆 commit 一次（避免中途 crash 全沒了）
        if inserted % 20 == 0:
            repo.commit()

    repo.commit()
    repo.close()

    return {
        "inserted_routes": inserted,
        "max_routes": max_routes if max_routes > 0 else None,
        "rps": rps,
        "timeout": timeout,
        "retries": retries,
        "routes_path": routes_path,
    }
PY
echo "[OK] Wrote: src/travel_tracker/pipelines/flights_snapshot.py"

# -------------------------
# 5) Patch main.py to add "flights" subcommand
# -------------------------
cp "src/travel_tracker/main.py" "$backup_dir/main.py.bak"

python3 - <<'PY'
from pathlib import Path
p = Path("src/travel_tracker/main.py")
s = p.read_text(encoding="utf-8")

if "{daily,biweekly" not in s and "daily" not in s:
    print("[WARN] main.py format unknown; patch still attempted.")

# 1) add import
if "run_flights" not in s:
    if "from travel_tracker.pipelines.daily_snapshot import run_daily" in s:
        s = s.replace(
            "from travel_tracker.pipelines.daily_snapshot import run_daily",
            "from travel_tracker.pipelines.daily_snapshot import run_daily\nfrom travel_tracker.pipelines.flights_snapshot import run_flights",
        )
    else:
        # fallback: insert after first imports
        lines = s.splitlines()
        insert_at = 0
        for i, line in enumerate(lines):
            if line.strip().startswith("import argparse"):
                insert_at = i + 1
                break
        lines.insert(insert_at, "from travel_tracker.pipelines.flights_snapshot import run_flights")
        s = "\n".join(lines)

# 2) add subparser "flights"
if 'add_parser("flights"' not in s:
    # find where daily/biweekly subparsers are defined
    # insert after biweekly parser block if possible
    anchor = 'sp.add_parser("biweekly"'
    idx = s.find(anchor)
    if idx == -1:
        # fallback: insert after daily parser
        anchor = 'sp.add_parser("daily"'
        idx = s.find(anchor)
    if idx == -1:
        raise SystemExit("[ERR] Cannot find subparser creation in main.py. Please paste main.py.")

    # insert after the block that sets up biweekly/daily; simplest insert near the first occurrence
    insert_pos = s.find("\n", idx)
    block = """
    p_f = sp.add_parser("flights", help="Fetch Trip.com flight routes HTML + store into flights_quotes")
    p_f.add_argument("--date", default=_today(), help="run date (YYYY-MM-DD)")
    p_f.add_argument("--force", action="store_true", help="force run even if same day")
"""
    s = s[:insert_pos] + block + s[insert_pos:]

# 3) handle cmd routing
if "args.cmd == \"flights\"" not in s:
    # insert before final return 2 or before biweekly handler end
    # try before "return 2"
    marker = "\n    return 2"
    pos = s.rfind(marker)
    if pos == -1:
        raise SystemExit("[ERR] Cannot find 'return 2' in main.py for dispatch insertion.")
    dispatch = """
    if args.cmd == "flights":
        # flights 不做「每日最多一次」限制，因為你可能想手動多跑測試
        result = run_flights(args.date, force=args.force)
        out = Path("reports/daily") / f"flights_{args.date}.md"
        lines = [
            f"# Flights Snapshot - {args.date}",
            "",
            "## Run Summary",
            f"- inserted routes: {result.get('inserted_routes')}",
            f"- routes_path: {result.get('routes_path')}",
            f"- rps/timeout/retries: {result.get('rps')}/{result.get('timeout')}/{result.get('retries')}",
            "",
            "Raw: data/raw/<run_date>/flights/<ORIGIN>/<DEST>/<ROUTE_ID>.html",
            "DB: data/db/travel_tracker.sqlite table flights_quotes",
        ]
        out.write_text("\\n".join(lines) + "\\n", encoding="utf-8")
        print(f"[OK] {out}")
        return 0

"""
    s = s[:pos] + dispatch + s[pos:]

p.write_text(s, encoding="utf-8")
print("[OK] Patched main.py (added flights command).")
PY

# -------------------------
# 6) Apply schema to current sqlite (safe)
# -------------------------
if [ -f "data/db/travel_tracker.sqlite" ]; then
  cp "data/db/travel_tracker.sqlite" "$backup_dir/travel_tracker.sqlite.bak"
fi

python3 - <<'PY'
from travel_tracker.storage.repository import Repository
repo = Repository()
repo.init_schema()
repo.close()
print("[OK] Schema applied to sqlite (init_schema).")
PY

echo ""
echo "[DONE] Flights scaffold installed."
echo ""
echo "Next commands:"
echo "  poetry run python -m travel_tracker.main flights --force"
echo ""
echo "Optional (limit for test):"
echo "  TRAVEL_FLIGHTS_MAX_ROUTES=5 TRAVEL_RPS=0.2 TRAVEL_TIMEOUT=8 TRAVEL_RETRIES=1 poetry run python -m travel_tracker.main flights --force"
