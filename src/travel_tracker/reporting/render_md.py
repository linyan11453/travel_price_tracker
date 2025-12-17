from __future__ import annotations

from pathlib import Path
from typing import Iterable


def write_markdown_report(out_dir: Path, filename: str, title: str, sections: list[dict]) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / filename

    lines: list[str] = []
    lines.append(f"# {title}")
    lines.append("")

    for sec in sections:
        h2 = (sec.get("h2") or "").strip()
        body = sec.get("body") or ""
        if h2:
            lines.append(f"## {h2}")
            lines.append("")
        if body:
            lines.append(body.rstrip())
            lines.append("")

    out.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return out
