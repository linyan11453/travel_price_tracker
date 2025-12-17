from __future__ import annotations

from dataclasses import dataclass


@dataclass
class SignalRow:
    run_date: str
    city_code: str
    city_name_zh: str
    source: str
    title: str
    url: str
    published_at: str | None
