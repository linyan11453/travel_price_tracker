from __future__ import annotations

from datetime import date as _date
from travel_tracker.sources_loader import load_sources
from travel_tracker.storage.repository import Repository
from travel_tracker.sources.news_rss import NewsSource, fetch_rss_items


def run_daily_news(
    run_date: str | None = None,
    city_code: str = "SIN",
    max_per_source: int = 20,
    only_cna: bool = True,
) -> dict:
    """
    從 data/sources.json 讀取新聞 RSS（建議以 CNA 為主），抓取後寫入 signals_news。
    - run_date: YYYY-MM-DD，None 則用今天
    - city_code: 例如 SIN
    - max_per_source: 每個來源最多處理幾筆
    - only_cna: True 則只跑 tags 含 cna 的來源（你要的：不要海峽日報）
    """
    d = run_date or _date.today().strftime("%Y-%m-%d")
    city_code = city_code.upper()

    bundle = load_sources("data/sources.json")

    # 找城市中文名（若找不到就留空字串）
    city_name_zh = ""
    for dest in bundle.destinations:
        if dest.id.upper() == city_code:
            city_name_zh = dest.name_zh
            break

    # 由 sources.json 的 bundle.news 產生 NewsSource
    sources_list: list[tuple[str, NewsSource]] = []
    for s in bundle.news:
        tags = [t.upper() for t in (s.tags or [])]
        if city_code not in tags:
            continue
        if only_cna and ("CNA" not in [t.upper() for t in (s.tags or [])]):
            continue

        # 用 s.id 當 source_id（寫入 signals_news 的 source_id 欄位）
        ns = NewsSource(
            city=city_code,
            topic="news",
            source=s.id,      # 這裡先塞 id，後面會同時寫入 source/source_id
            rss_url=s.url,
        )
        sources_list.append((s.id, ns))

    repo = Repository()
    inserted = 0
    total_seen = 0
    sources_ok = 0

    try:
        repo.init_schema()

        for source_id, src in sources_list:
            c = 0
            any_ok = False
            for item in fetch_rss_items(src):
                total_seen += 1

                # 強制補齊 signals_news 需要的欄位（以你實際表結構為準）
                item.setdefault("run_date", d)
                item.setdefault("city_code", city_code)
                item.setdefault("city_name_zh", city_name_zh)
                item.setdefault("source", source_id)
                item.setdefault("source_id", source_id)

                # 重要：寫入 signals_news（不要再寫 news_items）
                if repo.insert_signal("signals_news", item):
                    inserted += 1
                any_ok = True

                c += 1
                if c >= max_per_source:
                    break

            if any_ok:
                sources_ok += 1

        return {
            "run_date": d,
            "city_code": city_code,
            "sources_total": len(sources_list),
            "sources_ok": sources_ok,
            "total_seen": total_seen,
            "inserted": inserted,
            "max_per_source": max_per_source,
            "only_cna": only_cna,
        }
    finally:
        repo.close()
