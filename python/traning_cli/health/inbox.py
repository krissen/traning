"""Process health export files dropped in the inbox directory."""

import json
import logging
import shutil
from pathlib import Path

from .utils import health_metrics_dir, health_inbox_dir

log = logging.getLogger(__name__)


def _is_hae_format(filepath: Path) -> bool:
    """Check if a JSON file looks like HAE export format."""
    try:
        with open(filepath) as f:
            data = json.load(f)
        return "data" in data and "metrics" in data["data"]
    except (json.JSONDecodeError, KeyError):
        return False


def fetch_inbox(data_dir: Path | None = None, dry_run: bool = False) -> int:
    """Process JSON files from inbox → metrics directory.

    Returns the number of files moved.
    """
    inbox = health_inbox_dir(data_dir)
    metrics_dir = health_metrics_dir(data_dir)

    if not inbox.is_dir():
        log.info("Ingen inbox-mapp: %s", inbox)
        return 0

    files = list(inbox.glob("*.json"))
    if not files:
        log.info("Inbox tom")
        return 0

    if dry_run:
        for f in files:
            log.info("Dry run: would process %s", f.name)
        return len(files)

    metrics_dir.mkdir(parents=True, exist_ok=True)
    processed_dir = inbox / "processed"
    processed_dir.mkdir(exist_ok=True)

    n_moved = 0
    for filepath in files:
        if not _is_hae_format(filepath):
            log.warning("Ogiltig HAE-fil, hoppar över: %s", filepath.name)
            continue

        dest = metrics_dir / filepath.name
        if dest.exists():
            log.info("Redan importerad, hoppar över: %s", filepath.name)
            shutil.move(str(filepath), str(processed_dir / filepath.name))
            continue

        shutil.copy2(str(filepath), str(dest))
        shutil.move(str(filepath), str(processed_dir / filepath.name))
        log.info("Importerad: %s", filepath.name)
        n_moved += 1

    return n_moved
