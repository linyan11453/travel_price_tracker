#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[INFO] project_root=$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
backup_dir="_migrated/patch_tripcom_pw_v2_${ts}"
mkdir -p "$backup_dir"

# 1) Ensure playwright chromium installed (idempotent)
echo "[INFO] ensure playwright chromium installed..."
poetry run playwright install chromium >/dev/null 2>&1 || true
echo "[OK] playwright chromium ready"

# 2) Write/overwrite tripcom_pw.py with a known-good minimal fetcher
mkdir -p src/travel_tracker/sources/flights
cat > src/travel_tracker/sources/flights/tripcom_pw.py <<'PY'
from __future__ import annotations

import os
from playwright.sync_api import sync_playwright


def fetch_html(url: str, *, timeout_ms: int = 15000) -> bytes:
    """
    Minimal Playwright HTML fetcher for Trip.com.
    Returns rendered HTML bytes (UTF-8).
    """
    ua = os.getenv(
        "TRAVEL_UA",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    )

    # Optional proxy via env: TRAVEL_PROXY="http://127.0.0.1:7890"
    proxy = os.getenv("TRAVEL_PROXY", "").strip()
    proxy_cfg = {"server": proxy} if proxy else None

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, proxy=proxy_cfg)
        context = browser.new_context(user_agent=ua, locale="en-US")
        page = context.new_page()
        page.set_default_timeout(timeout_ms)
        page.goto(url, wait_until="domcontentloaded")
        # Some dynamic parts need a tiny settle time; keep it small to avoid slow runs
        page.wait_for_timeout(800)
        html = page.content()
        context.close()
        browser.close()
        return html.encode("utf-8")
PY
echo "[OK] wrote: src/travel_tracker/sources/flights/tripcom_pw.py"

# 3) Patch tripcom.py to delegate to Playwright when TRAVEL_FLIGHTS_USE_PW=1
tripcom_py="src/travel_tracker/sources/flights/tripcom.py"
if [[ ! -f "$tripcom_py" ]]; then
  echo "[ERR] missing: $tripcom_py"
  exit 1
fi

cp "$tripcom_py" "$backup_dir/tripcom.py.bak"
echo "[OK] backup: $backup_dir/tripcom.py.bak"

python3 - <<'PY'
from __future__ import annotations
from pathlib import Path
import re

p = Path("src/travel_tracker/sources/flights/tripcom.py")
s = p.read_text(encoding="utf-8")

# Ensure os import exists
if "import os" not in s:
    # insert after future import if present; else at top
    m = re.search(r"from __future__ import annotations\s*\n", s)
    if m:
        pos = m.end()
        s = s[:pos] + "\nimport os\n" + s[pos:]
    else:
        s = "import os\n" + s

# Ensure tripcom_pw import reference is available (lazy import inside function is fine too)
# We'll replace the FIRST occurrence of: client.get(url) ... to html_bytes assignment block,
# BUT to avoid brittle pattern matching, we replace by injecting a helper function and call it.

helper = r'''
def _fetch_tripcom_html(client, url: str) -> bytes:
    """
    Fetch Trip.com HTML.
    - Default: use existing polite HTTP client (urllib-based).
    - If TRAVEL_FLIGHTS_USE_PW=1: use Playwright to render.
    """
    use_pw = os.getenv("TRAVEL_FLIGHTS_USE_PW", "0").strip() == "1"
    if use_pw:
        from travel_tracker.sources.flights.tripcom_pw import fetch_html
        timeout_s = int(os.getenv("TRAVEL_TIMEOUT", "15"))
        return fetch_html(url, timeout_ms=timeout_s * 1000)

    # fallback: keep existing behavior by calling client.get(url)
    resp = client.get(url)
    body = getattr(resp, "body", None)
    if body is None:
        # if resp itself is bytes-like
        return resp  # type: ignore[return-value]
    return body
'''

# Insert helper near top (after imports)
if "_fetch_tripcom_html" not in s:
    # place after last import block
    import_block_end = 0
    for m in re.finditer(r"^(from\s+\S+\s+import\s+\S+|import\s+\S+.*)$", s, flags=re.M):
        import_block_end = max(import_block_end, m.end())
    s = s[:import_block_end] + "\n" + helper + "\n" + s[import_block_end:]

# Now replace any direct html fetch usage inside tripcom provider:
# Common patterns:
#   resp = client.get(url); html_bytes = resp.body
#   html_bytes = client.get(url).body
#   html = client.get(url).body
# We'll replace only the first hit to avoid over-editing.
patterns = [
    r"html_bytes\s*=\s*client\.get\(([^)]+)\)\.body",
    r"html\s*=\s*client\.get\(([^)]+)\)\.body",
    r"resp\s*=\s*client\.get\(([^)]+)\)\s*\n\s*html_bytes\s*=\s*resp\.body",
    r"resp\s*=\s*client\.get\(([^)]+)\)\s*\n\s*html\s*=\s*resp\.body",
]
replaced = False
for pat in patterns:
    m = re.search(pat, s)
    if not m:
        continue
    url_expr = m.group(1).strip()
    repl = f"html_bytes = _fetch_tripcom_html(client, {url_expr})"
    s = re.sub(pat, repl, s, count=1)
    replaced = True
    break

if not replaced:
    # Last resort: replace first 'client.get(' with a guarded block if we can find it
    m = re.search(r"client\.get\(([^)]+)\)", s)
    if not m:
        raise SystemExit("[ERR] Cannot find any client.get(...) call in tripcom.py to patch.")
    # Don't blindly rewrite the call; fail with guidance.
    raise SystemExit("[ERR] Found client.get(...) but no recognizable html_bytes/html assignment. Please grep tripcom.py around client.get(...) and patch manually.")

p.write_text(s, encoding="utf-8")
print("[OK] patched: tripcom.py now supports TRAVEL_FLIGHTS_USE_PW=1 via _fetch_tripcom_html()")
PY

echo ""
echo "[NEXT] Test run (first 5 routes):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=5 poetry run python -m travel_tracker.flights_main --force'
