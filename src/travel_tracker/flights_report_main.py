from __future__ import annotations

import argparse
from datetime import date as _date

from travel_tracker.pipelines.flights_summary import write_flights_summary


def main() -> int:
    ap = argparse.ArgumentParser(prog="travel_flights_report")
    ap.add_argument("--date", default=_date.today().isoformat())
    ap.add_argument("--provider", default="tripcom")
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args()

    out = write_flights_summary(run_date=args.date, provider=args.provider, top_n=args.top)
    print(f"[OK] {out['md']}")
    print(f"[OK] {out['csv']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
