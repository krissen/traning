"""Read/write ``$TRANING_DATA/kristian/devices.csv``.

Schema (fixed, shared with the R side building against the same file):

    valid_from,platform,model,os_version,certainty,origin,note

- ``valid_from``: ``YYYY-MM-DD``, the date the device/OS version took effect.
- ``platform``: ``apple_watch`` | ``garmin``.
- ``model``, ``os_version``: free text, may be empty.
- ``certainty``: ``exact`` (derived from data) | ``known_since`` (manual;
  the change happened at or before an otherwise-unknown date).
- ``origin``: ``manual`` | ``fit`` (derived from the historical FIT
  archive) | ``tcx`` (derived from a TCX ``<Creator>`` element — the
  live Garmin fetch and the TCX archive scan).
- ``note``: free text.

One row = one change (a new model and/or a new OS version for a platform).
On disk the file is sorted newest first (``valid_from`` descending, ties
broken by ``platform`` ascending) so a human skimming the file sees the
current device state at the top.
"""

from __future__ import annotations

import csv
import os
from datetime import date
from pathlib import Path
from typing import TypedDict

FIELDS = ["valid_from", "platform", "model", "os_version", "certainty", "origin", "note"]

PLATFORMS = {"apple_watch", "garmin"}
CERTAINTIES = {"exact", "known_since"}
ORIGINS = {"manual", "fit", "tcx"}


class DeviceRow(TypedDict):
    valid_from: str
    platform: str
    model: str
    os_version: str
    certainty: str
    origin: str
    note: str


def devices_csv_path(data_dir: Path) -> Path:
    return Path(data_dir) / "kristian" / "devices.csv"


def validate_row(row: DeviceRow | dict) -> None:
    """Raise ValueError if ``row`` doesn't satisfy the schema."""
    missing = [f for f in FIELDS if f not in row]
    if missing:
        raise ValueError(f"device row missing fields: {missing} — {row}")

    try:
        date.fromisoformat(row["valid_from"])
    except (ValueError, TypeError) as e:
        raise ValueError(f"invalid valid_from {row['valid_from']!r}: {e}") from e

    if row["platform"] not in PLATFORMS:
        raise ValueError(f"invalid platform {row['platform']!r}, expected one of {PLATFORMS}")
    if row["certainty"] not in CERTAINTIES:
        raise ValueError(f"invalid certainty {row['certainty']!r}, expected one of {CERTAINTIES}")
    if row["origin"] not in ORIGINS:
        raise ValueError(f"invalid origin {row['origin']!r}, expected one of {ORIGINS}")


def _sort_rows(rows: list[DeviceRow]) -> list[DeviceRow]:
    """Sort newest first (valid_from desc), ties broken by platform asc.

    Two stable sorts, platform first: Python's sort is stable, so rows
    that tie on the later (primary) key keep the relative order the
    earlier sort gave them.
    """
    by_platform = sorted(rows, key=lambda r: r["platform"])
    return sorted(by_platform, key=lambda r: r["valid_from"], reverse=True)


def read_devices(data_dir: Path) -> list[DeviceRow]:
    """Read and validate devices.csv. Returns [] if the file doesn't exist yet."""
    path = devices_csv_path(data_dir)
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = [dict(r) for r in reader]
    for row in rows:
        validate_row(row)
    return rows  # type: ignore[return-value]


def write_devices(data_dir: Path, rows: list[DeviceRow]) -> None:
    """Validate and atomically write devices.csv (tmp file + os.replace)."""
    for row in rows:
        validate_row(row)

    path = devices_csv_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    with tmp.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        for row in _sort_rows(rows):
            writer.writerow(row)
    os.replace(tmp, path)


def _is_duplicate(rows: list[DeviceRow], platform: str, model: str, os_version: str) -> bool:
    """True if a row for this exact (platform, model, os_version) already exists.

    Dedup ignores ``valid_from`` — the same device/OS combination is only
    recorded once regardless of when it's re-encountered (e.g. a later FIT
    scan re-deriving a change that was already logged manually).
    """
    return any(
        r["platform"] == platform and r["model"] == model and r["os_version"] == os_version
        for r in rows
    )


def add_device(
    data_dir: Path,
    *,
    platform: str,
    model: str = "",
    os_version: str = "",
    valid_from: str | None = None,
    certainty: str = "known_since",
    origin: str = "manual",
    note: str = "",
) -> DeviceRow | None:
    """Append one device-change row to devices.csv.

    Returns the new row, or None if an identical (platform, model,
    os_version) row already exists (dedup — no row is written).
    """
    rows = read_devices(data_dir)
    if _is_duplicate(rows, platform, model, os_version):
        return None

    row: DeviceRow = {
        "valid_from": valid_from or date.today().isoformat(),
        "platform": platform,
        "model": model,
        "os_version": os_version,
        "certainty": certainty,
        "origin": origin,
        "note": note,
    }
    validate_row(row)
    rows.append(row)
    write_devices(data_dir, rows)
    return row


def add_devices_bulk(data_dir: Path, candidates: list[DeviceRow]) -> list[DeviceRow]:
    """Append multiple candidate rows in one write, skipping duplicates.

    Used by ``device scan-fit --apply``, where writing one row at a time
    would re-read/re-write the file once per candidate. Duplicates are
    checked both against the file on disk and against earlier candidates
    in this same batch.
    """
    rows = read_devices(data_dir)
    added: list[DeviceRow] = []
    for candidate in candidates:
        if _is_duplicate(rows, candidate["platform"], candidate["model"], candidate["os_version"]):
            continue
        validate_row(candidate)
        rows.append(candidate)
        added.append(candidate)
    if added:
        write_devices(data_dir, rows)
    return added
