#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"

# --- sanity check ---
test -f "${ROOT}/pyproject.toml" || { echo "[ERR] Please run in project root (travel_price_tracker)."; exit 1; }
test -d "${ROOT}/src/travel_tracker" || { echo "[ERR] Missing src/travel_tracker. Your scaffold looks different."; exit 1; }

mkdir -p "${ROOT}/config"
mkdir -p "${ROOT}/data/raw"
mkdir -p "${ROOT}/src/travel_tracker/sources/flights"

ts="$(date +%Y%m%d_%H%M%S)"

# -------------------------
# 1) config: Trip.com airfares routes
# -------------------------
if [ ! -f "${ROOT}/config/flights_tripcom_airfares.json" ]; then
  cat > "${ROOT}/config/flights_tripcom_airfares.json" <<'JSON'
{
  "provider": "tripcom_airfares",
  "notes": "Trip.com 聚合最低價頁（路線A）。後續要擴充 20 城市：新增 routes[] 即可。",
  "routes": [
    {
      "id": "TRIPCOM_AIRFARES_SIN_TPE",
      "origin": "SIN",
      "destination": "TPE",
      "url": "https://www.trip.com/flights/singapore-to-taipei/airfares-sin-tpe/"
    },
    {
      "id": "TRIPCOM_AIRFARES_JHB_TPE",
      "origin": "JHB",
      "destination": "TPE",
      "url": "https://www.trip.com/flights/johor-bahru-to-taipei/airfares-jhb-tpe/"
    },
    {
      "id": "TRIPCOM_AIRFARES_SIN_BKK",
      "origin": "SIN",
      "destination": "BKK",
      "url": "https://www.trip.com/flights/singapore-to-bangkok/airfares-sin-bkk/"
    },
    {
      "id": "TRIPCOM_AIRFARES_JHB_BKK",
      "origin": "JHB",
      "destination": "BKK",
      "url": "https://www.trip.com/flights/johor-bahru-to-bangkok/airfares-jhb-bkk/"
    }
  ]
}
JSON
  echo "[OK] Created config/flights_tripcom_airfares.json"
else
  echo "[OK] config/flights_tripcom_airfares.json exists (skip)"
fi

# -------------------------
# 2) provider implementation
# -------------------------
cat > "${ROOT}/src/travel_tracker/sources/flights/tripcom_airfares.py" <<'PY'
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from travel_tracker.core.http_client import PoliteHttpClient


@dataclass
class FlightDeal:
    source_id: str
    origin: str
    destination: str
    title: str
    url: str
    price: float | None
    currency: str | None
    observed_at: str


def _now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _safe_slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("_")


def _extract_currency_and_price(html: str) -> tuple[str | None, float | None]:
    """
    Best-effort extraction for Trip.com airfares pages.
    We try multiple patterns because markup changes frequently.
    """

    # 1) Try to find embedded JSON blobs with price fields (common on OTA pages)
    # Look for "lowestPrice" / "minPrice" / "price" near currency.
    candidates = []

    # JSON-like key/value patterns
    json_price_patterns = [
        r'"lowestPrice"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"minPrice"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"price"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"amount"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
    ]
    for pat in json_price_patterns:
        for m in re.finditer(pat, html):
            candidates.append(m.group(1))

    # Currency patterns in JSON (e.g. "currency":"SGD")
    mcur = re.search(r'"currency"\s*:\s*"([A-Z]{3})"', html)
    currency = mcur.group(1) if mcur else None

    # If we got numeric candidates, choose the smallest plausible one (>0)
    price = None
    for s in candidates:
        try:
            v = float(s)
            if v > 0:
                price = v if price is None else min(price, v)
        except Exception:
            continue

    if currency and price is not None:
        return currency, price

    # 2) Fallback: text currency symbols + number
    # Examples: "S$123", "RM 456", "$789" (ambiguous), "SGD 123"
    sym_map = {
        "S$": "SGD",
        "RM": "MYR",
        "฿": "THB",
        "NT$": "TWD",
        "Rp": "IDR",
        "₱": "PHP",
        "₫": "VND",
        "¥": "JPY",
    }

    # Prefer explicit 3-letter currencies
    m = re.search(r"\b([A-Z]{3})\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?)\b", html)
    if m:
        c = m.group(1)
        p = float(m.group(2).replace(",", ""))
        if p > 0:
            return c, p

    # Symbols
    for sym, cur in sym_map.items():
        m2 = re.search(re.escape(sym) + r"\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?)", html)
        if m2:
            p = float(m2.group(1).replace(",", ""))
            if p > 0:
                return cur, p

    # Dollar sign ambiguous: treat as None currency
    m3 = re.search(r"\$\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?)", html)
    if m3:
        p = float(m3.group(1).replace(",", ""))
        if p > 0:
            return None, p

    return None, None


