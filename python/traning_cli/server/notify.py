"""Home Assistant notification helper."""

import logging
import os

import requests

log = logging.getLogger(__name__)


def notify(title: str, message: str) -> bool:
    """Send a push notification via Home Assistant REST API.

    Requires HA_URL and HA_TOKEN environment variables.
    Returns True if notification was sent, False otherwise.
    Never raises — notification failure must not block data operations.
    """
    ha_url = os.environ.get("HA_URL", "http://localhost:8123")
    ha_token = os.environ.get("HA_TOKEN")

    if not ha_token:
        log.debug("HA_TOKEN not set, skipping notification")
        return False

    try:
        resp = requests.post(
            f"{ha_url}/api/services/notify/mobile_app_anandavani",
            headers={
                "Authorization": f"Bearer {ha_token}",
                "Content-Type": "application/json",
            },
            json={"title": title, "message": message},
            timeout=5,
            verify=not ha_url.startswith("https://localhost"),
        )
        resp.raise_for_status()
        log.info("HA notification sent: %s", title)
        return True
    except Exception as e:
        log.warning("HA notification failed: %s", e)
        return False
