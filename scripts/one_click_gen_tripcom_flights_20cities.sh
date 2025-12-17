#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/config"

# 可選：只生成特定城市（用中文名或 IATA code）
# 例：TRAVEL_LIMIT_CITIES="台北,曼谷" ./scripts/one_click_gen_tripcom_flights_20cities.sh
LIMIT_RAW="${TRAVEL_LIMIT_CITIES:-}"

python3 - <<'PY'
import json, os
from pathlib import Path

root = Path(os.environ.get("ROOT", ".")).resolve()
out  = root / "config" / "flights_tripcom_routes.json"
limit_raw = os.environ.get("LIMIT_RAW","").strip()

origins = [
  ("SIN","新加坡"),
  ("JHB","新山"),
]

# 你的 20 城市（以 IATA/City code 為 key）
# kind = "airport" -> airport-xxx-yyy
# kind = "city"    -> airport-xxx-city-yyy (OSA/TYO)
dests = [
  ("KUL","吉隆坡","airport"),
  ("PEN","濱城","airport"),
  ("SIN","新加坡","airport"),
  ("DPS","峇里島","airport"),
  ("JKT","雅加達","airport"),
  ("HKT","普吉島","airport"),
  ("CNX","清邁","airport"),
  ("BKK","曼谷","airport"),
  ("PQC","富國島","airport"),
  ("SGN","胡志明市","airport"),
  ("MPH","長灘島","airport"),
  ("CEB","宿霧","airport"),
  ("PPS","巴拉望","airport"),
  ("TPE","台北","airport"),
  ("KHH","高雄","airport"),
  ("TNN","台南","airport"),
  ("CTS","北海道","airport"),
  ("OSA","大阪","city"),
  ("TYO","東京","city"),
  ("OKA","沖繩","airport"),
]

# limit 支援：中文名 / IATA code（逗號分隔）
limit_set = set()
if limit_raw:
  for x in [p.strip() for p in limit_raw.split(",") if p.strip()]:
    limit_set.add(x.upper())
    limit_set.add(x)  # 保留中文

def allowed(code:str, name_zh:str) -> bool:
  if not limit_set:
    return True
  return (code.upper() in limit_set) or (name_zh in limit_set)

routes = []
for o_code, o_name in origins:
  for d_code, d_name, kind in dests:
    if not allowed(d_code, d_name):
      continue
    if o_code.upper() == d_code.upper():
      continue

    o = o_code.lower()
    d = d_code.lower()
    if kind == "city":
      url = f"https://www.trip.com/flights/airport-{o}-city-{d}/"
    else:
      url = f"https://www.trip.com/flights/airport-{o}-{d}/"

    routes.append({
      "id": f"TRIPCOM_{o_code}_{d_code}",
      "provider": "tripcom",
      "origin": o_code,
      "destination": d_code,
      "destination_name_zh": d_name,
      "destination_kind": kind,
      "url": url
    })

payload = {
  "meta": {
    "generated_by": "one_click_gen_tripcom_flights_20cities.sh",
    "origins": [{"code": c, "name_zh": n} for c,n in origins],
    "limit": limit_raw or None
  },
  "routes": routes
}

out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"[OK] wrote: {out}")
print(f"[OK] routes: {len(routes)}")
PY