def load_routes(path: str | Path = "config/flights_tripcom_airfares.json") -> list[dict[str, Any]]:
    p = Path(path)
    data = json.loads(p.read_text(encoding="utf-8"))
    routes = data.get("routes", [])
    if not isinstance(routes, list):
        raise ValueError("config routes must be a list")
    return routes


def fetch_tripcom_airfares_deals(
    run_date: str,
    client: PoliteHttpClient,
    raw_dir: Path,
    routes: list[dict[str, Any]],
) -> list[FlightDeal]:
    deals: list[FlightDeal] = []
    raw_dir.mkdir(parents=True, exist_ok=True)

    for r in routes:
        sid = str(r.get("id") or "")
        origin = str(r.get("origin") or "").upper()
        dest = str(r.get("destination") or "").upper()
        url = str(r.get("url") or "")

        if not (sid and origin and dest and url):
            continue

        resp = client.get(url)
        html = (resp.body or b"").decode("utf-8", errors="replace")

        # Save raw
        out = raw_dir / origin / f"{_safe_slug(sid)}.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(html, encoding="utf-8")

        cur, price = _extract_currency_and_price(html)
        title = f"Trip.com airfares {origin}->{dest}"

        deals.append(
            FlightDeal(
                source_id=sid,
                origin=origin,
                destination=dest,
                title=title,
                url=url,
                price=price,
                currency=cur,
                observed_at=_now_iso(),
            )
        )

    return deals
PY
echo "[OK] Wrote src/travel_tracker/sources/flights/tripcom_airfares.py"

# -------------------------
# 3) DB schema: signals_flights
# -------------------------
cp -f "${ROOT}/scripts/db_init.sql" "${ROOT}/scripts/db_init.sql.bak_${ts}"

python3 - <<'PY'
from pathlib import Path

p = Path("scripts/db_init.sql")
s = p.read_text(encoding="utf-8")

if "CREATE TABLE IF NOT EXISTS signals_flights" in s:
    print("[OK] signals_flights already in db_init.sql (skip)")
    raise SystemExit(0)

block = """
-- flights (Trip.com airfares / others)
CREATE TABLE IF NOT EXISTS signals_flights (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_date TEXT NOT NULL,
  origin TEXT NOT NULL,
  destination TEXT NOT NULL,
  source_id TEXT,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  price REAL,
  currency TEXT,
  observed_at TEXT,
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_flights_dedup
  ON signals_flights(run_date, origin, destination, title, url);
"""

# Append at end
p.write_text(s.rstrip() + "\n\n" + block.strip() + "\n", encoding="utf-8")
print("[OK] Appended signals_flights table + uq_flights_dedup index to db_init.sql")
PY

# -------------------------
# 4) Repository: add insert_flight()
# -------------------------
cp -f "${ROOT}/src/travel_tracker/storage/repository.py" "${ROOT}/src/travel_tracker/storage/repository.py.bak_${ts}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/storage/repository.py")
s = p.read_text(encoding="utf-8")

if "def insert_flight(" in s:
    print("[OK] Repository.insert_flight already exists (skip)")
    raise SystemExit(0)

