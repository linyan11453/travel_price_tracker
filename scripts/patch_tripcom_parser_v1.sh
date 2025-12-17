#!/usr/bin/env bash
set -euo pipefail

p="src/travel_tracker/sources/flights/tripcom.py"
cp "$p" "${p}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

cat > "$p" <<'PY'
from __future__ import annotations

import html as _html
import json
import re
from dataclasses import dataclass
from typing import Any, Optional


@dataclass
class TripcomParseResult:
    ok: bool
    currency: str | None
    value: float | None
    notes: str


_SUSPECT_WORDS = [
    "captcha", "verify", "robot", "datadome", "akamai", "cloudflare",
    "access denied", "blocked", "forbidden", "security check",
]

_PRICE_KEYS = {
    "lowestprice", "minprice", "fromprice", "price", "priceamount", "lowest",
    "lowest_price", "min_price", "from_price",
}


def _find_next_data(html_text: str) -> Any | None:
    m = re.search(
        r'<script[^>]+id="__NEXT_DATA__"[^>]*>\s*(\{.*?\})\s*</script>',
        html_text,
        re.I | re.S,
    )
    if not m:
        return None
    raw = _html.unescape(m.group(1))
    try:
        return json.loads(raw)
    except Exception:
        return None


def _walk_collect_prices(obj: Any, out: list[tuple[str | None, float, str]]) -> None:
    # Collect possible (currency, value, path)
    if isinstance(obj, dict):
        # common shapes: {"currency":"SGD","amount":123}
        if "currency" in obj and ("amount" in obj or "value" in obj):
            cur = obj.get("currency")
            val = obj.get("amount", obj.get("value"))
            if isinstance(val, (int, float)) and isinstance(cur, str):
                out.append((cur, float(val), "currency_amount"))
        for k, v in obj.items():
            lk = str(k).lower()
            if lk in _PRICE_KEYS and isinstance(v, (int, float)):
                out.append((None, float(v), f"key:{lk}"))
            _walk_collect_prices(v, out)
    elif isinstance(obj, list):
        for it in obj:
            _walk_collect_prices(it, out)


def _regex_fallback(html_text: str) -> tuple[str | None, float | None]:
    # Try currency+amount patterns
    patterns = [
        r'"currency"\s*:\s*"([A-Z]{3})".{0,80}?"amount"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"amount"\s*:\s*([0-9]+(?:\.[0-9]+)?).{0,80}?"currency"\s*:\s*"([A-Z]{3})"',
        r'"price"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"minPrice"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
        r'"lowestPrice"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
    ]
    for pat in patterns:
        m = re.search(pat, html_text, re.I | re.S)
        if not m:
            continue
        if len(m.groups()) == 2:
            g1, g2 = m.group(1), m.group(2)
            # either (CUR, AMT) or (AMT, CUR)
            if re.fullmatch(r"[A-Z]{3}", g1):
                return g1, float(g2)
            if re.fullmatch(r"[A-Z]{3}", g2):
                return g2, float(g1)
        if len(m.groups()) == 1:
            return None, float(m.group(1))
    return None, None


def parse_tripcom_html(html_bytes: bytes) -> TripcomParseResult:
    text = html_bytes.decode("utf-8", errors="ignore")

    suspects = [w for w in _SUSPECT_WORDS if w.lower() in text.lower()]
    if suspects:
        return TripcomParseResult(ok=False, currency=None, value=None, notes=f"blocked_or_challenge:{suspects[0]}")

    data = _find_next_data(text)
    if data is not None:
        hits: list[tuple[str | None, float, str]] = []
        _walk_collect_prices(data, hits)
        if hits:
            # choose minimum positive price
            hits2 = [(c, v, p) for (c, v, p) in hits if v > 0]
            if hits2:
                c, v, path = sorted(hits2, key=lambda x: x[1])[0]
                return TripcomParseResult(ok=True, currency=c, value=v, notes=f"from_next_data:{path}")
        # next_data exists but no prices inside
        cur, val = _regex_fallback(text)
        if val is not None:
            return TripcomParseResult(ok=True, currency=cur, value=val, notes="regex_after_next_data")
        return TripcomParseResult(ok=False, currency=None, value=None, notes="next_data_no_price")

    # no next data: try regex
    cur, val = _regex_fallback(text)
    if val is not None:
        return TripcomParseResult(ok=True, currency=cur, value=val, notes="regex_no_next_data")

    # still nothing
    return TripcomParseResult(ok=False, currency=None, value=None, notes="no_price_found_in_html")
PY

echo "[OK] Patched: $p"
