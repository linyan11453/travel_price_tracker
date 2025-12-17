from __future__ import annotations

import os
import re
from datetime import date
from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.storage.repository import Repository
from travel_tracker.sources.flights.tripcom import load_tripcom_routes, fetch_route_html, TripcomRoute

def _today_iso() -> str:
    return date.today().isoformat()

def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)).strip())
    except Exception:
        return default

def _env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)).strip())
    except Exception:
        return default

def _extract_min_price_from_title(html_bytes: bytes) -> tuple[int, str | None, float | None, str | None]:
    """
    Trip.com pages (often) include 'from US$77' in <title>.
    We parse that as a best-effort baseline.
    Returns: (parse_ok, currency, value, note)
    """
    try:
        html = html_bytes.decode("utf-8", errors="ignore")
    except Exception:
        return 0, None, None, "decode_failed"

    m = re.search(r"<title[^>]*>(.*?)</title>", html, flags=re.IGNORECASE | re.DOTALL)
    title = (m.group(1).strip() if m else "")
    if not title:
        return 0, None, None, "no_title"

    # from US$77 | from S$72 | from RM 55 | from ฿1,234 etc.
    mm = re.search(r"\bfrom\s+((?:US\$|S\$|HK\$|NT\$|RM|฿|₱|¥|€|£))\s*([0-9][0-9,]*(?:\.[0-9]+)?)", title, flags=re.IGNORECASE)
    if not mm:
        return 0, None, None, "no_from_price_in_title"

    cur_raw = mm.group(1)
    val_raw = mm.group(2).replace(",", "")
    try:
        val = float(val_raw)
    except Exception:
        return 0, None, None, "price_parse_failed"

    cur_map = {
        "US$": "USD",
        "S$": "SGD",
        "HK$": "HKD",
        "NT$": "TWD",
        "RM": "MYR",
        "฿": "THB",
        "₱": "PHP",
        "¥": "JPY",
        "€": "EUR",
        "£": "GBP",
    }
    cur = cur_map.get(cur_raw, cur_raw)
    return 1, cur, val, "title_from_price"

def run_flights(run_date: str | None = None, *, force: bool = False) -> dict[str, object]:
    run_date = run_date or _today_iso()

    max_routes = _env_int("TRAVEL_FLIGHTS_MAX_ROUTES", 0)  # 0 = all
    rps = _env_float("TRAVEL_RPS", 0.2)
    timeout = _env_int("TRAVEL_TIMEOUT", 12)
    retries = _env_int("TRAVEL_RETRIES", 0)

    routes = load_tripcom_routes()
    if max_routes and max_routes > 0:
        routes = routes[:max_routes]

    client = PoliteHttpClient(cache_dir="data/cache/http", rps=rps, timeout_seconds=timeout, max_retries=retries)
    repo = Repository()

    inserted = 0
    total = 0

    report_lines: list[str] = []
    report_lines.append(f"# Flights Snapshot - {run_date}")
    report_lines.append("")
    report_lines.append("## Run Summary")
    report_lines.append(f"- routes: {len(routes)}")
    report_lines.append(f"- provider: tripcom")
    report_lines.append(f"- use_playwright: {os.getenv('TRAVEL_FLIGHTS_USE_PW','')}")
    report_lines.append("")

    for rt in routes:
        total += 1

        raw_dir = Path("data/raw") / run_date / "flights" / rt.origin / rt.destination
        raw_path = raw_dir / f"{rt.route_id}.html"

        res = fetch_route_html(client=client, route=rt, raw_path=raw_path)

        html_bytes = res.get("html_bytes") if isinstance(res, dict) else b""
        if not isinstance(html_bytes, (bytes, bytearray)):
            html_bytes = b""

        status_code = res.get("status_code") if isinstance(res, dict) else None
        if isinstance(status_code, str) and status_code.isdigit():
            status_code = int(status_code)
        if not isinstance(status_code, int):
            status_code = None

        notes = res.get("notes") if isinstance(res, dict) else None
        if notes is not None and not isinstance(notes, str):
            notes = str(notes)

        parse_ok, cur, val, parse_note = _extract_min_price_from_title(bytes(html_bytes))
        if notes:
            notes = f"{notes}; {parse_note}"
        else:
            notes = parse_note

        payload = {
            "run_date": run_date,
            "provider": "tripcom",
            "origin": rt.origin,
            "destination": rt.destination,
            "route_id": rt.route_id,
            "source_url": str(res.get("source_url") if isinstance(res, dict) else rt.url),
            "status_code": status_code,
            "parse_ok": int(parse_ok),
            "min_price_currency": cur,
            "min_price_value": val,
            "raw_path": str(raw_path),
            "notes": notes,
        }

        payload_db = dict(payload)

        payload_db.pop('raw_path', None)

        payload_db.pop('raw_html_path', None)

        payload_db.pop('html_path', None)

        payload_db.pop('raw_file', None)

        repo.insert_flight_quote(**payload_db)
        inserted += 1

        report_lines.append(f"### {rt.route_id} {rt.origin}->{rt.destination}")
        report_lines.append(f"- status_code: {status_code}")
        report_lines.append(f"- parse_ok: {parse_ok}")
        report_lines.append(f"- min_price: {cur or ''} {val or ''}")
        report_lines.append(f"- source: {payload['source_url']}")
        report_lines.append(f"- raw: {raw_path}")
        report_lines.append("")

    repo.commit()
    repo.close()

    out = Path("reports/daily")
    out.mkdir(parents=True, exist_ok=True)
    report_path = out / f"flights_{run_date}.md"
    report_path.write_text("\n".join(report_lines).strip() + "\n", encoding="utf-8")

    return {"run_date": run_date, "routes": len(routes), "inserted": inserted, "report": str(report_path)}
