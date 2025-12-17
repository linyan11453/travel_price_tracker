#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BK="_migrated/fix_flights_snapshot_sig_norm_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK"

cp src/travel_tracker/pipelines/flights_snapshot.py "$BK/flights_snapshot.py.bak"
echo "[OK] backup -> $BK/flights_snapshot.py.bak"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("src/travel_tracker/pipelines/flights_snapshot.py")
s = p.read_text(encoding="utf-8")

if "fetch_route_html" not in s:
    raise SystemExit("[ERR] flights_snapshot.py has no fetch_route_html usage")

# 1) 修正舊的 fetch_route_html 呼叫形式（盡量容忍多行）
# 常見舊型：
#   res = fetch_route_html(client=client, run_date=run_date, route=rt, raw_dir=ddir)
#   res = fetch_route_html(client=client, route=rt, raw_dir=ddir)
# -> 轉成：
#   raw_path = ddir / f"{rt.route_id}.html"
#   res = fetch_route_html(client=client, url=rt.url, raw_path=raw_path)

pat_old = re.compile(
    r"^(?P<indent>\s*)(?P<lhs>\w+)\s*=\s*fetch_route_html\(\s*(?P<args>[\s\S]*?)\s*\)\s*$",
    re.M,
)

def build_replacement(indent: str, lhs: str, args: str) -> str | None:
    # 嘗試抓 route 變數名（route=rt / route = route）
    m_route = re.search(r"\broute\s*=\s*(\w+)", args)
    m_rawdir = re.search(r"\braw_dir\s*=\s*(\w+)", args) or re.search(r"\brawdir\s*=\s*(\w+)", args) or re.search(r"\braw_dir\s*=\s*(\w+)", args)
    # 有些版本叫 raw_dir，有些叫 raw_dir=ddir
    if not m_rawdir:
        m_rawdir = re.search(r"\braw_dir\s*=\s*(\w+)", args)
    # 也可能原本就有 raw_path
    m_rawpath = re.search(r"\braw_path\s*=\s*(\w+)", args)
    m_url = re.search(r"\burl\s*=\s*([^\s,]+)", args)

    # client 參數（通常是 client=client）
    m_client = re.search(r"\bclient\s*=\s*([^\s,]+)", args)
    client_expr = m_client.group(1) if m_client else "client"

    # 若已經是新簽名（有 url + raw_path），就不動
    if m_url and (m_rawpath or "raw_path=" in args):
        return None

    # 產生 url expr
    if m_url:
        url_expr = m_url.group(1)
    elif m_route:
        rv = m_route.group(1)
        url_expr = f"{rv}.url"
    else:
        # 看看有沒有 rt["url"] 這種
        m_url2 = re.search(r"\broute_url\s*=\s*([^\s,]+)", args)
        if m_url2:
            url_expr = m_url2.group(1)
        else:
            # 沒 route 也沒 url，就不敢亂改
            return None

    # 產生 raw_path
    if m_rawpath:
        raw_path_expr = m_rawpath.group(1)
        raw_path_line = ""  # 已存在 raw_path 變數
    else:
        if m_rawdir:
            ddir = m_rawdir.group(1)
        else:
            # 找 raw_dir 變數名不存在就用 ddir（如果你檔案內就是 ddir 也 OK）
            ddir = "ddir"

        # route_id expr
        if m_route:
            rv = m_route.group(1)
            route_id_expr = f"{rv}.route_id"
        else:
            route_id_expr = "route_id"

        raw_path_line = f'{indent}raw_path = {ddir} / f"{{{route_id_expr}}}.html"\n'
        raw_path_expr = "raw_path"

    # 移除舊的 run_date / route / raw_dir 參數（避免混亂）
    # 直接重組成新呼叫（最穩）
    call_line = f"{indent}{lhs} = fetch_route_html(client={client_expr}, url={url_expr}, raw_path={raw_path_expr})\n"
    return raw_path_line + call_line

out = []
last = 0
repl_count = 0
for m in pat_old.finditer(s):
    indent = m.group("indent")
    lhs = m.group("lhs")
    args = m.group("args")

    rep = build_replacement(indent, lhs, args)
    if rep is None:
        continue

    out.append(s[last:m.start()])
    out.append(rep)
    last = m.end()
    repl_count += 1

if repl_count:
    out.append(s[last:])
    s = "".join(out)
    print(f"[OK] patched fetch_route_html callsites: {repl_count}")
else:
    print("[WARN] no callsite patched (maybe already new signature)")

# 2) 加 normalize 區塊：避免 bytes/dict/HttpResponse 造成 status_code 取不到
# 找一個合理的插入點：第一次出現 fetch_route_html(...) 的那段 loop 內，緊跟在呼叫後
m_call = re.search(r"^\s*\w+\s*=\s*fetch_route_html\([^\n]*\)\s*$", s, re.M)
if not m_call:
    raise SystemExit('[ERR] cannot locate "x = fetch_route_html(...)" line after patch')

# 取得被賦值的變數名
m_var = re.match(r"^\s*(\w+)\s*=", m_call.group(0))
var = m_var.group(1) if m_var else "res"

insert_pos = m_call.end()

norm_block = f"""
        # normalize (dict / HttpResponse-like / bytes)
        status_code = None
        html_bytes = b""
        min_price_currency = None
        min_price_value = None
        parse_ok = 0

        obj = {var}
        if isinstance(obj, dict):
            status_code = obj.get("status_code")
            html_bytes = obj.get("html_bytes") or b""
            min_price_currency = obj.get("min_price_currency")
            min_price_value = obj.get("min_price_value")
            parse_ok = 1 if (min_price_currency and min_price_value) else int(obj.get("parse_ok") or 0)
        elif isinstance(obj, (bytes, bytearray)):
            html_bytes = bytes(obj)
            status_code = 200 if html_bytes else None
        else:
            status_code = getattr(obj, "status_code", None) or getattr(obj, "status", None) or getattr(obj, "code", None)
            body = getattr(obj, "body", None) or getattr(obj, "content", None) or b""
            html_bytes = body.encode("utf-8", errors="ignore") if isinstance(body, str) else (body or b"")
"""

# 避免重複插入
if "normalize (dict / HttpResponse-like / bytes)" not in s:
    s = s[:insert_pos] + norm_block + s[insert_pos:]
    print("[OK] inserted normalize block")
else:
    print("[WARN] normalize block already exists; skip insert")

# 3) 把 insert_flight_quote(...) 參數改成用 normalize 後的變數
# 讓這些欄位用我們的 status_code/parse_ok/min_price_*
s = re.sub(r"status_code\s*=\s*[^,\n]+", "status_code=status_code", s)
s = re.sub(r"parse_ok\s*=\s*[^,\n]+", "parse_ok=parse_ok", s)
s = re.sub(r"min_price_currency\s*=\s*[^,\n]+", "min_price_currency=min_price_currency", s)
s = re.sub(r"min_price_value\s*=\s*[^,\n]+", "min_price_value=min_price_value", s)

p.write_text(s, encoding="utf-8")
print("[OK] wrote flights_snapshot.py")
PY

echo ""
echo "[NEXT] run (first 3 routes, PW on):"
echo 'TRAVEL_FLIGHTS_USE_PW=1 TRAVEL_FLIGHTS_MAX_ROUTES=3 TRAVEL_TIMEOUT=12 TRAVEL_RETRIES=0 poetry run python -m travel_tracker.flights_main --force'
