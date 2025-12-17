#!/usr/bin/env bash
set -euo pipefail

# repo root = scripts/run 往上兩層
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 兼容：如果 repo 內仍有 travel_price_tracker 子資料夾就進去，否則就以 ROOT_DIR 當專案根
if [[ -d "$ROOT_DIR/travel_price_tracker" ]]; then
  APP_DIR="$ROOT_DIR/travel_price_tracker"
else
  APP_DIR="$ROOT_DIR"
fi

cd "$APP_DIR"
mkdir -p logs

LOG_FILE="logs/biweekly_auto.log"

{
  echo "===== BIWEEKLY RUN START $(date -u +"%F %T") UTC ====="
  echo "[INFO] app dir: $APP_DIR"
  echo "[INFO] python3: $(command -v python3 || true)"
  echo "[INFO] poetry:  $(command -v poetry  || true)"

  # 依你的專案實際指令調整（示例：biweekly）
  if command -v poetry >/dev/null 2>&1 && [[ -f pyproject.toml ]]; then
    poetry run python -m travel_tracker.main biweekly
  else
    python3 -m travel_tracker.main biweekly
  fi

  echo "===== BIWEEKLY RUN END   $(date -u +"%F %T") UTC ====="
} 2>&1 | tee -a "$LOG_FILE"
