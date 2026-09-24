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

Corrupt files and FIT files that aren't activities (``file_id.type !=
"activity"``) are skipped and counted, never raised.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

import fitparse

from .log import DeviceRow

log = logging.getLogger(__name__)


@dataclass
class FitScanStats:
    scanned: int = 0
    ok: int = 0
    corrupt: int = 0
    skipped_not_activity: int = 0


@dataclass
class FitDeviceRecord:
    path: Path
    activity_date: date
    model: str
    os_version: str


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

    for msg in fit.messages:
        if msg.name == "file_id" and file_id is None:
            file_id = {d.name: d.value for d in msg}
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

    model = file_id.get("garmin_product")
    if model is None:
        model = file_id.get("product")
    model_str = "" if model is None else str(model)

    os_version = creator_software_version
    if os_version is None:
        os_version = file_id.get("software_version")

    return FitDeviceRecord(
        path=path,
        activity_date=time_created.date(),
        model=model_str,
        os_version=_format_os_version(os_version),
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
        stats.ok += 1
        records.append(record)

    return records, stats


def collapse_changes(records: list[FitDeviceRecord]) -> list[DeviceRow]:
    """Collapse a chronological record list into device-change candidates.

    Records are sorted by activity date first. One candidate row is
    emitted per point where (model, os_version) differs from the
    previous activity in the sequence — including the very first record,
    which establishes the earliest known device.
    """
    ordered = sorted(records, key=lambda r: r.activity_date)

    candidates: list[DeviceRow] = []
    prev: tuple[str, str] | None = None
    for record in ordered:
        current = (record.model, record.os_version)
        if current == prev:
            continue
        prev = current
        candidates.append(
            {
                "valid_from": record.activity_date.isoformat(),
                "platform": "garmin",
                "model": record.model,
                "os_version": record.os_version,
                "certainty": "exact",
                "origin": "fit",
                "note": f"scan-fit: {record.path.name}",
            }
        )
    return candidates


def scan_and_collapse(fit_dir: Path) -> tuple[list[DeviceRow], FitScanStats]:
    """Scan fit_dir and return (candidate device-change rows, scan stats)."""
    records, stats = scan_fit_directory(fit_dir)
    return collapse_changes(records), stats
