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


def _strip_ns(tag: str) -> str:
    if "}" in tag:
        return tag.split("}", 1)[1]
    return tag


def _txt(el: Optional[ET.Element]) -> str:
    if el is None or el.text is None:
        return ""
    return el.text.strip()


def _find_child(el: ET.Element, localname: str) -> Optional[ET.Element]:
    ln = localname.lower()
    for c in list(el):
        if _strip_ns(c.tag).lower() == ln:
            return c
    return None


def _find_children(el: ET.Element, localname: str) -> list[ET.Element]:
    ln = localname.lower()
    return [c for c in list(el) if _strip_ns(c.tag).lower() == ln]


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
    import xml.etree.ElementTree as ET
    from datetime import datetime
    from email.utils import parsedate_to_datetime

    def strip_ns(tag: str) -> str:
        return tag.split("}", 1)[-1] if "}" in tag else tag

    def get_text(el, path: str) -> str:
        x = el.find(path)
        return (x.text or "").strip() if x is not None and x.text else ""

    def find_first_attr(el, path: str, attr: str) -> str:
        x = el.find(path)
        return (x.attrib.get(attr) or "").strip() if x is not None else ""

    def to_iso(dt_str: str) -> str | None:
        if not dt_str:
            return None
        t = dt_str.strip()
        # ISO-8601
        try:
            return datetime.fromisoformat(t.replace("Z", "+00:00")).isoformat()
        except Exception:
            pass
        # RFC822 (RSS pubDate)
        try:
            return parsedate_to_datetime(t).isoformat()
        except Exception:
            return None

    root = ET.fromstring(xml_bytes)
    tag = strip_ns(root.tag).lower()

    out: list[FeedItem] = []

    # ---------- RSS ----------
    if tag == "rss":
        ch = root.find("./channel")
        if ch is None:
            return out
        for it in ch.findall("./item"):
            title = get_text(it, "./title") or "(no title)"
            url = get_text(it, "./link")
            # pubDate or dc:date
            pub = get_text(it, "./pubDate") or get_text(it, "./{http://purl.org/dc/elements/1.1/}date")
            out.append(FeedItem(title=title, url=url, published_at=to_iso(pub)))
        return out

    # ---------- Atom ----------
    if tag == "feed":
        # feed-level link fallback (when <entry> has no link)
        feed_link = ""
        for lk in root.findall("./{http://www.w3.org/2005/Atom}link"):
            href = (lk.attrib.get("href") or "").strip()
            if href:
                feed_link = href
                break

        for e in root.findall("./{http://www.w3.org/2005/Atom}entry"):
            title = get_text(e, "./{http://www.w3.org/2005/Atom}title") or "(no title)"

            # entry link (may be missing)
            url = ""
            for lk in e.findall("./{http://www.w3.org/2005/Atom}link"):
                href = (lk.attrib.get("href") or "").strip()
                if href:
                    url = href
                    break
            if not url:
                url = feed_link

            updated = get_text(e, "./{http://www.w3.org/2005/Atom}updated")
            published = get_text(e, "./{http://www.w3.org/2005/Atom}published")
            out.append(FeedItem(title=title, url=url, published_at=to_iso(published or updated)))
        return out

    # ---------- Fallback: try Atom then RSS ----------
    # Some feeds may have unexpected root tags; attempt best-effort parsing.
    try:
        # Atom-like: look for entry elements
        entries = root.findall(".//{http://www.w3.org/2005/Atom}entry")
        if entries:
            feed_link = ""
            lk0 = root.find(".//{http://www.w3.org/2005/Atom}link")
            if lk0 is not None:
                feed_link = (lk0.attrib.get("href") or "").strip()

            for e in entries:
                title = get_text(e, "./{http://www.w3.org/2005/Atom}title") or "(no title)"
                url = ""
                for lk in e.findall("./{http://www.w3.org/2005/Atom}link"):
                    href = (lk.attrib.get("href") or "").strip()
                    if href:
                        url = href
                        break
                if not url:
                    url = feed_link
                updated = get_text(e, "./{http://www.w3.org/2005/Atom}updated")
                published = get_text(e, "./{http://www.w3.org/2005/Atom}published")
                out.append(FeedItem(title=title, url=url, published_at=to_iso(published or updated)))
            return out
    except Exception:
        pass

    try:
        # RSS-like: look for item elements
        for it in root.findall(".//item"):
            title = get_text(it, "./title") or "(no title)"
            url = get_text(it, "./link")
            pub = get_text(it, "./pubDate") or get_text(it, "./{http://purl.org/dc/elements/1.1/}date")
            out.append(FeedItem(title=title, url=url, published_at=to_iso(pub)))
    except Exception:
        pass

    return out


def parse_opml(xml_bytes: bytes) -> list[str]:
    root = ET.fromstring(xml_bytes)
    urls: list[str] = []
    for o in root.findall(".//outline"):
        xml_url = o.attrib.get("xmlUrl") or o.attrib.get("xmlurl")
        if xml_url:
            urls.append(xml_url.strip())
    return list(dict.fromkeys(urls))


def parse_cap_alert(xml_bytes: bytes) -> list[FeedItem]:
    root = ET.fromstring(xml_bytes)
    if _strip_ns(root.tag).lower() != "alert":
        return []

    # sent might be nested, so iterate
    sent = None
    for el in root.iter():
        if _strip_ns(el.tag).lower() == "sent":
            sent = _parse_time(_txt(el))
            break

    out: list[FeedItem] = []
    for info in root.iter():
        if _strip_ns(info.tag).lower() != "info":
            continue

        headline = ""
        event = ""
        web = ""
        for c in list(info):
            n = _strip_ns(c.tag).lower()
            if n == "headline":
                headline = _txt(c)
            elif n == "event":
                event = _txt(c)
            elif n == "web":
                web = _txt(c)

        title = headline or event or "CAP Alert"
        out.append(FeedItem(title=title, url=web, published_at=sent))

    return out


def parse_any_feed(xml_bytes: bytes) -> list[FeedItem]:
    root = ET.fromstring(xml_bytes)
    tag = _strip_ns(root.tag).lower()
    if tag == "alert":
        return parse_cap_alert(xml_bytes)
    return parse_rss_or_atom(xml_bytes)
