#!/usr/bin/env bash
set -euo pipefail

[ -f pyproject.toml ] || { echo "[ERR] not in project root (pyproject.toml missing)"; exit 1; }

TARGET="src/travel_tracker/sources_loader.py"
[ -f "$TARGET" ] || { echo "[ERR] $TARGET not found"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
cp "$TARGET" "${TARGET}.bak_${TS}"
echo "[OK] Backup: ${TARGET}.bak_${TS}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/sources_loader.py")
s = p.read_text(encoding="utf-8")

# idempotent
if "TRAVEL_LIMIT_CITIES" in s:
    print("[OK] sources_loader.py already contains TRAVEL_LIMIT_CITIES logic, skip.")
    raise SystemExit(0)

# ensure import os
if re.search(r"^\s*import\s+os\s*$", s, flags=re.M) is None:
    # insert after initial imports block heuristically
    # try after "from __future__" line, else at top
    if re.search(r"^from __future__ import .*?$", s, flags=re.M):
        s = re.sub(r"^(from __future__ import .*?$)",
                   r"\1\n\nimport os",
                   s, count=1, flags=re.M)
    else:
        s = "import os\n" + s

helper = r'''

def _apply_limit_cities(destinations, limit_raw: str):
    """
    TRAVEL_LIMIT_CITIES 支援：
    - 城市代碼：TPE,BKK
    - 中文名：台北,曼谷（用 destination.name_zh 對照）
    - 台/臺同義
    """
    tokens = [t.strip() for t in (limit_raw or "").split(",") if t.strip()]
    if not tokens:
        return destinations

    by_id = {getattr(d, "id", "").upper(): d for d in destinations}
    by_zh = {}
    for d in destinations:
        name = (getattr(d, "name_zh", "") or "").strip()
        if name:
            by_zh[name] = d
            by_zh[name.replace("臺", "台")] = d

    chosen = []
    unknown = []
    for t in tokens:
        key = t.upper()
        if key in by_id:
            chosen.append(by_id[key]); continue
        if t in by_zh:
            chosen.append(by_zh[t]); continue
        t2 = t.replace("臺", "台")
        if t2 in by_zh:
            chosen.append(by_zh[t2]); continue
        unknown.append(t)

    # de-dup keep order
    seen = set()
    uniq = []
    for d in chosen:
        cid = getattr(d, "id", None)
        if cid and cid not in seen:
            uniq.append(d)
            seen.add(cid)

    print(f"[LIMIT] TRAVEL_LIMIT_CITIES={limit_raw} -> {[(getattr(d,'id',''), getattr(d,'name_zh','')) for d in uniq]}")
    if unknown:
        print(f"[WARN] Unknown city tokens ignored: {unknown}")
    return uniq
'''

# place helper near top (after imports)
# insert after first blank line following imports
ins_at = None
m = re.search(r"^(?:from .*?\n|import .*?\n)+\n", s, flags=re.M)
if m:
    ins_at = m.end()
else:
    ins_at = 0
s = s[:ins_at] + helper + "\n" + s[ins_at:]

# inject filtering right after destinations list is built inside load_sources()
# best-effort: find "destinations =" line inside load_sources
m2 = re.search(r"(?m)^(?P<indent>\s*)destinations\s*=\s*.+$", s)
if not m2:
    raise SystemExit("找不到 `destinations = ...`（sources_loader.py 版本不同）。請 grep -n \"destinations\" sources_loader.py 我再給你精準 patch。")

indent = m2.group("indent")
insert_pos = m2.end()

block = (
    f"\n{indent}limit_raw = os.getenv(\"TRAVEL_LIMIT_CITIES\", \"\").strip()\n"
    f"{indent}if limit_raw:\n"
    f"{indent}    destinations = _apply_limit_cities(destinations, limit_raw)\n"
)

s = s[:insert_pos] + block + s[insert_pos:]

p.write_text(s, encoding="utf-8")
print("[OK] Patched sources_loader.py: apply TRAVEL_LIMIT_CITIES right after destinations build.")
PY

echo "[OK] Run daily with limit: 台北,曼谷 (TPE,BKK)"
TRAVEL_LIMIT_CITIES="台北,曼谷" TRAVEL_RPS=2 TRAVEL_TIMEOUT=5 TRAVEL_RETRIES=0 \
  poetry run python -m travel_tracker.main daily --force

echo ""
echo "===== VERIFY HEADERS (should only include TPE/BKK + Run Summary) ====="
grep -n "^## " reports/daily/daily_2025-12-15.md || true

echo ""
echo "===== VERIFY (TPE) ====="
grep -n "## TPE" -n reports/daily/daily_2025-12-15.md -A 40 || true

echo ""
echo "===== VERIFY (BKK) ====="
grep -n "## BKK" -n reports/daily/daily_2025-12-15.md -A 40 || true

echo "[DONE] patch_limit_cities_sources_loader.sh"
