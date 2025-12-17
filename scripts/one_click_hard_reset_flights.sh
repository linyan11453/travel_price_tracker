#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
BK="_migrated/hard_reset_flights_${TS}"
mkdir -p "$BK"

backup() {
  local f="$1"
  if [ -f "$f" ]; then
    mkdir -p "$BK/$(dirname "$f")"
    cp -f "$f" "$BK/$f.bak"
    echo "[OK] backup: $BK/$f.bak"
  else
    echo "[WARN] missing (skip backup): $f"
  fi
}

FILES=(
  "src/travel_tracker/sources/flights/tripcom.py"
  "src/travel_tracker/sources/flights/tripcom_pw.py"
  "src/travel_tracker/pipelines/flights_snapshot.py"
  "src/travel_tracker/flights_main.py"
  "src/travel_tracker/storage/repository.py"
)

for f in "${FILES[@]}"; do backup "$f"; done

mkdir -p src/travel_tracker/sources/flights
mkdir -p src/travel_tracker/pipelines
mkdir -p scripts

# -----------------------------
# 1) tripcom_pw.py (Playwright)
# -----------------------------
cat > src/travel_tracker/sources/flights/tripcom_pw.py <<'PY'
from __future__ import annotations

import os

def fetch_html(url: str, *, timeout_seconds: int = 20) -> bytes:
    """
    Fetch fully-rendered HTML via Playwright.
    Used when TRAVEL_FLIGHTS_USE_PW=1.
    """
    # Lazy import to keep normal runs light.
    from playwright.sync_api import sync_playwright

    # Tight defaults; keep it stable.
    ua = os.getenv(
        "TRAVEL_PW_UA",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36",
    )

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(user_agent=ua, viewport={"width": 1280, "height": 720})
        page = ctx.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=timeout_seconds * 1000)
        # give SPA a short breath (avoid infinite waits)
        page.wait_for_timeout(1200)
        html = page.content()
        ctx.close()
        browser.close()
    return html.encode("utf-8", errors="ignore")
PY
echo "[OK] wrote: src/travel_tracker/sources/flights/tripcom_pw.py"

# -----------------------------
# 2) tripcom.py (routes + fetch)
# -----------------------------
cat > src/travel_tracker/sources/flights/tripcom.py <<'PY'
from __future__ import annotations

import json
import os
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

def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))

def load_tripcom_routes(path: str | Path = "config/flights_tripcom_routes.json") -> list[TripcomRoute]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"routes file not found: {p}")

    data = _read_json(p)
    if isinstance(data, dict) and "routes" in data:
        data = data["routes"]

    if not isinstance(data, list):
        raise ValueError("routes json must be a list (or {routes:[...]})")

    out: list[TripcomRoute] = []
    for r in data:
        if not isinstance(r, dict):
            continue
        rid = str(r.get("route_id") or r.get("id") or r.get("name") or "").strip()
        org = str(r.get("origin") or "").strip().upper()
        dst = str(r.get("destination") or "").strip().upper()
        url = str(r.get("url") or "").strip()
        if not (rid and org and dst and url):
            continue
        out.append(TripcomRoute(route_id=rid, origin=org, destination=dst, url=url))
    return out

def fetch_route_html(
    *,
    client: PoliteHttpClient,
    route: TripcomRoute,
    raw_path: Path,
    use_playwright: bool | None = None,
) -> dict[str, object]:
    """
    Canonical return:
      {
        "source_url": str,
        "status_code": int|None,
        "html_bytes": bytes,
        "notes": str|None,
      }
    """
    if use_playwright is None:
        use_playwright = os.getenv("TRAVEL_FLIGHTS_USE_PW", "").strip() in {"1", "true", "yes", "on"}

    url = route.url
    status_code: int | None = None
    notes: str | None = None
    html_bytes: bytes = b""

    try:
        if use_playwright:
            from travel_tracker.sources.flights.tripcom_pw import fetch_html
            html_bytes = fetch_html(url, timeout_seconds=int(os.getenv("TRAVEL_TIMEOUT", "20")))
            status_code = 200
            notes = "pw=1"
        else:
            resp = client.get(url)
            # PoliteHttpClient may return HttpResponse or raw bytes depending on older patches
            body = getattr(resp, "body", None)
            html_bytes = body if isinstance(body, (bytes, bytearray)) else (resp if isinstance(resp, (bytes, bytearray)) else b"")
            status_code = getattr(resp, "status", None) or getattr(resp, "status_code", None)
            notes = "pw=0"
    except Exception as e:
        notes = f"fetch_error={type(e).__name__}:{e}"
        html_bytes = b""
        status_code = status_code or None

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_bytes(html_bytes)

    return {
        "source_url": url,
        "status_code": status_code,
        "html_bytes": html_bytes,
        "notes": notes,
    }
PY
echo "[OK] wrote: src/travel_tracker/sources/flights/tripcom.py"

