#!/usr/bin/env bash
set -euo pipefail

cd "$HOME/Desktop/程式學習/爬蟲專案/旅遊/travel_price_tracker"

mkdir -p logs

RUN_DATE="$(date +%F)"

# 1) biweekly report (full)
poetry run python -m travel_tracker.main biweekly >> logs/biweekly_auto.log 2>&1

# 2) flights full snapshot
TRAVEL_FLIGHTS_USE_PW=1 \
TRAVEL_FLIGHTS_MAX_ROUTES=999 \
TRAVEL_TIMEOUT=25 \
TRAVEL_RETRIES=0 \
poetry run python -m travel_tracker.flights_main --force >> logs/biweekly_auto.log 2>&1

# 3) flights summary (md + csv)
poetry run python -m travel_tracker.flights_report_main --date "$RUN_DATE" --provider tripcom --top 20 \
  >> logs/biweekly_auto.log 2>&1

echo "[OK] biweekly+flights done: $RUN_DATE" >> logs/biweekly_auto.log
