#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

# 預設 8000，若你要改：PORT=8080 ./scripts/run/run_api.sh
PORT="${PORT:-8000}"

poetry run uvicorn travel_tracker.api.app:app --host 0.0.0.0 --port "$PORT"
