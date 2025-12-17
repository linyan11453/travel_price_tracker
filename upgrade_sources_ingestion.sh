#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"

mkdir -p \
  "${ROOT}/src/travel_tracker/core" \
  "${ROOT}/src/travel_tracker/sources/news" \
  "${ROOT}/src/travel_tracker/storage" \
  "${ROOT}/src/travel_tracker/pipelines"

# -------------------------
# 1) DB schema: add signals tables (safe to re-run)
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
  source_id TEXT NOT NULL,
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
  source_id TEXT NOT NULL,
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
  source_id TEXT NOT NULL,
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
# 2) core/http_client.py (stdlib, polite + cache + conditional GET)
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
    - exponential backoff retry
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

        headers = {"User-Agent": self.user_agent, "Accept": "*/*"}
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
                    return HttpResponse(url=url, status=304, headers=resp_headers, body=b"", from_cache=True)

                self._save_meta(url, {
                    "etag": resp_headers.get("etag"),
                    "last_modified": resp_headers.get("last-modified"),
                    "fetched_at": time.time(),
                })
                self._body_path(url).write_bytes(body)
                return HttpResponse(url=url, status=status, headers=resp_headers, body=body, from_cache=False)

            except Exception as e:
                last_error = e
                time.sleep(min(8, 2 ** (attempt - 1)))

        raise RuntimeError(f"HTTP GET failed after {self.max_retries} retries: {url}") from last_error
PY

# -------------------------
# 3) core/feed_parsers.py (RSS/Atom + OPML)
# -------------------------
cat > "${ROOT}/src/travel_tracker/core/feed_parsers.py" <<'PY'
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from email.utils import parsedate_to_datetime
from typing import Optional
from xml.etree import ElementTree as ET


@dataclass
class FeedItem:
    title: str
    url: str
    published_at: str | None


def _txt(el: Optional[ET.Element]) -> str:
    if el is None or el.text is None:
        return ""
    return el.text.strip()


def _parse_time(s: str) -> str | None:
    s = (s or "").strip()
    if not s:
        return None
    try:
        dt = parsedate_to_datetime(s)
        return dt.isoformat(timespec="seconds")
    except Exception:
        pass
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt.isoformat(timespec="seconds")
    except Exception:
        return None


def parse_rss_or_atom(xml_bytes: bytes) -> list[FeedItem]:
    root = ET.fromstring(xml_bytes)

    # RSS
    if root.tag.endswith("rss") or root.find("./channel") is not None:
        channel = root.find("./channel") if root.find("./channel") is not None else root
        out: list[FeedItem] = []
        for it in channel.findall("./item"):
            title = _txt(it.find("./title"))
            link = _txt(it.find("./link"))
            pub = _parse_time(_txt(it.find("./pubDate"))) or _parse_time(_txt(it.find("./date")))
            if title and link:
                out.append(FeedItem(title=title, url=link, published_at=pub))
        return out

    # Atom
    ns = {}
    if root.tag.startswith("{"):
        ns_uri = root.tag.split("}")[0].strip("{")
        ns = {"a": ns_uri}

    out = []
    entries = root.findall("./a:entry", ns) if ns else root.findall("./entry")
    for e in entries:
        title = _txt(e.find("./a:title", ns) if ns else e.find("./title"))
        link_el = e.find("./a:link", ns) if ns else e.find("./link")
        link = ""
        if link_el is not None:
            link = (link_el.attrib.get("href") or link_el.text or "").strip()
        updated = _txt(e.find("./a:updated", ns) if ns else e.find("./updated"))
        published = _txt(e.find("./a:published", ns) if ns else e.find("./published"))
        pub = _parse_time(published) or _parse_time(updated)
        if title and link:
            out.append(FeedItem(title=title, url=link, published_at=pub))
    return out


def parse_opml(xml_bytes: bytes) -> list[str]:
    root = ET.fromstring(xml_bytes)
    urls: list[str] = []
    for o in root.findall(".//outline"):
        xml_url = o.attrib.get("xmlUrl") or o.attrib.get("xmlurl")
        if xml_url:
            urls.append(xml_url.strip())
    return list(dict.fromkeys(urls))  # unique preserving order
PY

# -------------------------
# 4) data sources loader: support data/sources.json
# -------------------------
cat > "${ROOT}/src/travel_tracker/sources_loader.py" <<'PY'
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Destination:
    id: str
    name_zh: str
    country: str


@dataclass
class Source:
    id: str
    country: str | None
    type: str
    url: str
    tags: list[str]


