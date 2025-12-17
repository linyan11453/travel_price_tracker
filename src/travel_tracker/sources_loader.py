from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Destination:
    id: str
    name_zh: str
    country: str


@dataclass
class Source:
    id: str
    country: str | None
    type: str
    url: str
    tags: list[str]


@dataclass
class SourcesBundle:
    destinations: list[Destination]
    news: list[Source]
    weather: list[Source]
    safety: list[Source]


def load_sources(path: str = "data/sources.json") -> SourcesBundle:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Missing sources file: {path}")

    data = json.loads(p.read_text(encoding="utf-8"))

    dests = [
        Destination(id=d["id"], name_zh=d["name_zh"], country=d["country"])
        for d in data.get("destinations", [])
    ]

    def _to_sources(arr: list[dict]) -> list[Source]:
        out: list[Source] = []
        for s in arr:
            out.append(Source(
                id=s.get("id",""),
                country=s.get("country"),
                type=s.get("type","rss"),
                url=s.get("url",""),
                tags=list(s.get("tags", [])),
            ))
        return [x for x in out if x.id and x.url]

    src = data.get("sources", {})
    return SourcesBundle(
        destinations=dests,
        news=_to_sources(src.get("news_rss", [])),
        weather=_to_sources(src.get("weather_official", [])),
        safety=_to_sources(src.get("safety_official", [])),
    )
