"""Home Assistant notification helper."""

import json
import logging
from datetime import datetime
from pathlib import Path

import requests

from ..settings import get_settings

log = logging.getLogger(__name__)


def notify(title: str, message: str) -> bool:
    """Send a push notification via Home Assistant REST API.

    Requires HA_URL and HA_TOKEN environment variables.
    Returns True if notification was sent, False otherwise.
    Never raises — notification failure must not block data operations.
    """
    settings = get_settings()
    ha_url = settings.ha_url
    ha_token = settings.ha_token

    if not ha_token:
        log.debug("HA_TOKEN not set, skipping notification")
        return False

    try:
        resp = requests.post(
            f"{ha_url}/api/services/script/traning_notify",
            headers={
                "Authorization": f"Bearer {ha_token}",
                "Content-Type": "application/json",
            },
            json={"title": title, "message": message},
            timeout=5,
            verify=not ha_url.startswith("https://localhost"),
        )
        resp.raise_for_status()
        log.info("Avisering skickad: [%s] %s", title, message)
        return True
    except Exception as e:
        log.warning("Avisering misslyckades: [%s] %s — %s", title, message, e)
        return False


def log_notification(
    trigger: str,
    title: str,
    message: str,
    sent: bool,
    error: str | None = None,
) -> None:
    """Append notification event to JSONL log file.

    Log path: $TRANING_DATA/logs/notifications.jsonl
    Never raises — logging failure must not affect operation.
    """
    data_dir = get_settings().traning_data
    if not data_dir:
        return

    log_path = Path(data_dir) / "logs" / "notifications.jsonl"

    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        entry = {
            "ts": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            "trigger": trigger,
            "title": title,
            "message": message,
            "sent": sent,
        }
        if error:
            entry["error"] = error

        with open(log_path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass
