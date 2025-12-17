#!/usr/bin/env bash
set -euo pipefail

BK="_migrated/fix_flights_snapshot_defaults_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"
cp src/travel_tracker/pipelines/flights_snapshot.py "$BK/flights_snapshot.py.bak"
echo "[OK] backup -> $BK/flights_snapshot.py.bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")

lines = s.splitlines(True)

# 找 routes 的迴圈行（常見：for rt in routes: / for route in routes:）
loop_idx = None
for i, line in enumerate(lines):
    if re.search(r'^\s*for\s+\w+\s+in\s+routes\s*:\s*$', line):
        loop_idx = i
        break

if loop_idx is None:
    raise SystemExit("找不到 `for <x> in routes:`；請先 grep -n \"in routes\" src/travel_tracker/pipelines/flights_snapshot.py")

indent = re.match(r'^(\s*)', lines[loop_idx]).group(1) + "    "

block = (
    f"{indent}# Defaults per-route (avoid UnboundLocalError when fetch/parse fails)\n"
    f"{indent}status_code = None\n"
    f"{indent}parse_ok = 0\n"
    f"{indent}min_price_currency = None\n"
    f"{indent}min_price_value = None\n"
    f"{indent}error = None\n\n"
)

# 如果已經插過就不重複插入
for j in range(loop_idx+1, min(loop_idx+12, len(lines))):
    if "Defaults per-route" in lines[j]:
        print("[OK] defaults block already present; skip")
        break
else:
    lines.insert(loop_idx + 1, block)
    s2 = "".join(lines)
    p.write_text(s2, encoding="utf-8")
    print("[OK] inserted defaults block after routes loop")
PY

python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
echo "[OK] py_compile passed"
