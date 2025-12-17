#!/usr/bin/env bash
set -euo pipefail

BK="_migrated/fix_flights_snapshot_syntax_v2_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"

cp src/travel_tracker/pipelines/flights_snapshot.py "$BK/flights_snapshot.py.bak"
echo "[OK] backup -> $BK/flights_snapshot.py.bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
lines = p.read_text(encoding="utf-8").splitlines(True)

fixed = 0
for i, line in enumerate(lines):
    if "status_code=status_code" not in line:
        continue

    # 盡量抓出 getattr(XXX, ...) 的 XXX 當作變數名（raw / obj / res 等）
    m = re.search(r"getattr\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*['\"]status['\"]", line)
    var = m.group(1) if m else "obj"

    indent = re.match(r"^(\s*)", line).group(1)
    lines[i] = (
        f'{indent}status_code = getattr({var}, "status_code", None) or '
        f'getattr({var}, "status", None) or getattr({var}, "code", None)\n'
    )
    fixed += 1

out = "".join(lines)
p.write_text(out, encoding="utf-8")
print(f"[OK] fixed broken status_code lines: {fixed}")
PY

python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
echo "[OK] py_compile passed"
