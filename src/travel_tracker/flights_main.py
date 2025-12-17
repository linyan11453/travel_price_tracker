from __future__ import annotations

import argparse
from datetime import date

from travel_tracker.pipelines.flights_snapshot import run_flights

def main() -> int:
    p = argparse.ArgumentParser(prog="travel_flights")
    p.add_argument("--date", default=date.today().isoformat(), help="YYYY-MM-DD (default: today)")
    p.add_argument("--force", action="store_true", help="reserved (kept for compatibility)")
    args = p.parse_args()

    res = run_flights(args.date, force=args.force)
    print(f"[OK] {res['report']}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
