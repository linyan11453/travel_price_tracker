#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"

# If mistaken top-level travel_tracker exists, move aside (do not delete)
if [ -d "${ROOT}/travel_tracker" ]; then
  mkdir -p "${ROOT}/_migrated"
  mv "${ROOT}/travel_tracker" "${ROOT}/_migrated/travel_tracker_$(date +%Y%m%d_%H%M%S)"
fi

# Ensure key dirs
mkdir -p "${ROOT}/src/travel_tracker"

# Create required files
cat > "${ROOT}/README.md" <<'MD'
# travel_price_tracker

Quickstart:
```bash
cp .env.example .env
poetry install
poetry run python -m travel_tracker.main daily
poetry run python -m travel_tracker.main biweekly
MD

cat > "${ROOT}/pyproject.toml" <<'TOML'
[tool.poetry]
name = "travel-price-tracker"
version = "0.1.0"
description = "Asia travel price tracker"
authors = ["you you@example.com"]
readme = "README.md"
packages = [{ include = "travel_tracker", from = "src" }]

[tool.poetry.dependencies]
python = ">=3.11,<4.0"

[tool.poetry.group.dev.dependencies]
pytest = "^8.3.0"
TOML

cat > "${ROOT}/.env.example" <<'ENV'
APP_ENV=dev
TZ=Asia/Kuala_Lumpur
ENV

cat > "${ROOT}/src/travel_tracker/init.py" <<'PY'
version = "0.1.0"
PY

cat > "${ROOT}/src/travel_tracker/main.py" <<'PY'
import argparse
from datetime import datetime
from pathlib import Path

def _today_ymd() -> str:
return datetime.now().strftime("%Y-%m-%d")

def main() -> int:
p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
d = sub.add_parser("daily")
d.add_argument("--date", default=_today_ymd())
b = sub.add_parser("biweekly")
b.add_argument("--date", default=_today_ymd())
args = p.parse_args()

pgsql
複製程式碼
Path("reports/daily").mkdir(parents=True, exist_ok=True)
Path("reports/biweekly").mkdir(parents=True, exist_ok=True)

if args.cmd == "daily":
    out = Path("reports/daily") / f"daily_{args.date}.md"
    out.write_text(f"# Daily Snapshot - {args.date}\n", encoding="utf-8")
    print(f"[OK] {out}")
    return 0

if args.cmd == "biweekly":
    out = Path("reports/biweekly") / f"biweekly_{args.date}.md"
    out.write_text(f"# Biweekly Report - {args.date}\n", encoding="utf-8")
    print(f"[OK] {out}")
    return 0

return 2
if name == "main":
raise SystemExit(main())
PY

echo "[OK] Minimal scaffold repaired at: ${ROOT}"
