from __future__ import annotations

import re
from pathlib import Path

RUN_DATE = "2025-12-15"
BASE = Path(f"data/raw/{RUN_DATE}/flights")

SUSPECT_WORDS = [
    "captcha", "verify", "robot", "datadome", "akamai", "cloudflare",
    "access denied", "blocked", "forbidden", "security check",
]

def sniff(p: Path) -> None:
    b = p.read_bytes()
    s = b.decode("utf-8", errors="ignore")
    title = ""
    m = re.search(r"<title>\s*(.*?)\s*</title>", s, re.I | re.S)
    if m:
        title = re.sub(r"\s+", " ", m.group(1)).strip()

    has_next = '__NEXT_DATA__' in s
    has_price_word = bool(re.search(r'("price"|priceAmount|lowestPrice|minPrice|fromPrice)', s, re.I))
    suspects = [w for w in SUSPECT_WORDS if w.lower() in s.lower()]

    print(f"\n=== {p} ===")
    print(f"size={len(b)} title={title!r}")
    print(f"__NEXT_DATA__={has_next} price_tokens={has_price_word} suspects={suspects[:5]}")

def main() -> None:
    if not BASE.exists():
        print(f"[ERR] not found: {BASE}")
        return
    files = sorted(BASE.rglob("*.html"))
    if not files:
        print("[ERR] no html files found.")
        return
    for p in files[:10]:
        sniff(p)

if __name__ == "__main__":
    main()
