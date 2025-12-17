#!/usr/bin/env bash
set -euo pipefail
echo "[DB FILE]"
ls -lh data/db/travel_tracker.sqlite
echo
echo "[SYMLINK]"
ls -l data/processed/travel_tracker.sqlite || true
echo
echo "[TABLES]"
sqlite3 data/db/travel_tracker.sqlite ".tables"
echo
echo "[SANITY]"
sqlite3 data/db/travel_tracker.sqlite "select 1;"
