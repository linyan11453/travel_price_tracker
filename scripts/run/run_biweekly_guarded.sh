#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
cd "$HOME/Desktop/程式學習/爬蟲專案/旅遊/travel_price_tracker"

STATE_FILE="data/processed/biweekly_last_run.txt"

should_run="yes"
if [[ -f "$STATE_FILE" ]]; then
  last="$(cat "$STATE_FILE" | tr -d ' \n\r\t' || true)"
  if [[ -n "$last" ]]; then
    # 用 python 做日期差（避免 macOS date 參數差異）
    should_run="$(poetry run python - <<PY
from datetime import datetime
import sys
last = "${last}"
try:
    last_dt = datetime.strptime(last, "%Y-%m-%d")
except Exception:
    print("yes")
    sys.exit(0)

today = datetime.now()
days = (today.date() - last_dt.date()).days
print("yes" if days >= 14 else "no")
PY
)"
  fi
fi

if [[ "$should_run" != "yes" ]]; then
  echo "[BIWEEKLY-GUARD] skip (last run < 14 days)"
  exit 0
fi

# 真正執行 biweekly
poetry run python -m travel_tracker.main biweekly

# 記錄成功執行日（只在成功時寫入）
poetry run python - <<'PY'
from datetime import datetime
Path = __import__("pathlib").Path
Path("data/processed/biweekly_last_run.txt").write_text(datetime.now().strftime("%Y-%m-%d"), encoding="utf-8")
print("[BIWEEKLY-GUARD] updated state file")
PY
