"""Derive Apple Watch device-change candidates from a Health app export.

Health Auto Export's live feed (the one the ``traning fetch health`` /
``import health`` pipeline runs on) only ever sends ``sourceName`` — no
device identifier — so Apple Watch history can't be derived the way
``fit_scan``/``tcx_scan`` derive Garmin's (see ``docs/user/cli-reference.md``,
"Device log"). A full export from the iPhone Health app's own "Share All
Health Data" (``export.zip`` containing
``apple_health_export/export.xml``) does carry one: every ``<Record>``/
``<Workout>`` element has a ``device="<<HKDevice: ...>>"`` attribute with
``hardware:`` (e.g. ``Watch6,18``) and ``software:`` (e.g. ``10.1``)
fields for whichever device produced that sample.

The export is a manual, occasional one-off, not part of the automated
pipeline — expected to live at
``$TRANING_DATA/kristian/apple_health_export/export-<YYYY-MM-DD>.zip``,
gitignored (it's several GB uncompressed). ``traning device scan`` skips
this source with a message when no export is found there; every other
source still runs.

export.xml itself can be tens of millions of Record elements over a
multi-GB file — reading it whole, or even building one in-memory record
per element the way fit_scan/tcx_scan do per *file*, isn't an option.
Instead this reads it streaming, straight out of the zip
(``zipfile.ZipFile.open()`` handed to ``ET.iterparse``, clearing each
element right after use), and collapses on the fly: only the earliest
date seen for each (hardware, software) pair is kept, so memory is
bounded by the number of distinct device/firmware combinations in the
whole export (a handful), not the number of samples (tens of millions).
"""

from __future__ import annotations

import logging
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

from .common import (
    collapse_device_changes,
    normalize_os_version,
    normalize_watch_model,
    plausible_date,
)
from .log import DeviceRow

log = logging.getLogger(__name__)

EXPORT_XML_MEMBER_SUFFIX = "apple_health_export/export.xml"
WATCH_RECORD_TAGS = ("Record", "Workout")

# HealthKit's startDate/endDate/creationDate attributes are formatted
# "YYYY-MM-DD HH:MM:SS +HHMM" — local time plus an explicit offset, not
# UTC. datetime.strptime with %z parses the offset but leaves the
# hour/minute fields exactly as written; taking .date() of that value
# uses the local date as recorded, with no UTC conversion — which is
# what's wanted here (a device change is dated by the wall-clock day it
# happened on for the person wearing it, not by UTC's day boundary).
_DATE_FORMAT = "%Y-%m-%d %H:%M:%S %z"


@dataclass
class HealthKitDeviceRecord:
    path: Path
    activity_date: date
    model: str
    os_version: str


@dataclass
class HealthKitScanStats:
    export_path: Path | None = None
    elements_scanned: int = 0
    ok: int = 0
    skipped_no_device: int = 0
    skipped_non_watch: int = 0
    skipped_bad_date: int = 0
    bad_date_examples: list[str] = field(default_factory=list)
    groups: int = 0


def default_export_dir(data_dir: Path) -> Path:
    return Path(data_dir) / "kristian" / "apple_health_export"


def find_latest_export(export_dir: Path) -> Path | None:
    """Return the newest export-*.zip in export_dir, or None.

    Filenames sort correctly by name (``export-<YYYY-MM-DD>.zip``), so a
    plain lexical sort picks the newest without needing to stat mtimes.
    """
    if not export_dir.is_dir():
        return None
    candidates = sorted(export_dir.glob("export-*.zip"))
    return candidates[-1] if candidates else None


def _find_export_xml_member(zf: zipfile.ZipFile) -> str | None:
    for name in zf.namelist():
        if name.endswith(EXPORT_XML_MEMBER_SUFFIX):
            return name
    return None


def _parse_device_fields(device: str) -> tuple[str | None, str]:
    """Extract (hardware, software) out of a raw ``device="<<HKDevice: ...>>"``.

    The attribute is a free-text ``key:value`` list joined by ``", "``
    (comma-space) — split on that, not on a bare comma, because the
    hardware value itself contains one with no following space
    ("Watch6,18"); a bare-comma split (or a ``[^,>]+`` regex) would cut
    it off after "Watch6".

    ``hardware`` is None if the attribute has no ``hardware:`` field at
    all (e.g. an iPhone-only sample, or a sample with no device info).
    ``software`` defaults to "" — some records carry hardware without a
    software field.
    """
    hardware: str | None = None
    software = ""
    for part in device.strip().rstrip(">").split(", "):
        if part.startswith("hardware:"):
            hardware = part[len("hardware:") :].strip()
        elif part.startswith("software:"):
            software = part[len("software:") :].strip()
    return hardware, software


