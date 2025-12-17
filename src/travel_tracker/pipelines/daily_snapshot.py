from __future__ import annotations

import hashlib
from collections import defaultdict
from datetime import datetime
from pathlib import Path
import os
from typing import Any

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.sources.news.collector import fetch_items
from travel_tracker.sources_loader import load_sources
from travel_tracker.storage.repository import Repository


TOP_NEWS = 5
TOP_WEATHER = 3
TOP_SAFETY = 5


def _dt_key(published_at: str | None, created_at: str | None) -> datetime:
    for s in (published_at, created_at):
        if not s:
            continue
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        except Exception:
            pass
    return datetime.min


def _md_escape(s: str) -> str:
    # minimal escape for markdown links
    return (s or "").replace("]", "\\]")



# --- TW city-level filter (report only) ---
TW_CITY_KEYWORDS = {
    "TPE": ["臺北", "台北", "新北", "基隆"],
    "KHH": ["高雄"],
    "TNN": ["臺南", "台南"],
}

def _filter_tw_weather(city_code: str, items: list[dict]) -> list[dict]:
    kws = TW_CITY_KEYWORDS.get(city_code)
    if not kws:
        return items

    def hit(title: str) -> bool:
        t = title or ""
        return any(k in t for k in kws)

    kept = [it for it in items if hit(it.get("title", ""))]
    # 若全部被濾光，保留原本資料避免整段變空（你可以之後改成回傳 kept）
    return kept if kept else items



# --- City-level filter for NEWS (report only): must match city keywords, otherwise skip ---
CITY_NEWS_KEYWORDS = {
    "KUL": ["kuala lumpur", "kl", "putrajaya", "selangor", "petaling jaya", "pj", "吉隆坡"],
    "PEN": ["penang", "george town", "georgetown", "seberang perai", "butterworth", "檳城", "槟城"],

    "SIN": ["singapore", "新加坡"],
    "JKT": ["jakarta", "雅加达", "雅加達"],
    "DPS": ["bali", "denpasar", "峇里島", "巴厘", "登巴薩"],
    "HKT": ["phuket", "普吉"],
    "CNX": ["chiang mai", "清邁"],
    "BKK": ["bangkok", "曼谷"],

    "PQC": ["phu quoc", "富國", "富国"],
    "SGN": ["ho chi minh", "saigon", "胡志明", "西贡", "西貢"],

    "MPH": ["boracay", "長灘", "长滩"],
    "CEB": ["cebu", "宿霧", "宿雾"],
    "PPS": ["palawan", "puerto princesa", "巴拉望", "巴拉望島", "公主港"],

    "TPE": ["taipei", "臺北", "台北", "new taipei", "新北", "keelung", "基隆"],
    "KHH": ["kaohsiung", "高雄"],
    "TNN": ["tainan", "臺南", "台南"],

    "CTS": ["hokkaido", "sapporo", "北海道", "札幌"],
    "OSA": ["osaka", "大阪"],
    "TYO": ["tokyo", "東京"],
    "OKA": ["okinawa", "naha", "沖繩", "冲绳", "那覇", "那霸"],
}

def _filter_city_news(city_code: str, items: list[dict]) -> list[dict]:
    kws = CITY_NEWS_KEYWORDS.get(city_code)
    if not kws:
        # 若你要「所有城市都必須符合城市條件」：把這行改成 `return []`
        return items

    kws_l = [k.lower() for k in kws]

    kept = []
    for it in items:
        title = (it.get("title") or "").lower()
        url = (it.get("url") or "").lower()
        if any(k in title for k in kws_l) or any(k in url for k in kws_l):
            kept.append(it)

    # 不做 fallback：只符合國家但不符合城市 -> 直接跳過
    return kept


def _fmt_items(items: list[dict], topn: int) -> str:
    if not items:
        return "- (none)"
    lines = []
    seen = set()
    for it in items:
        title = _md_escape(it.get("title", "") or "")
        url = (it.get("url", "") or "").strip()
        key = (title.strip().lower(), url.lower())
        if key in seen:
            continue
        seen.add(key)

        ts = (it.get("published_at") or "").strip()
        if url:
            lines.append(f"- [{title}]({url}){(' — ' + ts) if ts else ''}")
        else:
            lines.append(f"- {title}{(' — ' + ts) if ts else ''}")

        if len(lines) >= topn:
            break

    return "\n".join(lines) if lines else "- (none)"


