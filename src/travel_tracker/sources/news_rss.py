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
