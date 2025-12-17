from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from travel_tracker.core.http_client import PoliteHttpClient


@dataclass
class FlightDeal:
    source_id: str
    origin: str
    destination: str
    title: str
    url: str
    price: float | None
    currency: str | None
    observed_at: str


def _now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _safe_slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("_")


def _extract_currency_and_price(html: str) -> tuple[str | None, float | None]:
    """
    Best-effort extraction for Trip.com airfares pages.
    We try multiple patterns because markup changes frequently.
    """

    # 1) Try to find embedded JSON blobs with price fields (common on OTA pages)
    # Look for "lowestPrice" / "minPrice" / "price" near currency.
    candidates = []

    # JSON-like key/value patterns
    json_price_patterns = [
        r'"lowestPrice"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"minPrice"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"price"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"amount"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
    ]
    for pat in json_price_patterns:
        for m in re.finditer(pat, html):
            candidates.append(m.group(1))

    # Currency patterns in JSON (e.g. "currency":"SGD")
    mcur = re.search(r'"currency"\s*:\s*"([A-Z]{3})"', html)
    currency = mcur.group(1) if mcur else None

    # If we got numeric candidates, choose the smallest plausible one (>0)
    price = None
    for s in candidates:
        try:
            v = float(s)
            if v > 0:
                price = v if price is None else min(price, v)
        except Exception:
            continue

    if currency and price is not None:
        return currency, price

    # 2) Fallback: text currency symbols + number
    # Examples: "S$123", "RM 456", "$789" (ambiguous), "SGD 123"
    sym_map = {
        "S$": "SGD",
        "RM": "MYR",
        "฿": "THB",
        "NT$": "TWD",
        "Rp": "IDR",
        "₱": "PHP",
        "₫": "VND",
        "¥": "JPY",
    }

    # Prefer explicit 3-letter currencies
    m = re.search(r"\b([A-Z]{3})\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?)\b", html)
    if m:
        c = m.group(1)
        p = float(m.group(2).replace(",", ""))
        if p > 0:
            return c, p

    # Symbols
    for sym, cur in sym_map.items():
        m2 = re.search(re.escape(sym) + r"\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?)", html)
        if m2:
            p = float(m2.group(1).replace(",", ""))
            if p > 0:
                return cur, p

    # Dollar sign ambiguous: treat as None currency
    m3 = re.search(r"\$\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?)", html)
    if m3:
        p = float(m3.group(1).replace(",", ""))
        if p > 0:
            return None, p

    return None, None


def load_routes(path: str | Path = "config/flights_tripcom_airfares.json") -> list[dict[str, Any]]:
    p = Path(path)
    data = json.loads(p.read_text(encoding="utf-8"))
    routes = data.get("routes", [])
    if not isinstance(routes, list):
        raise ValueError("config routes must be a list")
    return routes


def fetch_tripcom_airfares_deals(
    run_date: str,
    client: PoliteHttpClient,
    raw_dir: Path,
    routes: list[dict[str, Any]],
) -> list[FlightDeal]:
    deals: list[FlightDeal] = []
    raw_dir.mkdir(parents=True, exist_ok=True)

    for r in routes:
        sid = str(r.get("id") or "")
        origin = str(r.get("origin") or "").upper()
        dest = str(r.get("destination") or "").upper()
        url = str(r.get("url") or "")

        if not (sid and origin and dest and url):
            continue

        resp = client.get(url)
        html = (resp.body or b"").decode("utf-8", errors="replace")

        # Save raw
        out = raw_dir / origin / f"{_safe_slug(sid)}.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(html, encoding="utf-8")

        cur, price = _extract_currency_and_price(html)
        title = f"Trip.com airfares {origin}->{dest}"

        deals.append(
            FlightDeal(
                source_id=sid,
                origin=origin,
                destination=dest,
                title=title,
                url=url,
                price=price,
                currency=cur,
                observed_at=_now_iso(),
            )
        )

    return deals
