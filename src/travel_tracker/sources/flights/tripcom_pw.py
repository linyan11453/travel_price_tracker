from __future__ import annotations

import os

def fetch_html(url: str, *, timeout_seconds: int = 20) -> bytes:
    """
    Fetch fully-rendered HTML via Playwright.
    Used when TRAVEL_FLIGHTS_USE_PW=1.
    """
    # Lazy import to keep normal runs light.
    from playwright.sync_api import sync_playwright

    # Tight defaults; keep it stable.
    ua = os.getenv(
        "TRAVEL_PW_UA",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36",
    )

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(user_agent=ua, viewport={"width": 1280, "height": 720})
        page = ctx.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=timeout_seconds * 1000)
        # give SPA a short breath (avoid infinite waits)
        page.wait_for_timeout(1200)
        html = page.content()
        ctx.close()
        browser.close()
    return html.encode("utf-8", errors="ignore")
