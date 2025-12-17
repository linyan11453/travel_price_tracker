#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
BK="_migrated/reset_flights_pipeline_clean_${TS}"
mkdir -p "$BK"

cp -f src/travel_tracker/pipelines/flights_snapshot.py "$BK/flights_snapshot.py.bak" 2>/dev/null || true
cp -f src/travel_tracker/flights_main.py "$BK/flights_main.py.bak" 2>/dev/null || true
echo "[OK] backup -> $BK"

cat > src/travel_tracker/pipelines/flights_snapshot.py <<'PY'
from __future__ import annotations

import inspect
import os
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.sources.flights.tripcom import load_tripcom_routes, fetch_route_html
from travel_tracker.storage.repository import Repository


_PRICE_RE = re.compile(r'(?:(US\\$|SGD|TWD|MYR|THB|JPY|IDR|VND)\\s*([0-9][0-9,]*)(?:\\.[0-9]+)?)')

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

def _env_str(name: str, default: str) -> str:
    v = os.getenv(name)
    return default if v is None else v

def _pick_args(func, provided: dict[str, Any]) -> dict[str, Any]:
    sig = inspect.signature(func)
    return {k: v for k, v in provided.items() if k in sig.parameters}

def _parse_min_price_from_html(html_bytes: bytes) -> tuple[str | None, float | None]:
    # 先用最保守的 regex 嘗試，抓不到就回 None（Trip.com 多數情況需要 PW DOM 抓取）
    try:
        text = html_bytes.decode("utf-8", errors="ignore")
    except Exception:
        return None, None

    m = _PRICE_RE.search(text)
    if not m:
        return None, None

    cur = m.group(1)
    val_s = m.group(2).replace(",", "")
    try:
        val = float(val_s)
    except Exception:
        return cur, None
    return cur, val

def run_flights(run_date: str | None = None, force: bool = False) -> dict[str, Any]:
    run_date = run_date or _today_iso()

    max_routes = _env_int("TRAVEL_FLIGHTS_MAX_ROUTES", 10)
    rps = _env_float("TRAVEL_RPS", 0.2)
    timeout = _env_int("TRAVEL_TIMEOUT", 12)
    retries = _env_int("TRAVEL_RETRIES", 0)

    client = PoliteHttpClient(cache_dir="data/cache/http", rps=rps, timeout_seconds=timeout, max_retries=retries)

    routes = load_tripcom_routes("config/flights_tripcom_routes.json")
    routes = routes[:max_routes] if max_routes > 0 else routes

    repo = Repository()

    inserted = 0
    errors = 0

    for rt in routes:
        # Defaults per route (avoid NameError/UnboundLocalError)
        status_code = None
        parse_ok = 0
        min_price_currency = None
        min_price_value = None
        notes = None

        raw_dir = Path("data/raw") / run_date / "flights" / rt.origin / rt.destination
        raw_dir.mkdir(parents=True, exist_ok=True)
        raw_path = raw_dir / f"{rt.id}.html"

        try:
            html_bytes = fetch_route_html(client=client, url=rt.url, raw_path=raw_path)
            # 這裡 fetch_route_html 回 bytes，所以不強行猜 status_code
            min_price_currency, min_price_value = _parse_min_price_from_html(html_bytes)
            if min_price_currency and (min_price_value is not None):
                parse_ok = 1
        except Exception as e:
            errors += 1
            notes = repr(e)

        # 寫 DB：用 signature 自動對齊你 repository.py 的 insert_flight_quote 參數
        payload = {
            "provider": "tripcom",
            "origin": rt.origin,
            "destination": rt.destination,
            "route_id": rt.id,
            "url": rt.url,
            "status_code": status_code,
            "parse_ok": parse_ok,
            "min_price_currency": min_price_currency,
            "min_price_value": min_price_value,
            "raw_path": str(raw_path),
            "notes": notes,
            "run_date": run_date,
        }
        repo.insert_flight_quote(**_pick_args(repo.insert_flight_quote, payload))
        inserted += 1

    repo.commit()
    repo.close()

    return {
        "run_date": run_date,
        "inserted": inserted,
        "errors": errors,
        "max_routes": max_routes,
        "pw_enabled": _env_str("TRAVEL_FLIGHTS_USE_PW", "0"),
    }
PY

cat > src/travel_tracker/flights_main.py <<'PY'
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

from travel_tracker.pipelines.flights_snapshot import run_flights


def _today() -> str:
    return date.today().isoformat()


def main() -> int:
    p = argparse.ArgumentParser(prog="travel_price_tracker (flights)")
    p.add_argument("--date", default=_today())
    p.add_argument("--force", action="store_true")
    args = p.parse_args()

    result = run_flights(args.date, force=args.force)

    out_dir = Path("reports/daily")
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"flights_{args.date}.md"

    out.write_text(
        "\n".join([
            f"# Flights Snapshot - {args.date}",
            "",
            "## Run Summary",
            f"- inserted: {result['inserted']}",
            f"- errors: {result['errors']}",
            f"- max_routes: {result['max_routes']}",
            f"- TRAVEL_FLIGHTS_USE_PW: {result['pw_enabled']}",
            "",
            "Raw HTML: data/raw/<run_date>/flights/<ORIGIN>/<DEST>/<ROUTE_ID>.html",
        ]) + "\n",
        encoding="utf-8"
    )

    print(f"[OK] {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
python3 -m py_compile src/travel_tracker/flights_main.py
echo "[OK] py_compile passed (clean flights pipeline)"
