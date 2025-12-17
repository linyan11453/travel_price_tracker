#!/usr/bin/env bash
set -euo pipefail

if [ ! -f "pyproject.toml" ]; then
  echo "[ERR] pyproject.toml not found. Please cd into travel_price_tracker/ first."
  exit 1
fi

TARGET="src/travel_tracker/pipelines/daily_snapshot.py"
if [ ! -f "$TARGET" ]; then
  echo "[ERR] $TARGET not found."
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
cp "$TARGET" "${TARGET}.bak_${TS}"
echo "[OK] Backup: ${TARGET}.bak_${TS}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/daily_snapshot.py")
s = p.read_text(encoding="utf-8")

# Ensure `import os`
if "import os" not in s:
    s = s.replace("from pathlib import Path\n", "from pathlib import Path\nimport os\n", 1)

# Idempotent: if already added, skip
if "_apply_limit_cities(" not in s:
    # Insert helper near the top (before run_daily)
    m = re.search(r"^def\s+run_daily\s*\(", s, flags=re.M)
    if not m:
        raise SystemExit("找不到 def run_daily()。請貼 daily_snapshot.py 前 120 行我再給你精準 patch。")

    helper = r'''
def _apply_limit_cities(destinations, limit_raw: str):
    """
    TRAVEL_LIMIT_CITIES 支援：
    - 城市代碼：TPE,BKK
    - 中文名：台北,曼谷（會用 destination.name_zh 對照）
    - 中英混用皆可
    """
    tokens = [t.strip() for t in (limit_raw or "").split(",") if t.strip()]
    if not tokens:
        return destinations

    # build lookup
    by_id = {d.id.upper(): d for d in destinations}
    by_zh = {}
    for d in destinations:
        name = (getattr(d, "name_zh", "") or "").strip()
        if name:
            by_zh[name] = d
            by_zh[name.replace("臺", "台")] = d  # 台/臺同義

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
        if d.id not in seen:
            uniq.append(d)
            seen.add(d.id)

    print(f"[LIMIT] TRAVEL_LIMIT_CITIES={limit_raw} -> {[(d.id, getattr(d,'name_zh','')) for d in uniq]}")
    if unknown:
        print(f"[WARN] Unknown city tokens ignored: {unknown}")
    return uniq
'''
    s = s[:m.start()] + helper + "\n\n" + s[m.start():]

# Patch destinations loop: after `destinations = ...` add limit apply
# Find a line like: destinations = b.destinations
pat = r"^(?P<indent>\s*)destinations\s*=\s*b\.destinations\s*$"
mm = re.search(pat, s, flags=re.M)
if not mm:
    raise SystemExit("找不到 `destinations = b.destinations`。請 grep -n \"destinations =\" daily_snapshot.py 我再給你精準 patch。")

indent = mm.group("indent")
insert_at = mm.end()

patch = (
    f"\n{indent}limit_raw = os.getenv(\"TRAVEL_LIMIT_CITIES\", \"\").strip()\n"
    f"{indent}if limit_raw:\n"
    f"{indent}    destinations = _apply_limit_cities(destinations, limit_raw)\n"
)
s = s[:insert_at] + patch + s[insert_at:]

p.write_text(s, encoding="utf-8")
print("[OK] Applied: TRAVEL_LIMIT_CITIES support in daily_snapshot.py")
PY

echo "[OK] Running daily with limit: 台北,曼谷"
TRAVEL_LIMIT_CITIES="台北,曼谷" poetry run python -m travel_tracker.main daily --force

echo ""
echo "===== VERIFY (TPE) ====="
grep -n "## TPE" -n reports/daily/daily_2025-12-15.md -A 30 || true

echo ""
echo "===== VERIFY (BKK) ====="
grep -n "## BKK" -n reports/daily/daily_2025-12-15.md -A 30 || true

echo "[DONE] one_click_limit_cities.sh"
