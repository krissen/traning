"""Garmin Connect authentication with token persistence.

Three strategies, tried in order:
1. Saved tokens (fast, no network)
2. garminconnect's native login (curl_cffi TLS impersonation)
3. Browser login via Playwright (bypasses Cloudflare)
"""

import getpass
import json
import logging
import re
import tempfile
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

_TOKEN_FILE = "garmin_tokens.json"


class RateLimitedError(Exception):
    """Raised when Garmin rate-limits login attempts."""


def authenticate(token_dir: Path, force_reauth: bool = False) -> Garmin:
    """Return an authenticated Garmin client.

    Tries saved tokens first, then native login, then browser login.
    """
    token_dir.mkdir(parents=True, exist_ok=True)
    tokenstore = str(token_dir)
    token_file = token_dir / _TOKEN_FILE

    # Strategy 1: saved tokens
    if not force_reauth and token_file.exists():
        try:
            client = _load_tokens(token_file)
            if client:
                log.info("Authenticated with saved tokens")
                return client
        except Exception as e:
            log.debug("Token load failed: %s", e)
            log.info("Saved tokens expired or invalid, trying fresh login")

    # Strategy 2: garminconnect native login
    try:
        return _native_login(tokenstore)
    except RateLimitedError:
        log.warning("Native login blocked by Cloudflare, switching to browser login")
    except Exception as e:
        log.warning("Native login failed (%s), switching to browser login", e)

    # Strategy 3: browser login via Playwright
    return _browser_login(token_file)


def _load_tokens(token_file: Path) -> Garmin | None:
    """Load saved tokens. Handles both DI tokens and JWT_WEB."""
    data = json.loads(token_file.read_text())

    if data.get("di_token") and data.get("di_refresh_token"):
        # Standard garminconnect DI tokens
        client = Garmin()
        client.login(tokenstore=str(token_file.parent))
        return client

    if data.get("jwt_web"):
        # JWT_WEB from browser login
        client = Garmin()
        c = client.client
        c.jwt_web = data["jwt_web"]
        if data.get("csrf_token"):
            c.csrf_token = data["csrf_token"]
        # Verify the token still works
        c.connectapi("/userprofile-service/socialProfile")
        return client

    return None


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


def _browser_login(token_file: Path) -> Garmin:
    """Log in via a real browser to bypass Cloudflare.

    Opens Garmin SSO in Chrome. After user logs in, extracts
    JWT_WEB cookie from the browser session.
    """
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise RuntimeError(
            "Browser login requires Playwright. Install it:\n"
            "  pip install playwright"
        )

    sso_url = (
        f"{_SSO_SIGNIN}"
        f"?clientId={_PORTAL_CLIENT_ID}"
        f"&service={_PORTAL_SERVICE}"
    )

    print("\n--- Browser Login ---")
    print("A browser window will open. Log in to Garmin Connect.")
    print("The window closes automatically after login.\n")

    jwt_web = None
    csrf_token = None

    with sync_playwright() as pw, tempfile.TemporaryDirectory() as tmpdir:
        browser_opts = _find_system_browser()
        context = pw.chromium.launch_persistent_context(
            tmpdir,
            headless=False,
            ignore_default_args=["--enable-automation"],
            args=["--disable-blink-features=AutomationControlled"],
            **browser_opts,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(sso_url)

        # Wait for login to complete — look for JWT_WEB cookie
        for _ in range(240):  # 2 min timeout
            for c in context.cookies("https://connect.garmin.com"):
                if c["name"] == "JWT_WEB":
                    jwt_web = c["value"]
                elif c["name"] == "connect-csrf-token":
                    csrf_token = c["value"]
            if jwt_web:
                break
            page.wait_for_timeout(500)

        context.close()

    if not jwt_web:
        raise GarminConnectAuthenticationError(
            "Could not get JWT_WEB cookie. Did you complete the login?"
        )

    log.info("Got JWT_WEB from browser")

    # Save tokens
    data = {"jwt_web": jwt_web, "csrf_token": csrf_token}
    token_file.parent.mkdir(parents=True, exist_ok=True)
    token_file.write_text(json.dumps(data))
    log.debug("Tokens saved to %s", token_file)

    # Create client with JWT_WEB
    client = Garmin()
    c = client.client
    c.jwt_web = jwt_web
    if csrf_token:
        c.csrf_token = csrf_token

    log.info("Browser login successful")
    return client


def _find_system_browser() -> dict:
    """Find a Chromium-based browser compatible with Playwright.

    Returns kwargs for pw.chromium.launch_persistent_context().
    Note: Vivaldi is excluded — it crashes with Playwright's CDP flags.
    """
    candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]
    for path in candidates:
        if Path(path).exists():
            log.debug("Using system browser: %s", path)
            return {"executable_path": path}

    # Fallback: Playwright's bundled Chromium (less likely to pass Cloudflare)
    log.debug("No system browser found, using Playwright Chromium")
    return {}


def _prompt_mfa() -> str:
    """Prompt user for MFA/TOTP code."""
    return input("MFA code: ").strip()
