#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
backup_dir="_migrated/patch_httpclient_tripcom_pw_v2_${ts}"
mkdir -p "$backup_dir"

echo "[INFO] project_root=$ROOT"
echo "[INFO] backup_dir=$backup_dir"

# 1) ensure playwright chromium installed (idempotent)
poetry run playwright install chromium >/dev/null 2>&1 || true
echo "[OK] playwright chromium ready"

# 2) ensure tripcom_pw.py exists
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

# 3) patch http_client.py (robustly locate def get signature even if multiline/has -> annotation)
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

if "Trip.com Playwright override" in s:
    print("[OK] http_client.py already patched; skip.")
    raise SystemExit(0)

# ensure import os exists
if re.search(r"^import os\s*$", s, flags=re.M) is None:
    m = re.search(r"from __future__ import annotations\s*\n", s)
    if m:
        pos = m.end()
        s = s[:pos] + "import os\n" + s[pos:]
    else:
        s = "import os\n" + s

# locate "def get(" (allow spaces)
m = re.search(r"^(\s*)def\s+get\s*\(", s, flags=re.M)
if not m:
    # print some hints for user
    raise SystemExit("[ERR] cannot find 'def get(' in http_client.py. Please run: grep -n \"def \" src/travel_tracker/core/http_client.py | head -n 80")

indent = m.group(1)
sig_start = m.start()

# scan forward to find the ':' that ends the signature (paren-balanced)
paren = 0
end_colon = None
i = sig_start
while i < len(s):
    ch = s[i]
    if ch == "(":
        paren += 1
    elif ch == ")":
        paren = max(paren - 1, 0)
    elif ch == ":" and paren == 0:
        end_colon = i
        break
    i += 1

if end_colon is None:
    raise SystemExit("[ERR] cannot find end of function signature ':' for get().")

# move to next newline after signature
nl = s.find("\n", end_colon)
if nl == -1:
    raise SystemExit("[ERR] unexpected EOF after get() signature.")
insert_at = nl + 1

# skip blank lines
while insert_at < len(s) and s[insert_at] in ("\n", "\r"):
    insert_at += 1

# skip docstring if present
rest = s[insert_at:]
if rest.lstrip().startswith('"""') or rest.lstrip().startswith("'''"):
    quote = '"""' if rest.lstrip().startswith('"""') else "'''"
    # find docstring start index relative to insert_at
    ds0 = insert_at + rest.find(quote)
    ds1 = s.find(quote, ds0 + 3)
    if ds1 == -1:
        raise SystemExit("[ERR] unterminated docstring in get().")
    ds2 = s.find("\n", ds1 + 3)
    if ds2 == -1:
        raise SystemExit("[ERR] unexpected EOF after docstring.")
    insert_at = ds2 + 1

block = (
    f"{indent}    # Trip.com Playwright override (only when TRAVEL_FLIGHTS_USE_PW=1)\n"
    f"{indent}    if os.getenv('TRAVEL_FLIGHTS_USE_PW', '0').strip() == '1' and ('trip.com' in url):\n"
    f"{indent}        from travel_tracker.sources.flights.tripcom_pw import fetch_html\n"
    f"{indent}        html = fetch_html(url, timeout_ms=int(getattr(self, 'timeout_seconds', 12) * 1000))\n"
    f"{indent}        return HttpResponse(url=url, status=200, headers={{}}, body=html, from_cache=False)\n\n"
)

s = s[:insert_at] + block + s[insert_at:]
p.write_text(s, encoding="utf-8")
print("[OK] patched: PoliteHttpClient.get() supports TRAVEL_FLIGHTS_USE_PW=1 for trip.com")
PY

echo ""
echo "[NEXT] Test (first 5 routes):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=5 TRAVEL_TIMEOUT=12 TRAVEL_RETRIES=0 poetry run python -m travel_tracker.flights_main --force'
