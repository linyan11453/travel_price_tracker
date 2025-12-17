#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."  # repo root

SRC="data/sources.json"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="archive/backups/sources_${TS}.json"

mkdir -p archive/backups
cp "$SRC" "$BAK"
echo "[Backup] $BAK"

poetry run python - <<'PY'
import json
from pathlib import Path

src = Path("data/sources.json")
data = json.loads(src.read_text(encoding="utf-8"))

sources = data.get("sources", {})
news = list(sources.get("news_rss", []) or [])

# CNA 官方 RSS（outbound-feed）對應表
mapping = {
    "SG_CNA_LATEST":    "https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml",
    "SG_CNA_SINGAPORE": "https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml&category=10416",
    "SG_CNA_ASIA":      "https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml&category=6511",
    "SG_CNA_WORLD":     "https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml&category=6311",
    "SG_CNA_BUSINESS":  "https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml&category=6936",
}

kept = []
removed = []
changed = []

for s in news:
    sid = (s.get("id") or "").strip()
    url = (s.get("url") or "").strip()

    # 移除 Straits Times
    if "straitstimes.com" in url or sid.startswith("SG_ST"):
        removed.append((sid, url))
        continue

    # 修正 CNA URL
    if sid in mapping:
        new = mapping[sid]
        if url != new:
            s["url"] = new
            changed.append((sid, url, new))

    kept.append(s)

sources["news_rss"] = kept
data["sources"] = sources
src.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

print("[OK] patched data/sources.json")
print("[REMOVED]", len(removed))
for sid, url in removed:
    print(" -", sid, url)
print("[CHANGED]", len(changed))
for sid, old, new in changed:
    print(" -", sid)
    print("    old:", old)
    print("    new:", new)
PY