# --------------------------------
# 3) flights_snapshot.py (pipeline)
# --------------------------------
cat > src/travel_tracker/pipelines/flights_snapshot.py <<'PY'
from __future__ import annotations

import os
import re
from datetime import date
from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.storage.repository import Repository
from travel_tracker.sources.flights.tripcom import load_tripcom_routes, fetch_route_html, TripcomRoute

def _today_iso() -> str:
    return date.today().isoformat()

def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)).strip())
    except Exception:
        return default

def _env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)).strip())
    except Exception:
        return default

def _extract_min_price_from_title(html_bytes: bytes) -> tuple[int, str | None, float | None, str | None]:
    """
    Trip.com pages (often) include 'from US$77' in <title>.
    We parse that as a best-effort baseline.
    Returns: (parse_ok, currency, value, note)
    """
    try:
        html = html_bytes.decode("utf-8", errors="ignore")
    except Exception:
        return 0, None, None, "decode_failed"

    m = re.search(r"<title[^>]*>(.*?)</title>", html, flags=re.IGNORECASE | re.DOTALL)
    title = (m.group(1).strip() if m else "")
    if not title:
        return 0, None, None, "no_title"

    # from US$77 | from S$72 | from RM 55 | from ฿1,234 etc.
    mm = re.search(r"\bfrom\s+((?:US\$|S\$|HK\$|NT\$|RM|฿|₱|¥|€|£))\s*([0-9][0-9,]*(?:\.[0-9]+)?)", title, flags=re.IGNORECASE)
    if not mm:
        return 0, None, None, "no_from_price_in_title"

    cur_raw = mm.group(1)
    val_raw = mm.group(2).replace(",", "")
    try:
        val = float(val_raw)
    except Exception:
        return 0, None, None, "price_parse_failed"

    cur_map = {
        "US$": "USD",
        "S$": "SGD",
        "HK$": "HKD",
        "NT$": "TWD",
        "RM": "MYR",
        "฿": "THB",
        "₱": "PHP",
        "¥": "JPY",
        "€": "EUR",
        "£": "GBP",
    }
    cur = cur_map.get(cur_raw, cur_raw)
    return 1, cur, val, "title_from_price"

def run_flights(run_date: str | None = None, *, force: bool = False) -> dict[str, object]:
    run_date = run_date or _today_iso()

    max_routes = _env_int("TRAVEL_FLIGHTS_MAX_ROUTES", 0)  # 0 = all
    rps = _env_float("TRAVEL_RPS", 0.2)
    timeout = _env_int("TRAVEL_TIMEOUT", 12)
    retries = _env_int("TRAVEL_RETRIES", 0)

    routes = load_tripcom_routes()
    if max_routes and max_routes > 0:
        routes = routes[:max_routes]

    client = PoliteHttpClient(cache_dir="data/cache/http", rps=rps, timeout_seconds=timeout, max_retries=retries)
    repo = Repository()

    inserted = 0
    total = 0

    report_lines: list[str] = []
    report_lines.append(f"# Flights Snapshot - {run_date}")
    report_lines.append("")
    report_lines.append("## Run Summary")
    report_lines.append(f"- routes: {len(routes)}")
    report_lines.append(f"- provider: tripcom")
    report_lines.append(f"- use_playwright: {os.getenv('TRAVEL_FLIGHTS_USE_PW','')}")
    report_lines.append("")

    for rt in routes:
        total += 1

        raw_dir = Path("data/raw") / run_date / "flights" / rt.origin / rt.destination
        raw_path = raw_dir / f"{rt.route_id}.html"

        res = fetch_route_html(client=client, route=rt, raw_path=raw_path)

        html_bytes = res.get("html_bytes") if isinstance(res, dict) else b""
        if not isinstance(html_bytes, (bytes, bytearray)):
            html_bytes = b""

        status_code = res.get("status_code") if isinstance(res, dict) else None
        if isinstance(status_code, str) and status_code.isdigit():
            status_code = int(status_code)
        if not isinstance(status_code, int):
            status_code = None

        notes = res.get("notes") if isinstance(res, dict) else None
        if notes is not None and not isinstance(notes, str):
            notes = str(notes)

        parse_ok, cur, val, parse_note = _extract_min_price_from_title(bytes(html_bytes))
        if notes:
            notes = f"{notes}; {parse_note}"
        else:
            notes = parse_note

        payload = {
            "run_date": run_date,
            "provider": "tripcom",
            "origin": rt.origin,
            "destination": rt.destination,
            "route_id": rt.route_id,
            "source_url": str(res.get("source_url") if isinstance(res, dict) else rt.url),
            "status_code": status_code,
            "parse_ok": int(parse_ok),
            "min_price_currency": cur,
            "min_price_value": val,
            "raw_path": str(raw_path),
            "notes": notes,
        }

        repo.insert_flight_quote(**payload)
        inserted += 1

        report_lines.append(f"### {rt.route_id} {rt.origin}->{rt.destination}")
        report_lines.append(f"- status_code: {status_code}")
        report_lines.append(f"- parse_ok: {parse_ok}")
        report_lines.append(f"- min_price: {cur or ''} {val or ''}")
        report_lines.append(f"- source: {payload['source_url']}")
        report_lines.append(f"- raw: {raw_path}")
        report_lines.append("")

    repo.commit()
    repo.close()

    out = Path("reports/daily")
    out.mkdir(parents=True, exist_ok=True)
    report_path = out / f"flights_{run_date}.md"
    report_path.write_text("\n".join(report_lines).strip() + "\n", encoding="utf-8")

    return {"run_date": run_date, "routes": len(routes), "inserted": inserted, "report": str(report_path)}
