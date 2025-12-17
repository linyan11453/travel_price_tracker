#!/usr/bin/env bash
set -euo pipefail

# Always run from repo root
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[1/6] Install deps (idempotent)"
poetry add feedparser python-dateutil pyyaml >/dev/null 2>&1 || true

echo "[2/6] Create folders"
mkdir -p src/travel_tracker/reporting src/travel_tracker/sources src/travel_tracker/pipelines config

echo "[3/6] Write md helper"
cat > src/travel_tracker/reporting/md.py <<'PY'
from __future__ import annotations
from typing import Iterable, Sequence

def h2(title: str) -> str:
    return f"## {title}\n"

def h3(title: str) -> str:
    return f"### {title}\n"

def p(text: str) -> str:
    return f"{text}\n"

def bullets(items: Iterable[str]) -> str:
    items = list(items)
    if not items:
        return "_No data_\n"
    return "\n".join([f"- {x}" for x in items]) + "\n"

def _escape_cell(x: object) -> str:
    s = "" if x is None else str(x)
    return s.replace("\n", " ").replace("|", "\\|").strip()

def table(headers: Sequence[str], rows: Sequence[Sequence[object]]) -> str:
    headers = [_escape_cell(h) for h in headers]
    out = []
    out.append("| " + " | ".join(headers) + " |")
    out.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for r in rows:
        rr = [_escape_cell(c) for c in r]
        out.append("| " + " | ".join(rr) + " |")
    return "\n".join(out) + "\n"
PY

cat > src/travel_tracker/reporting/__init__.py <<'PY'
from . import md
__all__ = ["md"]
PY

echo "[4/6] Write RSS fetcher + daily_news pipeline + config placeholder"
cat > src/travel_tracker/sources/news_rss.py <<'PY'
from __future__ import annotations
from dataclasses import dataclass
from typing import Iterable
import feedparser
from email.utils import parsedate_to_datetime

@dataclass(frozen=True)
class NewsSource:
    city: str
    topic: str   # crime / weather
    source: str
    rss_url: str

def _to_iso(dt) -> str | None:
    if not dt:
        return None
    try:
        return dt.isoformat(timespec="seconds")
    except Exception:
        return None

def fetch_rss_items(src: NewsSource) -> Iterable[dict]:
    d = feedparser.parse(src.rss_url)
    for e in getattr(d, "entries", []) or []:
        title = (getattr(e, "title", None) or "").strip()
        url = (getattr(e, "link", None) or "").strip()
        if not title or not url:
            continue

        published = None
        if getattr(e, "published", None):
            try:
                published = parsedate_to_datetime(e.published)
            except Exception:
                published = None
        elif getattr(e, "updated", None):
            try:
                published = parsedate_to_datetime(e.updated)
            except Exception:
                published = None

        yield {
            "city": src.city,
            "topic": src.topic,
            "source": src.source,
            "title": title,
            "url": url,
            "published_at": _to_iso(published),
        }
PY

cat > src/travel_tracker/pipelines/daily_news.py <<'PY'
from __future__ import annotations
from pathlib import Path
import yaml

from travel_tracker.storage.repository import Repository
from travel_tracker.sources.news_rss import NewsSource, fetch_rss_items

DEFAULT_CONFIG = Path("config/news_sources.yaml")

def run_daily_news(config_path: str | None = None) -> dict:
    cfg_path = Path(config_path) if config_path else DEFAULT_CONFIG
    data = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}

    sources: list[NewsSource] = []
    for s in data.get("sources", []) or []:
        sources.append(NewsSource(
            city=s["city"],
            topic=s["topic"],
            source=s["source"],
            rss_url=s["rss_url"],
        ))

    repo = Repository()
    inserted = 0
    total = 0
    try:
        repo.init_schema()
        for src in sources:
            for item in fetch_rss_items(src):
                total += 1
                if repo.insert_news_item(**item):
                    inserted += 1
        return {"total": total, "inserted": inserted, "sources": len(sources)}
    finally:
        repo.close()
PY

if [ ! -f config/news_sources.yaml ]; then
cat > config/news_sources.yaml <<'YAML'
sources:
  - city: 新加坡
    topic: crime
    source: "SG safety RSS"
    rss_url: "https://example.com/singapore-crime.rss"

  - city: 新加坡
    topic: weather
    source: "SG weather RSS"
    rss_url: "https://example.com/singapore-weather.rss"
