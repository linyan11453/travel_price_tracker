#!/usr/bin/env bash
set -euo pipefail

BK="_migrated/fix_flights_snapshot_syntax_v3_$(date +%Y%m%d_%H%M%S)"
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
    # 修正：把 "status_code = <expr>" 改成 "status_code=<expr>,"
    # 僅針對我們剛剛 v2 造成的型態（含 getattr）
    if re.search(r'^\s*status_code\s*=\s*getattr\(', line):
        # 轉成 keyword arg
        newline = re.sub(r'^\s*status_code\s*=\s*', '    status_code=', line, count=1)
        # 保留原縮排（不要硬塞 4 空格）
        indent = re.match(r'^(\s*)', line).group(1)
        newline = indent + newline.lstrip()

        # 確保結尾有逗號（在函式參數/字典內常見）
        if not newline.rstrip().endswith(","):
            newline = newline.rstrip() + ",\n"

        lines[i] = newline
        fixed += 1

p.write_text("".join(lines), encoding="utf-8")
print(f"[OK] fixed lines: {fixed}")
PY

python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
echo "[OK] py_compile passed"