def _parse_local_date(value: str) -> date | None:
    try:
        return datetime.strptime(value, _DATE_FORMAT).date()
    except ValueError:
        return None


def scan_export(export_path: Path) -> tuple[list[HealthKitDeviceRecord], HealthKitScanStats]:
    """Stream export.xml out of export_path and collapse to per-device-change records.

    Raises if the zip or its export.xml member can't be opened/parsed —
    unlike fit_scan/tcx_scan's per-file scans, there's exactly one export
    file here, so a corrupt one is a real problem for the caller to
    surface, not something to silently count and skip.
    """
    stats = HealthKitScanStats(export_path=export_path)
    # (hardware, software) -> earliest activity_date seen for that pair.
    # Bounded by the number of distinct device/firmware combinations in
    # the whole export, not the number of samples.
    earliest: dict[tuple[str, str], date] = {}

    with zipfile.ZipFile(export_path) as zf:
        member = _find_export_xml_member(zf)
        if member is None:
            raise ValueError(f"{export_path}: no {EXPORT_XML_MEMBER_SUFFIX} member in export zip")

        with zf.open(member) as fh:
            for _event, elem in ET.iterparse(fh, events=("end",)):
                if elem.tag not in WATCH_RECORD_TAGS:
                    continue
                stats.elements_scanned += 1

                device = elem.get("device")
                start = elem.get("startDate")
                hardware = software = None
                if device:
                    hardware, software = _parse_device_fields(device)

                if not hardware:
                    stats.skipped_no_device += 1
                    elem.clear()
                    continue
                if not hardware.startswith("Watch"):
                    stats.skipped_non_watch += 1
                    elem.clear()
                    continue

                record_date = _parse_local_date(start) if start else None
                if record_date is None or not plausible_date(record_date):
                    stats.skipped_bad_date += 1
                    example = f"{start!r}  ({elem.tag}, {hardware})"
                    stats.bad_date_examples.append(example)
                    log.warning(
                        "Skipping unparseable/implausible startDate %r for %s in %s",
                        start,
                        hardware,
                        export_path,
                    )
                    elem.clear()
                    continue

                key = (hardware, software)
                if key not in earliest or record_date < earliest[key]:
                    earliest[key] = record_date
                stats.ok += 1
                elem.clear()

    stats.groups = len(earliest)
    records = [
        HealthKitDeviceRecord(
            path=export_path,
            activity_date=record_date,
            model=normalize_watch_model(hardware),
            os_version=normalize_os_version(software),
        )
        for (hardware, software), record_date in earliest.items()
    ]
    return records, stats


def collapse_changes(records: list[HealthKitDeviceRecord]) -> list[DeviceRow]:
    """Collapse per-(hardware, software) records into device-change candidates.

    See ``common.collapse_device_changes`` for the collapse rule. Records
    here already carry one entry per distinct (model, os_version), so
    this mostly just re-sorts by date and formats the row — the "collapse
    consecutive duplicates" part of the shared helper is a no-op unless
    normalization made two raw hardware/software pairs equal.
    """
    return collapse_device_changes(
        records, platform="apple_watch", origin="healthkit", note_prefix="healthkit-scan"
    )


def scan_and_collapse(
    data_dir: Path, export_path: Path | None = None
) -> tuple[list[DeviceRow], HealthKitScanStats | None]:
    """Scan the HealthKit export and return (candidate rows, scan stats).

    ``export_path`` overrides the default lookup (newest
    ``export-*.zip`` under ``default_export_dir(data_dir)``). Returns
    ``([], None)`` — not an empty-but-present stats object — when no
    export is found anywhere, so a caller can tell "no export available,
    source skipped" apart from "export scanned, found nothing".
    """
    if export_path is None:
        export_path = find_latest_export(default_export_dir(data_dir))
    if export_path is None or not export_path.is_file():
        return [], None

    records, stats = scan_export(export_path)
    return collapse_changes(records), stats
