"""Download activities from Garmin Connect and store locally."""

import json
import logging
import os
import time
from pathlib import Path

from garminconnect import Garmin

from .utils import (
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

# Partial-download retry cap. An activity whose details/TCX fail this many
# times in a row is permanently unavailable (deleted upstream, corrupt,
# etc.) rather than transiently flaky — retrying it forever would waste an
# API call and log a warning on every single run. See _download_activity().
RETRY_STATE_FILENAME = ".garmin_retry_state.json"
# 5 attempts × the 15-min Garmin timer ≈ 75 min before an activity is written
# off — enough margin that a long-but-transient details/TCX outage recovers,
# while still bounding a permanently-broken activity's retries.
MAX_PARTIAL_ATTEMPTS = 5


def _retry_state_path(data_dir: Path) -> Path:
    return data_dir / RETRY_STATE_FILENAME


def _load_retry_state(path: Path) -> dict[str, int]:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        log.warning("Could not read retry state %s, starting fresh", path)
        return {}


def _save_retry_state(path: Path, state: dict[str, int]) -> None:
    try:
        path.write_text(json.dumps(state, indent=2))
    except OSError:
        log.warning("Could not write retry state %s", path)


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
                complete = _download_activity(
                    client,
                    activity,
                    gc_dir,
                    tc_dir,
                    retry_state_path=_retry_state_path(data_dir),
                )
            except Exception:
                log.exception("Failed to download activity %s, skipping", activity_id)
                continue

            if complete:
                new_count += 1
                existing_ids.add(activity_id)
                if new_count % 10 == 0:
                    log.info("Fetched %d new activities so far ...", new_count)
            else:
                summary_still_missing = not any(
                    gc_dir.glob(f"*_{activity_id}_summary.json")
                )
                if summary_still_missing:
                    # No summary left behind — the next run's dedup scan
                    # (get_existing_activity_ids) won't find one for this
                    # activity, so it will be retried in full.
                    log.warning(
                        "Activity %s incomplete this run, will retry next run",
                        activity_id,
                    )
                # else: _download_activity hit MAX_PARTIAL_ATTEMPTS and gave
                # up, keeping the summary in place so it won't be retried
                # again — it already logged its own "giving up" message.

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
    retry_state_path: Path | None = None,
) -> bool:
    """Download summary JSON, details JSON, and TCX for one activity.

    Returns True only if all three artifacts (summary, details, TCX) were
    saved successfully. ``get_existing_activity_ids`` keys the dedup scan
    off ``*_summary.json`` alone, so a partial download (summary written,
    details or TCX failing) must NOT leave the summary file behind — that
    would make the activity look "already fetched" forever and it would
    never be retried. On partial failure we remove the summary again so
    the next run re-fetches the activity in full.

    ``retry_state_path``, when given, points at a small JSON file (one run
    per Garmin account) tracking how many times each activity has failed a
    partial download in a row. After ``MAX_PARTIAL_ATTEMPTS`` consecutive
    failures the activity is treated as permanently unavailable: we stop
    removing the summary (so the dedup scan in ``get_existing_activity_ids``
    picks it up and skips it on future runs) and log a clear "giving up"
    message instead of retrying forever. A subsequent successful full
    download clears the counter for that activity id.
    """
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

    complete = True

    # 2. Save details JSON
    try:
        details = client.get_activity(activity_id)
        details_path = gc_dir / f"{prefix}_details.json"
        details_path.write_text(json.dumps(details, indent=2, ensure_ascii=False))
        log.debug("Saved %s", details_path.name)
    except Exception:
        log.warning("Could not fetch details for %s", activity_id)
        complete = False

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
        complete = False

    if not complete:
        if retry_state_path is not None:
            state = _load_retry_state(retry_state_path)
            attempts = state.get(str(activity_id), 0) + 1
            if attempts >= MAX_PARTIAL_ATTEMPTS:
                log.error(
                    "Giving up on activity %s after %d failed attempts; "
                    "keeping the partial summary so it is not retried again",
                    activity_id,
                    attempts,
                )
                state.pop(str(activity_id), None)
                _save_retry_state(retry_state_path, state)
                # Leave summary_path in place: get_existing_activity_ids()
                # will now see this activity as "already fetched" and skip
                # it on future runs, capping the retries.
                return False
            state[str(activity_id)] = attempts
            _save_retry_state(retry_state_path, state)
        summary_path.unlink(missing_ok=True)
        return False

    if retry_state_path is not None:
        state = _load_retry_state(retry_state_path)
        if state.pop(str(activity_id), None) is not None:
            _save_retry_state(retry_state_path, state)

    name = activity.get("activityName", "?")
    log.info("Downloaded: %s — %s", iso_timestamp[:10], name)
    return True