YAML
fi

echo "[5/6] Write biweekly report (含今天 14 天 + News 章節)"
cat > src/travel_tracker/pipelines/biweekly_report.py <<'PY'
from __future__ import annotations
from datetime import datetime, timedelta

from travel_tracker.storage.repository import Repository
from travel_tracker.reporting import md

CITIES = [
    "吉隆坡","濱城","新加坡","峇里島","雅加達","普吉島","清邁","曼谷","富國島","胡志明市",
    "長灘島","宿霧","巴拉望","台北","高雄","台南","北海道","大阪","東京","沖繩"
]

TOPICS = [
    ("crime", "治安新聞"),
    ("weather", "天氣／氣候新聞"),
]

def run_biweekly(run_date: str) -> dict:
    run_dt = datetime.strptime(run_date, "%Y-%m-%d")
    start_dt = run_dt - timedelta(days=13)  # 含今天的14天

    print(f"[BIWEEKLY] start run_date={run_date}", flush=True)

    repo = Repository()
    try:
        repo.init_schema()

        sections: list[dict] = []
        sections.append({"h2": "Window", "body": f"{start_dt:%Y-%m-%d} ~ {run_date} (14 days)"})
        sections.append({"h2": "Flights", "body": "_No data (TODO)_"})
        sections.append({"h2": "Hotels", "body": "_No data (TODO)_"})
        sections.append({"h2": "Daily Cost", "body": "_No data (TODO)_"})

        body_parts: list[str] = []
        body_parts.append(md.p(f"期間：{start_dt:%Y-%m-%d} ~ {run_date}（含今天，共 14 天）"))

        any_city = False
        for city in CITIES:
            city_block: list[str] = [md.h3(city)]
            city_any = False

            for topic_key, topic_name in TOPICS:
                items = repo.list_news(
                    start_date=start_dt.strftime("%Y-%m-%d"),
                    end_date=run_date,
                    city=city,
                    topic=topic_key,
                    limit=20,
                )
                city_block.append(md.p(f"**{topic_name}**"))
                if items:
                    city_any = True
                    rows = []
                    for it in items[:20]:
                        dt = (it.get("published_at") or it.get("fetched_at") or "")[:19]
                        rows.append([dt, it.get("source",""), it.get("title",""), it.get("url","")])
                    city_block.append(md.table(["Date", "Source", "Title", "URL"], rows))
                else:
                    city_block.append(md.p("_No data_"))

            if city_any:
                any_city = True
                body_parts.append("".join(city_block))

        if not any_city:
            body_parts.append("_No news data in this window yet. Fill RSS URLs then run `... main news`._")

        sections.append({"h2": "News (Safety + Weather)", "body": "\n".join(body_parts).strip()})
        return {"sections": sections}
    finally:
        repo.close()
PY

echo "[6/6] Patch repository.py (news table + insert/list methods) and patch main.py (news command) best-effort"
python3 - <<'PY'
from __future__ import annotations
from pathlib import Path
import re

repo_path = Path("src/travel_tracker/storage/repository.py")
main_path = Path("src/travel_tracker/main.py")

NEWS_SCHEMA = """
CREATE TABLE IF NOT EXISTS news_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  city TEXT NOT NULL,
  topic TEXT NOT NULL,
  source TEXT NOT NULL,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  published_at TEXT,
  fetched_at TEXT NOT NULL,
  UNIQUE(url)
);
""".strip()

