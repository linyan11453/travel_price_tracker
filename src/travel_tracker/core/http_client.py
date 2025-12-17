from __future__ import annotations

import os
import hashlib
import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class HttpResponse:
    url: str
    status: int
    headers: dict[str, str]
    body: bytes
    from_cache: bool = False


class PoliteHttpClient:
    """
    Stdlib-only HTTP client with:
    - global rate limiting
    - exponential backoff retry
    - ETag / Last-Modified conditional GET cache
    - correct handling for HTTP 304 (urllib raises it as HTTPError)
    """
    def __init__(
        self,
        cache_dir: str = "data/cache/http",
        rps: float = 0.2,
        timeout_seconds: int = 25,
        max_retries: int = 3,
        user_agent: str = "travel_price_tracker/0.1 (+contact: you@example.com)",
    ) -> None:
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.min_interval = 1.0 / max(rps, 1e-9)
        self.timeout_seconds = timeout_seconds
        self.max_retries = max_retries
        self.user_agent = user_agent
        self._last_ts = 0.0

    def _sleep_gate(self) -> None:
        now = time.time()
        wait = self.min_interval - (now - self._last_ts)
        if wait > 0:
            time.sleep(wait)
        self._last_ts = time.time()

    def _key(self, url: str) -> str:
        return hashlib.sha256(url.encode("utf-8")).hexdigest()

    def _meta_path(self, url: str) -> Path:
        return self.cache_dir / f"{self._key(url)}.meta.json"

    def _body_path(self, url: str) -> Path:
        return self.cache_dir / f"{self._key(url)}.body.bin"

    def _load_meta(self, url: str) -> dict:
        p = self._meta_path(url)
        if not p.exists():
            return {}
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def _save_meta(self, url: str, meta: dict) -> None:
        self._meta_path(url).write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")

    def _load_cached_body(self, url: str) -> bytes:
        p = self._body_path(url)
        return p.read_bytes() if p.exists() else b""

    def get(self, url: str) -> HttpResponse:

        # Trip.com Playwright override (only when TRAVEL_FLIGHTS_USE_PW=1)

        if os.getenv('TRAVEL_FLIGHTS_USE_PW', '0').strip() == '1' and ('trip.com' in url):

            from travel_tracker.sources.flights.tripcom_pw import fetch_html

            html = fetch_html(url, timeout_ms=int(getattr(self, 'timeout_seconds', 12) * 1000))

            return HttpResponse(url=url, status=200, headers={}, body=html, from_cache=False)

        meta = self._load_meta(url)
        etag = meta.get("etag")
        last_modified = meta.get("last_modified")

        headers = {"User-Agent": self.user_agent, "Accept": "*/*"}
        if etag:
            headers["If-None-Match"] = etag
        if last_modified:
            headers["If-Modified-Since"] = last_modified

        last_error: Optional[Exception] = None

        for attempt in range(1, self.max_retries + 1):
            try:
                self._sleep_gate()
                req = urllib.request.Request(url, headers=headers, method="GET")
                with urllib.request.urlopen(req, timeout=self.timeout_seconds) as resp:
                    status = getattr(resp, "status", 200)
                    resp_headers = {k.lower(): v for k, v in resp.headers.items()}
                    body = resp.read()

                # Normal 2xx path
                self._save_meta(url, {
                    "etag": resp_headers.get("etag"),
                    "last_modified": resp_headers.get("last-modified"),
                    "fetched_at": time.time(),
                })
                self._body_path(url).write_bytes(body)
                return HttpResponse(url=url, status=status, headers=resp_headers, body=body, from_cache=False)

            except urllib.error.HTTPError as e:
                # IMPORTANT: urllib raises 304 as HTTPError
                if e.code == 304:
                    cached = self._load_cached_body(url)
                    hdrs = {k.lower(): v for k, v in (e.headers.items() if e.headers else [])}
                    return HttpResponse(url=url, status=304, headers=hdrs, body=cached, from_cache=True)

                last_error = e
                time.sleep(min(8, 2 ** (attempt - 1)))

            except Exception as e:
                last_error = e
                time.sleep(min(8, 2 ** (attempt - 1)))

        raise RuntimeError(f"HTTP GET failed after {self.max_retries} retries: {url}") from last_error
