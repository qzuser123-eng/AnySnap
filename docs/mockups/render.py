#!/usr/bin/env python3
"""Re-render the README menu illustrations from docs/mockups/menu.html.
Requires: pip install playwright && playwright install chromium"""
import asyncio, pathlib
from playwright.async_api import async_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page(viewport={"width": 1100, "height": 470}, device_scale_factor=2)
        for view, out in [("destination", "menu-destination.png"), ("recent", "menu-recent.png")]:
            await page.goto(f"file://{ROOT}/docs/mockups/menu.html?view={view}")
            await page.wait_for_timeout(400)
            await page.screenshot(path=str(ROOT / "docs/images" / out))
        await browser.close()

asyncio.run(main())
