from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class CitySources:
    code: str
    name_zh: str
    news_rss: list[str]
    weather_rss: list[str]
    safety_rss: list[str]


def load_sources(path: str = "config/sources.json") -> list[CitySources]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    cities = data.get("cities", {})
    out: list[CitySources] = []
    for code, payload in cities.items():
        out.append(
            CitySources(
                code=code,
                name_zh=payload["name_zh"],
                news_rss=list(payload.get("news_rss", [])),
                weather_rss=list(payload.get("weather_rss", [])),
                safety_rss=list(payload.get("safety_rss", [])),
            )
        )
    return out
