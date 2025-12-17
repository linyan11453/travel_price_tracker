#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="src/travel_tracker/pipelines/flights_snapshot.py"
test -f "$TARGET" || { echo "[ERR] missing $TARGET"; exit 1; }

BK="_migrated/fix_flights_snapshot_bytes_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"
cp "$TARGET" "$BK/$(basename "$TARGET").bak"
echo "[OK] backup -> $BK/$(basename "$TARGET").bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")

# 1) 把 res = fetch_route_html(...) 改成 raw = fetch_route_html(...)
if "res = fetch_route_html" in s:
    s = s.replace("res = fetch_route_html", "raw = fetch_route_html", 1)
elif "res=fetch_route_html" in s:
    s = s.replace("res=fetch_route_html", "raw=fetch_route_html", 1)
elif "raw = fetch_route_html" not in s and "raw=fetch_route_html" not in s:
    raise SystemExit('[ERR] 找不到 fetch_route_html 呼叫（請 grep -n "fetch_route_html" flights_snapshot.py）')

# 2) 在 raw = fetch_route_html(...) 呼叫後插入「統一整理 html_bytes / status_code」區塊
m = re.search(r"(raw\s*=\s*fetch_route_html\s*\()", s)
if not m:
    raise SystemExit('[ERR] 找不到 raw = fetch_route_html( 開頭')

start = m.start(1)
i = m.end(1)  # position after "("
depth = 1
while i < len(s) and depth > 0:
    ch = s[i]
    if ch == "(":
        depth += 1
    elif ch == ")":
        depth -= 1
    i += 1

if depth != 0:
    raise SystemExit("[ERR] 無法配對 fetch_route_html(...) 括號")

# 找到 statement 結尾（到換行）
while i < len(s) and s[i] != "\n":
    i += 1
if i < len(s):
    i += 1  # include newline

# 避免重複插入（如果你已經插過）
if "status_code =" not in s[slice(i, min(len(s), i+400))] and "html_bytes =" not in s[slice(i, min(len(s), i+400))]:
    block = (
        "\n"
        "        # normalize fetch result (bytes / HttpResponse-like)\n"
        "        status_code = None\n"
        "        html_bytes = b\"\"\n"
        "        if isinstance(raw, (bytes, bytearray)):\n"
        "            html_bytes = bytes(raw)\n"
        "            status_code = 200 if html_bytes else None\n"
        "        else:\n"
        "            # support objects like HttpResponse(url,status,headers,body,from_cache)\n"
        "            status_code = getattr(raw, 'status_code', None) or getattr(raw, 'status', None) or getattr(raw, 'code', None)\n"
        "            body = getattr(raw, 'body', None) or getattr(raw, 'content', None) or getattr(raw, 'html', None)\n"
        "            if isinstance(body, str):\n"
        "                html_bytes = body.encode('utf-8', errors='ignore')\n"
        "            elif isinstance(body, (bytes, bytearray)):\n"
        "                html_bytes = bytes(body)\n"
        "            else:\n"
        "                html_bytes = b\"\"\n"
        "\n"
    )
    s = s[:i] + block + s[i:]

# 3) 把後面所有 res.xxx 改成用 status_code / html_bytes
# status_code=res.status_code / res.status / res.code
s = re.sub(r"status_code\s*=\s*res\.\w+", "status_code=status_code", s)
s = re.sub(r"status_code\s*:\s*res\.\w+", "status_code: status_code", s)  # 防呆

# 常見：html_bytes=res.body / res.html_bytes / res.content
s = re.sub(r"\bres\.(body|html_bytes|content|html)\b", "html_bytes", s)

# 仍有 res. 的話就提示（不直接失敗，避免你卡住）
if re.search(r"\bres\.\w+", s):
    # 只警告，不中斷
    s = "# [WARN] leftover res.* found; please grep 'res.' if run fails\n" + s

p.write_text(s, encoding="utf-8")
print("[OK] patched flights_snapshot.py: now supports raw bytes return; uses status_code/html_bytes")
PY

echo ""
echo "[NEXT] rerun (first 3 routes, PW on):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=3 TRAVEL_TIMEOUT=12 TRAVEL_RETRIES=0 poetry run python -m travel_tracker.flights_main --force'
