#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "[STEP] backup data files"
ts="$(date +%Y%m%d_%H%M%S)"
cp -a data/sources.json "data/sources.json.bak_${ts}" 2>/dev/null || true
cp -a data/destinations.json "data/destinations.json.bak_${ts}" 2>/dev/null || true

python3 - <<'PY'
import json
from pathlib import Path

# ---------- helpers ----------
def load_json(path: Path):
    if not path.exists():
        raise SystemExit(f"Missing file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))

def dump_json(path: Path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def ensure_list(root, key):
    if key not in root or not isinstance(root[key], list):
        root[key] = []
    return root[key]

def upsert_by_id(lst, items):
    existing = {x.get("id") for x in lst if isinstance(x, dict)}
    for it in items:
        if it["id"] not in existing:
            lst.append(it)
            existing.add(it["id"])

# ---------- paths ----------
sources_path = Path("data/sources.json")
dest_path = Path("data/destinations.json")

cfg = load_json(sources_path)

# 兼容兩種格式：{news:[...]} 或 {sources:{news:[...]}}
root = cfg.get("sources") if isinstance(cfg, dict) and isinstance(cfg.get("sources"), dict) else cfg
if not isinstance(root, dict):
    raise SystemExit("data/sources.json format unexpected (root is not object).")

news_list = ensure_list(root, "news")
safety_list = ensure_list(root, "safety")
weather_list = ensure_list(root, "weather")  # 先保留；你已有政府氣象源就不硬塞

# ---------- add sources (city-oriented RSS) ----------
# 目標：TRAVEL_REQUIRE_CITY_MATCH=1 時，「title 內一定會常出現 台北/Taipei、曼谷/Bangkok」
ADD_NEWS = [
    {
        "id": "TW_GOOGLE_NEWS_TAIPEI_7D",
        "type": "rss",
        "country": "TW",
        "url": "https://news.google.com/rss/search?q=%E5%8F%B0%E5%8C%97%20OR%20Taipei%20when%3A7d&hl=zh-TW&gl=TW&ceid=TW:zh-Hant",
        "tags": ["news", "city", "taipei"],
        "notes": "城市型新聞（台北/Taipei），用於 TRAVEL_REQUIRE_CITY_MATCH=1"
    },
    {
        "id": "TH_GOOGLE_NEWS_BANGKOK_7D",
        "type": "rss",
        "country": "TH",
        "url": "https://news.google.com/rss/search?q=%E6%9B%BC%E8%B0%B7%20OR%20Bangkok%20when%3A7d&hl=en&gl=TH&ceid=TH:en",
        "tags": ["news", "city", "bangkok"],
        "notes": "城市型新聞（曼谷/Bangkok），用於 TRAVEL_REQUIRE_CITY_MATCH=1"
    },
]

ADD_SAFETY = [
    {
        "id": "TW_GOOGLE_NEWS_TAIPEI_SAFETY_14D",
        "type": "rss",
        "country": "TW",
        "url": "https://news.google.com/rss/search?q=%E5%8F%B0%E5%8C%97%20%E6%B2%BB%E5%AE%89%20OR%20Taipei%20crime%20when%3A14d&hl=zh-TW&gl=TW&ceid=TW:zh-Hant",
        "tags": ["safety", "city", "taipei"],
        "notes": "城市型治安（台北/Taipei crime）"
    },
    {
        "id": "TH_GOOGLE_NEWS_BANGKOK_SAFETY_14D",
        "type": "rss",
        "country": "TH",
        "url": "https://news.google.com/rss/search?q=%E6%9B%BC%E8%B0%B7%20%E6%B2%BB%E5%AE%89%20OR%20Bangkok%20crime%20when%3A14d&hl=en&gl=TH&ceid=TH:en",
        "tags": ["safety", "city", "bangkok"],
        "notes": "城市型治安（曼谷/Bangkok crime）"
    },
]

upsert_by_id(news_list, ADD_NEWS)
upsert_by_id(safety_list, ADD_SAFETY)

# 寫回 sources.json（維持原本結構）
if isinstance(cfg, dict) and isinstance(cfg.get("sources"), dict):
    cfg["sources"] = root
else:
    cfg = root
dump_json(sources_path, cfg)

print("[OK] updated data/sources.json (added TPE/BKK city RSS for news+safety)")

# ---------- add aliases for destinations ----------
if dest_path.exists():
    dest = load_json(dest_path)
    if not isinstance(dest, list):
        raise SystemExit("data/destinations.json format unexpected (should be a list).")

    def add_alias(d, aliases):
        cur = d.get("aliases")
        if cur is None:
            d["aliases"] = []
            cur = d["aliases"]
        if not isinstance(cur, list):
            d["aliases"] = []
            cur = d["aliases"]
        s = set(cur)
        for a in aliases:
            if a and a not in s:
                cur.append(a)
                s.add(a)

    for d in dest:
        if not isinstance(d, dict): 
            continue
        if d.get("id") == "TPE":
            add_alias(d, ["台北", "臺北", "Taipei", "TAIPEI"])
        if d.get("id") == "BKK":
            add_alias(d, ["曼谷", "Bangkok", "BANGKOK", "กรุงเทพ", "Krung Thep"])

    dump_json(dest_path, dest)
    print("[OK] updated data/destinations.json (added aliases for TPE/BKK)")
else:
    print("[WARN] data/destinations.json not found, skipped aliases patch.")
PY

echo "[STEP] quick run (limit 台北,曼谷 + require city match)"
TRAVEL_LIMIT_CITIES="台北,曼谷" TRAVEL_REQUIRE_CITY_MATCH=1 \
  poetry run python -m travel_tracker.main daily

echo ""
echo "===== HEADERS ====="
grep -n "^## " reports/daily/daily_$(date +%F).md || true

echo ""
echo "[DONE] one_click_add_sources_tpe_bkk.sh"
