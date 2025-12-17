#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="src/travel_tracker/pipelines/flights_snapshot.py"
test -f "$TARGET" || { echo "[ERR] missing $TARGET"; exit 1; }

BK="_migrated/fix_flights_snapshot_signature_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"
cp "$TARGET" "$BK/$(basename "$TARGET").bak"
echo "[OK] backup -> $BK/$(basename "$TARGET").bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")
before = s

# 把舊介面：fetch_route_html(client=client, route=rt, raw_dir=ddir)
# 改成新介面：fetch_route_html(client=client, url=rt.url, raw_path=ddir / f"{rt.route_id}.html")
#（用 inline raw_path，避免插入多行造成 patch 失敗）

patterns = [
    r"fetch_route_html\(\s*client\s*=\s*client\s*,\s*route\s*=\s*rt\s*,\s*raw_dir\s*=\s*ddir\s*\)",
    r"fetch_route_html\(\s*client\s*=\s*client\s*,\s*raw_dir\s*=\s*ddir\s*,\s*route\s*=\s*rt\s*\)",
    r"fetch_route_html\(\s*client\s*=\s*client\s*,\s*route\s*=\s*rt\s*,\s*raw_path\s*=\s*ddir\s*\)",  # 有人寫錯 raw_path
]

repl = r'fetch_route_html(client=client, url=getattr(rt,"url",""), raw_path=(ddir / f"{getattr(rt,"route_id", getattr(rt,"id","route"))}.html"))'

replaced = False
for pat in patterns:
    if re.search(pat, s):
        s = re.sub(pat, repl, s, count=1)
        replaced = True
        break

# 有些版本寫成 res = fetch_route_html(...) / html_bytes = fetch_route_html(...)
# 不管左邊是什麼，重點是把呼叫改掉；上面已處理。

if not replaced:
    # 再試一次：直接把關鍵字 route=rt / raw_dir=ddir 轉掉（更寬鬆）
    s2 = re.sub(r"route\s*=\s*rt\s*,\s*raw_dir\s*=\s*ddir", r'url=getattr(rt,"url",""), raw_path=(ddir / f"{getattr(rt,"route_id", getattr(rt,"id","route"))}.html")', s, count=1)
    if s2 == s:
        raise SystemExit('[ERR] 找不到 fetch_route_html(...) 呼叫可替換；請執行：grep -n "fetch_route_html" src/travel_tracker/pipelines/flights_snapshot.py')
    s = s2

p.write_text(s, encoding="utf-8")
print("[OK] patched flights_snapshot.py: fetch_route_html() call now uses url/raw_path")
PY

echo ""
echo "[VERIFY] import + signature:"
poetry run python - <<'PY'
from travel_tracker.sources.flights.tripcom import fetch_route_html
import inspect
print("fetch_route_html signature =", inspect.signature(fetch_route_html))
PY

echo ""
echo "[NEXT] Run (first 3 routes, PW on):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=3 TRAVEL_TIMEOUT=12 TRAVEL_RETRIES=0 poetry run python -m travel_tracker.flights_main --force'
