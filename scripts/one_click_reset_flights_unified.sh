#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
BK="_migrated/reset_flights_unified_${TS}"
mkdir -p "$BK"

# backup (only flights-related)
for f in \
  src/travel_tracker/flights_main.py \
  src/travel_tracker/pipelines/flights_snapshot.py \
  src/travel_tracker/sources/flights/tripcom.py \
  src/travel_tracker/sources/flights/tripcom_pw.py
do
  if [ -f "$f" ]; then
    mkdir -p "$BK/$(dirname "$f")"
    cp -f "$f" "$BK/$f.bak"
  fi
done
echo "[OK] backup -> $BK"

# 1) Trip.com route loader + fetch wrapper (UNIFIED)
cat > src/travel_tracker/sources/flights/tripcom.py <<'PY'
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class TripcomRoute:
    route_id: str
    origin: str
    destination: str
    url: str
    provider: str = "tripcom"

    # backward-compat alias: old code may use rt.id
    @property
    def id(self) -> str:
        return self.route_id


def _norm_code(x: Any) -> str:
    return str(x or "").strip().upper()


def load_tripcom_routes(path: str | Path) -> list[TripcomRoute]:
    p = Path(path)
    data = json.loads(p.read_text(encoding="utf-8"))

    # accept list[dict] or {"routes":[...]}
    items = data.get("routes") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise ValueError(f"Invalid routes json: expected list or dict.routes, got {type(items)}")

    routes: list[TripcomRoute] = []
    for it in items:
        if not isinstance(it, dict):
            continue

        # accept multiple key styles: route_id/id, origin/from, destination/to
        rid = it.get("route_id") or it.get("id") or it.get("routeId")
        origin = it.get("origin") or it.get("from") or it.get("origin_code")
        dest = it.get("destination") or it.get("to") or it.get("dest_code")
        url = it.get("url") or it.get("link")

        if not (rid and origin and dest and url):
            continue

        routes.append(
            TripcomRoute(
                route_id=str(rid).strip(),
                origin=_norm_code(origin),
                destination=_norm_code(dest),
                url=str(url).strip(),
            )
        )

    return routes


def fetch_route_html(*, client: Any, url: str, raw_path: Path) -> Any:
    """
    Unified contract:
      - always writes html bytes into raw_path
      - returns whatever client.get(url) returns (HttpResponse-like object)
    """
    resp = client.get(url)

    body = getattr(resp, "body", resp)
    if body is None:
        html_bytes = b""
    elif isinstance(body, bytes):
        html_bytes = body
    else:
        html_bytes = str(body).encode("utf-8", errors="ignore")

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_bytes(html_bytes)
    return resp
PY
echo "[OK] wrote: src/travel_tracker/sources/flights/tripcom.py"

# 2) Playwright helper (provide multiple function names to match any previous caller)
cat > src/travel_tracker/sources/flights/tripcom_pw.py <<'PY'
from __future__ import annotations

import os
from typing import Optional

# NOTE: We keep names flexible so patched http_client can import whichever it expects.

def _timeout_ms() -> int:
    try:
        return int(os.getenv("TRAVEL_TIMEOUT", "12")) * 1000
    except Exception:
        return 12000

async def _fetch_with_pw(url: str) -> bytes:
    from playwright.async_api import async_playwright

    timeout = _timeout_ms()
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        await page.goto(url, wait_until="domcontentloaded", timeout=timeout)
        # small settle time for hydration
        try:
            await page.wait_for_timeout(800)
        except Exception:
            pass
        html = await page.content()
        await browser.close()
        return html.encode("utf-8", errors="ignore")

def fetch_tripcom_html(url: str) -> bytes:
    import asyncio
    return asyncio.run(_fetch_with_pw(url))

# aliases
fetch_html = fetch_tripcom_html
fetch_html_bytes = fetch_tripcom_html
PY
echo "[OK] wrote: src/travel_tracker/sources/flights/tripcom_pw.py"

# 3) Flights snapshot pipeline (UNIFIED naming; works with HttpResponse OR bytes)
cat > src/travel_tracker/pipelines/flights_snapshot.py <<'PY'
from __future__ import annotations

import inspect
import os
import re
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

def _pick_args(func, provided: dict[str, Any]) -> dict[str, Any]:
    sig = inspect.signature(func)
    return {k: v for k, v in provided.items() if k in sig.parameters}

def _bytes_from_resp(resp: Any) -> bytes:
    body = getattr(resp, "body", resp)
    if body is None:
        return b""
    if isinstance(body, bytes):
        return body
    return str(body).encode("utf-8", errors="ignore")

def _status_code_from_resp(resp: Any) -> int | None:
    # tolerate multiple field names
    for k in ("status_code", "status", "code"):
        v = getattr(resp, k, None)
        if isinstance(v, int):
            return v
    return None

def _parse_min_price_from_html(html_bytes: bytes) -> tuple[str | None, float | None]:
    # Best-effort regex only (Trip.com often needs DOM extraction; this keeps pipeline stable)
    text = html_bytes.decode("utf-8", errors="ignore")
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
    if max_routes > 0:
        routes = routes[:max_routes]

    repo = Repository()
    inserted = 0
    errors = 0

    for rt in routes:
        # unified fields
        route_id = getattr(rt, "route_id", None) or getattr(rt, "id", None) or ""
        origin = getattr(rt, "origin", "") or ""
        destination = getattr(rt, "destination", "") or ""
        url = getattr(rt, "url", "") or ""

        status_code: int | None = None
        parse_ok = 0
        min_price_currency: str | None = None
        min_price_value: float | None = None
        notes: str | None = None

        raw_dir = Path("data/raw") / run_date / "flights" / origin / destination
        raw_path = raw_dir / f"{route_id}.html"

        try:
            resp = fetch_route_html(client=client, url=url, raw_path=raw_path)
            status_code = _status_code_from_resp(resp)
            html_bytes = _bytes_from_resp(resp)
            min_price_currency, min_price_value = _parse_min_price_from_html(html_bytes)
            if min_price_currency and (min_price_value is not None):
                parse_ok = 1
        except Exception as e:
            errors += 1
            notes = repr(e)

        payload = {
            "provider": "tripcom",
            "origin": origin,
            "destination": destination,
            "route_id": route_id,
            "url": url,
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

    return {"run_date": run_date, "inserted": inserted, "errors": errors, "max_routes": len(routes)}
PY
echo "[OK] wrote: src/travel_tracker/pipelines/flights_snapshot.py"

# 4) flights_main (UNIFIED CLI; keeps --force)
cat > src/travel_tracker/flights_main.py <<'PY'
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

from travel_tracker.pipelines.flights_snapshot import run_flights


def _today() -> str:
    return date.today().isoformat()


def main() -> int:
    p = argparse.ArgumentParser(prog="travel_price_tracker flights")
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
            f"- routes: {result['max_routes']}",
            "",
            "Raw HTML: data/raw/<run_date>/flights/<ORIGIN>/<DEST>/<ROUTE_ID>.html",
        ]) + "\n",
        encoding="utf-8",
    )

    print(f"[OK] {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
echo "[OK] wrote: src/travel_tracker/flights_main.py"

python3 -m py_compile src/travel_tracker/sources/flights/tripcom.py
python3 -m py_compile src/travel_tracker/sources/flights/tripcom_pw.py
python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
python3 -m py_compile src/travel_tracker/flights_main.py
echo "[OK] py_compile passed (flights unified)"
