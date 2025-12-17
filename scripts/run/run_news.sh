#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
cd "$HOME/Desktop/程式學習/爬蟲專案/旅遊/travel_price_tracker"

# 可自行調整 max-per-source
poetry run python -m travel_tracker.main news --max-per-source 10