def _apply_limit_cities(destinations, limit_raw: str):
    """
    TRAVEL_LIMIT_CITIES 支援：
    - 城市代碼：TPE,BKK
    - 中文名：台北,曼谷（用 destination.name_zh 對照）
    - 台/臺同義
    """
    tokens = [t.strip() for t in (limit_raw or "").split(",") if t.strip()]
    if not tokens:
        return destinations

    by_id = {getattr(d, "id", "").upper(): d for d in destinations}
    by_zh = {}
    for d in destinations:
        name = (getattr(d, "name_zh", "") or "").strip()
        if name:
            by_zh[name] = d
            by_zh[name.replace("臺", "台")] = d

    chosen = []
    unknown = []
    for t in tokens:
        key = t.upper()
        if key in by_id:
            chosen.append(by_id[key]); continue
        if t in by_zh:
            chosen.append(by_zh[t]); continue
        t2 = t.replace("臺", "台")
        if t2 in by_zh:
            chosen.append(by_zh[t2]); continue
        unknown.append(t)

    # de-dup keep order
    seen = set()
    uniq = []
    for d in chosen:
        cid = getattr(d, "id", None)
        if cid and cid not in seen:
            uniq.append(d)
            seen.add(cid)

    print(f"[LIMIT] TRAVEL_LIMIT_CITIES={limit_raw} -> {[(getattr(d,'id',''), getattr(d,'name_zh','')) for d in uniq]}")
    if unknown:
        print(f"[WARN] Unknown city tokens ignored: {unknown}")
    return uniq


