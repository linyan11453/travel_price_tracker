#!/usr/bin/env bash
set -euo pipefail

[ -f pyproject.toml ] || { echo "[ERR] not in project root (pyproject.toml missing)"; exit 1; }

SL="src/travel_tracker/sources_loader.py"
DS="src/travel_tracker/pipelines/daily_snapshot.py"

# 1) restore sources_loader.py from latest backup to remove SyntaxError
latest_bak="$(ls -1t "${SL}".bak_* 2>/dev/null | head -n 1 || true)"
if [ -z "${latest_bak}" ]; then
  echo "[ERR] No backup found for ${SL} (expected ${SL}.bak_*)"
  exit 1
fi

cp "${latest_bak}" "${SL}"
echo "[OK] Restored sources_loader.py from: ${latest_bak}"

# 2) patch daily_snapshot.py right after load_sources(...)
TS="$(date +%Y%m%d_%H%M%S)"
cp "$DS" "${DS}.bak_${TS}"
echo "[OK] Backup: ${DS}.bak_${TS}"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/daily_snapshot.py")
s = p.read_text(encoding="utf-8")

# ensure import os exists
if re.search(r"^\s*import\s+os\s*$", s, flags=re.M) is None:
    # insert after imports block if possible
    m = re.search(r"(?m)^(from .*?\n|import .*?\n)+\n", s)
    if m:
        s = s[:m.end()] + "import os\n" + s[m.end():]
    else:
        s = "import os\n" + s

# ensure helper exists (idempotent)
if "_apply_limit_cities(" not in s:
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
    # place helper before run_daily definition if possible
    m = re.search(r"(?m)^def\s+run_daily\s*\(", s)
    if m:
        s = s[:m.start()] + helper + "\n\n" + s[m.start():]
    else:
        s = helper + "\n\n" + s

# insert filter block immediately after "<var> = load_sources(...)" (idempotent)
if "TRAVEL_LIMIT_CITIES" not in s or "->" not in s:
    pass  # helper already prints it; ignore

if "TRAVEL_LIMIT_CITIES" in s and "load_sources(" in s and "destinations = _apply_limit_cities" in s:
    print("[OK] daily_snapshot.py already contains limit block after load_sources; skip.")
else:
    m = re.search(r"(?m)^(?P<indent>\s*)(?P<var>[A-Za-z_]\w*)\s*=\s*load_sources\s*\(.*$", s)
    if not m:
        raise SystemExit("找不到 `x = load_sources(...)`。請 grep -n \"load_sources\" daily_snapshot.py 我再給你精準 patch。")

    indent = m.group("indent")
    var = m.group("var")

    insert_at = m.end()
    block = (
        f"\n{indent}limit_raw = os.getenv(\"TRAVEL_LIMIT_CITIES\", \"\").strip()\n"
        f"{indent}if limit_raw:\n"
        f"{indent}    {var}.destinations = _apply_limit_cities({var}.destinations, limit_raw)\n"
    )
    s = s[:insert_at] + block + s[insert_at:]
    print(f"[OK] Inserted TRAVEL_LIMIT_CITIES block after: {var} = load_sources(...)")

p.write_text(s, encoding="utf-8")
print("[OK] Patched daily_snapshot.py")
PY

echo "[OK] Run daily with limit: 台北,曼谷"
TRAVEL_LIMIT_CITIES="台北,曼谷" TRAVEL_RPS=2 TRAVEL_TIMEOUT=5 TRAVEL_RETRIES=0 \
  poetry run python -m travel_tracker.main daily --force

echo ""
echo "===== VERIFY HEADERS (should only include Run Summary + TPE + BKK) ====="
grep -n "^## " reports/daily/daily_2025-12-15.md || true

echo "[DONE] fix_limit_cities.sh"
