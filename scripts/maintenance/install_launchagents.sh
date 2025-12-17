#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LA_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$PROJECT_DIR/logs"
STATE_DIR="$PROJECT_DIR/data/processed"

mkdir -p "$LA_DIR" "$LOG_DIR" "$STATE_DIR" "$PROJECT_DIR/scripts"

# ---- runner: news ----
cat > "$PROJECT_DIR/scripts/run_news.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
cd "$HOME/Desktop/程式學習/爬蟲專案/旅遊/travel_price_tracker"

# 可自行調整 max-per-source
poetry run python -m travel_tracker.main news --max-per-source 10
BASH
chmod +x "$PROJECT_DIR/scripts/run_news.sh"

# ---- runner: biweekly (guarded every 14 days) ----
cat > "$PROJECT_DIR/scripts/run_biweekly_guarded.sh" <<'BASH'
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
BASH
chmod +x "$PROJECT_DIR/scripts/run_biweekly_guarded.sh"

# ---- LaunchAgent: daily news (09:00) ----
NEWS_PLIST="$LA_DIR/com.te-enlin.travel_price_tracker.news.daily.plist"
cat > "$NEWS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.te-enlin.travel_price_tracker.news.daily</string>

    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${PROJECT_DIR}/scripts/run_news.sh</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
      <key>Hour</key><integer>9</integer>
      <key>Minute</key><integer>0</integer>
    </dict>

    <key>RunAtLoad</key><true/>

    <key>StandardOutPath</key>
    <string>${PROJECT_DIR}/logs/launchagent_news.log</string>
    <key>StandardErrorPath</key>
    <string>${PROJECT_DIR}/logs/launchagent_news.err.log</string>
  </dict>
</plist>
PLIST

# ---- LaunchAgent: biweekly guarded (09:10 daily trigger) ----
BIWEEKLY_PLIST="$LA_DIR/com.te-enlin.travel_price_tracker.biweekly.guarded.plist"
cat > "$BIWEEKLY_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.te-enlin.travel_price_tracker.biweekly.guarded</string>

    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${PROJECT_DIR}/scripts/run_biweekly_guarded.sh</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
      <key>Hour</key><integer>9</integer>
      <key>Minute</key><integer>10</integer>
    </dict>

    <key>RunAtLoad</key><true/>

    <key>StandardOutPath</key>
    <string>${PROJECT_DIR}/logs/launchagent_biweekly.log</string>
    <key>StandardErrorPath</key>
    <string>${PROJECT_DIR}/logs/launchagent_biweekly.err.log</string>
  </dict>
</plist>
PLIST

# ---- load agents ----
launchctl unload "$NEWS_PLIST" 2>/dev/null || true
launchctl unload "$BIWEEKLY_PLIST" 2>/dev/null || true

launchctl load "$NEWS_PLIST"
launchctl load "$BIWEEKLY_PLIST"

UID_NUM="$(id -u)"
launchctl kickstart -k "gui/${UID_NUM}/com.te-enlin.travel_price_tracker.news.daily" || true
launchctl kickstart -k "gui/${UID_NUM}/com.te-enlin.travel_price_tracker.biweekly.guarded" || true

echo "===== INSTALLED ====="
echo "News plist:     $NEWS_PLIST"
echo "Biweekly plist: $BIWEEKLY_PLIST"
echo "Logs:"
echo "  $PROJECT_DIR/logs/launchagent_news.log"
echo "  $PROJECT_DIR/logs/launchagent_biweekly.log"
