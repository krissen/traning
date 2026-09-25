"""Derive device-change candidates from historical Garmin FIT files.

Scans ``$TRANING_DATA/kristian/filer/fit/**`` (recursively, following
symlinks), pulls the creator device's product name and firmware/software
version plus the activity's creation date out of each file, and collapses
the chronological sequence into a minimal set of "device changed here"
events — one row per point where the (model, os_version) pair differs
from the previous activity.

FIT layout used, per file:
- ``file_id``: ``manufacturer``, ``garmin_product`` (or numeric ``product``
  for unrecognised product ids), ``time_created`` — the activity date.
- ``device_info`` where ``device_index == "creator"``: ``software_version``
  of the recording device itself (not a paired sensor like a HR strap).

Corrupt files, FIT files that aren't activities (``file_id.type !=
"activity"``), and files whose activity date is implausible (see
``common.plausible_date``) are skipped and counted, never raised.

Model and OS version are normalized (see ``common.normalize_model`` /
``common.normalize_os_version``) before a record is built, so a FIT-
derived and a TCX-derived row for the same real device change compare
equal in ``merge_candidates()``.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

import fitparse

from .common import (
    collapse_device_changes,
    garmin_activity_local_date,
    normalize_model,
    normalize_os_version,
    plausible_date,
    utc_to_stockholm_date,
)
from .log import DeviceRow

log = logging.getLogger(__name__)

# A local_timestamp farther than this from time_created is a broken
# watch clock, not a timezone: valid UTC offsets span -12 to +14 h.
# (Seen in the archive: time_created in 2061 with a local_timestamp in
# 2017 — trusting it invented a "connect" device row in 2017.)
MAX_LOCAL_UTC_SKEW = timedelta(hours=14)


@dataclass
class FitScanStats:
    scanned: int = 0
    ok: int = 0
    corrupt: int = 0
    skipped_not_activity: int = 0
    skipped_bad_date: int = 0
    bad_date_examples: list[str] = field(default_factory=list)


@dataclass
class FitDeviceRecord:
    path: Path
    activity_date: date
    model: str
    os_version: str
    # Raw UTC creation moment, kept so the scan can plausibility-check
    # the source (not just the resolved date) — see scan_fit_directory.
    time_created: datetime | None = None


def _trusted_local_timestamp(
    local: datetime | date | None, time_created: datetime
) -> datetime | date | None:
    """Return `local` iff it can plausibly be `time_created`'s wall-clock.

    A bare date carries no time to check against, and an aware/naive
    mix can't be subtracted — both are untrusted. Anything farther
    than MAX_LOCAL_UTC_SKEW from time_created is a broken clock (see
    above), and the caller falls back to UTC-converted-to-Stockholm.
    """
    if not isinstance(local, datetime):
        return None
    try:
        skew = abs(local - time_created)
    except TypeError:
        return None
    return local if skew <= MAX_LOCAL_UTC_SKEW else None


def _iter_fit_files(fit_dir: Path):
    """Yield every *.fit/*.FIT file under fit_dir, following symlinks."""
    for root, _dirs, files in os.walk(fit_dir, followlinks=True):
        for name in files:
            if name.lower().endswith(".fit"):
                yield Path(root) / name


def _format_os_version(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and value == int(value):
        return str(int(value))
    return str(value)


def parse_fit_device(path: Path) -> FitDeviceRecord | None:
    """Extract (model, os_version, activity_date) from one FIT file.

    Returns None for a non-activity FIT file (e.g. a settings/monitoring
    file). Raises on a corrupt/unreadable file — callers count those.
    """
    fit = fitparse.FitFile(str(path))

    file_id: dict | None = None
    creator_software_version = None
    activity_local_timestamp = None

    for msg in fit.messages:
        if msg.name == "file_id" and file_id is None:
            file_id = {d.name: d.value for d in msg}
        elif msg.name == "activity" and activity_local_timestamp is None:
            fields = {d.name: d.value for d in msg}
            candidate = fields.get("local_timestamp")
            if isinstance(candidate, (datetime, date)):
                activity_local_timestamp = candidate
        elif msg.name == "device_info":
            fields = {d.name: d.value for d in msg}
            if fields.get("device_index") == "creator":
                sw = fields.get("software_version")
                if sw is not None:
                    creator_software_version = sw

    if file_id is None:
        raise ValueError(f"{path}: no file_id message")

    if file_id.get("type") != "activity":
        return None

    time_created = file_id.get("time_created")
    if not isinstance(time_created, datetime):
        raise ValueError(f"{path}: file_id.time_created missing or not a datetime")

    # FIT's activity.local_timestamp is wall-clock time where the
    # activity happened; file_id may carry one too. Either beats the
    # UTC time_created (converted to Europe/Stockholm as fallback) —
    # but only when it agrees with time_created (see
    # _trusted_local_timestamp): a broken watch clock is worse than no
    # local time at all.
    file_id_local = file_id.get("local_timestamp")
    raw_local = activity_local_timestamp
    if raw_local is None and isinstance(file_id_local, (datetime, date)):
        raw_local = file_id_local
    local_timestamp = _trusted_local_timestamp(raw_local, time_created)
    activity_date = garmin_activity_local_date(
        local_timestamp=local_timestamp, utc_moment=time_created
    )
    assert activity_date is not None  # utc_moment given, always resolves

    model = file_id.get("garmin_product")
    if model is None:
        model = file_id.get("product")
    model_str = "" if model is None else str(model)

    os_version = creator_software_version
    if os_version is None:
        os_version = file_id.get("software_version")

    return FitDeviceRecord(
        path=path,
        activity_date=activity_date,
        model=normalize_model(model_str),
        os_version=normalize_os_version(_format_os_version(os_version)),
        time_created=time_created,
    )


def scan_fit_directory(fit_dir: Path) -> tuple[list[FitDeviceRecord], FitScanStats]:
    """Scan every FIT file under fit_dir. Never raises — errors are counted."""
    stats = FitScanStats()
    records: list[FitDeviceRecord] = []

    if not fit_dir.is_dir():
        return records, stats

    for path in _iter_fit_files(fit_dir):
        stats.scanned += 1
        try:
            record = parse_fit_device(path)
        except Exception:
            log.debug("Corrupt or unreadable FIT file, skipping: %s", path, exc_info=True)
            stats.corrupt += 1
            continue
        if record is None:
            stats.skipped_not_activity += 1
            continue
        # Plausibility is checked on the resolved date AND on the raw
        # time_created: a corrupt time_created (bogus year) must be
        # rejected even when a local_timestamp gave a sane-looking
        # final date for it.
        created_ok = record.time_created is None or plausible_date(
            utc_to_stockholm_date(record.time_created)
        )
        if not plausible_date(record.activity_date) or not created_ok:
            stats.skipped_bad_date += 1
            stats.bad_date_examples.append(f"{record.activity_date.isoformat()}  {path.name}")
            log.warning("Skipping implausible activity date %s in %s", record.activity_date, path)
            continue
        stats.ok += 1
        records.append(record)

    return records, stats


def collapse_changes(records: list[FitDeviceRecord]) -> list[DeviceRow]:
    """Collapse a chronological FIT record list into device-change candidates.

    See ``common.collapse_device_changes`` for the collapse rule.
    """
    return collapse_device_changes(records, platform="garmin", origin="fit", note_prefix="fit-scan")


def scan_and_collapse(fit_dir: Path) -> tuple[list[DeviceRow], FitScanStats]:
    """Scan fit_dir and return (candidate device-change rows, scan stats)."""
    records, stats = scan_fit_directory(fit_dir)
    return collapse_changes(records), stats
