#!/usr/bin/env bash
set -euo pipefail

BK="_migrated/fix_flights_snapshot_obj_undef_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"
cp src/travel_tracker/pipelines/flights_snapshot.py "$BK/flights_snapshot.py.bak"
echo "[OK] backup -> $BK/flights_snapshot.py.bak"

python3 - <<'PY'
from pathlib import Path

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")

before = s

# 1) 把任何引用 obj 取 status_code 的那行，改成 status_code=None,
s = s.replace(
    'status_code=getattr(obj, "status_code", None) or getattr(obj, "status", None) or getattr(obj, "code", None),',
    'status_code=None,'
)
s = s.replace(
    "status_code=getattr(obj, 'status_code', None) or getattr(obj, 'status', None) or getattr(obj, 'code', None),",
    "status_code=None,"
)

# 2) 保底：如果還有其它 status_code=getattr(obj, 開頭的行，也直接改掉
lines = s.splitlines(True)
out = []
fixed = 0
for line in lines:
    if "status_code=getattr(obj" in line:
        indent = line.split("status_code=")[0]
        out.append(f"{indent}status_code=None,\n")
        fixed += 1
    else:
        out.append(line)

s2 = "".join(out)

if s2 == before:
    print("[WARN] no changes applied (pattern not found). Please grep the status_code line.")
else:
    p.write_text(s2, encoding="utf-8")
    print(f"[OK] patched. fixed_lines={fixed}")
PY

python3 -m py_compile src/travel_tracker/pipelines/flights_snapshot.py
echo "[OK] py_compile passed"
