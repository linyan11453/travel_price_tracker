#!/usr/bin/env bash
set -euo pipefail

RUN_DATE="2025-12-15"
BASE="data/raw/${RUN_DATE}/flights/SIN"

echo "[INFO] scanning html under: ${BASE}"
files=$(find "${BASE}" -name "*.html" | head -n 20 || true)
if [ -z "${files}" ]; then
  echo "[ERR] no html files"
  exit 1
fi

for f in $files; do
  echo ""
  echo "=== $f ==="
  echo "size=$(wc -c < "$f")"
  # 抓 script/src/可能 API 字眼
  grep -Eoi "(api|graphql|search|flight|fare|price|xhr|fetch)" "$f" | head -n 20 || true
  # 抽出所有 URL，挑出疑似 api 的
  grep -Eo 'https?://[^"'"'"' <>()]+' "$f" | egrep -i "api|graphql|flight|search|fare|price" | head -n 30 || true
done
