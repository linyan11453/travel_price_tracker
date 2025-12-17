#!/usr/bin/env bash
set -euo pipefail

# 1) 強化 alerts：把 source 失敗記到獨立檔案（不覆蓋 NEEDS_HUMAN）
cat > src/travel_tracker/human_in_loop/alerts.py <<'PY'
from __future__ import annotations

from pathlib import Path
from datetime import datetime

def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")

def write_human_alert(run_date: str, reason: str, next_step: str) -> Path:
    out_dir = Path("reports/daily")
    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / f"NEEDS_HUMAN_{run_date}.md"
    p.write_text(
        "\n".join([
            f"# Needs Human Intervention ({run_date})",
            "",
            "## Reason",
            reason,
            "",
            "## Next step",
            next_step,
            "",
        ]) + "\n",
        encoding="utf-8",
    )
    return p

def append_source_error(run_date: str, scope: str, source_id: str, url: str, err: str) -> Path:
    out_dir = Path("reports/daily")
    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / f"source_errors_{run_date}.md"
    line = f"- [{_now()}] [{scope}] {source_id} {url}\n  - {err}\n"
    if p.exists():
        p.write_text(p.read_text(encoding="utf-8") + line, encoding="utf-8")
    else:
        p.write_text(f"# Source Errors ({run_date})\n\n{line}", encoding="utf-8")
    return p
PY

# 2) 強化 daily：每個 source try/except，失敗寫入 source_errors_*.md，但不中斷整個 run
cat > src/travel_tracker/pipelines/daily_snapshot.py <<'PY'
from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from travel_tracker.core.http_client import PoliteHttpClient
from travel_tracker.human_in_loop.alerts import write_human_alert, append_source_error
from travel_tracker.sources.news.collector import fetch_items
from travel_tracker.sources_loader import load_sources
from travel_tracker.storage.repository import Repository


def run_daily(run_date: str, *, force: bool = False) -> dict:
    repo = Repository()
    repo.init_schema()

    if repo.has_daily_run(run_date):
        if not force:
            repo.close()
            return {"sections": [{"h2": "Daily Snapshot", "body": f"已存在 {run_date} 的 daily run（每日最多一次）。本次不重跑。"}]}
        repo.delete_daily_run(run_date)

    repo.record_run("daily", run_date)

    client = PoliteHttpClient(cache_dir="data/cache/http", rps=0.2, timeout_seconds=25, max_retries=3)

    counts = defaultdict(int)
    errors = defaultdict(int)

    try:
        bundle = load_sources("data/sources.json")

        # Expand OPML (country-level) — 失敗就跳過，不中斷
        expanded_news: list[tuple[str, str | None, str, str]] = []
        for s in bundle.news:
            if s.type.lower() == "opml":
                raw = Path("data/raw") / run_date / "opml" / f"{s.id}.xml"
                try:
                    _, urls = fetch_items(client=client, url=s.url, source_type="opml", raw_path=raw)
                    for u in urls:
                        expanded_news.append((s.id, s.country, "rss", u))
                except Exception as e:
                    errors["opml"] += 1
                    append_source_error(run_date, "opml", s.id, s.url, repr(e))
            else:
                expanded_news.append((s.id, s.country, s.type, s.url))

        expanded_weather = [(s.id, s.country, s.type, s.url) for s in bundle.weather if s.type.lower() != "todo"]
        expanded_safety  = [(s.id, s.country, s.type, s.url) for s in bundle.safety if s.type.lower() != "todo"]

        # For each destination city: ingest sources by matching country
        for d in bundle.destinations:
            # NEWS
            for sid, scountry, stype, surl in expanded_news:
                if scountry and scountry != d.country:
                    continue
                raw = Path("data/raw") / run_date / "news" / d.id / f"{sid}.xml"
                try:
                    items, _ = fetch_items(client=client, url=surl, source_type=stype, raw_path=raw)
                    for it in items[:50]:
                        repo.insert_signal("signals_news", run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)
                        counts["news"] += 1
                except Exception as e:
                    errors["news"] += 1
                    append_source_error(run_date, f"news:{d.id}", sid, surl, repr(e))

            # WEATHER
            for sid, scountry, stype, surl in expanded_weather:
                if scountry and scountry != d.country:
                    continue
                raw = Path("data/raw") / run_date / "weather" / d.id / f"{sid}.xml"
                try:
                    items, _ = fetch_items(client=client, url=surl, source_type=stype, raw_path=raw)
                    for it in items[:50]:
                        repo.insert_signal("signals_weather", run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)
                        counts["weather"] += 1
                except Exception as e:
                    errors["weather"] += 1
                    append_source_error(run_date, f"weather:{d.id}", sid, surl, repr(e))

            # SAFETY
            for sid, scountry, stype, surl in expanded_safety:
                if scountry and scountry != d.country:
                    continue
                raw = Path("data/raw") / run_date / "safety" / d.id / f"{sid}.xml"
                try:
                    items, _ = fetch_items(client=client, url=surl, source_type=stype, raw_path=raw)
                    for it in items[:50]:
                        repo.insert_signal("signals_safety", run_date, d.id, d.name_zh, sid, it.title, it.url, it.published_at)
                        counts["safety"] += 1
                except Exception as e:
                    errors["safety"] += 1
                    append_source_error(run_date, f"safety:{d.id}", sid, surl, repr(e))

        repo.commit()
        repo.close()

        body_lines = [
            f"- inserted news: {counts['news']}",
            f"- inserted weather: {counts['weather']}",
            f"- inserted safety: {counts['safety']}",
            "",
            f"- fetch errors: news={errors['news']}, weather={errors['weather']}, safety={errors['safety']}, opml={errors['opml']}",
            "",
            "Raw files: data/raw/<run_date>/(news|weather|safety)/<CITY>/<SOURCE_ID>.xml",
            "Cache: data/cache/http/ (ETag/Last-Modified + body)",
            "If errors>0: see reports/daily/source_errors_<run_date>.md",
        ]

        return {"sections": [{"h2": "Run Summary", "body": "\n".join(body_lines)}]}

    except Exception as e:
        # 這裡只留「致命錯誤」：例如 sources.json 不存在、DB 無法寫入等
        write_human_alert(run_date=run_date, reason=str(e), next_step="先確認 data/sources.json 存在、sqlite 可寫入、磁碟權限正常。")
        repo.close()
        raise
PY

echo "[OK] Resilient daily patch applied."
