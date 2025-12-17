#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
backup_dir="_migrated/patch_httpclient_tripcom_pw_${ts}"
mkdir -p "$backup_dir"

echo "[INFO] project_root=$ROOT"
echo "[INFO] backup_dir=$backup_dir"

# 1) ensure playwright chromium installed (idempotent)
poetry run playwright install chromium >/dev/null 2>&1 || true
echo "[OK] playwright chromium ready"

# 2) ensure tripcom_pw.py exists (write minimal fetcher)
mkdir -p src/travel_tracker/sources/flights
cat > src/travel_tracker/sources/flights/tripcom_pw.py <<'PY'
from __future__ import annotations

import os
from playwright.sync_api import sync_playwright


def fetch_html(url: str, *, timeout_ms: int = 15000) -> bytes:
    ua = os.getenv(
        "TRAVEL_UA",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    )
    proxy = os.getenv("TRAVEL_PROXY", "").strip()
    proxy_cfg = {"server": proxy} if proxy else None

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, proxy=proxy_cfg)
        context = browser.new_context(user_agent=ua, locale="en-US")
        page = context.new_page()
        page.set_default_timeout(timeout_ms)
        page.goto(url, wait_until="domcontentloaded")
        page.wait_for_timeout(800)
        html = page.content()
        context.close()
        browser.close()
        return html.encode("utf-8")
PY
echo "[OK] wrote: src/travel_tracker/sources/flights/tripcom_pw.py"

# 3) patch PoliteHttpClient.get to use Playwright for trip.com when TRAVEL_FLIGHTS_USE_PW=1
py="src/travel_tracker/core/http_client.py"
test -f "$py" || { echo "[ERR] missing $py"; exit 1; }

cp "$py" "$backup_dir/http_client.py.bak"
echo "[OK] backup: $backup_dir/http_client.py.bak"

python3 - <<'PY'
from __future__ import annotations
from pathlib import Path
import re

p = Path("src/travel_tracker/core/http_client.py")
s = p.read_text(encoding="utf-8")

# ensure import os
if re.search(r"^import os\s*$", s, flags=re.M) is None:
    # place after __future__ if exists, else at top
    m = re.search(r"from __future__ import annotations\s*\n", s)
    if m:
        pos = m.end()
        s = s[:pos] + "import os\n" + s[pos:]
    else:
        s = "import os\n" + s

# find def get(...) line
m = re.search(r"^(\s*)def get\([^)]*\):\s*\n", s, flags=re.M)
if not m:
    raise SystemExit("[ERR] cannot find def get(...) in http_client.py")

indent = m.group(1)
start = m.end()

# skip docstring if present
i = start
lines = s[start:].splitlines(True)
consumed = 0
def _strip(l: str) -> str:
    return l.strip()

# find first non-empty line
idx = 0
while idx < len(lines) and _strip(lines[idx]) == "":
    consumed += len(lines[idx]); idx += 1

# if docstring starts
if idx < len(lines) and _strip(lines[idx]).startswith(('"""',"'''")):
    quote = '"""' if _strip(lines[idx]).startswith('"""') else "'''"
    consumed += len(lines[idx]); idx += 1
    while idx < len(lines):
        consumed += len(lines[idx])
        if quote in lines[idx]:
            idx += 1
            break
        idx += 1

insert_at = start + consumed

block = (
    f"{indent}    # Trip.com Playwright override (only when TRAVEL_FLIGHTS_USE_PW=1)\n"
    f"{indent}    if os.getenv('TRAVEL_FLIGHTS_USE_PW', '0').strip() == '1' and ('trip.com' in url):\n"
    f"{indent}        from travel_tracker.sources.flights.tripcom_pw import fetch_html\n"
    f"{indent}        html = fetch_html(url, timeout_ms=int(self.timeout_seconds * 1000))\n"
    f"{indent}        # keep HttpResponse contract so downstream code stays unchanged\n"
    f"{indent}        return HttpResponse(url=url, status=200, headers={{}}, body=html, from_cache=False)\n\n"
)

# prevent double insert
if "Trip.com Playwright override" in s:
    raise SystemExit("[OK] http_client.py already patched; skip.")

s = s[:insert_at] + block + s[insert_at:]
p.write_text(s, encoding="utf-8")
print("[OK] patched: PoliteHttpClient.get() now supports TRAVEL_FLIGHTS_USE_PW=1 for trip.com")
PY

echo ""
echo "[NEXT] Test (first 5 routes):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=5 TRAVEL_TIMEOUT=12 TRAVEL_RETRIES=0 poetry run python -m travel_tracker.flights_main --force'
