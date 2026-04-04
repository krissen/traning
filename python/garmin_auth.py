"""Garmin Connect authentication with token persistence."""

import getpass
import logging
from pathlib import Path

from garminconnect import Garmin
from garminconnect.exceptions import (
    GarminConnectAuthenticationError,
    GarminConnectTooManyRequestsError,
)

log = logging.getLogger(__name__)


class RateLimitedError(Exception):
    """Raised when Garmin rate-limits login attempts."""


def authenticate(token_dir: Path, force_reauth: bool = False) -> Garmin:
    """Return an authenticated Garmin client.

    Tries saved tokens first. Falls back to interactive login if tokens
    are missing, expired, or force_reauth is True.
    """
    token_dir.mkdir(parents=True, exist_ok=True)
    tokenstore = str(token_dir)

    if not force_reauth:
        try:
            client = Garmin()
            client.login(tokenstore=tokenstore)
            log.info("Authenticated with saved tokens")
            return client
        except Exception as e:
            log.debug("Token login failed: %s", e)
            log.info("Saved tokens expired or missing, need interactive login")

    return _interactive_login(tokenstore)


def _interactive_login(tokenstore: str) -> Garmin:
    """Prompt for credentials and log in."""
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
            raise RateLimitedError(
                "Garmin rate-limited the login request. "
                "Wait a few minutes and try again."
            ) from e
        raise
    log.info("Logged in and tokens saved to %s", tokenstore)
    return client


def _prompt_mfa() -> str:
    """Prompt user for MFA/TOTP code."""
    return input("MFA code: ").strip()
