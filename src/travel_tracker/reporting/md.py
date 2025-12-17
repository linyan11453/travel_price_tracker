from __future__ import annotations
from typing import Iterable, Sequence

def h2(title: str) -> str:
    return f"## {title}\n"

def h3(title: str) -> str:
    return f"### {title}\n"

def p(text: str) -> str:
    return f"{text}\n"

def bullets(items: Iterable[str]) -> str:
    items = list(items)
    if not items:
        return "_No data_\n"
    return "\n".join([f"- {x}" for x in items]) + "\n"

def _escape_cell(x: object) -> str:
    s = "" if x is None else str(x)
    return s.replace("\n", " ").replace("|", "\\|").strip()

def table(headers: Sequence[str], rows: Sequence[Sequence[object]]) -> str:
    headers = [_escape_cell(h) for h in headers]
    out = []
    out.append("| " + " | ".join(headers) + " |")
    out.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for r in rows:
        rr = [_escape_cell(c) for c in r]
        out.append("| " + " | ".join(rr) + " |")
    return "\n".join(out) + "\n"
