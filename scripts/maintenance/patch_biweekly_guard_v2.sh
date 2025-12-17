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
if "[GUARD] biweekly is disabled when TRAVEL_LIMIT_CITIES" in s:
    print("[OK] Guard already exists, skip.")
    raise SystemExit(0)

# ensure import os at top-level
if re.search(r"(?m)^\s*import\s+os\s*$", s) is None:
    m = re.search(r"(?m)^(from .*?\n|import .*?\n)+\n", s)
    if m:
        s = s[:m.end()] + "import os\n" + s[m.end():]
    else:
        s = "import os\n" + s

# find run_biweekly def line
m = re.search(r"(?m)^(?P<indent>\s*)def\s+run_biweekly\s*\(.*\)\s*:\s*$", s)
if not m:
    raise SystemExit("找不到 def run_biweekly(...): 請 grep -n \"def run_biweekly\" biweekly_report.py")

indent = m.group("indent")
def_line_end = s.find("\n", m.end())
if def_line_end == -1:
    def_line_end = len(s)

insert_pos = def_line_end + 1

# if immediate docstring exists, insert after it (best practice)
rest = s[insert_pos:]
m2 = re.match(r"(\s*)(\"\"\"|''')", rest)
if m2:
    delim = m2.group(2)
    # find closing delimiter
    close_idx = rest.find(delim, m2.end())
    if close_idx != -1:
        close_idx2 = rest.find("\n", close_idx + len(delim))
        if close_idx2 != -1:
            insert_pos = insert_pos + close_idx2 + 1

guard = (
    f"{indent}    # Refuse to run biweekly in limited-city mode (safety guard)\n"
    f"{indent}    limit_raw = os.getenv('TRAVEL_LIMIT_CITIES', '').strip()\n"
    f"{indent}    if limit_raw:\n"
    f"{indent}        raise SystemExit(\n"
    f"{indent}            f\"[GUARD] biweekly is disabled when TRAVEL_LIMIT_CITIES is set: {{limit_raw}}. \"\n"
    f"{indent}            f\"Unset TRAVEL_LIMIT_CITIES to run full biweekly.\"\n"
    f"{indent}        )\n\n"
)

s = s[:insert_pos] + guard + s[insert_pos:]
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
