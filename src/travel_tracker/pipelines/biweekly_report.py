from __future__ import annotations

from datetime import datetime, timedelta
from travel_tracker.storage.repository import Repository
from travel_tracker.reporting import md

CITIES = [
    "吉隆坡","濱城","新加坡","峇里島","雅加達","普吉島","清邁","曼谷","富國島","胡志明市",
    "長灘島","宿霧","巴拉望","台北","高雄","台南","北海道","大阪","東京","沖繩"
]

TOPICS = [
    ("crime", "治安新聞"),
    ("weather", "天氣／氣候新聞"),
]

TOP_N_PER_TOPIC = 5
SUMMARY_TOP_N_CITIES = 10


def run_biweekly(run_date: str) -> dict:
    run_dt = datetime.strptime(run_date, "%Y-%m-%d")
    start_dt = run_dt - timedelta(days=13)  # 含今天共 14 天
    print(f"[BIWEEKLY] start run_date={run_date}", flush=True)

    repo = Repository()
    try:
        repo.init_schema()

        sections = [
            {"h2": "Window", "body": f"{start_dt:%Y-%m-%d} ~ {run_date} (14 days, inclusive)"},
            {"h2": "Flights", "body": "_No data (TODO)_"},
            {"h2": "Hotels", "body": "_No data (TODO)_"},
            {"h2": "Daily Cost", "body": "_No data (TODO)_"},
        ]

        # ---- News section ----
        body = []
        body.append(md.p(f"期間：{start_dt:%Y-%m-%d} ~ {run_date}（含今天，共 14 天）"))
        body.append(md.p(f"每城市每類最多顯示 Top {TOP_N_PER_TOPIC} 則（避免報表過長）。"))

        # Summary: top cities by total news count in window
        # Use direct SQL on repo.conn (SQLite) for efficiency
        sql = """
        SELECT city, COUNT(*) AS n
        FROM news_items
        WHERE SUBSTR(COALESCE(published_at, fetched_at), 1, 10) >= ?
          AND SUBSTR(COALESCE(published_at, fetched_at), 1, 10) <= ?
        GROUP BY city
        ORDER BY n DESC, city ASC
        LIMIT ?
        """
        rows = repo.conn.execute(sql, (start_dt.strftime("%Y-%m-%d"), run_date, SUMMARY_TOP_N_CITIES)).fetchall()
        if rows:
            body.append(md.h3("城市新聞量排行（Top）"))
            body.append(md.table(["City", "Items (14d)"], [[r[0], r[1]] for r in rows]))
        else:
            body.append(md.p("_No news data yet. Run `... main news` after setting RSS sources._"))

        any_city = False

        for city in CITIES:
            city_blocks = []
            city_any = False

            for topic_key, topic_name in TOPICS:
                items = repo.list_news(
                    start_date=start_dt.strftime("%Y-%m-%d"),
                    end_date=run_date,
                    city=city,
                    topic=topic_key,
                    limit=TOP_N_PER_TOPIC,
                )

                if items:
                    city_any = True
                    if not city_blocks:
                        city_blocks.append(md.h3(city))
                    city_blocks.append(md.p(f"**{topic_name}（Top {TOP_N_PER_TOPIC}）**"))
                    rows2 = []
                    for it in items:
                        dt = (it.get("published_at") or it.get("fetched_at") or "")[:19]
                        rows2.append([dt, it.get("source", ""), it.get("title", ""), it.get("url", "")])
                    city_blocks.append(md.table(["Date", "Source", "Title", "URL"], rows2))

            if city_any:
                any_city = True
                body.append("".join(city_blocks))

        if not any_city:
            body.append(md.p("_No per-city news found in this window._"))

        sections.append({"h2": "News (Safety + Weather)", "body": "\n".join(body).strip()})
        return {"sections": sections}

    finally:
        repo.close()
