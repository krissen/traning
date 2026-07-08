"""Fetch HAE workouts from the TCP server with full metadata.

Pulls historical workouts month by month and writes each one to disk in
the same format as the live push pipeline (one JSON per workout under
``health_export/workouts/``).  Existing files are skipped so the operation
is resumable.

The key insight: ``includeMetadata: true`` is the documented but easy-to-miss
arg that turns on avgHeartRate, heartRateData, etc.  Without it the response
contains only basic stats.
"""

import json
import logging
import time
import unicodedata
from datetime import datetime, timedelta
from pathlib import Path

from .hae_client import HAEError, HAEWorkoutsError, query_hae
from .utils import health_workouts_dir

log = logging.getLogger(__name__)

__all__ = [
    "HAEError", "HAEWorkoutsError", "fetch_workouts_tcp",
]

DEFAULT_TIMEOUT = 300.0  # seconds; large windows can take 15s+
DEFAULT_TZ = "+0100"  # Stockholm winter; HAE accepts any tz with absolute datetimes


def _query_workouts(start: str, end: str, include_metadata: bool = True,
                    metadata_aggregation: str = "minutes",
                    timeout: float = DEFAULT_TIMEOUT) -> list[dict]:
    """Send a workouts query to the HAE TCP server.

    ``start`` / ``end`` must be formatted ``"yyyy-MM-dd HH:mm:ss Z"``.
    Returns the list of workout dicts on success (possibly empty).
    Raises HAEWorkoutsError on connection / parse / shape failures.
    """
    body = query_hae(
        "workouts",
        {
            "start": start,
            "end": end,
            "includeMetadata": include_metadata,
            "includeRoutes": False,
            "metadataAggregation": metadata_aggregation,
        },
        request_id="fetch_workouts",
        timeout=timeout,
    )
    return body.get("workouts", []) or []


def _workout_filename(w: dict) -> str:
    """Build the canonical filename for a workout — matches save_workout_push."""
    name = w.get("name", "workout")
    start = w.get("start", "")
    ts = start[:19].replace("-", "").replace(":", "").replace(" ", "_")
    safe_name = unicodedata.normalize("NFKD", name)
    safe_name = safe_name.encode("ascii", "ignore").decode("ascii")
    safe_name = safe_name.replace(" ", "_").replace("/", "_")
    return f"{safe_name}-{ts}.json"


def _save_workout(w: dict, workouts_dir: Path) -> bool:
    """Write workout JSON to disk. Returns True if newly written."""
    filepath = workouts_dir / _workout_filename(w)
    if filepath.exists():
        return False
    workouts_dir.mkdir(parents=True, exist_ok=True)
    with open(filepath, "w", encoding="utf-8") as f:
        json.dump({"data": {"workouts": [w]}}, f, ensure_ascii=False)
    return True


def _month_iter(start_date: datetime, end_date: datetime):
    """Yield (chunk_start, chunk_end) datetimes month by month."""
    cur = start_date
    while cur < end_date:
        if cur.month == 12:
            nxt = cur.replace(year=cur.year + 1, month=1)
        else:
            nxt = cur.replace(month=cur.month + 1)
        yield cur, min(nxt, end_date)
        cur = nxt


def _fmt(d: datetime) -> str:
    return d.strftime("%Y-%m-%d %H:%M:%S ") + DEFAULT_TZ


def fetch_workouts_tcp(start_date: str | datetime, end_date: str | datetime | None = None,
                       data_dir: Path | None = None, dry_run: bool = False,
                       include_metadata: bool = True,
                       metadata_aggregation: str = "minutes",
                       max_retries: int = 2) -> dict[str, int]:
    """Fetch workouts month by month and save each to disk.

    Args:
        start_date: ``"yyyy-mm-dd"`` string or datetime.
        end_date: same; defaults to today.
        data_dir: override traning-data root.
        dry_run: only count, don't write.
        include_metadata: include avgHeartRate etc.  Default True.
        metadata_aggregation: 'minutes' or 'seconds'.  Higher granularity
            means bigger responses but lossless HR data.
        max_retries: retry count per chunk on transient errors.

    Returns dict with counts: ``new``, ``existing``, ``empty_chunks``,
    ``failed_chunks``.
    """
    if isinstance(start_date, str):
        start_dt = datetime.strptime(start_date, "%Y-%m-%d")
    else:
        start_dt = start_date
    if end_date is None:
        end_dt = datetime.now() + timedelta(days=1)
    elif isinstance(end_date, str):
        end_dt = datetime.strptime(end_date, "%Y-%m-%d")
    else:
        end_dt = end_date

    workouts_dir = health_workouts_dir(data_dir)
    counts = {"new": 0, "existing": 0, "empty_chunks": 0, "failed_chunks": 0}

    log.info("Fetching workouts %s → %s (metadata=%s, agg=%s)",
             start_dt.date(), end_dt.date(), include_metadata, metadata_aggregation)

    for chunk_start, chunk_end in _month_iter(start_dt, end_dt):
        s, e = _fmt(chunk_start), _fmt(chunk_end)
        label = chunk_start.strftime("%Y-%m")

        wks = None
        for attempt in range(max_retries + 1):
            try:
                t0 = time.time()
                wks = _query_workouts(s, e, include_metadata=include_metadata,
                                      metadata_aggregation=metadata_aggregation)
                dt = time.time() - t0
                break
            except HAEWorkoutsError as ex:
                if attempt < max_retries:
                    log.warning("  %s: %s — retrying in 3s", label, ex)
                    time.sleep(3)
                else:
                    log.error("  %s: failed after retries: %s", label, ex)
                    counts["failed_chunks"] += 1

        if wks is None:
            continue
        if not wks:
            log.info("  %s: 0 workouts (%.1fs)", label, dt)
            counts["empty_chunks"] += 1
            continue

        n_new = 0
        n_existing = 0
        for w in wks:
            if dry_run:
                fp = workouts_dir / _workout_filename(w)
                if fp.exists():
                    n_existing += 1
                else:
                    n_new += 1
            else:
                if _save_workout(w, workouts_dir):
                    n_new += 1
                else:
                    n_existing += 1

        counts["new"] += n_new
        counts["existing"] += n_existing
        log.info("  %s: %d wk (%d new, %d existing, %.1fs)",
                 label, len(wks), n_new, n_existing, dt)

    return counts
