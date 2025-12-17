#!/usr/bin/env bash
set -euo pipefail

TARGET="src/travel_tracker/main.py"
[ -f "$TARGET" ] || { echo "[ERR] $TARGET not found"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
cp "$TARGET" "${TARGET}.bak_${TS}"
echo "[OK] Backup: ${TARGET}.bak_${TS}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/main.py")
s = p.read_text(encoding="utf-8")

# idempotent
if "[GUARD] biweekly is disabled when TRAVEL_LIMIT_CITIES is set:" in s:
    print("[OK] Guard already exists. Skip.")
    raise SystemExit(0)

# ensure import os
if re.search(r"(?m)^\s*import\s+os\s*$", s) is None:
    m = re.search(r"(?m)^(from .*?\n|import .*?\n)+\n", s)
    if m:
        s = s[:m.end()] + "import os\n" + s[m.end():]
    else:
        s = "import os\n" + s

# find the biweekly command branch
m = re.search(r'(?m)^(?P<indent>\s*)if\s+args\.cmd\s*==\s*["\']biweekly["\']\s*:\s*$', s)
if not m:
    raise SystemExit('找不到 if args.cmd == "biweekly": 請 grep -n "biweekly" src/travel_tracker/main.py')

indent = m.group("indent")
insert_pos = s.find("\n", m.end())
if insert_pos == -1:
    insert_pos = len(s)
else:
    insert_pos += 1

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
print("[OK] Patched main.py: guard inserted into biweekly branch.")
PY

echo ""
echo "Test (should FAIL):"
TRAVEL_LIMIT_CITIES="台北,曼谷" poetry run python -m travel_tracker.main biweekly --force || true

echo ""
echo "Test (should PASS):"
poetry run python -m travel_tracker.main biweekly --force

echo "[DONE] patch_biweekly_guard_main.sh"
