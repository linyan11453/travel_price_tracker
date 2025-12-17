#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

ts="$(date +%Y%m%d_%H%M%S)"
cp -f src/travel_tracker/pipelines/daily_snapshot.py "src/travel_tracker/pipelines/daily_snapshot.py.bak_${ts}"
echo "[OK] Backup: src/travel_tracker/pipelines/daily_snapshot.py.bak_${ts}"

python3 - <<'PY'
from pathlib import Path

p = Path("src/travel_tracker/pipelines/daily_snapshot.py")
s = p.read_text(encoding="utf-8")

# 找最後一段 sections -> repo.close()（通常只有一段）
idx_sections = s.rfind("sections = []")
idx_close = s.rfind("repo.close()")

if idx_sections == -1 or idx_close == -1 or idx_close < idx_sections:
    raise SystemExit("找不到 sections = [] 或 repo.close()（或順序不對）。請 grep -n \"sections = \\[\\]\" 與 \"repo.close\" daily_snapshot.py")

# 取得 sections 那行的縮排
line_start = s.rfind("\n", 0, idx_sections) + 1
indent = ""
while line_start + len(indent) < len(s) and s[line_start + len(indent)] in (" ", "\t"):
    indent += s[line_start + len(indent)]

# 用同樣縮排重建「產報告 sections」區塊（保留 repo.close() 之後的 return）
new_block = f"""{indent}sections = []
{indent}for d in destinations:
{indent}    city_code = getattr(d, "id", "")
{indent}    city_name_zh = getattr(d, "name_zh", "")
{indent}    c = grouped.get(city_code) or {{"city_name_zh": city_name_zh, "news": [], "weather": [], "safety": []}}
{indent}    # 確保 key 存在
{indent}    c.setdefault("news", [])
{indent}    c.setdefault("weather", [])
{indent}    c.setdefault("safety", [])
{indent}    c["city_name_zh"] = c.get("city_name_zh") or city_name_zh

{indent}    body = []
{indent}    body.append(f"### News (Top {{TOP_NEWS}})")
{indent}    body.append(_fmt_items(c["news"], TOP_NEWS))
{indent}    body.append("")
{indent}    body.append(f"### Weather (Top {{TOP_WEATHER}})")
{indent}    body.append(_fmt_items(c["weather"], TOP_WEATHER))
{indent}    body.append("")
{indent}    body.append(f"### Safety (Top {{TOP_SAFETY}})")
{indent}    body.append(_fmt_items(c["safety"], TOP_SAFETY))

{indent}    sections.append({{"h2": f"{{city_code}} {{c['city_name_zh']}}", "body": "\\n".join(body)}})

"""

# 用切片把 sections 區塊整段替換到 repo.close() 前一行
before = s[:idx_sections]
after = s[idx_close:]  # 從 repo.close() 開始保留
p.write_text(before + new_block + after, encoding="utf-8")
print("[OK] Patched daily_snapshot.py: report now renders all destinations (including empty).")
PY

echo "[OK] Running (limit 台北、曼谷) ..."
TRAVEL_LIMIT_CITIES="台北,曼谷" TRAVEL_REQUIRE_CITY_MATCH=1 \
  poetry run python -m travel_tracker.main daily --force

echo ""
echo "===== HEADERS ====="
grep -n "^## " reports/daily/daily_2025-12-15.md || true
