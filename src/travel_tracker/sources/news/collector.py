from __future__ import annotations

from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.core.feed_parsers import parse_opml, parse_any_feed, FeedItem


def fetch_items(*, client: PoliteHttpClient, url: str, source_type: str, raw_path: Path) -> tuple[list[FeedItem], list[str]]:
    """
    Returns (items, expanded_feed_urls)
    - If OPML: expanded_feed_urls will have child RSS URLs; items empty.
    - Else: tries RSS/Atom/CAP auto-detect.
    """
    resp = client.get(url)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_bytes(resp.body)

    st = (source_type or "").lower()
    if st == "opml":
        return [], parse_opml(resp.body)

    items = parse_any_feed(resp.body)
    # Ensure url is never empty (DB url often NOT NULL)
    fixed: list[FeedItem] = []
    for it in items:
        fixed.append(FeedItem(
            title=it.title,
            url=it.url or url,
            published_at=it.published_at
        ))
    return fixed, []
