"""Shared helpers for the FIT/TCX device scanners."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import date
from pathlib import Path
from typing import Protocol

from .log import DeviceRow

# Garmin's own devices go back to ~2003; nothing in this data repo predates
# 2000. Below that (or after today) the recorded activity_date is corrupt
# metadata, not a real device change — most commonly a FIT/TCX file with a
# bogus or unset time_created/Id field.
MIN_PLAUSIBLE_DATE = date(2000, 1, 1)


def plausible_date(d: date) -> bool:
    """True if ``d`` is a believable activity date (not corrupt metadata)."""
    return MIN_PLAUSIBLE_DATE <= d <= date.today()


class ScannedDeviceRecord(Protocol):
    """Structural type shared by FitDeviceRecord and TcxScanRecord."""

    path: Path
    activity_date: date
    model: str
    os_version: str


def collapse_device_changes(
    records: Sequence[ScannedDeviceRecord],
    *,
    platform: str,
    origin: str,
    note_prefix: str,
) -> list[DeviceRow]:
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
                "platform": platform,
                "model": record.model,
                "os_version": record.os_version,
                "certainty": "exact",
                "origin": origin,
                "note": f"{note_prefix}: {record.path.name}",
            }
        )
    return candidates


def merge_candidates(*candidate_lists: list[DeviceRow]) -> list[DeviceRow]:
    """Merge candidate rows from multiple scanners into one deduped set.

    Keys on (platform, model, os_version); the earliest ``valid_from``
    wins so the same real-world device change derived from two archives
    (FIT and TCX) collapses into a single row instead of two. Ties
    (identical valid_from from both sources) keep whichever candidate
    was encountered first once inputs are sorted by (valid_from, origin)
    — deterministic regardless of the lists' original order.
    """
    combined = [row for rows in candidate_lists for row in rows]
    combined.sort(key=lambda r: (r["valid_from"], r["origin"]))

    best: dict[tuple[str, str, str], DeviceRow] = {}
    for row in combined:
        key = (row["platform"], row["model"], row["os_version"])
        current = best.get(key)
        if current is None or row["valid_from"] < current["valid_from"]:
            best[key] = row
    return list(best.values())