METHODS = """
def insert_news_item(
    self,
    *,
    city: str,
    topic: str,
    source: str,
    title: str,
    url: str,
    published_at: str | None,
) -> bool:
    from datetime import datetime
    fetched_at = datetime.utcnow().isoformat(timespec="seconds")

    # SQLite
    sql1 = \"\"\"
    INSERT OR IGNORE INTO news_items
    (city, topic, source, title, url, published_at, fetched_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    \"\"\"
    try:
        cur = self.conn.execute(sql1, (city, topic, source, title, url, published_at, fetched_at))
        try:
            self.conn.commit()
        except Exception:
            pass
        try:
            return cur.rowcount == 1
        except Exception:
            return True
    except Exception:
        pass

    # MySQL
    sql2 = \"\"\"
    INSERT IGNORE INTO news_items
    (city, topic, source, title, url, published_at, fetched_at)
    VALUES (%s, %s, %s, %s, %s, %s, %s)
    \"\"\"
    try:
        cur = self.conn.execute(sql2, (city, topic, source, title, url, published_at, fetched_at))
        try:
            self.conn.commit()
        except Exception:
            pass
        try:
            return cur.rowcount == 1
        except Exception:
            return True
    except Exception as e:
        msg = str(e).lower()
        if "unique" in msg or "duplicate" in msg or "constraint" in msg:
            return False
        raise

def list_news(
    self,
    *,
    start_date: str,
    end_date: str,
    city: str | None = None,
    topic: str | None = None,
    limit: int = 50,
) -> list[dict]:
    where = []
    params = []

    where.append("SUBSTR(COALESCE(published_at, fetched_at), 1, 10) >= ?")
    where.append("SUBSTR(COALESCE(published_at, fetched_at), 1, 10) <= ?")
    params.extend([start_date, end_date])

    if city:
        where.append("city = ?")
        params.append(city)
    if topic:
        where.append("topic = ?")
        params.append(topic)

    sql = f\"\"\"
    SELECT city, topic, source, title, url, published_at, fetched_at
    FROM news_items
    WHERE {' AND '.join(where)}
    ORDER BY COALESCE(published_at, fetched_at) DESC
    LIMIT ?
    \"\"\"
    params.append(limit)

    try:
        cur = self.conn.execute(sql, params)
    except Exception:
        cur = self.conn.execute(sql.replace("?", "%s"), params)

    rows = cur.fetchall()
    out = []
    for r in rows:
        out.append({
            "city": r[0],
            "topic": r[1],
            "source": r[2],
            "title": r[3],
            "url": r[4],
            "published_at": r[5],
            "fetched_at": r[6],
        })
    return out
""".strip() + "\n"

# Patch repository.py
if repo_path.exists():
    s = repo_path.read_text(encoding="utf-8")
    if "news_items" not in s:
        m = re.search(r"def\s+init_schema\s*\(\s*self\s*\)\s*:", s)
        if m:
            ins = m.end()
            inject = "\n    # --- news schema (auto) ---\n    self.conn.execute('''" + NEWS_SCHEMA + "''')\n    try:\n        self.conn.commit()\n    except Exception:\n        pass\n    # --- end news schema (auto) ---\n"
            s = s[:ins] + inject + s[ins:]
        else:
            print("[WARN] repository.py: cannot find init_schema; schema not injected")

    if "def insert_news_item" not in s:
        m2 = re.search(r"\n\s*def\s+close\s*\(\s*self\s*\)\s*:", s)
        if m2:
            s = s[:m2.start()] + "\n\n" + METHODS + "\n" + s[m2.start():]
        else:
            s = s + "\n\n" + METHODS

    repo_path.write_text(s, encoding="utf-8")
    print("[OK] patched repository.py")
else:
    print("[WARN] missing repository.py; skip")

# Patch main.py (best-effort)
if main_path.exists():
    s = main_path.read_text(encoding="utf-8")
    if "run_daily_news" not in s:
        s = "from travel_tracker.pipelines.daily_news import run_daily_news\n" + s

    # If you have argparse command dispatch, we only append a minimal handler at EOF (safe)
    if 'command == "news"' not in s and "args.command == \"news\"" not in s:
        s += "\n\n# --- auto news command (fallback) ---\n" \
             "try:\n" \
             "    if getattr(locals().get('args', None), 'command', None) == 'news':\n" \
             "        result = run_daily_news()\n" \
             "        print(f\"[NEWS] sources={result.get('sources')} total={result.get('total')} inserted={result.get('inserted')}\", flush=True)\n" \
             "except Exception:\n" \
             "    pass\n"

    main_path.write_text(s, encoding="utf-8")
    print("[OK] patched main.py (fallback append)")
else:
    print("[WARN] missing main.py; skip")
PY

echo "===== DONE ====="
echo "Next:"
echo "1) Edit config/news_sources.yaml with real RSS URLs"
echo "2) Run: poetry run python -m travel_tracker.main news"
echo "3) Run: poetry run python -m travel_tracker.main biweekly"
