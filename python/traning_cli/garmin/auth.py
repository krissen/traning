"""Garmin Connect authentication via pirate-garmin.

Uses pirate-garmin for browser-based auth (bypasses Cloudflare),
then injects DI tokens into garminconnect for API access.

Login methods:
- browser (default): pirate-garmin browser login -> DI tokens (~1 year)
- native: garminconnect's built-in TLS impersonation (often blocked)

Credentials are read from environment or .Renviron (GARMIN_EMAIL, GARMIN_PASSWORD).
"""

import getpass
import logging
import os
from pathlib import Path

from garminconnect import Garmin

from .utils import _read_renviron, get_project_root

log = logging.getLogger(__name__)


def _get_credentials() -> tuple[str, str]:
    """Get Garmin credentials from env/.Renviron or prompt."""
    renviron = _read_renviron(get_project_root() / ".Renviron")

    email = os.environ.get("GARMIN_EMAIL") or renviron.get("GARMIN_EMAIL")
    password = os.environ.get("GARMIN_PASSWORD") or renviron.get("GARMIN_PASSWORD")

    if not email:
        email = input("Email: ").strip()
    if not password:
        password = getpass.getpass("Password: ")

    return email, password


def authenticate(
    token_dir: Path,
    force_reauth: bool = False,
    method: str = "browser",
) -> Garmin:
    """Return an authenticated Garmin client.

    Args:
        token_dir: Directory for token storage
        force_reauth: Force fresh login
        method: 'browser' (pirate-garmin) or 'native' (garminconnect)
    """
    token_dir.mkdir(parents=True, exist_ok=True)

    if method == "native":
        return _native_login(str(token_dir))

    return _pirate_login(token_dir, force_reauth)


def _pirate_login(token_dir: Path, force_reauth: bool = False) -> Garmin:
    """Authenticate via pirate-garmin -> inject DI tokens into garminconnect."""
    try:
        from pirate_garmin.auth import AuthManager, Credentials
    except ImportError:
        raise RuntimeError(
            "Browser login requires pirate-garmin. Install it:\n"
            "  pip install pirate-garmin"
        )

    app_dir = str(token_dir / "pirate-garmin")

    # Try loading saved session first
    if not force_reauth:
        manager = AuthManager(app_dir=app_dir)
        try:
            session = manager.ensure_authenticated()
            log.info("Authenticated with saved tokens")
            return _inject_tokens(session)
        except Exception as e:
            log.debug("Saved session failed: %s", e)
            log.info("Need fresh login")

    # Fresh login
    email, password = _get_credentials()
    manager = AuthManager(
        credentials=Credentials(email, password),
        app_dir=app_dir,
    )
    session = manager.ensure_authenticated()
    manager.save_native_session(session)
    log.info("Logged in, tokens saved (valid ~1 year)")

    return _inject_tokens(session)


def _inject_tokens(session) -> Garmin:
    """Create a garminconnect Garmin client with pirate-garmin's DI tokens."""
    client = Garmin()
    c = client.client
    c.di_token = session.di.token.access_token
    c.di_refresh_token = getattr(session.di.token, "refresh_token", None)
    c.di_client_id = session.di.client_id
    return client


def _native_login(tokenstore: str) -> Garmin:
    """Log in via garminconnect's built-in strategies (often Cloudflare-blocked)."""
    from garminconnect.exceptions import (
        GarminConnectAuthenticationError,
        GarminConnectTooManyRequestsError,
    )

    email, password = _get_credentials()
    client = Garmin(
        email=email,
        password=password,
        prompt_mfa=lambda: input("MFA code: ").strip(),
    )
    try:
        client.login(tokenstore=tokenstore)
    except (GarminConnectTooManyRequestsError, GarminConnectAuthenticationError) as e:
        if "429" in str(e) or "Rate Limit" in str(e):
            raise RuntimeError(
                "Garmin rate-limited the request. Try --login-method browser"
            ) from e
        raise
    log.info("Native login successful, tokens saved to %s", tokenstore)
    return client
