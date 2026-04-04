"""Download activities from Garmin Connect and store locally."""

import json
import logging
import os
import time
from pathlib import Path

from garminconnect import Garmin

from garmin_utils import (
    activity_filename_prefix,
    extract_activity_id,
    gconnect_dir,
    prefix_to_symlink_name,
    tcx_dir,
)

log = logging.getLogger(__name__)

# Garmin API rate limiting
REQUEST_DELAY = 1.0  # seconds between API calls
BACKOFF_BASE = 2.0
BACKOFF_MAX = 60.0
MAX_RETRIES = 5
PAGE_SIZE = 100  # activities per API page


def get_existing_activity_ids(gc_dir: Path) -> set[int]:
    """Scan gconnect/ for *_summary.json and extract activity IDs."""
    ids: set[int] = set()
    if not gc_dir.is_dir():
        return ids
    for f in gc_dir.iterdir():
        aid = extract_activity_id(f.name)
        if aid is not None:
            ids.add(aid)
    log.info("Found %d existing activities in %s", len(ids), gc_dir)
    return ids


def fetch_new_activities(
    client: Garmin,
    data_dir: Path,
    limit: int = 50,
    fetch_all: bool = False,
    dry_run: bool = False,
) -> int:
    """Download new activities from Garmin Connect.

    Returns the number of new activities fetched.
    """
    gc_dir = gconnect_dir(data_dir)
    tc_dir = tcx_dir(data_dir)

    if not gc_dir.is_dir():
        raise FileNotFoundError(f"gconnect directory not found: {gc_dir}")
    if not tc_dir.is_dir():
        raise FileNotFoundError(f"tcx directory not found: {tc_dir}")

    existing_ids = get_existing_activity_ids(gc_dir)
    new_count = 0
    offset = 0
    consecutive_known = 0

    while True:
        if not fetch_all and new_count >= limit:
            break

        batch = _fetch_activity_list(client, offset, PAGE_SIZE)
        if not batch:
            log.info("No more activities from API")
            break

        for activity in batch:
            if not fetch_all and new_count >= limit:
                break

            activity_id = activity.get("activityId")
            if activity_id is None:
                continue

            if activity_id in existing_ids:
                consecutive_known += 1
                # Stop after 10 consecutive known activities (we've caught up)
                if not fetch_all and consecutive_known >= 10:
                    log.info("Found %d consecutive known activities, stopping", consecutive_known)
                    return new_count
                continue

            consecutive_known = 0

            if dry_run:
                name = activity.get("activityName", "?")
                start = activity.get("startTimeGMT", "?")
                print(f"  [dry-run] {start} — {name} (id: {activity_id})")
                new_count += 1
                continue

            try:
                _download_activity(client, activity, gc_dir, tc_dir)
                new_count += 1
                existing_ids.add(activity_id)
                if new_count % 10 == 0:
                    log.info("Fetched %d new activities so far ...", new_count)
            except Exception:
                log.exception("Failed to download activity %s, skipping", activity_id)

        offset += PAGE_SIZE

    return new_count


def _fetch_activity_list(client: Garmin, start: int, limit: int) -> list[dict]:
    """Fetch a page of activities from the API with retry."""
    for attempt in range(MAX_RETRIES):
        try:
            time.sleep(REQUEST_DELAY)
            return client.get_activities(start=start, limit=limit)
        except Exception as e:
            if "429" in str(e) or "Too Many" in str(e):
                delay = min(BACKOFF_BASE ** (attempt + 1), BACKOFF_MAX)
                log.warning("Rate limited, waiting %.0fs ...", delay)
                time.sleep(delay)
            else:
                raise
    log.error("Max retries exceeded fetching activity list at offset %d", start)
    return []


def _download_activity(
    client: Garmin,
    activity: dict,
    gc_dir: Path,
    tc_dir: Path,
) -> None:
    """Download summary JSON, details JSON, and TCX for one activity."""
    activity_id = activity["activityId"]
    start_gmt = activity.get("startTimeGMT", "")

    # Build the ISO8601 timestamp from startTimeGMT
    # API returns "2023-11-18 19:48:49" — convert to "2023-11-18T19:48:49+00:00"
    iso_timestamp = start_gmt.replace(" ", "T") + "+00:00" if start_gmt else str(activity_id)
    prefix = activity_filename_prefix(iso_timestamp, activity_id)

    # 1. Save summary JSON (the activity list entry itself)
    summary_path = gc_dir / f"{prefix}_summary.json"
    summary_path.write_text(json.dumps(activity, indent=2, ensure_ascii=False))
    log.debug("Saved %s", summary_path.name)

    time.sleep(REQUEST_DELAY)

    # 2. Save details JSON
    try:
        details = client.get_activity(activity_id)
        details_path = gc_dir / f"{prefix}_details.json"
        details_path.write_text(json.dumps(details, indent=2, ensure_ascii=False))
        log.debug("Saved %s", details_path.name)
    except Exception:
        log.warning("Could not fetch details for %s", activity_id)

    time.sleep(REQUEST_DELAY)

    # 3. Download TCX
    try:
        tcx_data = client.download_activity(activity_id)
        tcx_path = gc_dir / f"{prefix}.tcx"
        tcx_path.write_bytes(tcx_data)
        log.debug("Saved %s", tcx_path.name)

        # Create symlink in tcx/
        symlink_name = prefix_to_symlink_name(prefix) + ".tcx"
        symlink_path = tc_dir / symlink_name
        if not symlink_path.exists():
            target = os.path.relpath(tcx_path, tc_dir)
            symlink_path.symlink_to(target)
            log.debug("Symlink %s -> %s", symlink_name, target)
    except Exception:
        log.warning("Could not download TCX for %s", activity_id)

    name = activity.get("activityName", "?")
    log.info("Downloaded: %s — %s", iso_timestamp[:10], name)
