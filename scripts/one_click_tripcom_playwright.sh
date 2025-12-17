#!/usr/bin/env bash
set -euo pipefail

# 1) deps
poetry add -q playwright || true
poetry run playwright install chromium

# 2) provider
mkdir -p src/travel_tracker/sources/flights
cat > src/travel_tracker/sources/flights/tripcom_pw.py <<'PY'
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from playwright.sync_api import sync_playwright


@dataclass
class PWPrice:
    ok: bool
    currency: str | None
    value: float | None
    notes: str


PRICE_KEYS = {"price", "minprice", "lowestprice", "fromprice", "amount", "value"}

def _walk(obj: Any, out: list[tuple[str|None, float]]) -> None:
    if isinstance(obj, dict):
        if "currency" in obj and ("amount" in obj or "value" in obj):
            cur = obj.get("currency")
            val = obj.get("amount", obj.get("value"))
            if isinstance(cur, str) and isinstance(val, (int, float)) and val > 0:
                out.append((cur, float(val)))
        for k, v in obj.items():
            lk = str(k).lower()
            if lk in PRICE_KEYS and isinstance(v, (int, float)) and v > 0:
                out.append((None, float(v)))
            _walk(v, out)
    elif isinstance(obj, list):
        for it in obj:
            _walk(it, out)

def fetch_min_price_from_tripcom(url: str, timeout_ms: int = 15000) -> PWPrice:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()

        hits: list[tuple[str|None, float]] = []
        matched = {"count": 0}

        def on_response(resp):
            try:
                rt = resp.request.resource_type
                ct = (resp.headers.get("content-type") or "").lower()
                if rt not in ("xhr", "fetch"):
                    return
                if "application/json" not in ct:
                    return
                # 只挑跟 flights/search/price 相關的 response（可再調整）
                if not re.search(r"(flight|flights|search|price|fare)", resp.url, re.I):
                    return
                data = resp.json()
                matched["count"] += 1
                _walk(data, hits)
            except Exception:
                return

        page.on("response", on_response)

        try:
            page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
            page.wait_for_timeout(4000)  # 等 XHR
        except Exception as e:
            browser.close()
            return PWPrice(False, None, None, f"goto_fail:{type(e).__name__}")

        browser.close()

        if not hits:
            return PWPrice(False, None, None, f"no_json_price_hits resp_json={matched['count']}")
        cur, val = sorted(hits, key=lambda x: x[1])[0]
        return PWPrice(True, cur, val, "ok_from_xhr_json")
PY

echo "[OK] wrote: src/travel_tracker/sources/flights/tripcom_pw.py"

# 3) patch pipeline to use PW when TRAVEL_FLIGHTS_USE_PW=1
p="src/travel_tracker/pipelines/flights_snapshot.py"
cp "$p" "${p}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")

if "TRAVEL_FLIGHTS_USE_PW" in s:
    print("[OK] already patched.")
    raise SystemExit(0)

# 找到 tripcom 取得 html / parse 那段，前面插入 pw 分支（用最保守的文字插入，避免大改）
insert = """
    use_pw = os.environ.get("TRAVEL_FLIGHTS_USE_PW", "").strip() == "1"
"""
if "import os" not in s:
    s = "import os\n" + s

# 放在 run_flights 開頭附近（靠近 max_routes / client 建立前）
m = re.search(r"def run_flights\(", s)
if not m:
    raise SystemExit("cannot find def run_flights in flights_snapshot.py")
pos = s.find("\n", m.start())
s = s[:pos+1] + insert + s[pos+1:]

# 在 tripcom loop 內插入：如果 use_pw 就直接走 pw 抓價
needle = "html_bytes ="
idx = s.find(needle)
if idx == -1:
    raise SystemExit("cannot find html_bytes assignment; open flights_snapshot.py and locate where html is fetched")

block = """
            if use_pw and provider == "tripcom":
                from travel_tracker.sources.flights.tripcom_pw import fetch_min_price_from_tripcom
                pw = fetch_min_price_from_tripcom(url, timeout_ms=int(timeout_seconds * 1000))
                repo.insert_flight_quote(
                    provider=provider,
                    origin=origin,
                    destination=destination,
                    route_id=route_id,
                    status_code=200 if pw.ok else None,
                    parse_ok=1 if pw.ok else 0,
                    min_price_currency=pw.currency,
                    min_price_value=pw.value,
                    notes=pw.notes,
                )
                repo.commit()
                continue

"""
s = s[:idx] + block + s[idx:]

p.write_text(s, encoding="utf-8")
print("[OK] patched flights_snapshot.py: TRAVEL_FLIGHTS_USE_PW=1 enables playwright path")
PY

echo ""
echo "[NEXT] test run (first 5 routes):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=5 poetry run python -m travel_tracker.flights_main --force'
