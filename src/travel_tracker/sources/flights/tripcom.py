from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from travel_tracker.core.http_client import PoliteHttpClient

@dataclass(frozen=True)
class TripcomRoute:
    route_id: str
    origin: str
    destination: str
    url: str

def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))

def load_tripcom_routes(path: str | Path = "config/flights_tripcom_routes.json") -> list[TripcomRoute]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"routes file not found: {p}")

    data = _read_json(p)
    if isinstance(data, dict) and "routes" in data:
        data = data["routes"]

    if not isinstance(data, list):
        raise ValueError("routes json must be a list (or {routes:[...]})")

    out: list[TripcomRoute] = []
    for r in data:
        if not isinstance(r, dict):
            continue
        rid = str(r.get("route_id") or r.get("id") or r.get("name") or "").strip()
        org = str(r.get("origin") or "").strip().upper()
        dst = str(r.get("destination") or "").strip().upper()
        url = str(r.get("url") or "").strip()
        if not (rid and org and dst and url):
            continue
        out.append(TripcomRoute(route_id=rid, origin=org, destination=dst, url=url))
    return out

def fetch_route_html(
    *,
    client: PoliteHttpClient,
    route: TripcomRoute,
    raw_path: Path,
    use_playwright: bool | None = None,
) -> dict[str, object]:
    """
    Canonical return:
      {
        "source_url": str,
        "status_code": int|None,
        "html_bytes": bytes,
        "notes": str|None,
      }
    """
    if use_playwright is None:
        use_playwright = os.getenv("TRAVEL_FLIGHTS_USE_PW", "").strip() in {"1", "true", "yes", "on"}

    url = route.url
    status_code: int | None = None
    notes: str | None = None
    html_bytes: bytes = b""

    try:
        if use_playwright:
            from travel_tracker.sources.flights.tripcom_pw import fetch_html
            html_bytes = fetch_html(url, timeout_seconds=int(os.getenv("TRAVEL_TIMEOUT", "20")))
            status_code = 200
            notes = "pw=1"
        else:
            resp = client.get(url)
            # PoliteHttpClient may return HttpResponse or raw bytes depending on older patches
            body = getattr(resp, "body", None)
            html_bytes = body if isinstance(body, (bytes, bytearray)) else (resp if isinstance(resp, (bytes, bytearray)) else b"")
            status_code = getattr(resp, "status", None) or getattr(resp, "status_code", None)
            notes = "pw=0"
    except Exception as e:
        notes = f"fetch_error={type(e).__name__}:{e}"
        html_bytes = b""
        status_code = status_code or None

    raw_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.write_bytes(html_bytes)

    return {
        "source_url": url,
        "status_code": status_code,
        "html_bytes": html_bytes,
        "notes": notes,
    }
