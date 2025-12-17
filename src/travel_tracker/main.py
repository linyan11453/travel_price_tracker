from travel_tracker.pipelines.daily_news import run_daily_news
import argparse
from datetime import datetime
from pathlib import Path

import os
from travel_tracker.pipelines.daily_snapshot import run_daily
from travel_tracker.pipelines.biweekly_report import run_biweekly
from travel_tracker.reporting.render_md import write_markdown_report


def _today_ymd() -> str:
    return datetime.now().strftime("%Y-%m-%d")


def main() -> int:
    p = argparse.ArgumentParser(prog="travel_price_tracker")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("daily", help="Run daily snapshot (max once/day; use --force to rerun)")
    d.add_argument("--date", default=_today_ymd())
    d.add_argument("--force", action="store_true", help="Rerun daily even if already ran for the date")

    b = sub.add_parser("biweekly", help="Run biweekly report")
    b.add_argument("--date", default=_today_ymd())

    n = sub.add_parser("news", help="Ingest news RSS into DB")
    n.add_argument("--date", default=_today_ymd())
    n.add_argument("--config", default="config/news_sources.yaml")

    n.add_argument("--max-per-source", type=int, default=20)
    args = p.parse_args()

    if args.cmd == "daily":
        result = run_daily(args.date, force=args.force)
        out = write_markdown_report(
            Path("reports/daily"),
            f"daily_{args.date}.md",
            f"Daily Snapshot - {args.date}",
            result["sections"],
        )
        print(f"[OK] {out}")
        return 0

    if args.cmd == "biweekly":

        # Refuse to run biweekly in limited-city mode (safety guard)

        limit_raw = os.getenv('TRAVEL_LIMIT_CITIES', '').strip()

        if limit_raw:

            raise SystemExit(

                f"[GUARD] biweekly is disabled when TRAVEL_LIMIT_CITIES is set: {limit_raw}. "

                f"Unset TRAVEL_LIMIT_CITIES to run full biweekly."

            )

        result = run_biweekly(args.date)
        out = write_markdown_report(
            Path("reports/biweekly"),
            f"biweekly_{args.date}.md",
            f"Biweekly Report - {args.date}",
            result["sections"],
        )
        print(f"[OK] {out}")
        return 0

    if args.cmd == "news":
        result = run_daily_news(args.config, max_per_source=args.max_per_source)
        sections = [
            {"h2": "Run Date", "body": args.date},
            {"h2": "Config", "body": args.config},
            {"h2": "Summary", "body": f"sources={result.get('sources')} total={result.get('total')} inserted={result.get('inserted')}"},
        ]
        out = write_markdown_report(
            Path("reports/news"),
            f"news_{args.date}.md",
            f"News Ingest - {args.date}",
            sections,
        )
        print(f"[NEWS] sources={result.get('sources')} total={result.get('total')} inserted={result.get('inserted')}", flush=True)
        print(f"[OK] {out}")
        return 0

    return 2
if __name__ == "__main__":
    raise SystemExit(main())


