#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p data

# 1) 建立/覆蓋 城市關鍵字設定
cat > data/city_keywords.json <<'JSON'
{
  "TPE": {
    "news": ["台北", "臺北", "Taipei"],
    "weather": ["臺北市", "台北市", "新北市", "基隆市", "Taipei"]
  },
  "BKK": {
    "news": ["曼谷", "Bangkok", "Krung Thep"],
    "weather": ["Bangkok", "กรุงเทพ", "曼谷"]
  },
  "KHH": {
    "news": ["高雄", "Kaohsiung"],
    "weather": ["高雄市", "Kaohsiung"]
  },
  "TNN": {
    "news": ["台南", "臺南", "Tainan"],
    "weather": ["臺南市", "台南市", "Tainan"]
  },
  "KUL": {
    "news": ["Kuala Lumpur", "KL", "吉隆坡"],
    "weather": ["Kuala Lumpur", "吉隆坡"]
  },
  "PEN": {
    "news": ["Penang", "George Town", "檳城", "槟城", "濱城"],
    "weather": ["Penang", "George Town", "檳城", "槟城", "濱城"]
  }
}
JSON

# 2) Patch daily_snapshot.py：加入城市關鍵字過濾（嚴格模式預設開）
python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/daily_snapshot.py")
s = p.read_text(encoding="utf-8")

if "TRAVEL_REQUIRE_CITY_MATCH" in s and "city_keywords.json" in s:
    print("[SKIP] daily_snapshot.py already patched for city keyword filtering.")
    raise SystemExit(0)

# 找插入點：在 bundle = load_sources(...) 之後插入
m = re.search(r"\bbundle\s*=\s*load_sources\([^\)]*\)\s*\n", s)
if not m:
    raise SystemExit("找不到 `bundle = load_sources(...)`，請 grep -n \"load_sources\" daily_snapshot.py 我再給你精準 patch。")

insert_at = m.end()

block = r'''
    # -----------------------------
    # City keyword filtering (strict)
    # -----------------------------
    import os, json

    require_city_match = os.getenv("TRAVEL_REQUIRE_CITY_MATCH", "1").strip() not in {"0","false","False"}
    kw_path = os.getenv("TRAVEL_CITY_KEYWORDS", "data/city_keywords.json")
    city_kw = {}
    try:
        kw_file = Path(kw_path)
        if kw_file.exists():
            city_kw = json.loads(kw_file.read_text(encoding="utf-8"))
    except Exception:
        city_kw = {}

    def _match_city_kw(city_code: str, kind: str, title: str, url: str) -> bool:
        """
        kind: news/weather/safety
        規則：
          - strict(require_city_match=1) 時：該 city 若沒有 keywords -> 直接視為不匹配（跳過）
          - 有 keywords -> title/url 任一包含關鍵字即匹配
        """
        city_code = (city_code or "").upper()
        kw = (city_kw.get(city_code, {}) or {}).get(kind, []) or []
        if require_city_match and not kw:
            return False
        hay = f"{title or ''}\n{url or ''}"
        return any(k and k in hay for k in kw) if kw else True
'''
s2 = s[:insert_at] + block + s[insert_at:]

# 3) 將 insert_signal 前加上過濾判斷（news/weather/safety）
def add_guard(kind: str) -> str:
    # 找到 repo.insert_signal("signals_xxx", ... it.title, it.url, it.published_at)
    pat = rf"repo\.insert_signal\(\s*\"signals_{kind}\"\s*,\s*run_date\s*,\s*d\.id\s*,\s*d\.name_zh\s*,\s*sid\s*,\s*it\.title\s*,\s*it\.url\s*,\s*it\.published_at\s*\)"
    if not re.search(pat, s2):
        return s2  # 不強行破壞
    return re.sub(
        pat,
        rf'''if _match_city_kw(d.id, "{kind}", it.title, it.url):
            repo.insert_signal("signals_{kind}", run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)''',
        s2,
        count=1
    )

s3 = s2
for kind in ("news", "weather", "safety"):
    s3 = add_guard(kind)

p.write_text(s3, encoding="utf-8")
print("[OK] Patched daily_snapshot.py: strict city keyword filtering enabled.")
PY

echo "[OK] one_click_city_keywords_filter.sh applied."
echo ""
echo "Run example (limit to 台北、曼谷 for speed):"
echo 'TRAVEL_LIMIT_CITIES="台北,曼谷" TRAVEL_REQUIRE_CITY_MATCH=1 poetry run python -m travel_tracker.main daily --force'