def run_daily(run_date: str, *, force: bool = False) -> dict[str, Any]:
    repo = Repository()
    repo.init_schema()

    # Clear previous source_errors for this date (avoid stale errors confusing the summary)
    err_file = Path("reports/daily") / f"source_errors_{run_date}.md"
    if err_file.exists():
        err_file.unlink()

    if (not force) and repo.has_daily_run(run_date):
        sections = [
            {
                "h2": "Run Summary",
                "body": "\n".join([
                    "- skipped: already has daily run (use --force to rerun)",
                ]),
            }
        ]
        return {"sections": sections}

    if force:
        repo.delete_daily_run(run_date)

    client = PoliteHttpClient(cache_dir="data/cache/http", rps=0.2, timeout_seconds=8, max_retries=1)

    bundle = load_sources("data/sources.json")


    # -----------------------------
    # City keyword filtering (strict)
    # -----------------------------
    import os, json

    require_city_match = os.getenv("TRAVEL_REQUIRE_CITY_MATCH", "1").strip() not in {"0","false","False"}
    kw_path = os.getenv("TRAVEL_CITY_KEYWORDS", "data/city_keywords.json")
    city_kw = {}
    try:
        kw_file = Path(kw_path)
        if kw_file.exists():
            city_kw = json.loads(kw_file.read_text(encoding="utf-8"))
    except Exception:
        city_kw = {}

    def _match_city_kw(city_code: str, kind: str, title: str, url: str) -> bool:
        """
        kind: news/weather/safety
        規則：
          - strict(require_city_match=1) 時：該 city 若沒有 keywords -> 直接視為不匹配（跳過）
          - 有 keywords -> title/url 任一包含關鍵字即匹配
        """
        city_code = (city_code or "").upper()
        kw = (city_kw.get(city_code, {}) or {}).get(kind, []) or []
        if require_city_match and not kw:
            return False
        hay = f"{title or ''}\n{url or ''}"
        return any(k and k in hay for k in kw) if kw else True
    limit_raw = os.getenv("TRAVEL_LIMIT_CITIES", "").strip()

    if limit_raw:

        bundle.destinations = _apply_limit_cities(bundle.destinations, limit_raw)


    inserted = {"news": 0, "weather": 0, "safety": 0}
    fetch_errors = {"news": 0, "weather": 0, "safety": 0, "opml": 0}

    errors: list[str] = []

    def _write_err(scope: str, city_id: str, source_id: str, url: str, exc: Exception) -> None:
        errors.append(f"- [{datetime.now().isoformat(timespec='seconds')}] [{scope}:{city_id}] {source_id} {url}\n  - {repr(exc)}")

    # generic runner for news/weather/safety
    def _run_kind(kind: str, sources: list[Any], table: str) -> None:
        nonlocal inserted

        for d in bundle.destinations:
            # match by country code (ISO-2 in your current sources.json)
            matched = [s for s in sources if getattr(s, "country", None) == d.country and (getattr(s, "type", "") or "").lower() != "todo"]
            for s in matched:
                stype = (s.type or "").lower()
                raw_dir = Path(f"data/raw/{run_date}/{kind}/{d.id}")
                raw_dir.mkdir(parents=True, exist_ok=True)

                try:
                    if stype == "opml":
                        raw_path = raw_dir / f"{s.id}.opml"
                        _, urls = fetch_items(client=client, url=s.url, source_type="opml", raw_path=raw_path)
                        # expand OPML into child feeds
                        for u in urls:
                            sid = f"{s.id}__{hashlib.md5(u.encode('utf-8')).hexdigest()[:8]}"
                            child_raw = raw_dir / f"{sid}.xml"
                            try:
                                items, _ = fetch_items(client=client, url=u, source_type="rss", raw_path=child_raw)
                                for it in items:
                                    repo.insert_signal(table, run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)
                                    inserted[kind] += 1
                                repo.commit()
                            except Exception as e:
                                fetch_errors["opml"] += 1
                                _write_err(kind, d.id, sid, u, e)
                        continue

                    raw_path = raw_dir / f"{s.id}.xml"
                    items, _ = fetch_items(client=client, url=s.url, source_type=stype, raw_path=raw_path)
                    for it in items:
                        repo.insert_signal(table, run_date, d.id, d.name_zh, s.id, it.title, it.url, it.published_at)
                        inserted[kind] += 1
                    repo.commit()

                except Exception as e:
                    fetch_errors[kind] += 1
                    _write_err(kind, d.id, s.id, s.url, e)

    _run_kind("news", bundle.news, "signals_news")
    _run_kind("weather", bundle.weather, "signals_weather")
    _run_kind("safety", bundle.safety, "signals_safety")

    # record run
    repo.record_run("daily", run_date)

    # write source_errors if any
    if errors:
        err_file.parent.mkdir(parents=True, exist_ok=True)
        err_file.write_text("# Source Errors (" + run_date + ")\n\n" + "\n".join(errors) + "\n", encoding="utf-8")

    # Build grouped report from DB (per city)
    def _fetch(table: str) -> list[dict]:
        cols = repo._table_cols(table)  # cached pragma
        source_col = "source_id" if "source_id" in cols else ("source" if "source" in cols else None)
        sel = ["city_code", "city_name_zh", "title", "url", "published_at", "created_at"]
        if source_col:
            sel.insert(2, f"{source_col} AS source_id")
        q = f"SELECT {', '.join(sel)} FROM {table} WHERE run_date=?"
        rows = repo.conn.execute(q, (run_date,)).fetchall()
        out = []
        for r in rows:
            # tuple mapping by position
            dct = {sel[i].split(" AS ")[-1]: r[i] for i in range(len(sel))}
            out.append(dct)
        return out

    news_rows = _fetch("signals_news")
    weather_rows = _fetch("signals_weather")
    safety_rows = _fetch("signals_safety")

    by_city: dict[str, dict[str, Any]] = {}
    def _ensure(city_code: str, city_name_zh: str) -> dict[str, Any]:
        if city_code not in by_city:
            by_city[city_code] = {"city_name_zh": city_name_zh, "news": [], "weather": [], "safety": []}
        return by_city[city_code]

    for r in news_rows:
        _ensure(r["city_code"], r["city_name_zh"])["news"].append(r)
    for r in weather_rows:
        _ensure(r["city_code"], r["city_name_zh"])["weather"].append(r)
    for r in safety_rows:
        _ensure(r["city_code"], r["city_name_zh"])["safety"].append(r)

    for city_code, payload in by_city.items():
        for k in ("news", "weather", "safety"):
            payload[k].sort(key=lambda x: _dt_key(x.get("published_at"), x.get("created_at")), reverse=True)

    # Sections
    summary_lines = [
        f"- inserted news: {inserted['news']}",
        f"- inserted weather: {inserted['weather']}",
        f"- inserted safety: {inserted['safety']}",
        "",
        f"- fetch errors: news={fetch_errors['news']}, weather={fetch_errors['weather']}, safety={fetch_errors['safety']}, opml={fetch_errors['opml']}",
        "",
        "Raw files: data/raw/<run_date>/(news|weather|safety)/<CITY>/<SOURCE_ID>.xml",
        "Cache: data/cache/http/ (ETag/Last-Modified + body)",
        "If errors>0: see reports/daily/source_errors_<run_date>.md",
    ]
    sections = [{"h2": "Run Summary", "body": "\n".join(summary_lines)}]

    # City blocks (only include cities with any items)
    for city_code in sorted(by_city.keys()):
        c = by_city[city_code]
        # City-level news filter (report only)
        c["news"] = _filter_city_news(city_code, c.get("news", []))

        # TW weather keyword filter (report only)
        c["weather"] = _filter_tw_weather(city_code, c.get("weather", []))

        if not (c["news"] or c["weather"] or c["safety"]):
            continue
        body = []
        body.append(f"### News (Top {TOP_NEWS})")
        body.append(_fmt_items(c["news"], TOP_NEWS))
        body.append("")
        body.append(f"### Weather (Top {TOP_WEATHER})")
        body.append(_fmt_items(c["weather"], TOP_WEATHER))
        body.append("")
        body.append(f"### Safety (Top {TOP_SAFETY})")
        body.append(_fmt_items(c["safety"], TOP_SAFETY))

        sections.append({"h2": f"{city_code} {c['city_name_zh']}", "body": "\n".join(body)})

    repo.close()
    return {"sections": sections}
