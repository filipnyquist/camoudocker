#!/usr/bin/env python3
"""Connect to the Camoufox server container and load a page.

    pip install playwright==1.60.0
    python examples/client.py [ws://localhost:4444/camoufox] [https://example.com]

The server owns the browser, so the client only needs Playwright -- no Camoufox
install and no browser download on this side. The version has to match the
server's, though: Playwright refuses the websocket handshake across versions,
and Camoufox 0.5.5 pins 1.60.0.
"""

import sys

from playwright.sync_api import sync_playwright

WS_ENDPOINT = sys.argv[1] if len(sys.argv) > 1 else 'ws://localhost:4444/camoufox'
URL = sys.argv[2] if len(sys.argv) > 2 else 'https://example.com'

with sync_playwright() as playwright:
    browser = playwright.firefox.connect(WS_ENDPOINT)
    page = browser.new_page()
    page.goto(URL, wait_until='domcontentloaded')

    print('title:     ', page.title())
    print('user agent:', page.evaluate('navigator.userAgent'))
    print('platform:  ', page.evaluate('navigator.platform'))
    print('timezone:  ', page.evaluate('Intl.DateTimeFormat().resolvedOptions().timeZone'))

    page.screenshot(path='screenshot.png')
    print('screenshot: screenshot.png')

    # Every connection shares the one browser instance, so close the page and
    # let go of the connection rather than leaving contexts behind.
    page.close()
    browser.close()
