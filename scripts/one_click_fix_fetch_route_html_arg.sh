#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="src/travel_tracker/pipelines/flights_snapshot.py"
test -f "$TARGET" || { echo "[ERR] missing $TARGET"; exit 1; }

BK="_migrated/fix_fetch_route_html_arg_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"
cp "$TARGET" "$BK/$(basename "$TARGET").bak"
echo "[OK] backup -> $BK/$(basename "$TARGET").bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")

before = s

# 1) 常見關鍵字呼叫（你目前看到的）
s = re.sub(
    r"fetch_route_html\(\s*client\s*=\s*client\s*,\s*run_date\s*=\s*run_date\s*,\s*route\s*=\s*rt\s*,\s*raw_dir\s*=\s*ddir\s*\)",
    "fetch_route_html(client=client, route=rt, raw_dir=ddir)",
    s,
    count=1
)

# 2) 容錯：run_date 位置可能不同
s = re.sub(
    r"fetch_route_html\(\s*client\s*=\s*client\s*,\s*route\s*=\s*rt\s*,\s*run_date\s*=\s*run_date\s*,\s*raw_dir\s*=\s*ddir\s*\)",
    "fetch_route_html(client=client, route=rt, raw_dir=ddir)",
    s,
    count=1
)

# 3) 再容錯：可能是 positional + keyword 混用
s = re.sub(
    r"fetch_route_html\(\s*client\s*=\s*client\s*,\s*run_date\s*=\s*run_date\s*,",
    "fetch_route_html(client=client,",
    s,
    count=1
)

if s == before:
    raise SystemExit("[ERR] 找不到需要替換的 fetch_route_html(...) 呼叫；請 grep -n \"fetch_route_html\" flights_snapshot.py 貼我。")

p.write_text(s, encoding="utf-8")
print("[OK] patched flights_snapshot.py: removed run_date kwarg")
PY

echo ""
echo "[VERIFY] current signature:"
poetry run python - <<'PY'
from travel_tracker.sources.flights.tripcom import fetch_route_html
import inspect
print(inspect.signature(fetch_route_html))
PY

echo ""
echo "[OK] done. Now rerun:"
echo "TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=3 TRAVEL_TIMEOUT=12 TRAVEL_RETRIES=0 poetry run python -m travel_tracker.flights_main --force"
