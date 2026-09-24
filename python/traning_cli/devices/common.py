"""Shared helpers for the FIT/TCX device scanners."""

from __future__ import annotations

import re
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


# -- model name normalization ------------------------------------------------
#
# FIT's file_id.garmin_product is a short internal code ("fr610"); TCX's
# <Creator><Name> is a human string, but not a consistent one across the
# archive's history ("Garmin Forerunner 610", "Forerunner305" with no
# space). Without normalizing both to the same canonical form, the same
# physical watch never dedups across FIT and TCX in merge_candidates() —
# their (model, os_version) keys never match even though they describe the
# same device change. Table-driven for FIT's opaque codes (there's no
# pattern to derive "fr610" -> "Forerunner 610" from); regex-driven for
# TCX's human names, which vary in prefix/spacing but not vocabulary.
FIT_PRODUCT_NAMES: dict[str, str] = {
    "fr305": "Forerunner 305",
    "fr610": "Forerunner 610",
    "fr620": "Forerunner 620",
    "fr945": "Forerunner 945",
}

_TCX_STRIP_GARMIN_PREFIX = re.compile(r"^Garmin\s+(Forerunner\s*\d+)$")
_TCX_MISSING_SPACE = re.compile(r"^(Forerunner)(\d+)$")


def normalize_model(model: str) -> str:
    """Canonicalize a device model string, FIT code or TCX name alike.

    Unknown strings ("Allmän ANT-enhet", "Garmin Fitness Device" — generic
    placeholders, not real model names) are returned unchanged rather than
    guessed at.
    """
    if not model:
        return model
    if model in FIT_PRODUCT_NAMES:
        return FIT_PRODUCT_NAMES[model]

    stripped = _TCX_STRIP_GARMIN_PREFIX.sub(r"\1", model)
    spaced = _TCX_MISSING_SPACE.sub(r"\1 \2", stripped)
    return spaced


# -- generic-device filter ---------------------------------------------------
#
# Two placeholder names recur in the TCX Creator archive: "Allmän
# ANT-enhet" (28 Running files, 2011-11-09..2011-12-30, all the same
# UnitId — one real FR610 whose export path briefly failed to resolve a
# product name to text, not a device swap) and "Garmin Fitness Device"
# (2 files, 2006-05-24/25 — an early desktop-export default template,
# UnitId 0). Investigated 2026-09-24; product owner decision: filter,
# don't try to attribute them to a real model.
#
# Keyed on the literal <Name>, not <ProductID>: the first investigation
# assumed ProductID 1345 was exclusive to "Allmän ANT-enhet" and used it
# as the filter key, but 1345 turned out to be Forerunner 610's real,
# correctly-resolved product ID in 169 other files ("Garmin Forerunner
# 610") — filtering on it would have dropped those too. The name IS the
# generic part; that's what actually distinguishes the noise.
GENERIC_DEVICE_NAMES = frozenset({"Allmän ANT-enhet", "Garmin Fitness Device"})


def is_generic_device(name: str) -> bool:
    """True if name is a known placeholder, not a real device name."""
    return name in GENERIC_DEVICE_NAMES


def normalize_os_version(version: str) -> str:
    """Canonicalize a firmware/OS version string to its minimal numeric form.

    TCX builds versions as "{major}.{minor}" (e.g. "2.70", "13.0"); FIT
    reports a float directly (e.g. 3.3, 3.0). Both settle on the same
    minimal form here — trailing zeros dropped, a whole number written
    without a decimal point ("2.70" -> "2.7", "13.0" -> "13") — rather than
    a fixed two-decimal form: it's shorter, matches the FIT side's
    pre-existing convention (fit_scan's os_version already dropped ".0" for
    whole numbers before this normalization existed), and most importantly
    makes "2.70" (TCX) and "2.7" (a hand-entered --os-version) compare
    equal without the reader needing to know which source produced which.
    Non-numeric input (empty string, unparseable) is returned unchanged.
    """
    if not version:
        return version
    try:
        value = float(version)
    except ValueError:
        return version
    if value == int(value):
        return str(int(value))
    text = f"{value:.10f}".rstrip("0").rstrip(".")
    return text


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