PY
echo "[OK] wrote: src/travel_tracker/pipelines/flights_snapshot.py"

# -----------------------------
# 4) flights_main.py (CLI entry)
# -----------------------------
cat > src/travel_tracker/flights_main.py <<'PY'
from __future__ import annotations

import argparse
from datetime import date

from travel_tracker.pipelines.flights_snapshot import run_flights

def main() -> int:
    p = argparse.ArgumentParser(prog="travel_flights")
    p.add_argument("--date", default=date.today().isoformat(), help="YYYY-MM-DD (default: today)")
    p.add_argument("--force", action="store_true", help="reserved (kept for compatibility)")
    args = p.parse_args()

    res = run_flights(args.date, force=args.force)
    print(f"[OK] {res['report']}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
PY
echo "[OK] wrote: src/travel_tracker/flights_main.py"

# ---------------------------------------------------------
# 5) Patch repository.py: replace insert_flight_quote() only
# ---------------------------------------------------------
python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/storage/repository.py")
s = p.read_text(encoding="utf-8")

m = re.search(r"\n\s+def insert_flight_quote\s*\(", s)
if not m:
    raise SystemExit("[ERR] repository.py: cannot find def insert_flight_quote(...)")

start = m.start()
m2 = re.search(r"\n    def \w+\s*\(", s[m.end():])
end = (m.end() + m2.start()) if m2 else len(s)

replacement = r'''
    def insert_flight_quote(
        self,
        *,
        run_date: str,
        provider: str,
        origin: str,
        destination: str,
        route_id: str,
        source_url: str,
        status_code: int | None = None,
        parse_ok: int = 0,
        min_price_currency: str | None = None,
        min_price_value: float | None = None,
        raw_path: str | None = None,
        notes: str | None = None,
        created_at: str | None = None,
    ) -> None:
        """
        Canonical flights_quotes insert (strict + consistent):
          - run_date: REQUIRED (DB NOT NULL)
          - source_url: REQUIRED
          - route_id/origin/destination/provider: REQUIRED
        """
        cols = self._table_cols("flights_quotes")

        if not run_date:
            raise ValueError("insert_flight_quote(): run_date is required")
        if not source_url:
            raise ValueError("insert_flight_quote(): source_url is required")

        col_names: list[str] = []
        values: list[object] = []

        def add(col: str, val: object) -> None:
            if col in cols:
                col_names.append(col)
                values.append(val)

        add("run_date", run_date)
        add("provider", provider)
        add("origin", origin)
        add("destination", destination)
        add("route_id", route_id)

        # schema compatibility
        if "source_url" in cols:
            add("source_url", source_url)
        elif "url" in cols:
            add("url", source_url)

        add("status_code", status_code)
        add("parse_ok", int(parse_ok))
        add("min_price_currency", min_price_currency)
        add("min_price_value", min_price_value)
        add("raw_path", raw_path)
        add("notes", notes)
        add("created_at", created_at or _now_iso())

        placeholders = ",".join(["?"] * len(values))
        sql = f"INSERT INTO flights_quotes({','.join(col_names)}) VALUES ({placeholders})"
        self.conn.execute(sql, tuple(values))
'''.lstrip("\n")

s2 = s[:start] + "\n" + replacement + s[end:]
p.write_text(s2, encoding="utf-8")
print("[OK] patched repository.py: insert_flight_quote() replaced (canonical)")
PY

# -----------------------------
# 6) Compile check
# -----------------------------
python3 -m py_compile src/travel_tracker/sources/flights/tripcom.py
python3 -m py_compile src/travel_tracker/sources/flights/tripcom_pw.py
python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
python3 -m py_compile src/travel_tracker/flights_main.py
python3 -m py_compile src/travel_tracker/storage/repository.py
echo "[OK] py_compile passed (flights hard reset)"

echo ""
echo "[NEXT] Test run (first 3 routes):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=3 TRAVEL_TIMEOUT=20 TRAVEL_RETRIES=0 poetry run python -m travel_tracker.flights_main --force'
