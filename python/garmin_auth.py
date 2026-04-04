"""Garmin Connect authentication with token persistence.

Three strategies, tried in order:
1. Saved tokens (fast, no network)
2. garminconnect's native login (curl_cffi TLS impersonation)
3. Browser login via Playwright (bypasses Cloudflare)
"""

import getpass
import logging
import re
from pathlib import Path

from garminconnect import Garmin
from garminconnect.exceptions import (
    GarminConnectAuthenticationError,
    GarminConnectTooManyRequestsError,
)

log = logging.getLogger(__name__)

# Garmin SSO constants (match garminconnect's client.py)
_SSO_BASE = "https://sso.garmin.com"
_SSO_SIGNIN = f"{_SSO_BASE}/sso/signin"
_PORTAL_CLIENT_ID = "GarminConnect"
_PORTAL_SERVICE = "https://connect.garmin.com/app"


class RateLimitedError(Exception):
    """Raised when Garmin rate-limits login attempts."""


def authenticate(token_dir: Path, force_reauth: bool = False) -> Garmin:
    """Return an authenticated Garmin client.

    Tries saved tokens first, then native login, then browser login.
    """
    token_dir.mkdir(parents=True, exist_ok=True)
    tokenstore = str(token_dir)

    # Strategy 1: saved tokens
    if not force_reauth:
        try:
            client = Garmin()
            client.login(tokenstore=tokenstore)
            log.info("Authenticated with saved tokens")
            return client
        except Exception as e:
            log.debug("Token login failed: %s", e)
            log.info("Saved tokens expired or missing, trying fresh login")

    # Strategy 2: garminconnect native login
    try:
        return _native_login(tokenstore)
    except RateLimitedError:
        log.warning("Native login blocked by Cloudflare, switching to browser login")
    except Exception as e:
        log.warning("Native login failed (%s), switching to browser login", e)

    # Strategy 3: browser login via Playwright
    return _browser_login(tokenstore)


def _native_login(tokenstore: str) -> Garmin:
    """Log in via garminconnect's built-in strategies."""
    print("\n--- Garmin Connect Login ---")
    email = input("Email: ").strip()
    password = getpass.getpass("Password: ")

    client = Garmin(
        email=email,
        password=password,
        prompt_mfa=_prompt_mfa,
    )
    try:
        client.login(tokenstore=tokenstore)
    except (GarminConnectTooManyRequestsError, GarminConnectAuthenticationError) as e:
        if "429" in str(e) or "Rate Limit" in str(e):
            raise RateLimitedError(str(e)) from e
        raise
    log.info("Logged in and tokens saved to %s", tokenstore)
    return client


def _browser_login(tokenstore: str) -> Garmin:
    """Log in via a real browser to bypass Cloudflare.

    Opens Garmin SSO in Chromium. The user logs in normally (including
    MFA if needed). We capture the service ticket from the redirect
    and exchange it for OAuth tokens.
    """
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise RuntimeError(
            "Browser login requires Playwright. Install it:\n"
            "  pip install playwright && playwright install chromium"
        )

    sso_url = (
        f"{_SSO_SIGNIN}"
        f"?clientId={_PORTAL_CLIENT_ID}"
        f"&service={_PORTAL_SERVICE}"
    )

    print("\n--- Browser Login ---")
    print("A browser window will open. Log in to Garmin Connect.")
    print("The window closes automatically after login.\n")

    ticket = None

    with sync_playwright() as pw:
        # Use a real system browser (not Playwright's Chromium) to avoid
        # Cloudflare detecting automation flags.
        browser = pw.chromium.launch(
            headless=False,
            **_find_system_browser(),
        )
        page = browser.new_page()

        def _on_request(request):
            nonlocal ticket
            # Garmin redirects to service URL with ?ticket=ST-...
            m = re.search(r"[?&]ticket=(ST-[^&]+)", request.url)
            if m and not ticket:
                ticket = m.group(1)
                log.debug("Captured service ticket: %s...", ticket[:20])

        page.on("request", _on_request)
        page.goto(sso_url)

        # Wait up to 2 minutes for user to complete login
        try:
            page.wait_for_url("**/modern/**", timeout=120_000)
        except Exception:
            pass  # ticket might already be captured

        browser.close()

    if not ticket:
        raise GarminConnectAuthenticationError(
            "Could not capture service ticket. Did you complete the login?"
        )

    log.info("Got service ticket, exchanging for tokens ...")

    # Exchange ticket for OAuth tokens using garminconnect internals
    client = Garmin()
    client.client._establish_session(
        ticket, service_url=_PORTAL_SERVICE
    )
    client.client.dump(tokenstore)
    log.debug("Tokens saved to %s", tokenstore)

    # Reload via normal path (loads tokens + fetches profile)
    client = Garmin()
    client.login(tokenstore=tokenstore)
    log.info("Browser login successful")
    return client


def _find_system_browser() -> dict:
    """Find a Chromium-based browser on the system.

    Returns kwargs for pw.chromium.launch() — either
    executable_path (Vivaldi, etc.) or channel ('chrome').
    """
    candidates = [
        "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]
    for path in candidates:
        if Path(path).exists():
            log.debug("Using system browser: %s", path)
            return {"executable_path": path}

    # Fallback: let Playwright try its own Chrome channel
    log.debug("No system browser found, trying Playwright chrome channel")
    return {"channel": "chrome"}


def _prompt_mfa() -> str:
    """Prompt user for MFA/TOTP code."""
    return input("MFA code: ").strip()
