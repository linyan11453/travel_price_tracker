#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

mkdir -p logs
poetry run python -m travel_tracker.main daily --force 2>&1 | tee logs/daily.log

# ---- latest pointers (portfolio-friendly) ----
LATEST_DAILY="$(ls -1t reports/daily/daily_*.md | head -n 1 || true)"
if [ -n "${LATEST_DAILY:-}" ] && [ -f "$LATEST_DAILY" ]; then
  mkdir -p reports/daily
  cp -f "$LATEST_DAILY" reports/daily/latest.md
  cp -f "$LATEST_DAILY" reports/latest.md
  echo "[OK] reports/latest.md updated -> $LATEST_DAILY"
fi
