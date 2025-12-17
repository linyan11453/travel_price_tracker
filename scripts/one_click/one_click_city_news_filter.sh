#!/usr/bin/env bash
set -euo pipefail

# 1) sanity check: must be project root
if [ ! -f "pyproject.toml" ]; then
  echo "[ERR] pyproject.toml not found. Please cd into travel_price_tracker/ first."
  exit 1
fi

TARGET="src/travel_tracker/pipelines/daily_snapshot.py"
if [ ! -f "$TARGET" ]; then
  echo "[ERR] $TARGET not found."
  exit 1
fi

# 2) backup
TS="$(date +%Y%m%d_%H%M%S)"
cp "$TARGET" "${TARGET}.bak_${TS}"
echo "[OK] Backup: ${TARGET}.bak_${TS}"

# 3) patch (idempotent)
python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/daily_snapshot.py")
s = p.read_text(encoding="utf-8")

# If already present, do nothing
if "CITY_NEWS_KEYWORDS" in s and "_filter_city_news" in s:
    print("[SKIP] City news filter already present.")
else:
    pos = s.find("def _fmt_items")
    if pos == -1:
        raise SystemExit("找不到 def _fmt_items，請貼 daily_snapshot.py 前 200 行我再給你精準 patch。")

    inject = r'''
# --- City-level filter for NEWS (report only): must match city keywords, otherwise skip ---
CITY_NEWS_KEYWORDS = {
    "KUL": ["kuala lumpur", "kl", "putrajaya", "selangor", "petaling jaya", "pj", "吉隆坡"],
    "PEN": ["penang", "george town", "georgetown", "seberang perai", "butterworth", "檳城", "槟城"],

    "SIN": ["singapore", "新加坡"],
    "JKT": ["jakarta", "雅加达", "雅加達"],
    "DPS": ["bali", "denpasar", "峇里島", "巴厘", "登巴薩"],
    "HKT": ["phuket", "普吉"],
    "CNX": ["chiang mai", "清邁"],
    "BKK": ["bangkok", "曼谷"],

    "PQC": ["phu quoc", "富國", "富国"],
    "SGN": ["ho chi minh", "saigon", "胡志明", "西贡", "西貢"],

    "MPH": ["boracay", "長灘", "长滩"],
    "CEB": ["cebu", "宿霧", "宿雾"],
    "PPS": ["palawan", "puerto princesa", "巴拉望", "巴拉望島", "公主港"],

    "TPE": ["taipei", "臺北", "台北", "new taipei", "新北", "keelung", "基隆"],
    "KHH": ["kaohsiung", "高雄"],
    "TNN": ["tainan", "臺南", "台南"],

    "CTS": ["hokkaido", "sapporo", "北海道", "札幌"],
    "OSA": ["osaka", "大阪"],
    "TYO": ["tokyo", "東京"],
    "OKA": ["okinawa", "naha", "沖繩", "冲绳", "那覇", "那霸"],
}

def _filter_city_news(city_code: str, items: list[dict]) -> list[dict]:
    kws = CITY_NEWS_KEYWORDS.get(city_code)
    if not kws:
        # 若你要「所有城市都必須符合城市條件」：把這行改成 `return []`
        return items

    kws_l = [k.lower() for k in kws]

    kept = []
    for it in items:
        title = (it.get("title") or "").lower()
        url = (it.get("url") or "").lower()
        if any(k in title for k in kws_l) or any(k in url for k in kws_l):
            kept.append(it)

    # 不做 fallback：只符合國家但不符合城市 -> 直接跳過
    return kept
'''
    s2 = s[:pos] + inject + "\n\n" + s[pos:]

    m = re.search(r"^(?P<indent>\s*)c\s*=\s*by_city\[\s*city_code\s*\]\s*$", s2, flags=re.M)
    if not m:
        raise SystemExit("找不到 `c = by_city[city_code]` 這行。請 grep -n \"by_city\\[city_code\\]\" daily_snapshot.py 我再給你精準 patch。")

    indent = m.group("indent")
    insert_at = m.end()

    s2 = s2[:insert_at] + f"\n{indent}# City-level news filter (report only)\n{indent}c[\"news\"] = _filter_city_news(city_code, c.get(\"news\", []))\n" + s2[insert_at:]

    p.write_text(s2, encoding="utf-8")
    print("[OK] Applied: city-level NEWS filter (no fallback).")
PY

# 4) run daily (force)
poetry run python -m travel_tracker.main daily --force

# 5) quick verify for KUL/PEN
echo ""
echo "===== VERIFY (KUL) ====="
grep -n "## KUL" -n reports/daily/daily_2025-12-15.md -A 25 || true
echo ""
echo "===== VERIFY (PEN) ====="
grep -n "## PEN" -n reports/daily/daily_2025-12-15.md -A 25 || true

echo "[DONE] one_click_city_news_filter.sh"
