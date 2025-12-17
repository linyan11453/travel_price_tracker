from __future__ import annotations

from pathlib import Path
from datetime import datetime

def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")

def write_human_alert(run_date: str, reason: str, next_step: str) -> Path:
    out_dir = Path("reports/daily")
    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / f"NEEDS_HUMAN_{run_date}.md"
    p.write_text(
        "\n".join([
            f"# Needs Human Intervention ({run_date})",
            "",
            "## Reason",
            reason,
            "",
            "## Next step",
            next_step,
            "",
        ]) + "\n",
        encoding="utf-8",
    )
    return p

def append_source_error(run_date: str, scope: str, source_id: str, url: str, err: str) -> Path:
    out_dir = Path("reports/daily")
    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / f"source_errors_{run_date}.md"
    line = f"- [{_now()}] [{scope}] {source_id} {url}\n  - {err}\n"
    if p.exists():
        p.write_text(p.read_text(encoding="utf-8") + line, encoding="utf-8")
    else:
        p.write_text(f"# Source Errors ({run_date})\n\n{line}", encoding="utf-8")
    return p