# Insert method before commit()
m = re.search(r"\n\s*def commit\(self\)\s*->\s*None\s*:\n", s)
if not m:
    raise SystemExit("[ERR] Can't find def commit() in repository.py")

insert_at = m.start()

method = """
    def insert_flight(
        self,
        run_date: str,
        origin: str,
        destination: str,
        source_id: str | None,
        title: str,
        url: str,
        price: float | None,
        currency: str | None,
        observed_at: str | None,
    ) -> None:
        # Use INSERT OR IGNORE because we create uq_flights_dedup
        self.conn.execute(
            \"\"\"INSERT OR IGNORE INTO signals_flights(
                run_date, origin, destination, source_id, title, url, price, currency, observed_at, created_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?)\"\"\",
            (run_date, origin, destination, source_id or "", title, url, price, currency, observed_at, _now_iso()),
        )
"""

s2 = s[:insert_at] + method + "\n" + s[insert_at:]
p.write_text(s2, encoding="utf-8")
print("[OK] Added Repository.insert_flight()")
PY

# -------------------------
# 5) Biweekly report: include flights section (latest per route)
# -------------------------
cp -f "${ROOT}/src/travel_tracker/pipelines/biweekly_report.py" "${ROOT}/src/travel_tracker/pipelines/biweekly_report.py.bak_${ts}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/biweekly_report.py")
s = p.read_text(encoding="utf-8")

if "signals_flights" in s and "Trip.com airfares" in s:
    print("[OK] biweekly_report already patched for flights (skip)")
    raise SystemExit(0)

# Ensure imports
if "from travel_tracker.storage.repository import Repository" not in s:
    # best effort: do nothing (file may differ)
    pass

# Find return {"sections": sections} and inject just before it
m = re.search(r"\n\s*return\s+\{\s*\"sections\"\s*:\s*sections\s*\}\s*\n", s)
if not m:
    raise SystemExit("[ERR] Can't find return {\"sections\": sections} in biweekly_report.py. Please paste the file head.")

inject = """
    # -------------------------
    # Flights (Trip.com airfares, route-A)
    # -------------------------
    try:
        rows = repo.conn.execute(
            \"\"\"SELECT origin, destination, title, url, price, currency, observed_at
               FROM signals_flights
               WHERE run_date=?
               ORDER BY origin, destination, price ASC\"\"\",
            (run_date,),
        ).fetchall()

        if rows:
            lines = []
            lines.append("### Flights (Trip.com airfares / route-A)")
            last_key = None
            for r in rows:
                origin, dest, title, url, price, currency, observed_at = r
                key = (origin, dest)
                if key != last_key:
                    lines.append(f"\\n**{origin} -> {dest}**")
                    last_key = key
                if price is None:
                    lines.append(f"- {title}: (price not found)  {url}")
                else:
                    cur = currency or ""
                    lines.append(f"- {title}: {cur} {price:g}  ({observed_at or ''})  {url}")

            sections.append({"h2": "Flights", "body": "\\n".join(lines)})
        else:
            sections.append({"h2": "Flights", "body": "No flights data yet. Fill config/flights_tripcom_airfares.json and run biweekly again."})
    except Exception as e:
        sections.append({"h2": "Flights", "body": f"Flights section error: {e}"})
"""

s2 = s[:m.start()] + inject + "\n" + s[m.start():]
p.write_text(s2, encoding="utf-8")
print("[OK] Patched biweekly_report.py to include flights section")
PY

# -------------------------
# 6) Ensure schema applied (init_schema is idempotent)
# -------------------------
python3 - <<'PY'
from travel_tracker.storage.repository import Repository
repo = Repository()
repo.init_schema()
repo.close()
print("[OK] DB schema ensured (signals_flights created).")
PY

echo ""
echo "[OK] Done."
echo "Next:"
echo "  1) Edit config/flights_tripcom_airfares.json -> add routes (SIN/JHB x your 20 cities)"
echo "  2) Run: poetry run python -m travel_tracker.main biweekly"
