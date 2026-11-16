#!/usr/bin/env python3
"""供 fingerprint_probe 调用的 Playwright WebKit 驱动；不是 WKWebView 真机。"""
import asyncio
import json
import sys

from playwright.async_api import async_playwright


async def main():
    url = next(arg for arg in sys.argv[1:] if arg.startswith('https://localhost:'))
    async with async_playwright() as runtime:
        browser = await runtime.webkit.launch(headless=True)
        try:
            # 只允许实验回环端点，证书忽略不进入生产应用。
            context = await browser.new_context(ignore_https_errors=True)
            page = await context.new_page()
            print(json.dumps({'engine': 'Playwright WebKit', 'version': browser.version}), flush=True)
            await page.goto(url, wait_until='domcontentloaded')
            await page.wait_for_function("document.title === 'fluxdo-probe-done'")
        finally:
            await browser.close()


if __name__ == '__main__':
    asyncio.run(main())