@dataclass
class SourcesBundle:
    destinations: list[Destination]
    news: list[Source]
    weather: list[Source]
    safety: list[Source]


def load_sources(path: str = "data/sources.json") -> SourcesBundle:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Missing sources file: {path}")

    data = json.loads(p.read_text(encoding="utf-8"))

    dests = [
        Destination(id=d["id"], name_zh=d["name_zh"], country=d["country"])
        for d in data.get("destinations", [])
    ]

    def _to_sources(arr: list[dict]) -> list[Source]:
        out: list[Source] = []
        for s in arr:
            out.append(Source(
                id=s.get("id",""),
                country=s.get("country"),
                type=s.get("type","rss"),
                url=s.get("url",""),
                tags=list(s.get("tags", [])),
            ))
        return [x for x in out if x.id and x.url]

    src = data.get("sources", {})
    return SourcesBundle(
        destinations=dests,
        news=_to_sources(src.get("news_rss", [])),
        weather=_to_sources(src.get("weather_official", [])),
        safety=_to_sources(src.get("safety_official", [])),
    )
PY

# -------------------------
# 5) repository: add insert_signal (override file)
# -------------------------
cat > "${ROOT}/src/travel_tracker/storage/repository.py" <<'PY'
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from travel_tracker.storage.db import connect_sqlite

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

    def delete_daily_run(self, run_date: str) -> None:
        self.conn.execute("DELETE FROM runs WHERE run_type='daily' AND run_date=?", (run_date,))
        self.conn.commit()

    def record_run(self, run_type: str, run_date: str) -> None:
        self.conn.execute(
            "INSERT INTO runs(run_type, run_date, created_at) VALUES(?,?,?)",
            (run_type, run_date, _now_iso()),
        )
        self.conn.commit()

    def insert_signal(self, table: str, run_date: str, city_code: str, city_name_zh: str, source_id: str, title: str, url: str, published_at: str | None) -> None:
        if table not in {"signals_news", "signals_weather", "signals_safety"}:
            raise ValueError("Invalid table")
        self.conn.execute(
            f"""INSERT INTO {table}(
                run_date, city_code, city_name_zh, source_id, title, url, published_at, created_at
            ) VALUES (?,?,?,?,?,?,?,?)""",
            (run_date, city_code, city_name_zh, source_id, title, url, published_at, _now_iso()),
        )

    def commit(self) -> None:
        self.conn.commit()
PY

# -------------------------
# 6) sources/news/collector.py : fetch RSS/OPML and return items
# -------------------------
cat > "${ROOT}/src/travel_tracker/sources/news/collector.py" <<'PY'
from __future__ import annotations

from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.core.feed_parsers import parse_opml, parse_rss_or_atom, FeedItem


def fetch_items(*, client: PoliteHttpClient, url: str, source_type: str, raw_path: Path) -> tuple[list[FeedItem], list[str]]:
    """
    Returns (items, expanded_feed_urls)
    - If OPML: expanded_feed_urls will have child RSS URLs; items empty.
    - If RSS/Atom: expanded_feed_urls empty; items filled.
    """
    resp = client.get(url)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_bytes(resp.body)

    st = (source_type or "").lower()
    if st == "opml":
        return [], parse_opml(resp.body)

    # Treat everything else as feed xml
    return parse_rss_or_atom(resp.body), []
PY

# -------------------------
# 7) pipelines/daily_snapshot.py : map country-level sources -> each destination city
# -------------------------
cat > "${ROOT}/src/travel_tracker/pipelines/daily_snapshot.py" <<'PY'
from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.human_in_loop.alerts import write_human_alert
from travel_tracker.sources.news.collector import fetch_items
from travel_tracker.sources_loader import load_sources
from travel_tracker.storage.repository import Repository


