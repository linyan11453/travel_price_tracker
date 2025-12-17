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
