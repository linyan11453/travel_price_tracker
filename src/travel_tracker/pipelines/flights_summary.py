from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

from travel_tracker.storage.db import connect_sqlite


@dataclass
class Dest:
    id: str
    name_zh: str


def _load_destinations_map() -> Dict[str, str]:
    """
    盡量用現有 config/destinations.json（你前面已經有 20 cities）
    若不存在就回傳空 dict（fallback: 只顯示 IATA code）
    """
    p = Path("config/destinations.json")
    if not p.exists():
        return {}
    import json

    data = json.loads(p.read_text(encoding="utf-8"))
    out: Dict[str, str] = {}
    for x in data:
        cid = (x.get("id") or "").upper().strip()
        name = (x.get("name_zh") or "").strip()
        if cid:
            out[cid] = name or cid
    return out


def _query_rows(run_date: str, provider: str) -> List[dict]:
    conn = connect_sqlite()
    try:
        # 1 row per (run_date, provider, origin, destination, route_id) because you UPSERTed
        sql = """
        SELECT
          provider,
          origin,
          destination,
          route_id,
          status_code,
          parse_ok,
          min_price_currency,
          min_price_value,
          source_url,
          created_at
        FROM flights_quotes
        WHERE run_date = ?
          AND provider = ?
        ORDER BY origin, destination, route_id;
        """
        rows = conn.execute(sql, (run_date, provider)).fetchall()
        cols = [d[0] for d in conn.execute("PRAGMA table_info(flights_quotes);").fetchall()]  # not used, keep simple
        # sqlite rows are tuples; map manually by select order:
        out = []
        for r in rows:
            out.append(
                dict(
                    provider=r[0],
                    origin=r[1],
                    destination=r[2],
                    route_id=r[3],
                    status_code=r[4],
                    parse_ok=r[5],
                    min_price_currency=r[6],
                    min_price_value=r[7],
                    source_url=r[8],
                    created_at=r[9],
                )
            )
        return out
    finally:
        conn.close()


def _best_by_pair(rows: List[dict]) -> Dict[Tuple[str, str], dict]:
    """
    同一個 origin->destination 可能有多個 route_id（或將來你加更多 provider）。
    這裡取 parse_ok=1 且 min_price_value 最低者；若都沒有 parse_ok=1，就留空。
    """
    best: Dict[Tuple[str, str], dict] = {}
    for r in rows:
        k = (r["origin"], r["destination"])
        ok = (r.get("parse_ok") == 1) and (r.get("min_price_value") is not None)
        if k not in best:
            best[k] = r
            continue
        cur = best[k]
        cur_ok = (cur.get("parse_ok") == 1) and (cur.get("min_price_value") is not None)
        if ok and (not cur_ok):
            best[k] = r
        elif ok and cur_ok:
            if float(r["min_price_value"]) < float(cur["min_price_value"]):
                best[k] = r
    return best


def write_flights_summary(run_date: str, provider: str = "tripcom", top_n: int = 20) -> dict:
    dest_map = _load_destinations_map()
    rows = _query_rows(run_date, provider)
    best = _best_by_pair(rows)

    # group by origin
    by_origin: Dict[str, List[dict]] = {}
    for (o, d), r in best.items():
        by_origin.setdefault(o, []).append(r)

    # sort inside each origin by price (ok first, then price asc)
    def key_price(r: dict):
        ok = (r.get("parse_ok") == 1) and (r.get("min_price_value") is not None)
        price = float(r["min_price_value"]) if ok else 1e18
        return (0 if ok else 1, price)

    for o in by_origin:
        by_origin[o].sort(key=key_price)

    # write CSV (all best pairs)
    csv_path = Path(f"reports/tables/flights_summary_{run_date}.csv")
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "run_date",
                "provider",
                "origin",
                "destination",
                "destination_name_zh",
                "parse_ok",
                "status_code",
                "min_price_currency",
                "min_price_value",
                "source_url",
                "created_at",
            ]
        )
        for o in sorted(by_origin.keys()):
            for r in by_origin[o]:
                d = (r.get("destination") or "").upper()
                w.writerow(
                    [
                        run_date,
                        provider,
                        r.get("origin"),
                        d,
                        dest_map.get(d, d),
                        r.get("parse_ok"),
                        r.get("status_code"),
                        r.get("min_price_currency"),
                        r.get("min_price_value"),
                        r.get("source_url"),
                        r.get("created_at"),
                    ]
                )

    # write Markdown (Top N per origin)
    md_path = Path(f"reports/daily/flights_summary_{run_date}.md")
    md_path.parent.mkdir(parents=True, exist_ok=True)

    lines: List[str] = []
    lines.append(f"# Flights Summary - {run_date}")
    lines.append("")
    lines.append(f"- provider: {provider}")
    lines.append(f"- routes(best pairs): {sum(len(v) for v in by_origin.values())}")
    lines.append(f"- top_n per origin: {top_n}")
    lines.append("")
    for o in sorted(by_origin.keys()):
        lines.append(f"## {o}")
        lines.append("")
        lines.append("| Destination | Name(zh) | Min Price | Currency | OK | Status | Link | Updated |")
        lines.append("|---|---|---:|---|---:|---:|---|---|")
        for r in by_origin[o][:top_n]:
            d = (r.get("destination") or "").upper()
            name = dest_map.get(d, d)
            ok = r.get("parse_ok") or 0
            st = r.get("status_code") or ""
            cur = r.get("min_price_currency") or ""
            val = r.get("min_price_value")
            val_str = f"{val:.2f}" if isinstance(val, (int, float)) else (str(val) if val is not None else "")
            link = r.get("source_url") or ""
            updated = r.get("created_at") or ""
            lines.append(f"| {d} | {name} | {val_str} | {cur} | {ok} | {st} | {link} | {updated} |")
        lines.append("")

    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {"md": str(md_path), "csv": str(csv_path), "pairs": sum(len(v) for v in by_origin.values())}
