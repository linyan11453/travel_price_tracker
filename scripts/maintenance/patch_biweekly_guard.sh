#!/usr/bin/env bash
set -euo pipefail

TARGET="src/travel_tracker/pipelines/biweekly_report.py"
[ -f "$TARGET" ] || { echo "[ERR] $TARGET not found"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
cp "$TARGET" "${TARGET}.bak_${TS}"
echo "[OK] Backup: ${TARGET}.bak_${TS}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/biweekly_report.py")
s = p.read_text(encoding="utf-8")

# idempotent
if "TRAVEL_LIMIT_CITIES" in s and "Refuse to run biweekly" in s:
    print("[OK] Guard already exists, skip.")
    raise SystemExit(0)

# ensure import os
if re.search(r"^\s*import\s+os\s*$", s, flags=re.M) is None:
    m = re.search(r"(?m)^(from .*?\n|import .*?\n)+\n", s)
    if m:
        s = s[:m.end()] + "import os\n" + s[m.end():]
    else:
        s = "import os\n" + s

# find run_biweekly definition
m = re.search(r"(?m)^(?P<indent>\s*)def\s+run_biweekly\s*\(", s)
if not m:
    raise SystemExit("找不到 def run_biweekly(...). 請 grep -n \"def run_biweekly\" biweekly_report.py")

indent = m.group("indent")
insert_at = m.end()

# insert after function signature line (after first ':')
# locate the ':' that ends the def line (same line)
line_start = s.rfind("\n", 0, insert_at) + 1
line_end = s.find("\n", insert_at)
if line_end == -1:
    line_end = len(s)
def_line = s[line_start:line_end]
if ":" not in def_line:
    raise SystemExit("run_biweekly def line seems unusual (missing ':'). Please paste the top of run_biweekly.")

# insert guard after the def line newline
guard_pos = line_end + 1

guard = (
    f"{indent}    # Refuse to run biweekly in limited-city mode (safety guard)\n"
    f"{indent}    limit_raw = os.getenv('TRAVEL_LIMIT_CITIES', '').strip()\n"
    f"{indent}    if limit_raw:\n"
    f"{indent}        raise SystemExit(\n"
    f"{indent}            f\"[GUARD] biweekly is disabled when TRAVEL_LIMIT_CITIES is set: {limit_raw}. \"\n"
    f"{indent}            f\"Unset TRAVEL_LIMIT_CITIES to run full biweekly.\" \n"
    f"{indent}        )\n\n"
)

s = s[:guard_pos] + guard + s[guard_pos:]
p.write_text(s, encoding="utf-8")
print("[OK] Patched biweekly_report.py: guard added.")
PY

echo "[OK] Guard installed."
echo ""
echo "Test (should FAIL):"
TRAVEL_LIMIT_CITIES="台北,曼谷" poetry run python -m travel_tracker.main biweekly --force || true
echo ""
echo "Test (should PASS):"
poetry run python -m travel_tracker.main biweekly --force
