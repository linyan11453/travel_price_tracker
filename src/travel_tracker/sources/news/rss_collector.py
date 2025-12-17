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
