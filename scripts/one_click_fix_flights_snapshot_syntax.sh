#!/usr/bin/env bash
set -euo pipefail

BK="_migrated/fix_flights_snapshot_syntax_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"

cp src/travel_tracker/pipelines/flights_snapshot.py "$BK/flights_snapshot.py.bak"
echo "[OK] backup -> $BK/flights_snapshot.py.bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")
s2 = s

# 1) 修復 normalize 區塊被 regex 弄壞的那行（你現在報錯那個）
s2 = re.sub(
    r'status_code=status_code,\s*"status_code",\s*None\)\s*or\s*getattr\(obj,\s*"status",\s*None\)\s*or\s*getattr\(obj,\s*"code",\s*None\)',
    'status_code = getattr(obj, "status_code", None) or getattr(obj, "status", None) or getattr(obj, "code", None)',
    s2,
)

# 若還有其它變形（保守抓：行內出現 status_code=status_code, "status_code"）
s2 = re.sub(
    r'^\s*status_code=status_code,\s*"status_code",\s*None\)\s*or\s*getattr\(obj,\s*"status",\s*None\)\s*or\s*getattr\(obj,\s*"code",\s*None\)\s*$',
    '        status_code = getattr(obj, "status_code", None) or getattr(obj, "status", None) or getattr(obj, "code", None)',
    s2,
    flags=re.M,
)

# 2) 僅針對 repo.insert_flight_quote(...) 這段做 kwarg 修正（避免再污染 normalize block）
m = re.search(r"(repo\.insert_flight_quote\([\s\S]*?\)\s*)", s2)
if m:
    block = m.group(1)

    def kwfix(text: str, key: str, value: str) -> str:
        # key=xxx（直到逗號或右括號前）
        return re.sub(rf"\b{re.escape(key)}\s*=\s*[^,\n\)]+", f"{key}={value}", text)

    block2 = block
    block2 = kwfix(block2, "status_code", "status_code")
    block2 = kwfix(block2, "parse_ok", "parse_ok")
    block2 = kwfix(block2, "min_price_currency", "min_price_currency")
    block2 = kwfix(block2, "min_price_value", "min_price_value")

    s2 = s2[:m.start(1)] + block2 + s2[m.end(1):]

else:
    print("[WARN] repo.insert_flight_quote(...) block not found; only fixed syntax line.")

if s2 == s:
    print("[WARN] no changes made (maybe already fixed?)")
else:
    p.write_text(s2, encoding="utf-8")
    print("[OK] patched flights_snapshot.py")
PY

# 3) 快速語法檢查
python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
echo "[OK] py_compile passed"
