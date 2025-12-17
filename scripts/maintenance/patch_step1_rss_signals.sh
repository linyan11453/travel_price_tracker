#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"

mkdir -p \
  "${ROOT}/config" \
  "${ROOT}/src/travel_tracker/core" \
  "${ROOT}/src/travel_tracker/storage" \
  "${ROOT}/src/travel_tracker/pipelines" \
  "${ROOT}/src/travel_tracker/sources/news"

# -------------------------
# 1) config/sources.json  (你之後只需要填 RSS/Atom URL)
# -------------------------
cat > "${ROOT}/config/sources.json" <<'JSON'
{
  "cities": {
    "KUL": { "name_zh": "吉隆坡", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "PEN": { "name_zh": "濱城", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "SIN": { "name_zh": "新加坡", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "DPS": { "name_zh": "峇里島", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "JKT": { "name_zh": "雅加達", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "HKT": { "name_zh": "普吉島", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "CNX": { "name_zh": "清邁", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "BKK": { "name_zh": "曼谷", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "PQC": { "name_zh": "富國島", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "SGN": { "name_zh": "胡志明市", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "MPH": { "name_zh": "長灘島", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "CEB": { "name_zh": "宿霧", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "PPS": { "name_zh": "巴拉望", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "TPE": { "name_zh": "台北", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "KHH": { "name_zh": "高雄", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "TNN": { "name_zh": "台南", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "CTS": { "name_zh": "北海道", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "OSA": { "name_zh": "大阪", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "TYO": { "name_zh": "東京", "news_rss": [], "weather_rss": [], "safety_rss": [] },
    "OKA": { "name_zh": "沖繩", "news_rss": [], "weather_rss": [], "safety_rss": [] }
  }
}
JSON

# -------------------------
# 2) scripts/db_init.sql (擴充 signals_* tables；安全可重複執行)
# -------------------------
cat > "${ROOT}/scripts/db_init.sql" <<'SQL'
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_type TEXT NOT NULL,
  run_date TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS signals_news (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_date TEXT NOT NULL,
  city_code TEXT NOT NULL,
  city_name_zh TEXT NOT NULL,
  source TEXT NOT NULL,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  published_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS signals_weather (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_date TEXT NOT NULL,
  city_code TEXT NOT NULL,
  city_name_zh TEXT NOT NULL,
  source TEXT NOT NULL,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  published_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS signals_safety (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_date TEXT NOT NULL,
  city_code TEXT NOT NULL,
  city_name_zh TEXT NOT NULL,
  source TEXT NOT NULL,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  published_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_runs_type_date ON runs(run_type, run_date);
CREATE INDEX IF NOT EXISTS idx_news_date_city ON signals_news(run_date, city_code);
CREATE INDEX IF NOT EXISTS idx_weather_date_city ON signals_weather(run_date, city_code);
CREATE INDEX IF NOT EXISTS idx_safety_date_city ON signals_safety(run_date, city_code);
SQL

# -------------------------
# 3) core/http_client.py (stdlib + ETag/Last-Modified + cache)
# -------------------------
cat > "${ROOT}/src/travel_tracker/core/http_client.py" <<'PY'
from __future__ import annotations

import hashlib
import json
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class HttpResponse:
    url: str
    status: int
    headers: dict[str, str]
    body: bytes
    from_cache: bool = False


class PoliteHttpClient:
    """
    Stdlib-only HTTP client with:
    - global rate limiting
    - simple exponential backoff
    - ETag / Last-Modified conditional GET cache
    """
    def __init__(
        self,
        cache_dir: str = "data/cache/http",
        rps: float = 0.2,
        timeout_seconds: int = 25,
        max_retries: int = 3,
        user_agent: str = "travel_price_tracker/0.1 (+contact: you@example.com)",
    ) -> None:
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.min_interval = 1.0 / max(rps, 1e-9)
        self.timeout_seconds = timeout_seconds
        self.max_retries = max_retries
        self.user_agent = user_agent
        self._last_ts = 0.0

    def _sleep_gate(self) -> None:
        now = time.time()
        wait = self.min_interval - (now - self._last_ts)
        if wait > 0:
            time.sleep(wait)
        self._last_ts = time.time()

    def _key(self, url: str) -> str:
        return hashlib.sha256(url.encode("utf-8")).hexdigest()

    def _meta_path(self, url: str) -> Path:
        return self.cache_dir / f"{self._key(url)}.meta.json"

    def _body_path(self, url: str) -> Path:
        return self.cache_dir / f"{self._key(url)}.body.bin"

    def _load_meta(self, url: str) -> dict:
        p = self._meta_path(url)
        if not p.exists():
            return {}
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def _save_meta(self, url: str, meta: dict) -> None:
        self._meta_path(url).write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")

    def get(self, url: str) -> HttpResponse:
        meta = self._load_meta(url)
        etag = meta.get("etag")
        last_modified = meta.get("last_modified")

        headers = {
            "User-Agent": self.user_agent,
            "Accept": "*/*",
        }
        if etag:
            headers["If-None-Match"] = etag
        if last_modified:
            headers["If-Modified-Since"] = last_modified

        last_error: Optional[Exception] = None

        for attempt in range(1, self.max_retries + 1):
            try:
                self._sleep_gate()
                req = urllib.request.Request(url, headers=headers, method="GET")
                with urllib.request.urlopen(req, timeout=self.timeout_seconds) as resp:
                    status = getattr(resp, "status", 200)
                    resp_headers = {k.lower(): v for k, v in resp.headers.items()}
                    body = resp.read()

                if status == 304:
                    body_path = self._body_path(url)
                    if body_path.exists():
                        return HttpResponse(url=url, status=304, headers=resp_headers, body=body_path.read_bytes(), from_cache=True)
                    # fallthrough: cache missing, treat as empty
                    return HttpResponse(url=url, status=304, headers=resp_headers, body=b"", from_cache=True)

                # cache update
                new_meta = {
                    "etag": resp_headers.get("etag"),
                    "last_modified": resp_headers.get("last-modified"),
                    "fetched_at": time.time(),
                }
                self._save_meta(url, new_meta)
                self._body_path(url).write_bytes(body)

                return HttpResponse(url=url, status=status, headers=resp_headers, body=body, from_cache=False)

            except Exception as e:
                last_error = e
                # exponential backoff (1s, 2s, 4s...) with cap
                sleep_s = min(8, 2 ** (attempt - 1))
                time.sleep(sleep_s)

        raise RuntimeError(f"HTTP GET failed after {self.max_retries} retries: {url}") from last_error
PY

# -------------------------
# 4) core/rss_parser.py (RSS/Atom 解析：只取 title/url/published_at)
# -------------------------
cat > "${ROOT}/src/travel_tracker/core/rss_parser.py" <<'PY'
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from email.utils import parsedate_to_datetime
from typing import Iterable, Optional
from xml.etree import ElementTree as ET


@dataclass
class FeedItem:
    title: str
    url: str
    published_at: str | None


def _safe_text(el: Optional[ET.Element]) -> str:
    if el is None or el.text is None:
        return ""
    return el.text.strip()


def _parse_rfc822_or_iso(s: str) -> str | None:
    s = (s or "").strip()
    if not s:
        return None
    # RSS pubDate (RFC822)
    try:
        dt = parsedate_to_datetime(s)
        return dt.isoformat(timespec="seconds")
    except Exception:
        pass
    # Atom updated/issued (ISO8601)
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt.isoformat(timespec="seconds")
    except Exception:
        return None


def parse_feed(xml_bytes: bytes) -> list[FeedItem]:
    """
    Supports RSS 2.0 and Atom (best-effort).
    Returns minimal fields: title, url, published_at
    """
    root = ET.fromstring(xml_bytes)

    # Detect Atom namespace
    tag = root.tag.lower()
    is_atom = "feed" in tag and "atom" in tag

    items: list[FeedItem] = []

    if root.tag.endswith("rss") or root.find("./channel") is not None:
        # RSS
        channel = root.find("./channel") if root.find("./channel") is not None else root
        for it in channel.findall("./item"):
            title = _safe_text(it.find("./title"))
            link = _safe_text(it.find("./link"))
            pub = _parse_rfc822_or_iso(_safe_text(it.find("./pubDate"))) or _parse_rfc822_or_iso(_safe_text(it.find("./date")))
            if title and link:
                items.append(FeedItem(title=title, url=link, published_at=pub))
        return items

    # Atom (namespace-aware)
    ns = {}
    if root.tag.startswith("{"):
        ns_uri = root.tag.split("}")[0].strip("{")
        ns = {"a": ns_uri}

    for entry in root.findall("./a:entry", ns) if ns else root.findall("./entry"):
        title = _safe_text(entry.find("./a:title", ns) if ns else entry.find("./title"))
        # link: <link href="..."/> or <link>...</link>
        link_el = entry.find("./a:link", ns) if ns else entry.find("./link")
        link = ""
        if link_el is not None:
            href = link_el.attrib.get("href")
            link = (href or link_el.text or "").strip()
        updated = _safe_text(entry.find("./a:updated", ns) if ns else entry.find("./updated"))
        published = _safe_text(entry.find("./a:published", ns) if ns else entry.find("./published"))
        pub = _parse_rfc822_or_iso(published) or _parse_rfc822_or_iso(updated)
        if title and link:
            items.append(FeedItem(title=title, url=link, published_at=pub))

    return items
PY

# -------------------------
# 5) config loader
# -------------------------
cat > "${ROOT}/src/travel_tracker/config.py" <<'PY'
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class CitySources:
    code: str
    name_zh: str
    news_rss: list[str]
    weather_rss: list[str]
    safety_rss: list[str]


def load_sources(path: str = "config/sources.json") -> list[CitySources]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    cities = data.get("cities", {})
    out: list[CitySources] = []
    for code, payload in cities.items():
        out.append(
            CitySources(
                code=code,
                name_zh=payload["name_zh"],
                news_rss=list(payload.get("news_rss", [])),
                weather_rss=list(payload.get("weather_rss", [])),
                safety_rss=list(payload.get("safety_rss", [])),
            )
        )
    return out
PY

# -------------------------
# 6) storage/models.py + repository.py (insert_signal)
# -------------------------
cat > "${ROOT}/src/travel_tracker/storage/models.py" <<'PY'
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class SignalRow:
    run_date: str
    city_code: str
    city_name_zh: str
    source: str
    title: str
    url: str
    published_at: str | None
PY

cat > "${ROOT}/src/travel_tracker/storage/repository.py" <<'PY'
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from travel_tracker.storage.db import connect_sqlite
from travel_tracker.storage.models import SignalRow


def _now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


class Repository:
    def __init__(self) -> None:
        self.conn = connect_sqlite()

    def close(self) -> None:
        self.conn.close()

    def init_schema(self) -> None:
        sql = Path("scripts/db_init.sql").read_text(encoding="utf-8")
        self.conn.executescript(sql)
        self.conn.commit()

    def has_daily_run(self, run_date: str) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM runs WHERE run_type='daily' AND run_date=? LIMIT 1",
            (run_date,),
        ).fetchone()
        return row is not None

    def record_run(self, run_type: str, run_date: str) -> None:
        self.conn.execute(
            "INSERT INTO runs(run_type, run_date, created_at) VALUES(?,?,?)",
            (run_type, run_date, _now_iso()),
        )
        self.conn.commit()

    def insert_signal(self, table: str, row: SignalRow) -> None:
        if table not in {"signals_news", "signals_weather", "signals_safety"}:
            raise ValueError("Invalid signal table")
        self.conn.execute(
            f"""INSERT INTO {table}(
                run_date, city_code, city_name_zh, source, title, url, published_at, created_at
            ) VALUES (?,?,?,?,?,?,?,?)""",
            (
                row.run_date,
                row.city_code,
                row.city_name_zh,
                row.source,
                row.title,
                row.url,
                row.published_at,
                _now_iso(),
            ),
        )

    def commit(self) -> None:
        self.conn.commit()
PY

# -------------------------
# 7) sources/news/rss_collector.py
# -------------------------
cat > "${ROOT}/src/travel_tracker/sources/news/rss_collector.py" <<'PY'
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.core.rss_parser import parse_feed


@dataclass
class CollectedItem:
    title: str
    url: str
    published_at: str | None


def fetch_feed_items(*, run_date: str, city_code: str, kind: str, feed_url: str, client: PoliteHttpClient) -> list[CollectedItem]:
    """
    kind: news / weather / safety (for raw storage path only)
    """
    resp = client.get(feed_url)
    # save raw
    raw_dir = Path("data/raw") / run_date / kind / city_code
    raw_dir.mkdir(parents=True, exist_ok=True)
    (raw_dir / "feed.xml").write_bytes(resp.body)

    items = parse_feed(resp.body)
    return [CollectedItem(title=i.title, url=i.url, published_at=i.published_at) for i in items]
PY

# -------------------------
# 8) pipelines/daily_snapshot.py (真正抓 RSS -> DB -> 報告)
# -------------------------
cat > "${ROOT}/src/travel_tracker/pipelines/daily_snapshot.py" <<'PY'
from __future__ import annotations

from collections import defaultdict

from travel_tracker.config import load_sources
from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.human_in_loop.alerts import write_human_alert
from travel_tracker.sources.news.rss_collector import fetch_feed_items
from travel_tracker.storage.models import SignalRow
from travel_tracker.storage.repository import Repository


def run_daily(run_date: str) -> dict:
    repo = Repository()
    repo.init_schema()

    if repo.has_daily_run(run_date):
        repo.close()
        return {
            "sections": [
                {"h2": "Daily Snapshot", "body": f"已存在 {run_date} 的 daily run（每日最多一次）。本次不重跑。"}
            ]
        }

    repo.record_run("daily", run_date)

    client = PoliteHttpClient(
        cache_dir="data/cache/http",
        rps=0.2,
        timeout_seconds=25,
        max_retries=3,
        user_agent="travel_price_tracker/0.1 (+contact: you@example.com)",
    )

    counts = defaultdict(int)
    sample_lines: list[str] = []

    try:
        cities = load_sources()

        for c in cities:
            # NEWS
            for idx, url in enumerate(c.news_rss, start=1):
                items = fetch_feed_items(run_date=run_date, city_code=c.code, kind="news", feed_url=url, client=client)
                for it in items[:50]:  # hard cap per feed
                    repo.insert_signal(
                        "signals_news",
                        SignalRow(run_date, c.code, c.name_zh, source=f"rss:{idx}", title=it.title, url=it.url, published_at=it.published_at),
                    )
                    counts["news"] += 1

            # WEATHER
            for idx, url in enumerate(c.weather_rss, start=1):
                items = fetch_feed_items(run_date=run_date, city_code=c.code, kind="weather", feed_url=url, client=client)
                for it in items[:50]:
                    repo.insert_signal(
                        "signals_weather",
                        SignalRow(run_date, c.code, c.name_zh, source=f"rss:{idx}", title=it.title, url=it.url, published_at=it.published_at),
                    )
                    counts["weather"] += 1

            # SAFETY
            for idx, url in enumerate(c.safety_rss, start=1):
                items = fetch_feed_items(run_date=run_date, city_code=c.code, kind="safety", feed_url=url, client=client)
                for it in items[:50]:
                    repo.insert_signal(
                        "signals_safety",
                        SignalRow(run_date, c.code, c.name_zh, source=f"rss:{idx}", title=it.title, url=it.url, published_at=it.published_at),
                    )
                    counts["safety"] += 1

        repo.commit()

        sample_lines.append(f"- news inserted: {counts['news']}")
        sample_lines.append(f"- weather inserted: {counts['weather']}")
        sample_lines.append(f"- safety inserted: {counts['safety']}")
        sample_lines.append("")
        sample_lines.append("提醒：目前 sources.json 預設是空清單；你填入 RSS/Atom URL 後就會開始累積資料。")

        repo.close()
        return {
            "sections": [
                {"h2": "Run Summary", "body": "\n".join(sample_lines).strip()},
                {"h2": "Raw Storage", "body": f"data/raw/{run_date}/(news|weather|safety)/<CITY_CODE>/feed.xml"},
                {"h2": "Cache", "body": "data/cache/http/ 會保存 ETag/Last-Modified 與 body，用於避免重抓。"},
            ]
        }

    except Exception as e:
        write_human_alert(run_date=run_date, reason=str(e), next_step="檢查 RSS URL 是否可達、是否需代理、或來源是否非 RSS/Atom。")
        repo.close()
        raise
PY

echo "[OK] Step1 RSS signals patch applied."
