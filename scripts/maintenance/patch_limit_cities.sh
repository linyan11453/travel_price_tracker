#!/usr/bin/env bash
set -euo pipefail

[ -f pyproject.toml ] || { echo "[ERR] not in project root (pyproject.toml missing)"; exit 1; }

TARGET="src/travel_tracker/pipelines/daily_snapshot.py"
[ -f "$TARGET" ] || { echo "[ERR] $TARGET missing"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
cp "$TARGET" "${TARGET}.bak_${TS}"
echo "[OK] Backup: ${TARGET}.bak_${TS}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/daily_snapshot.py")
s = p.read_text(encoding="utf-8")

# ensure import os
if re.search(r"^\s*import\s+os\s*$", s, flags=re.M) is None:
    # insert near top after pathlib import if possible
    s = re.sub(r"^(from\s+pathlib\s+import\s+Path\s*)$",
               r"\1\nimport os",
               s, count=1, flags=re.M)

# helper (idempotent)
if "_apply_limit_cities(" not in s:
    m = re.search(r"^def\s+run_daily\s*\(", s, flags=re.M)
    if not m:
        raise SystemExit("找不到 def run_daily()，請貼 daily_snapshot.py 前 120 行我再給你精準 patch。")

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
    s = s[:m.start()] + helper + "\n\n" + s[m.start():]

# insert limit block before the first `for ... in destinations:`
if "TRAVEL_LIMIT_CITIES" not in s:
    m2 = re.search(r"^(?P<indent>\s*)for\s+\w+\s+in\s+destinations\s*:\s*$", s, flags=re.M)
    if not m2:
        raise SystemExit("找不到 `for x in destinations:`，請 grep -n \"destinations\" daily_snapshot.py 我再給你精準 patch。")

    indent = m2.group("indent")
    block = (
        f"{indent}limit_raw = os.getenv(\"TRAVEL_LIMIT_CITIES\", \"\").strip()\n"
        f"{indent}if limit_raw:\n"
        f"{indent}    destinations = _apply_limit_cities(destinations, limit_raw)\n\n"
    )
    s = s[:m2.start()] + block + s[m2.start():]

p.write_text(s, encoding="utf-8")
print("[OK] Patched daily_snapshot.py: TRAVEL_LIMIT_CITIES enabled (inserted before loop).")
PY

echo "[OK] Run: only 台北、曼谷"
TRAVEL_LIMIT_CITIES="台北,曼谷" poetry run python -m travel_tracker.main daily --force

echo ""
echo "===== VERIFY (TPE) ====="
grep -n "## TPE" -n reports/daily/daily_2025-12-15.md -A 40 || true
echo ""
echo "===== VERIFY (BKK) ====="
grep -n "## BKK" -n reports/daily/daily_2025-12-15.md -A 40 || true

echo "[DONE] patch_limit_cities.sh"