def run_daily(run_date: str, *, force: bool = False) -> dict:
    repo = Repository()
    repo.init_schema()

    if repo.has_daily_run(run_date):
        if not force:
            repo.close()
            return {"sections": [{"h2": "Daily Snapshot", "body": f"已存在 {run_date} 的 daily run（每日最多一次）。本次不重跑。"}]}
        # force rerun: delete marker (signals will still accumulate; later可加dedupe)
        repo.delete_daily_run(run_date)

    repo.record_run("daily", run_date)

    client = PoliteHttpClient(cache_dir="data/cache/http", rps=0.2, timeout_seconds=25, max_retries=3)

    counts = defaultdict(int)
    notes: list[str] = []

    try:
        bundle = load_sources("data/sources.json")

        # Expand OPML once (country-level)
        expanded_news = []
        for s in bundle.news:
            if s.type.lower() == "opml":
                raw = Path("data/raw") / run_date / "opml" / f"{s.id}.xml"
                _, urls = fetch_items(client=client, url=s.url, source_type="opml", raw_path=raw)
                for u in urls:
                    expanded_news.append((s.id, s.country, "rss", u))
            else:
                expanded_news.append((s.id, s.country, s.type, s.url))

        expanded_weather = [(s.id, s.country, s.type, s.url) for s in bundle.weather if s.type.lower() != "todo"]
        expanded_safety  = [(s.id, s.country, s.type, s.url) for s in bundle.safety if s.type.lower() != "todo"]

        # For each destination city: ingest sources by matching country
        for d in bundle.destinations:
            # NEWS
            for sid, scountry, stype, surl in expanded_news:
                if scountry and scountry != d.country:
                    continue
                raw = Path("data/raw") / run_date / "news" / d.id / f"{sid}.xml"
                items, _ = fetch_items(client=client, url=surl, source_type=stype, raw_path=raw)
                for it in items[:50]:
                    repo.insert_signal("signals_news", run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)
                    counts["news"] += 1

            # WEATHER
            for sid, scountry, stype, surl in expanded_weather:
                if scountry and scountry != d.country:
                    continue
                raw = Path("data/raw") / run_date / "weather" / d.id / f"{sid}.xml"
                items, _ = fetch_items(client=client, url=surl, source_type=stype, raw_path=raw)
                for it in items[:50]:
                    repo.insert_signal("signals_weather", run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)
                    counts["weather"] += 1

            # SAFETY (目前多為 TODO，不會寫入)
            for sid, scountry, stype, surl in expanded_safety:
                if scountry and scountry != d.country:
                    continue
                raw = Path("data/raw") / run_date / "safety" / d.id / f"{sid}.xml"
                items, _ = fetch_items(client=client, url=surl, source_type=stype, raw_path=raw)
                for it in items[:50]:
                    repo.insert_signal("signals_safety", run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)
                    counts["safety"] += 1

        repo.commit()
        repo.close()

        notes.append(f"- inserted news: {counts['news']}")
        notes.append(f"- inserted weather: {counts['weather']}")
        notes.append(f"- inserted safety: {counts['safety']}")
        notes.append("")
        notes.append("Raw files: data/raw/<run_date>/(news|weather|safety)/<CITY>/<SOURCE_ID>.xml")
        notes.append("Cache: data/cache/http/ (ETag/Last-Modified + body)")

        return {"sections": [{"h2": "Run Summary", "body": "\n".join(notes)}]}

    except Exception as e:
        write_human_alert(run_date=run_date, reason=str(e), next_step="檢查 data/sources.json URL 是否可達或是否非 RSS/OPML。")
        repo.close()
        raise
PY

# -------------------------
# 8) main.py : add --force for daily
# -------------------------
cat > "${ROOT}/src/travel_tracker/main.py" <<'PY'
import argparse
from datetime import datetime
from pathlib import Path

from travel_tracker.pipelines.daily_snapshot import run_daily
from travel_tracker.pipelines.biweekly_report import run_biweekly
from travel_tracker.reporting.render_md import write_markdown_report


def _today_ymd() -> str:
    return datetime.now().strftime("%Y-%m-%d")


def main() -> int:
    p = argparse.ArgumentParser(prog="travel_price_tracker")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("daily", help="Run daily snapshot (max once/day; use --force to rerun)")
    d.add_argument("--date", default=_today_ymd())
    d.add_argument("--force", action="store_true", help="Rerun daily even if already ran for the date")

    b = sub.add_parser("biweekly", help="Run biweekly report")
    b.add_argument("--date", default=_today_ymd())

    args = p.parse_args()

    if args.cmd == "daily":
        result = run_daily(args.date, force=args.force)
        out = write_markdown_report(
            Path("reports/daily"),
            f"daily_{args.date}.md",
            f"Daily Snapshot - {args.date}",
            result["sections"],
        )
        print(f"[OK] {out}")
        return 0

    if args.cmd == "biweekly":
        result = run_biweekly(args.date)
        out = write_markdown_report(
            Path("reports/biweekly"),
            f"biweekly_{args.date}.md",
            f"Biweekly Report - {args.date}",
            result["sections"],
        )
        print(f"[OK] {out}")
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
PY

echo "[OK] Ingestion upgrade applied."
