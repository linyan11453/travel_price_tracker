#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# backup
ts="$(date +%Y%m%d_%H%M%S)"
cp -f src/travel_tracker/pipelines/daily_snapshot.py "src/travel_tracker/pipelines/daily_snapshot.py.bak_${ts}"
echo "[OK] Backup: src/travel_tracker/pipelines/daily_snapshot.py.bak_${ts}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/daily_snapshot.py")
s = p.read_text(encoding="utf-8")

# 1) 把 for city_code, c in grouped.items(): 改成 for d in destinations:
pat = r"\n(?P<indent>[ \t]*)for\s+city_code\s*,\s*c\s+in\s+grouped\.items\(\)\s*:\s*\n"
m = re.search(pat, s)
if not m:
    raise SystemExit("找不到 `for city_code, c in grouped.items():`（檔案版本不同）。請 grep -n \"grouped.items\" daily_snapshot.py 我再給你精準 patch。")

indent = m.group("indent")

replacement = (
    "\n" + indent + "for d in destinations:\n"
    + indent + "    city_code = getattr(d, 'id', '')\n"
    + indent + "    city_name_zh = getattr(d, 'name_zh', '')\n"
    + indent + "    c = grouped.get(city_code) or {'city_name_zh': city_name_zh, 'news': [], 'weather': [], 'safety': []}\n"
    + indent + "    # 若 DB 有資料，仍以 DB 的 city_name_zh 為主；否則用 destinations 的\n"
    + indent + "    c['city_name_zh'] = c.get('city_name_zh') or city_name_zh\n"
)

s2 = re.sub(pat, replacement, s, count=1)
p.write_text(s2, encoding="utf-8")
print("[OK] Patched: daily report renders all destinations (including empty ones).")
PY

echo "[OK] Patch applied."
echo ""
echo "Now run (limit 台北、曼谷) and verify headers:"
TRAVEL_LIMIT_CITIES="台北,曼谷" TRAVEL_REQUIRE_CITY_MATCH=1 poetry run python -m travel_tracker.main daily --force
echo ""
grep -n "^## " reports/daily/daily_2025-12-15.md || true
